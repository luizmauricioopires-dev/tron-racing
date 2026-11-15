import Foundation

/// Canais de vídeo do painel (formato do MotoNav, modo "painel novo"/estendido).
///
/// Porta 10921 (controle), cabeçalho de 8 bytes LE: [UInt16 cmd][UInt16 tamanho][Int32 0] + corpo
///   0x10 pedido de config (800x480, H.264...)  -> 0x11 [Int32 2=H.264][UInt16 w][UInt16 h][byte estendido]
///   0x40 sinal de vida -> 0x41;  0x60 estado da tela -> 0x61;  0x70 iniciar vídeo -> 0x71
/// Porta 10920 (dados): o painel manda 0x72 (~30x/s) pedindo o próximo quadro.
///   resposta: [Int32 4+tamanho][Int32 índice][AUD + quadro]  (ou 00 00 00 00 sem quadro novo)
final class RvServer {
    static let reqConfig: UInt16 = 0x10, rlyConfig: UInt16 = 0x11
    static let reqHeartbeat: UInt16 = 0x40, rlyHeartbeat: UInt16 = 0x41
    static let reqScreenConf: UInt16 = 0x60, rlyScreenConf: UInt16 = 0x61
    static let reqDataStart: UInt16 = 0x70, rlyDataStart: UInt16 = 0x71
    static let reqDataNext: UInt16 = 0x72
    static let rlyUnsupported: UInt16 = 0x7F02
    private static let viewState = [UInt8]("{\"viewAreaConfig\":{\"state\":0},\"supportFunction\":0}".utf8)
    private static let aud: [UInt8] = [0, 0, 0, 1, 9, 0xF0]

    private let lock = NSLock()
    private var _lastPollAt = Date.distantPast
    var lastPollAt: Date { lock.lock(); defer { lock.unlock() }; return _lastPollAt }

    private var width = 800, height = 480, bitrate = 2_500_000, extByte: UInt8 = 1

    // ------------------------------------------------------------------ 10921

    func handleCtrl(_ s: TCPSocket) throws {
        while true {
            let (cmd, body) = try readCmd(s)
            switch cmd {
            case RvServer.reqConfig:
                parseConfig(body)
                var reply = [UInt8]()
                reply.appendLE32(2) // 2 = H.264
                reply.appendLE16(UInt16(width))
                reply.appendLE16(UInt16(height))
                reply.append(extByte)
                try writeCmd(s, RvServer.rlyConfig, reply)
                Log.d("RV -> config aceita: H.264 \(width)x\(height) (estendido \(extByte))")
                FrameHub.shared.panelWantsVideo(width: width, height: height, bitrate: bitrate)
            case RvServer.reqScreenConf:
                try writeCmd(s, RvServer.rlyScreenConf, RvServer.viewState)
                Log.d("RV <- estado da tela: \(Pxc.preview(body, max: 200))")
            case RvServer.reqHeartbeat:
                try writeCmd(s, RvServer.rlyHeartbeat)
            case RvServer.reqDataStart:
                try writeCmd(s, RvServer.rlyDataStart)
                FrameHub.shared.requestKeyFrame()
                Log.d("RV -> início do vídeo confirmado")
            default:
                Log.d(String(format: "RV <- comando não tratado 0x%04X (%d bytes)", cmd, body.count))
                try writeCmd(s, RvServer.rlyUnsupported)
            }
        }
    }

    private func parseConfig(_ b: [UInt8]) {
        guard b.count >= 24 else { Log.d("RV <- config curta (\(b.count) bytes): \(b.hex)"); return }
        width = Int(b.le16(0)); height = Int(b.le16(2))
        let fps = b.le32(4), enc = b.le32(8), codec = b.le32(12)
        let br = Int(b.le32(20))
        if br > 0 { bitrate = min(br, 3_000_000) }
        // o codificador trabalha em blocos de 16 pixels
        if width & 0xFFF0 >= 16 { width &= 0xFFF0 }
        if height & 0xFFF0 >= 16 { height &= 0xFFF0 }
        extByte = b.count >= 30 ? b[29] : 1
        Log.d("RV <- config: \(width)x\(height) fps=\(fps) encoder=\(enc) codec=\(codec) bitrate=\(br)")
    }

    // ------------------------------------------------------------------ 10920

    func handleData(_ s: TCPSocket) throws {
        let hub = FrameHub.shared
        hub.requestKeyFrame()
        var waitingKey = true
        var index: Int32 = 0
        var sent = 0, bytes = 0
        var lastReport = Date()
        let zero: [UInt8] = [0, 0, 0, 0]
        var polls = 0, empty = 0
        var lastPoll = CFAbsoluteTimeGetCurrent()
        var maxGap = 0.0
        while true {
            let (cmd, _) = try readCmd(s)
            lock.lock(); _lastPollAt = Date(); lock.unlock()
            let nowPoll = CFAbsoluteTimeGetCurrent()
            maxGap = max(maxGap, nowPoll - lastPoll)
            lastPoll = nowPoll
            polls += 1
            if cmd != RvServer.reqDataNext {
                Log.d(String(format: "RV-DATA <- comando inesperado 0x%04X", cmd))
                continue
            }
            var frame = hub.frames.poll(timeout: 0.025)
            // só começa a mandar a partir de um quadro-chave
            while let f = frame, waitingKey, !f.key { frame = hub.frames.pollNow() }
            guard let f = frame else { empty += 1; try s.write(zero); continue }
            if f.key { waitingKey = false }
            let au = RvServer.aud + f.data
            var pkt = [UInt8]()
            pkt.reserveCapacity(8 + au.count)
            pkt.appendLE32(Int32(4 + au.count))
            pkt.appendLE32(index)
            pkt += au
            index = (index &+ 1) & 0x7FFFFFFF
            // pedaços de 4 KB, como o MotoNav / ZC-Panel
            var off = 0
            while off < pkt.count {
                let end = min(off + 4096, pkt.count)
                try s.write(Array(pkt[off..<end]))
                off = end
                if off < pkt.count { usleep(2000) }
            }
            sent += 1; bytes += pkt.count
            if Date().timeIntervalSince(lastReport) > 5 {
                Log.d("RV -> \(sent) quadros (\(bytes / 1024) KB) em 5 s; painel pediu \(polls)x (\(empty) sem quadro), maior espera \(Int(maxGap * 1000)) ms")
                sent = 0; bytes = 0; lastReport = Date(); polls = 0; empty = 0; maxGap = 0
            }
        }
    }

    // ------------------------------------------------------------------ utilidades

    private func readCmd(_ s: TCPSocket) throws -> (UInt16, [UInt8]) {
        let h = try s.readFully(8)
        let cmd = h.le16(0), len = Int(h.le16(2))
        return (cmd, try s.readFully(len))
    }

    private func writeCmd(_ s: TCPSocket, _ cmd: UInt16, _ body: [UInt8] = []) throws {
        var out = [UInt8]()
        out.appendLE16(cmd); out.appendLE16(UInt16(body.count)); out.appendLE32(0)
        out += body
        try s.write(out)
    }
}
