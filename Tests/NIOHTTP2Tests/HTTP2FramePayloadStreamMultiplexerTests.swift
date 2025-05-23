//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import NIOHPACK  // for HPACKHeaders initializers
@testable import NIOHTTP2

extension Channel {
    /// Adds a simple no-op `HTTP2StreamMultiplexer` to the pipeline.
    fileprivate func addNoOpMultiplexer(mode: NIOHTTP2Handler.ParserMode) {
        XCTAssertNoThrow(
            try self.eventLoop.makeCompletedFuture {
                let mux = HTTP2StreamMultiplexer(mode: mode, channel: self) { channel in
                    self.eventLoop.makeSucceededFuture(())
                }
                try self.pipeline.syncOperations.addHandler(mux)
            }.wait()
        )
    }
}

private struct MyError: Error {}

/// A handler that asserts the frames received match the expected set.
internal final class FramePayloadExpecter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let expectedFrames: [HTTP2Frame.FramePayload]
    private var actualFrames: [HTTP2Frame.FramePayload] = []
    private var inactive = false

    init(expectedPayload: [HTTP2Frame.FramePayload]) {
        self.expectedFrames = expectedPayload
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTAssertFalse(self.inactive)
        let frame = self.unwrapInboundIn(data)
        self.actualFrames.append(frame)
    }

    func channelInactive(context: ChannelHandlerContext) {
        XCTAssertFalse(self.inactive)
        self.inactive = true

        XCTAssertEqual(self.expectedFrames.count, self.actualFrames.count)

        for (idx, expectedFrame) in self.expectedFrames.enumerated() {
            let actualFrame = self.actualFrames[idx]
            expectedFrame.assertFramePayloadMatches(this: actualFrame)
        }
    }
}

