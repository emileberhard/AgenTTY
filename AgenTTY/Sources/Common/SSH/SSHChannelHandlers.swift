import Foundation
@unsafe @preconcurrency import NIOCore
@unsafe @preconcurrency import NIOSSH

nonisolated final class ShellChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let outputHandler: SSHClientSession.OutputHandler
    private var inboundPacketCount = 0

    init(outputHandler: @escaping SSHClientSession.OutputHandler) {
        self.outputHandler = outputHandler
    }

    func channelActive(context: ChannelHandlerContext) {
        EsmaLog.ssh.info("shell channel active")
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        EsmaLog.ssh.info("shell channel inactive")
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        inboundPacketCount += 1
        let packetBytes = packet.data.readableBytes
        if EsmaDiagnostics.shouldLog(counter: inboundPacketCount, defaultLimit: 10) {
            EsmaLog.ssh.info("inbound packet #\(self.inboundPacketCount) type=\(String(describing: packet.type), privacy: .public) bytes=\(packetBytes)")
        }

        guard case .byteBuffer(var buffer) = packet.data else {
            if EsmaDiagnostics.shouldLog(counter: inboundPacketCount, defaultLimit: 10) {
                EsmaLog.ssh.info("inbound packet #\(self.inboundPacketCount) ignored: non-byteBuffer payload")
            }
            return
        }

        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }

        outputHandler(Data(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            EsmaLog.ssh.info("shell exit status=\(exitStatus.exitStatus)")
        case ChannelEvent.inputClosed:
            EsmaLog.ssh.info("shell input closed by remote")
        default:
            EsmaLog.ssh.info("shell inbound event=\(String(describing: event), privacy: .public)")
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        EsmaLog.ssh.error("shell channel error: \(String(describing: error), privacy: .public)")
        context.close(promise: nil)
    }
}

nonisolated final class RootSSHDiagnosticsHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let failureRecorder: AgenTTYSSHFailureRecorder

    init(failureRecorder: AgenTTYSSHFailureRecorder) {
        self.failureRecorder = failureRecorder
    }

    func channelActive(context: ChannelHandlerContext) {
        EsmaLog.ssh.info("ssh root channel active")
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        EsmaLog.ssh.info("ssh root channel inactive")
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        EsmaLog.ssh.info("ssh root inbound event=\(String(describing: event), privacy: .public)")
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        EsmaLog.ssh.error("ssh root pipeline error: \(String(describing: error), privacy: .public)")

        if let outcome = AgenTTYSSHTransportFailureClassifier.outcome(for: error) {
            // Record the real cause before the server hangs up, otherwise the
            // close future fabricates a transient `.transportClosed` outcome and
            // the app reconnects into the same failed negotiation forever.
            failureRecorder.record(outcome)
            context.close(promise: nil)
            return
        }

        context.fireErrorCaught(error)
    }
}

nonisolated final class ExecCommandChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let maxCapturedOutputBytes = 1_048_576
    private var capturedOutputBytes: [UInt8] = []
    private(set) var didTruncateOutput = false
    private(set) var exitStatus: UInt32?

    var outputText: String {
        String(decoding: capturedOutputBytes, as: UTF8.self)
    }

    var outputPreview: String {
        outputText
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = packet.data else { return }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }

        if bytes.count >= maxCapturedOutputBytes {
            capturedOutputBytes = Array(bytes.suffix(maxCapturedOutputBytes))
            didTruncateOutput = true
            return
        }

        let totalBytes = capturedOutputBytes.count + bytes.count
        if totalBytes > maxCapturedOutputBytes {
            let overflow = totalBytes - maxCapturedOutputBytes
            if overflow > 0 {
                capturedOutputBytes.removeFirst(overflow)
            }
            didTruncateOutput = true
        }

        capturedOutputBytes.append(contentsOf: bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = UInt32(exit.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }
}
