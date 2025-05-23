//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix

final class Bench1Conn10kRequests: Benchmark {
    var group: MultiThreadedEventLoopGroup!
    var server: Channel!
    var client: Channel!

    func setUp() throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.server = try setupServer(group: self.group)
        self.client = try setupClient(group: self.group, address: self.server.localAddress!)
    }

    func tearDown() {
        try! self.client.close().wait()
        try! self.server.close().wait()
        try! self.group.syncShutdownGracefully()
        self.group = nil
    }

    func run() throws -> Int {
        var bodyByteCount = 0
        for _ in 0..<10_000 {
            bodyByteCount += try sendOneRequest(channel: self.client)
        }
        return bodyByteCount
    }
}

func setupServer(group: EventLoopGroup) throws -> Channel {
    let bootstrap = ServerBootstrap(group: group)
        // Specify backlog and enable SO_REUSEADDR for the server itself
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

        // Set the handlers that are applied to the accepted Channels
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let sync = channel.pipeline.syncOperations
                let _ = try sync.configureHTTP2Pipeline(
                    mode: .server,
                    connectionConfiguration: .init(),
                    streamConfiguration: .init()
                ) { streamChannel -> EventLoopFuture<Void> in
                    streamChannel.eventLoop.makeCompletedFuture {
                        let sync = streamChannel.pipeline.syncOperations
                        try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                        try sync.addHandler(HTTP1TestServer())
                        try sync.addHandler(ErrorHandler())
                    }
                }

                try sync.addHandler(ErrorHandler())
            }
        }

        // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
        .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

    return try bootstrap.bind(host: "127.0.0.1", port: 12345).wait()
}

func sendOneRequest(channel: Channel) throws -> Int {
    let responseReceivedPromise = channel.eventLoop.makePromise(of: Int.self)

    channel.pipeline.handler(type: HTTP2StreamMultiplexer.self).whenSuccess { multiplexer in
        multiplexer.createStreamChannel(promise: nil) { streamChannel in
            streamChannel.eventLoop.makeCompletedFuture {
                let sync = streamChannel.pipeline.syncOperations
                try sync.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))

                let requestHandler = SendRequestHandler(
                    host: "127.0.0.1",
                    request: .init(
                        version: .init(major: 2, minor: 0),
                        method: .GET,
                        uri: "/",
                        headers: ["host": "localhost"]
                    ),
                    responseReceivedPromise: responseReceivedPromise
                )
                try sync.addHandler(requestHandler)
                try sync.addHandler(ErrorHandler())
            }
        }
    }

    return try responseReceivedPromise.futureResult.wait()
}

func setupClient(
    group: EventLoopGroup,
    address: SocketAddress
) throws -> Channel {
    try ClientBootstrap(group: group)
        .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ErrorHandler())
            }
        }
        .connect(to: address).flatMap { channel in
            channel.configureHTTP2Pipeline(mode: .client, position: .first) { channel in
                channel.eventLoop.makeSucceededFuture(())
            }.map { _ in channel }
        }.wait()
}

final class HTTP1TestServer: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = self.unwrapInboundIn(data) else {
            return
        }

        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)

        // Insert an event loop tick here. This more accurately represents real workloads in SwiftNIO, which will not
        // re-entrantly write their response frames.
        let channel = context.channel
        context.eventLoop.execute {
            channel.getOption(HTTP2StreamChannelOptions.streamID).flatMap { (streamID) -> EventLoopFuture<Void> in
                var headers = HTTPHeaders()
                headers.add(name: "content-length", value: "5")
                headers.add(name: "x-stream-id", value: String(Int(streamID)))
                channel.write(
                    HTTPServerResponsePart.head(
                        HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok, headers: headers)
                    ),
                    promise: nil
                )

                var buffer = channel.allocator.buffer(capacity: 12)
                buffer.writeStaticString("hello")
                channel.write(
                    HTTPServerResponsePart.body(.byteBuffer(buffer)),
                    promise: nil
                )
                return channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            }.whenComplete { _ in
                loopBoundContext.value.close(promise: nil)
            }
        }
    }
}

final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Never

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Server received error: \(error)")
        context.close(promise: nil)
    }
}

final class SendRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let responseReceivedPromise: EventLoopPromise<Int>
    private let host: String
    private let request: HTTPRequestHead
    private var bytesReceived: Int = 0

    init(host: String, request: HTTPRequestHead, responseReceivedPromise: EventLoopPromise<Int>) {
        self.responseReceivedPromise = responseReceivedPromise
        self.host = host
        self.request = request
    }

    func channelActive(context: ChannelHandlerContext) {
        assert(context.channel.parent!.isActive)
        context.write(self.wrapOutboundOut(.head(self.request)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let resPart = self.unwrapInboundIn(data)
        if case .body(let buffer) = resPart {
            self.bytesReceived += buffer.readableBytes
        }
        if case .end = resPart {
            self.responseReceivedPromise.succeed(self.bytesReceived)
        }
    }
}