final class HTTP2FramePayloadStreamMultiplexerTests: XCTestCase {
    var channel: EmbeddedChannel!

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        self.channel = nil
    }

    private func activateStream(_ streamID: HTTP2StreamID) {
        let activated = NIOHTTP2StreamCreatedEvent(
            streamID: streamID,
            localInitialWindowSize: 16384,
            remoteInitialWindowSize: 16384
        )
        self.channel.pipeline.fireUserInboundEventTriggered(activated)
    }

    func testMultiplexerIgnoresFramesOnStream0() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        let simplePingFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .ping(HTTP2PingData(withInteger: 5), ack: false)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHeadersFramesCreateNewChannels() throws {
        let channelCount = ManagedAtomic<Int>(0)
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's send a bunch of headers frames.
        for streamID in stride(from: 1, to: 100, by: 2) {
            let frame = HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        XCTAssertEqual(channelCount.load(ordering: .sequentiallyConsistent), 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseThemselvesWhenToldTo() throws {
        let completedChannelCount = ManagedAtomic<Int>(0)
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channel.closeFuture.whenSuccess {
                completedChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
            }
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's send a bunch of headers frames with endStream on them. This should open some streams.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(
                streamID: streamID,
                payload: .headers(.init(headers: HPACKHeaders(), endStream: true))
            )
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }
        XCTAssertEqual(completedChannelCount.load(ordering: .sequentiallyConsistent), 0)

        // Now we send them all a clean exit.
        for streamID in streamIDs {
            let event = StreamClosedEvent(streamID: streamID, reason: nil)
            self.channel.pipeline.fireUserInboundEventTriggered(event)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage all the promises should be completed.
        XCTAssertEqual(completedChannelCount.load(ordering: .sequentiallyConsistent), 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterResetStreamFrameFirstThenEvent() throws {
        let errorEncounteredHandler = ErrorEncounteredHandler()
        let streamChannelClosed = NIOLockedValueBox(false)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            try? channel.pipeline.syncOperations.addHandler(errorEncounteredHandler)
            XCTAssertNil(errorEncounteredHandler.encounteredError)
            channel.closeFuture.whenSuccess {
                streamChannelClosed.withLockedValue { $0 = true }
            }
            return channel.pipeline.addHandler(
                FramePayloadExpecter(expectedPayload: [frame.payload, rstStreamFrame.payload])
            )
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)
        XCTAssertNil(errorEncounteredHandler.encounteredError)

        // Now we can send a RST_STREAM frame.
        XCTAssertNoThrow(try self.channel.writeInbound(rstStreamFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed, the appropriate error code should have been
        // fired down the pipeline.
        streamChannelClosed.withLockedValue { XCTAssertTrue($0) }
        XCTAssertEqual(
            errorEncounteredHandler.encounteredError as? NIOHTTP2Errors.StreamClosed,
            NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel)
        )
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterGoawayFrameFirstThenEvent() throws {
        let errorEncounteredHandler = ErrorEncounteredHandler()
        let streamChannelClosed = NIOLockedValueBox(false)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        let goAwayFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil)
        )

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            try? channel.pipeline.syncOperations.addHandler(errorEncounteredHandler)
            XCTAssertNil(errorEncounteredHandler.encounteredError)
            channel.closeFuture.whenSuccess {
                streamChannelClosed.withLockedValue { $0 = true }
            }
            // The channel won't see the goaway frame.
            return channel.pipeline.addHandler(FramePayloadExpecter(expectedPayload: [frame.payload]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)
        XCTAssertNil(errorEncounteredHandler.encounteredError)

        // Now we can send a GOAWAY frame. This will close the stream.
        XCTAssertNoThrow(try self.channel.writeInbound(goAwayFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .refusedStream)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed, the appropriate error code should have been
        // fired down the pipeline.
        streamChannelClosed.withLockedValue { XCTAssertTrue($0) }
        XCTAssertEqual(
            errorEncounteredHandler.encounteredError as? NIOHTTP2Errors.StreamClosed,
            NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .refusedStream)
        )
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesForUnknownStreamsAreReported() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let streamID = HTTP2StreamID(5)
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))

        XCTAssertThrowsError(try self.channel.writeInbound(dataFrame)) { error in
            XCTAssertEqual(streamID, (error as? NIOHTTP2Errors.NoSuchStream).map { $0.streamID })
        }

        self.channel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesForClosedStreamsAreReported() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        // We need to open the stream, then close it. A headers frame will open it, and then the closed event will close it.
        let streamID = HTTP2StreamID(5)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // Ok, now we can send a DATA frame for the now-closed stream.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))

        XCTAssertThrowsError(try self.channel.writeInbound(dataFrame)) { error in
            XCTAssertEqual(streamID, (error as? NIOHTTP2Errors.NoSuchStream).map { $0.streamID })
        }

        self.channel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosingIdleChannels() throws {
        let frameReceiver = FrameWriteRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's send a bunch of headers frames. These will all be answered by RST_STREAM frames.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
            self.activateStream(streamID)
        }

        let expectedFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .rstStream(.cancel)) }
        XCTAssertEqual(expectedFrames.count, frameReceiver.flushedWrites.count)
        for (idx, expectedFrame) in expectedFrames.enumerated() {
            let actualFrame = frameReceiver.flushedWrites[idx]
            expectedFrame.assertFrameMatches(this: actualFrame)
        }
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosingActiveChannels() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame.
        childChannel.close(promise: nil)
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosePromiseIsSatisfiedWithTheEvent() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        let closed = ManagedAtomic<Bool>(false)
        childChannel.close().whenComplete { _ in
            closed.store(true, ordering: .sequentiallyConsistent)
        }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))

        // Now send the stream closed event. This will satisfy the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultipleClosePromisesAreSatisfied() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(1)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it several times. This triggers one RST_STREAM frame. The channel will not be closed at this time.
        let firstClosed = ManagedAtomic<Bool>(false)
        let secondClosed = ManagedAtomic<Bool>(false)
        let thirdClosed = ManagedAtomic<Bool>(false)
        childChannel.close().whenComplete { _ in
            XCTAssertFalse(firstClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(secondClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(thirdClosed.load(ordering: .sequentiallyConsistent))
            firstClosed.store(true, ordering: .sequentiallyConsistent)
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(secondClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(thirdClosed.load(ordering: .sequentiallyConsistent))
            secondClosed.store(true, ordering: .sequentiallyConsistent)
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertTrue(secondClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(thirdClosed.load(ordering: .sequentiallyConsistent))
            thirdClosed.store(true, ordering: .sequentiallyConsistent)
        }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertFalse(thirdClosed.load(ordering: .sequentiallyConsistent))

        // Now send the stream closed event. This will satisfy the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertTrue(thirdClosed.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosePromiseSucceedsAndErrorIsFiredDownstream() throws {
        let frameReceiver = FrameWriteRecorder()
        let errorEncounteredHandler = ErrorEncounteredHandler()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelPromise.succeed(channel)
            try? channel.pipeline.syncOperations.addHandler(errorEncounteredHandler)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame.
        // Make sure the closeFuture is not failed (closing still succeeds).
        // The promise from calling close() should fail to provide the caller with diagnostics.
        childChannel.closeFuture.whenFailure { _ in
            XCTFail("The close promise should not be failed.")
        }
        childChannel.close().whenComplete { result in
            switch result {
            case .success:
                XCTFail("The close promise should have been failed.")
            case .failure(let error):
                XCTAssertTrue(error is NIOHTTP2Errors.StreamClosed)
            }
        }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertNil(errorEncounteredHandler.encounteredError)

        // Now send the stream closed event. This will fire the error down the pipeline.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertEqual(
            errorEncounteredHandler.encounteredError as? NIOHTTP2Errors.StreamClosed,
            NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel)
        )

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesAreNotDeliveredUntilStreamIsSetUp() throws {
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFramePayloadRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(1)

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).wait()
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Send a few data frames for this stream, which should also not go through.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Use a PING frame to check that the channel is still functioning.
        let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        XCTAssertNoThrow(try self.channel.writeInbound(ping))
        try self.channel.assertReceivedFrame().assertPingFrameMatches(this: ping)
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, complete the setup promise. This should trigger all the frames to be delivered.
        setupCompletePromise.succeed(())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertHeadersFramePayloadMatches(this: frame.payload)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFramePayloadMatches(this: dataFrame.payload)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesAreNotDeliveredIfSetUpFails() throws {
        let writeRecorder = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFramePayloadRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's send a headers frame to open the stream, along with some DATA frames.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).wait()
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, fail the setup promise. This should deliver a RST_STREAM frame, but not yet close the channel.
        // The channel should, however, be inactive.
        let channelClosed = ManagedAtomic<Bool>(false)
        childChannel.closeFuture.whenComplete { _ in channelClosed.store(true, ordering: .sequentiallyConsistent) }
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)
        XCTAssertFalse(channelClosed.load(ordering: .sequentiallyConsistent))

        setupCompletePromise.fail(MyError())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        // Even delivering a new DATA frame should do nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Now sending the stream closed event should complete the closure. All frames should be dropped. No new writes.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        XCTAssertFalse(channelClosed.load(ordering: .sequentiallyConsistent))

        (childChannel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(channelClosed.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testFlushingOneChannelDoesntFlushThemAll() async throws {
        let writeTracker = FrameWriteRecorder()
        let (channelsStream, channelsContinuation) = AsyncStream.makeStream(of: Channel.self)
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channelsContinuation.yield(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeTracker).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open two streams.
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(
                streamID: streamID,
                payload: .headers(.init(headers: HPACKHeaders(), endStream: true))
            )
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
            self.activateStream(streamID)
        }
        var streamChannelIterator = channelsStream.makeAsyncIterator()
        let firstStreamChannel = await streamChannelIterator.next()!
        let secondStreamChannel = await streamChannelIterator.next()!

        // We will now write a headers frame to each channel. Neither frame should be written to the connection. To verify this
        // we will flush the parent channel.
        for channel in [firstStreamChannel, secondStreamChannel] {
            let frame = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders()))
            channel.write(frame, promise: nil)
        }
        self.channel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 0)

        // Now we're going to flush only the first child channel. This should cause one flushed write.
        firstStreamChannel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 1)

        // Now the other.
        secondStreamChannel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testUnflushedWritesFailOnClose() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            childChannelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        let childChannel = try childChannelPromise.futureResult.wait()

        // We will now write a headers frame to the channel, but don't flush it.
        let writeError = NIOLockedValueBox<Error?>(nil)
        let responseFrame = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders()))
        childChannel.write(responseFrame).whenFailure { error in
            writeError.withLockedValue { writeError in
                writeError = error
            }
        }
        writeError.withLockedValue { writeError in
            XCTAssertNil(writeError)
        }

        // Now we're going to deliver a normal close to the stream.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        writeError.withLockedValue { writeError in
            XCTAssertEqual(writeError as? ChannelError, ChannelError.eof)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testUnflushedWritesFailOnError() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            childChannelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        let childChannel = try childChannelPromise.futureResult.wait()

        // We will now write a headers frame to the channel, but don't flush it.
        let writeError = NIOLockedValueBox<Error?>(nil)
        let responseFrame = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders()))
        childChannel.write(responseFrame).whenFailure { error in
            writeError.withLockedValue { writeError in
                writeError = error
            }
        }
        writeError.withLockedValue { writeError in
            XCTAssertNil(writeError)
        }

        // Now we're going to deliver a normal close to the stream.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        writeError.withLockedValue { writeError in
            XCTAssertEqual(
                writeError as? NIOHTTP2Errors.StreamClosed,
                NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel)
            )
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesFailOnClosedStreamChannels() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            childChannelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // Now let's close it.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        let childChannel = try childChannelPromise.futureResult.wait()

        // We will now write a headers frame to the channel. This should fail immediately.
        let writeError = NIOLockedValueBox<Error?>(nil)
        let responseFrame = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders()))
        childChannel.write(responseFrame).whenFailure { error in
            writeError.withLockedValue { writeError in
                writeError = error
            }
        }
        writeError.withLockedValue { writeError in
            XCTAssertEqual(writeError as? ChannelError, ChannelError.ioOnClosedChannel)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadPullsInAllFrames() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let frameRecorder = InboundFramePayloadRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) {
            channel -> EventLoopFuture<Void> in
            childChannelPromise.succeed(channel)

            // We're going to disable autoRead on this channel.
            return channel.getOption(ChannelOptions.autoRead).map {
                XCTAssertTrue($0)
            }.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: false)
            }.flatMap {
                channel.getOption(ChannelOptions.autoRead)
            }.map {
                XCTAssertFalse($0)
            }.flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(1)

        let childChannel = try childChannelPromise.futureResult.wait()

        // Now we're going to deliver 5 data frames for this stream.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        for _ in 0..<5 {
            let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // These frames should not have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // We'll call read() on the child channel.
        childChannel.read()

        // All frames should now have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertFramePayloadMatches(this: frame.payload)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFramePayload(endStream: false, payload: buffer)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testReadIsPerChannel() async throws {
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)

        // We don't have access to the streamID in the inbound stream initializer; we have to track
        // the expected ID here.
        let autoRead = ManagedAtomic<Bool>(false)

        let (channelsStream, channelsContinuation) = AsyncStream.makeStream(of: Channel.self)
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) {
            channel -> EventLoopFuture<Void> in
            channelsContinuation.yield(channel)
            // We'll disable auto read on the first channel only.
            let autoReadValue = autoRead.exchange(true, ordering: .sequentiallyConsistent)

            return channel.setOption(ChannelOptions.autoRead, value: autoReadValue).flatMap {
                channel.pipeline.addHandler(InboundFramePayloadRecorder())
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open two streams.
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
            self.activateStream(streamID)
        }
        var streamChannelIterator = channelsStream.makeAsyncIterator()
        let firstStreamChannel = await streamChannelIterator.next()!
        let secondStreamChannel = await streamChannelIterator.next()!

        // Stream 1 should not have received a frame, stream 3 should.
        try await firstStreamChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).map { recorder in
            XCTAssertEqual(recorder.receivedFrames.count, 0)
        }.get()
        try await secondStreamChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).map { recorder in
            XCTAssertEqual(recorder.receivedFrames.count, 1)
        }.get()

        // Deliver a DATA frame to each stream, which should also have gone into stream 3 but not stream 1.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        // Stream 1 should not have received a frame, stream 3 should.
        try await firstStreamChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).map { recorder in
            XCTAssertEqual(recorder.receivedFrames.count, 0)
        }.get()
        try await secondStreamChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).map { recorder in
            XCTAssertEqual(recorder.receivedFrames.count, 2)
        }.get()

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadWillCauseAutomaticFrameDelivery() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let frameRecorder = InboundFramePayloadRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) {
            channel -> EventLoopFuture<Void> in
            childChannelPromise.succeed(channel)

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        let childChannel = try childChannelPromise.futureResult.wait()

        XCTAssertNotNil(childChannel)

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Call read, the header frame will come through.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Call read again, nothing happens.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Now deliver a data frame.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        // Delivering another data frame does nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadWithNoPendingDataCausesReadOnParentChannel() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let readCounter = ReadCounter()
        let frameRecorder = InboundFramePayloadRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) {
            channel -> EventLoopFuture<Void> in
            childChannelPromise.succeed(channel)

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(readCounter).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        let childChannel = try childChannelPromise.futureResult.wait()

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // There should be no calls to read.
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 0)
        }

        // Call read, the header frame will come through. No calls to read on the parent stream.
        childChannel.read()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 0)
        }

        // Call read again, read is called on the parent stream. No frames delivered.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 1)
        }

        // Now deliver a data frame.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered. No extra call to read.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 1)
        }

        // Another call to read issues a read to the parent stream.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        // Another call to read, this time does not issue a read to the parent stream.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        // Delivering two more frames does not cause another call to read, and only one frame
        // is delivered.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHandlersAreRemovedOnClosure() throws {
        let handlerRemoved = ManagedAtomic<Bool>(false)
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in
            handlerRemoved.store(true, ordering: .sequentiallyConsistent)
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channel.pipeline.addHandler(HandlerRemovedHandler(removedPromise: handlerRemovedPromise))
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved.load(ordering: .sequentiallyConsistent))

        // Now we send the channel a clean exit.
        let event = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(event)
        XCTAssertFalse(handlerRemoved.load(ordering: .sequentiallyConsistent))

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHandlersAreRemovedOnClosureWithError() throws {
        let handlerRemoved = ManagedAtomic<Bool>(false)
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in
            handlerRemoved.store(true, ordering: .sequentiallyConsistent)
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channel.pipeline.addHandler(HandlerRemovedHandler(removedPromise: handlerRemovedPromise))
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved.load(ordering: .sequentiallyConsistent))

        // Now we send the channel a clean exit.
        let event = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(event)
        XCTAssertFalse(handlerRemoved.load(ordering: .sequentiallyConsistent))

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatingOutboundChannel() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let createdChannelCount = ManagedAtomic<Int>(0)
        let configuredChannelCount = ManagedAtomic<Int>(0)
        let streamIDs = NIOLockedValueBox([HTTP2StreamID]())
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { channel in
                createdChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { channel in
                configuredChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                // Write some headers: the flush will trigger a stream ID to be assigned to the channel.
                channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: [:]))).whenSuccess {
                    channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { streamID in
                        streamIDs.withLockedValue { streamIDs in
                            streamIDs.append(streamID)
                        }
                    }
                }
            }
        }

        // Run the loop to create the channels.
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 0)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs.count, 0)
        }

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 3)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs, [2, 4, 6].map { HTTP2StreamID($0) })
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatingOutboundChannelClient() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let createdChannelCount = ManagedAtomic<Int>(0)
        let configuredChannelCount = ManagedAtomic<Int>(0)
        let streamIDs = NIOLockedValueBox([HTTP2StreamID]())
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { channel in
                createdChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { channel in
                configuredChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                // Write some headers: the flush will trigger a stream ID to be assigned to the channel.
                channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: [:]))).whenSuccess {
                    channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { streamID in
                        streamIDs.withLockedValue { streamIDs in
                            streamIDs.append(streamID)
                        }
                    }
                }
            }
        }

        // Run the loop to create the channels.
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 0)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs.count, 0)
        }

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 3)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesOnCreatedChannelAreDelayed() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannelPromise.succeed(channel)
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        let childChannel = try childChannelPromise.futureResult.wait()
        childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders())), promise: nil)

        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        configurePromise.succeed(())
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesAreCancelledOnFailingInitializer() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannelPromise.succeed(channel)
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        let childChannel = try childChannelPromise.futureResult.wait()

        let writeError = NIOLockedValueBox<Error?>(nil)
        childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders()))).whenFailure {
            error in
            writeError.withLockedValue { writeError in
                writeError = error
            }
        }
        writeError.withLockedValue { writeError in
            XCTAssertNil(writeError)
        }

        configurePromise.fail(MyError())

        writeError.withLockedValue { writeError in
            XCTAssertNotNil(writeError)
            XCTAssertTrue(writeError is MyError)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFailingInitializerDoesNotWrite() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        multiplexer.createStreamChannel(promise: nil) { channel in
            configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        configurePromise.fail(MyError())
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelDoesNotActivateEarly() throws {
        let activated = ManagedAtomic<Bool>(false)

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        activePromise.futureResult.map {
            activated.store(true, ordering: .sequentiallyConsistent)
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        multiplexer.createStreamChannel(promise: nil) { channel in
            let activeRecorder = ActiveHandler(activatedPromise: activePromise)
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertFalse(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelActivatesIfParentIsActive() throws {
        let activated = ManagedAtomic<Bool>(false)

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        activePromise.futureResult.map {
            activated.store(true, ordering: .sequentiallyConsistent)
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8765)).wait())
        XCTAssertFalse(activated.load(ordering: .sequentiallyConsistent))

        multiplexer.createStreamChannel(promise: nil) { channel in
            let activeRecorder = ActiveHandler(activatedPromise: activePromise)
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testInitiatedChildChannelActivates() throws {
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let activated = ManagedAtomic<Bool>(false)

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        activePromise.futureResult.map {
            activated.store(true, ordering: .sequentiallyConsistent)
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            let activeRecorder = ActiveHandler(activatedPromise: activePromise)
            return channel.pipeline.addHandler(activeRecorder)
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        self.channel.pipeline.fireChannelActive()

        // Open a new stream.
        XCTAssertFalse(activated.load(ordering: .sequentiallyConsistent))
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultiplexerIgnoresPriorityFrames() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        let simplePingFrame = HTTP2Frame(
            streamID: 106,
            payload: .priority(.init(exclusive: true, dependency: .rootStream, weight: 15))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultiplexerForwardsActiveToParent() throws {
        self.channel.addNoOpMultiplexer(mode: .client)

        let activated = ManagedAtomic<Bool>(false)

        let activePromise = self.channel.eventLoop.makePromise(of: Void.self)
        activePromise.futureResult.whenSuccess {
            activated.store(true, ordering: .sequentiallyConsistent)
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(ActiveHandler(activatedPromise: activePromise)).wait())
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/nothing")).wait())
        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelCanBeClosedImmediately() throws {
        let closed = ManagedAtomic<Bool>(false)

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        multiplexer.createStreamChannel(promise: nil) { channel in
            channel.close().whenComplete { _ in
                closed.store(true, ordering: .sequentiallyConsistent)
            }
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testCreatedChildChannelCanBeClosedBeforeWritingHeaders() throws {
        let closed = ManagedAtomic<Bool>(false)

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: channelPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let child = try assertNoThrowWithValue(channelPromise.futureResult.wait())
        child.closeFuture.whenComplete { _ in
            closed.store(true, ordering: .sequentiallyConsistent)
        }

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        child.close(promise: nil)
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testCreatedChildChannelCanBeClosedImmediatelyWhenBaseIsActive() throws {
        let closed = ManagedAtomic<Bool>(false)

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        multiplexer.createStreamChannel(promise: nil) { channel in
            channel.close().whenComplete { _ in
                closed.store(true, ordering: .sequentiallyConsistent)
            }
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testCreatedChildChannelCanBeClosedBeforeWritingHeadersWhenBaseIsActive() throws {
        let closed = ManagedAtomic<Bool>(false)

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: channelPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let child = try assertNoThrowWithValue(channelPromise.futureResult.wait())
        child.closeFuture.whenComplete { _ in
            closed.store(true, ordering: .sequentiallyConsistent)
        }

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        child.close(promise: nil)
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testMultiplexerCoalescesFlushCallsDuringChannelRead() throws {
        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Add a flush counter.
        let flushCounter = FlushCounter()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(flushCounter).wait())

        // Add a server-mode multiplexer that will add an auto-response handler.
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channel.pipeline.addHandler(QuickFramePayloadResponseHandler())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We're going to send in 10 request frames.
        let requestHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        XCTAssertEqual(flushCounter.flushCount, 0)
        let framesToSend = stride(from: 1, through: 19, by: 2).map {
            HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(.init(headers: requestHeaders, endStream: true)))
        }
        for frame in framesToSend {
            self.channel.pipeline.fireChannelRead(frame)
        }
        self.channel.embeddedEventLoop.run()

        // Response frames should have been written, but no flushes, so they aren't visible.
        XCTAssertEqual(try self.channel.sentFrames().count, 0)
        XCTAssertEqual(flushCounter.flushCount, 0)

        // Now send channel read complete. The frames should be flushed through.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(try self.channel.sentFrames().count, 10)
        XCTAssertEqual(flushCounter.flushCount, 1)
    }

    func testMultiplexerDoesntFireReadCompleteForEachFrame() {
        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let frameRecorder = InboundFramePayloadRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { childChannel in
            childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 0)
        }

        // Wake up and activate the stream.
        let requestHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let requestFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: requestHeaders, endStream: false)))
        self.channel.pipeline.fireChannelRead(requestFrame)
        self.activateStream(1)
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 1)
        }

        // Now we're going to send 9 data frames.
        var requestData = self.channel.allocator.buffer(capacity: 1024)
        requestData.writeBytes("Hello world!".utf8)
        let dataFrames = repeatElement(
            HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(requestData), endStream: false))),
            count: 9
        )

        for frame in dataFrames {
            self.channel.pipeline.fireChannelRead(frame)
        }

        // We should have 1 read (the HEADERS), and one read complete.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 1)
        }

        // Fire read complete on the parent and it'll propagate to the child. This will trigger the reads.
        self.channel.pipeline.fireChannelReadComplete()

        // We should have 10 reads, and two read completes.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 2)
        }

        // If we fire a new read complete on the parent, the child doesn't see it this time, as it received no frames.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 2)
        }
    }

    func testMultiplexerCorrectlyTellsAllStreamsAboutReadComplete() {
        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // These are deliberately getting inserted to all streams. The test above confirms the single-stream
        // behaviour is correct.
        let frameRecorder = InboundFramePayloadRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { childChannel in
            childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 0)
        }

        // Wake up and activate the streams.
        let requestHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])

        for streamID in [HTTP2StreamID(1), HTTP2StreamID(3), HTTP2StreamID(5)] {
            let requestFrame = HTTP2Frame(
                streamID: streamID,
                payload: .headers(.init(headers: requestHeaders, endStream: false))
            )
            self.channel.pipeline.fireChannelRead(requestFrame)
            self.activateStream(streamID)
        }
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 3)
        }

        // Firing in readComplete does not cause a second readComplete for each stream, as no frames were delivered.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 3)
        }

        // Now we're going to send a data frame on stream 1.
        var requestData = self.channel.allocator.buffer(capacity: 1024)
        requestData.writeBytes("Hello world!".utf8)
        let frame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(requestData), endStream: false)))
        self.channel.pipeline.fireChannelRead(frame)

        // We should have 3 reads, and 3 read completes. The frame is not delivered as we have no frame fast-path.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 3)
        }

        // Fire read complete on the parent and it'll propagate to the child, but only to the one
        // that saw a frame.
        self.channel.pipeline.fireChannelReadComplete()

        // We should have 4 reads, and 4 read completes.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 4)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 4)
        }

        // If we fire a new read complete on the parent, the children don't see it.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 4)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 4)
        }
    }

    func testMultiplexerModifiesStreamChannelWritabilityBasedOnFixedSizeTokens() throws {
        let multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: self.channel,
            outboundBufferSizeHighWatermark: 100,
            outboundBufferSizeLowWatermark: 50
        ) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))

        var dataBuffer = childChannel.allocator.buffer(capacity: 90)
        dataBuffer.writeBytes(repeatElement(0, count: 90))
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(headersPayload, promise: nil)
        childChannel.write(dataPayload, promise: nil)
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write another 20 byte DATA frame (20 bytes). This should flip the channel writability.
        dataBuffer = childChannel.allocator.buffer(capacity: 20)
        dataBuffer.writeBytes(repeatElement(0, count: 20))
        let secondDataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(secondDataPayload, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now we're going to send another HEADERS frame (for trailers). This should not affect the channel writability.
        let trailers = HPACKHeaders([])
        let trailersFrame = HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true))
        childChannel.write(trailersFrame, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now we flush the writes. This flips the writability again.
        childChannel.flush()
        XCTAssertTrue(childChannel.isWritable)
    }

    func testMultiplexerModifiesStreamChannelWritabilityBasedOnParentChannelWritability() throws {
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a few new child streams.
        let promises = (0..<5).map { _ in self.channel.eventLoop.makePromise(of: Channel.self) }
        for promise in promises {
            multiplexer.createStreamChannel(promise: promise) { childChannel in
                childChannel.eventLoop.makeSucceededFuture(())
            }
        }
        self.channel.embeddedEventLoop.run()

        let channels = try assertNoThrowWithValue(promises.map { promise in try promise.futureResult.wait() })

        // These are all writable.
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])

        // We need to write (and flush) some data so that the streams get stream IDs.
        for childChannel in channels {
            XCTAssertNoThrow(
                try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: [:]))).wait()
            )
        }

        // Mark the parent channel not writable. This currently changes nothing.
        self.channel.isWritable = false
        self.channel.pipeline.fireChannelWritabilityChanged()
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])

        // Now activate each channel. As we do, we'll see its writability state change.
        for childChannel in channels {
            let streamID = try assertNoThrowWithValue(childChannel.getOption(HTTP2StreamChannelOptions.streamID).wait())
            self.activateStream(streamID)
            XCTAssertFalse(childChannel.isWritable, "Channel \(streamID) is incorrectly writable")
        }

        // All are now non-writable.
        XCTAssertEqual(channels.map { $0.isWritable }, [false, false, false, false, false])

        // And back again.
        self.channel.isWritable = true
        self.channel.pipeline.fireChannelWritabilityChanged()
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])
    }

    func testMultiplexerModifiesStreamChannelWritabilityBasedOnFixedSizeTokensAndChannelWritability() throws {
        let multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: self.channel,
            outboundBufferSizeHighWatermark: 100,
            outboundBufferSizeLowWatermark: 50
        ) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        // We need to write (and flush) some data so that the streams get stream IDs.
        XCTAssertNoThrow(try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: [:]))).wait())

        self.activateStream(1)
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))

        var dataBuffer = childChannel.allocator.buffer(capacity: 90)
        dataBuffer.writeBytes(repeatElement(0, count: 90))
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(headersPayload, promise: nil)
        childChannel.write(dataPayload, promise: nil)
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write another 20 byte DATA frame (20 bytes). This should flip the channel writability.
        dataBuffer = childChannel.allocator.buffer(capacity: 20)
        dataBuffer.writeBytes(repeatElement(0, count: 20))
        let secondDataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(secondDataPayload, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now we're going to send another HEADERS frame (for trailers). This should not affect the channel writability.
        let trailers = HPACKHeaders([])
        let trailersPayload = HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true))
        childChannel.write(trailersPayload, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now mark the channel not writable.
        self.channel.isWritable = false
        self.channel.pipeline.fireChannelWritabilityChanged()

        // Now we flush the writes. The channel remains not writable.
        childChannel.flush()
        XCTAssertFalse(childChannel.isWritable)

        // Now we mark the parent channel writable. This flips the writability state.
        self.channel.isWritable = true
        self.channel.pipeline.fireChannelWritabilityChanged()
        XCTAssertTrue(childChannel.isWritable)
    }

    func testStreamChannelToleratesFailingInitializer() {
        struct DummyError: Error {}
        let multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: self.channel,
            outboundBufferSizeHighWatermark: 100,
            outboundBufferSizeLowWatermark: 50
        ) { channel in
            XCTFail("Must not be called")
            return channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            childChannel.close().flatMap {
                childChannel.eventLoop.makeFailedFuture(DummyError())
            }
        }
        self.channel.embeddedEventLoop.run()
    }

    func testInboundChannelWindowSizeIsCustomisable() throws {
        let targetWindowSize = 1 << 18

        let multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: self.channel,
            targetWindowSize: targetWindowSize
        ) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }

        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5)).wait())

        // Ok, create an inbound channel.
        let frame = HTTP2Frame(streamID: HTTP2StreamID(1), payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // Now claim that the window got consumed. Nothing happens.
        XCTAssertNoThrow(try XCTAssertNil(self.channel.readOutbound(as: HTTP2Frame.self)))
        var windowEvent = NIOHTTP2WindowUpdatedEvent(
            streamID: 1,
            inboundWindowSize: (targetWindowSize / 2) + 1,
            outboundWindowSize: nil
        )
        channel.pipeline.fireUserInboundEventTriggered(windowEvent)
        XCTAssertNoThrow(try XCTAssertNil(self.channel.readOutbound(as: HTTP2Frame.self)))

        // Consume the last byte.
        windowEvent = NIOHTTP2WindowUpdatedEvent(
            streamID: 1,
            inboundWindowSize: (targetWindowSize / 2),
            outboundWindowSize: nil
        )
        channel.pipeline.fireUserInboundEventTriggered(windowEvent)
        guard let receivedFrame = try assertNoThrowWithValue(self.channel.readOutbound(as: HTTP2Frame.self)) else {
            XCTFail("No frame received")
            return
        }

        receivedFrame.assertWindowUpdateFrame(streamID: 1, windowIncrement: targetWindowSize / 2)
        XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: false))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWeCanCreateFrameAndPayloadBasedStreamsOnAMultiplexer() throws {
        let frameRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(frameRecorder))

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel, inboundStreamInitializer: nil)
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Create a payload based stream.
        let streamAPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamAPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        let streamA = try assertNoThrowWithValue(try streamAPromise.futureResult.wait())
        // We haven't written on the stream yet: it shouldn't have a stream ID.
        XCTAssertThrowsError(try streamA.getOption(HTTP2StreamChannelOptions.streamID).wait()) { error in
            XCTAssert(error is NIOHTTP2Errors.NoStreamIDAvailable)
        }

        // Create a frame based stream.
        let streamBPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamBPromise) { channel, streamID in
            // stream A doesn't have an ID yet.
            XCTAssertEqual(streamID, HTTP2StreamID(1))
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        let streamB = try assertNoThrowWithValue(try streamBPromise.futureResult.wait())

        // Do some writes on A and B.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))

        // (We checked the streamID above.)
        XCTAssertNoThrow(try streamB.writeAndFlush(HTTP2Frame(streamID: 1, payload: headersPayload)).wait())

        // Write on stream A.
        XCTAssertNoThrow(try streamA.writeAndFlush(headersPayload).wait())
        // Stream A must have an ID now.
        XCTAssertEqual(try streamA.getOption(HTTP2StreamChannelOptions.streamID).wait(), HTTP2StreamID(3))

        frameRecorder.flushedWrites.assertFramesMatch([
            HTTP2Frame(streamID: 1, payload: headersPayload),
            HTTP2Frame(streamID: 3, payload: headersPayload),
        ])
    }

    func testReadWhenUsingAutoreadOnChildChannel() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let readCounter = ReadCounter()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) {
            channel -> EventLoopFuture<Void> in
            childChannelPromise.succeed(channel)

            // We're going to _enable_ autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: true).flatMap {
                channel.pipeline.addHandler(readCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        _ = try childChannelPromise.futureResult.wait()

        // There should be two calls to read: the first, when the stream was activated, the second after the HEADERS
        // frame was delivered.
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        // Now deliver a data frame.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered, _and_ a call to read should have happened.
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 3)
        }

        // Delivering two more frames causes two more calls to read.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 5)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWindowUpdateIsNotEmittedAfterStreamIsClosed() throws {
        let targetWindowSize = 1024
        let multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: self.channel,
            targetWindowSize: targetWindowSize
        ) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Write a headers frame.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let headersFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers)))
        self.channel.pipeline.fireChannelRead(headersFrame)

        // Activate the stream.
        self.activateStream(1)

        // Send a window updated event.
        let windowUpdated = NIOHTTP2WindowUpdatedEvent(streamID: 1, inboundWindowSize: 128, outboundWindowSize: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(windowUpdated)
        self.channel.pipeline.fireChannelReadComplete()

        // We expect the a WINDOW_UPDATE frame: our inbound window size is 128 but has a target of 1024.
        let frame = try assertNoThrowWithValue(try self.channel.readOutbound(as: HTTP2Frame.self))!
        frame.assertWindowUpdateFrame(streamID: 1, windowIncrement: 896)

        // The inbound window size should now be our target: 1024. Write enough bytes to consume the
        // inbound window.
        let data = HTTP2Frame.FramePayload.data(
            .init(data: .byteBuffer(.init(repeating: 0, count: targetWindowSize + 1)))
        )
        let dataFrame = HTTP2Frame(streamID: 1, payload: data)
        self.channel.pipeline.fireChannelRead(dataFrame)

        self.channel.pipeline.fireUserInboundEventTriggered(StreamClosedEvent(streamID: 1, reason: nil))
        self.channel.pipeline.fireChannelReadComplete()

        // We've consumed the inbound window: normally we'd expect a WINDOW_UPDATE frame but since
        // the stream has closed we don't expect to read anything out.
        XCTAssertNil(try self.channel.readOutbound(as: HTTP2Frame.self))
    }

    func testWindowUpdateIsNotEmittedAfterStreamIsClosedEvenOnLaterFrame() throws {
        let targetWindowSize = 128
        let multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: self.channel,
            targetWindowSize: targetWindowSize
        ) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Write a headers frame.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let headersFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers)))
        self.channel.pipeline.fireChannelRead(headersFrame)

        // Activate the stream.
        self.activateStream(1)

        // Send a window updated event.
        var windowUpdated = NIOHTTP2WindowUpdatedEvent(streamID: 1, inboundWindowSize: 128, outboundWindowSize: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(windowUpdated)
        self.channel.pipeline.fireChannelReadComplete()

        // The inbound window size should now be our target: 128. Write enough bytes to consume the
        // inbound window as two frames: a 127-byte frame, followed by a 1-byte with END_STREAM set.
        let bytes = ByteBuffer(repeating: 0, count: targetWindowSize)
        let firstData = HTTP2Frame.FramePayload.data(
            .init(data: .byteBuffer(bytes.getSlice(at: bytes.readerIndex, length: targetWindowSize - 1)!))
        )
        let secondData = HTTP2Frame.FramePayload.data(
            .init(data: .byteBuffer(bytes.getSlice(at: bytes.readerIndex, length: 1)!), endStream: true)
        )
        let firstDataFrame = HTTP2Frame(streamID: 1, payload: firstData)
        let secondDataFrame = HTTP2Frame(streamID: 1, payload: secondData)

        self.channel.pipeline.fireChannelRead(firstDataFrame)
        windowUpdated = NIOHTTP2WindowUpdatedEvent(streamID: 1, inboundWindowSize: 1, outboundWindowSize: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(windowUpdated)

        self.channel.pipeline.fireChannelRead(secondDataFrame)
        // This is nil here for a reason: it reflects what would actually be sent in the real code. Relevantly, the nil currently
        // does not actually propagate into the handler, which matters a lot.
        windowUpdated = NIOHTTP2WindowUpdatedEvent(streamID: 1, inboundWindowSize: nil, outboundWindowSize: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(windowUpdated)

        self.channel.pipeline.fireChannelReadComplete()

        // We've consumed the inbound window: normally we'd expect a WINDOW_UPDATE frame but since
        // the stream has closed we don't expect to read anything out.
        XCTAssertNil(try self.channel.readOutbound(as: HTTP2Frame.self))
    }

    func testStreamChannelSupportsSyncOptions() throws {
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            XCTAssert(channel is HTTP2StreamChannel)
            if let sync = channel.syncOptions {
                do {
                    let streamID = try sync.getOption(HTTP2StreamChannelOptions.streamID)
                    XCTAssertEqual(streamID, HTTP2StreamID(1))

                    let autoRead = try sync.getOption(ChannelOptions.autoRead)
                    try sync.setOption(ChannelOptions.autoRead, value: !autoRead)
                    XCTAssertNotEqual(autoRead, try sync.getOption(ChannelOptions.autoRead))
                } catch {
                    XCTFail("Missing StreamID")
                }
            } else {
                XCTFail("syncOptions was nil but should be supported for HTTP2StreamChannel")
            }

            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        let frame = HTTP2Frame(streamID: HTTP2StreamID(1), payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
    }

    func testStreamErrorIsDeliveredToChannel() throws {
        let goodHeaders = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])
        var badHeaders = goodHeaders
        badHeaders.add(name: "transfer-encoding", value: "chunked")

        let multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: self.channel
        ) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now create two child channels with error recording handlers in them. Save one, ignore the other.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannelPromise.succeed(channel)
            return channel.pipeline.addHandler(ErrorRecorder())
        }

        let secondChildChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: nil) { channel in
            secondChildChannelPromise.succeed(channel)
            // For this one we'll do a write immediately, to bring it into existence and give it a stream ID.
            channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: goodHeaders)), promise: nil)
            return channel.pipeline.addHandler(ErrorRecorder())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try childChannelPromise.futureResult.wait()
        try childChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(errors.count, 0)
            }
        }.wait()
        let secondChildChannel = try secondChildChannelPromise.futureResult.wait()
        try secondChildChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(errors.count, 0)
            }
        }.wait()

        // On this child channel, write and flush an invalid headers frame.
        childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: badHeaders)), promise: nil)

        // Now, synthetically deliver the stream error that should have been produced.
        self.channel.pipeline.fireErrorCaught(
            NIOHTTP2Errors.streamError(
                streamID: 3,
                baseError: NIOHTTP2Errors.forbiddenHeaderField(name: "transfer-encoding", value: "chunked")
            )
        )

        // It should come through to the channel.
        try childChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(
                    errors.first.flatMap { $0 as? NIOHTTP2Errors.ForbiddenHeaderField },
                    NIOHTTP2Errors.forbiddenHeaderField(name: "transfer-encoding", value: "chunked")
                )
            }
        }.wait()
        try secondChildChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(errors.count, 0)
            }
        }.wait()

        // Simulate closing the child channel in response to the error.
        childChannel.close(promise: nil)

        self.channel.embeddedEventLoop.run()

        // Only the HEADERS frames should have been written: we closed before the other channel became active, so
        // it should not have triggered an RST_STREAM frame.
        let frames = try self.channel.sentFrames()
        XCTAssertEqual(frames.count, 2)

        frames[0].assertHeadersFrame(endStream: false, streamID: 1, headers: goodHeaders, priority: nil, type: .request)
        frames[1].assertHeadersFrame(
            endStream: false,
            streamID: 3,
            headers: badHeaders,
            priority: nil,
            type: .doNotValidate
        )
    }

    func testPendingReadsAreFlushedEvenWithoutUnsatisfiedReadOnChannelInactive() throws {
        let goodHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost"),
        ])

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { channel in
            XCTFail("Server push is unexpected")
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(multiplexer))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now create two child channels with error recording handlers in them. Save one, ignore the other.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannelPromise.succeed(channel)
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ReadAndFrameConsumer())
            }
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try childChannelPromise.futureResult.wait()

        let streamID = HTTP2StreamID(1)

        let payload = HTTP2Frame.FramePayload.Headers(headers: goodHeaders, endStream: true)
        XCTAssertNoThrow(try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(payload)).wait())

        let frames = try self.channel.sentFrames()
        XCTAssertEqual(frames.count, 1)
        frames.first?.assertHeadersFrameMatches(this: HTTP2Frame(streamID: streamID, payload: .headers(payload)))

        let channel: EmbeddedChannel = self.channel!
        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).flatMapThrowing { consumer in
            XCTAssertEqual(consumer.readCount, 1)

            // 1. pass header onwards
            let responseHeaderPayload = HTTP2Frame.FramePayload.headers(.init(headers: [":status": "200"]))
            XCTAssertNoThrow(try channel.writeInbound(HTTP2Frame(streamID: streamID, payload: responseHeaderPayload)))

            XCTAssertEqual(consumer.receivedFrames.count, 1)
            XCTAssertEqual(consumer.readCompleteCount, 1)
            XCTAssertEqual(consumer.readCount, 2)

            consumer.forwardRead = false
        }.wait()

        // 2. pass body onwards
        let responseBody1 = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(.init(string: "foo"))))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTP2Frame(streamID: streamID, payload: responseBody1)))

        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).flatMapThrowing { consumer in
            XCTAssertEqual(consumer.receivedFrames.count, 2)
            XCTAssertEqual(consumer.readCompleteCount, 2)
            XCTAssertEqual(consumer.readCount, 3)
            XCTAssertEqual(consumer.readPending, true)
        }.wait()

        // 3. pass on more body - should not change a thing, since read is pending in consumer

        let responseBody2 = HTTP2Frame.FramePayload.data(
            .init(data: .byteBuffer(.init(string: "bar")), endStream: true)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(HTTP2Frame(streamID: streamID, payload: responseBody2)))

        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).flatMapThrowing { consumer in
            XCTAssertEqual(consumer.receivedFrames.count, 2)
            XCTAssertEqual(consumer.readCompleteCount, 2)
            XCTAssertEqual(consumer.readCount, 3)
            XCTAssertEqual(consumer.readPending, true)

            XCTAssertEqual(consumer.channelInactiveCount, 0)
        }.wait()

        // 4. signal stream is closed – this should force forward all pending frames
        self.channel.pipeline.fireUserInboundEventTriggered(StreamClosedEvent(streamID: streamID, reason: nil))

        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).flatMapThrowing { consumer in
            XCTAssertEqual(consumer.receivedFrames.count, 3)
            XCTAssertEqual(consumer.readCompleteCount, 3)
            XCTAssertEqual(consumer.readCount, 3)
            XCTAssertEqual(consumer.channelInactiveCount, 1)
            XCTAssertEqual(consumer.readPending, true)
        }.wait()
    }
}

final class ErrorRecorder: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    let errors = NIOLockedValueBox<[Error]>([])

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errors.withLockedValue { errors in
            errors.append(error)
        }
        context.fireErrorCaught(error)
    }
}

private final class ReadAndFrameConsumer: ChannelInboundHandler, ChannelOutboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundIn = HTTP2Frame.FramePayload

    private(set) var receivedFrames: [HTTP2Frame.FramePayload] = []
    private(set) var readCount = 0
    private(set) var readCompleteCount = 0
    private(set) var channelInactiveCount = 0
    private(set) var readPending = false

    var forwardRead = true {
        didSet {
            if self.forwardRead, self.readPending {
                self.context.read()
                self.readPending = false
            }
        }
    }

    var context: ChannelHandlerContext!

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.receivedFrames.append(self.unwrapInboundIn(data))
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.readCompleteCount += 1
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.channelInactiveCount += 1
        context.fireChannelInactive()
    }

    func read(context: ChannelHandlerContext) {
        self.readCount += 1
        if forwardRead {
            context.read()
            self.readPending = false
        } else {
            self.readPending = true
        }
    }
}

final class UserInboundEventRecorder: ChannelInboundHandler {
    typealias InboundIn = Any

    private let receivedEvents: NIOLockedValueBox<[Any]>

    var events: [Any] {
        self.receivedEvents.withLockedValue { $0 }
    }

    init() {
        self.receivedEvents = NIOLockedValueBox([])
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self.receivedEvents.withLockedValue { $0.append(event) }
        context.fireUserInboundEventTriggered(event)
    }
}
