import ReplayKit
import CoreMedia
import VideoToolbox
import QuartzCore

/// Extensão de transmissão de tela: o iOS entrega aqui a tela inteira do iPhone (com o Waze ou
/// qualquer app aberto). A gente reduz para o tamanho do painel, codifica em H.264 e manda para o
/// app Tron Racing, que repassa ao painel da moto.
final class SampleHandler: RPBroadcastSampleHandler {

    private let work = DispatchQueue(label: "tron.broadcast.work")
    private let net = DispatchQueue(label: "tron.broadcast.net")
    private var socket: TCPSocket?
    private var settings = FrameLink.Settings()
    private var scaler: FrameScaler?
    private var encoder: H264Encoder?
    private var running = false
    private var busy = false
    private var queued = 0
    private let queuedLock = NSLock()
    private var lastOut: CVPixelBuffer?
    private var lastEncodeAt = CFAbsoluteTimeGetCurrent()
    private var lastAcceptAt: CFAbsoluteTime = 0
    private var repeatTimer: DispatchSourceTimer?
    private var pending = 0 // mensagens na fila de envio
    private let pendingLock = NSLock()
    private var sentFrames = 0
    private var lastStats = CFAbsoluteTimeGetCurrent()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        running = true
        connectLoop()
        // A ReplayKit só manda quadro quando a tela muda. O painel fecha o vídeo se ficar sem
        // quadro; então a cada 100 ms sem novidade repetimos o último.
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.repeatIfIdle() }
        t.resume()
        repeatTimer = t
    }

    override func broadcastPaused() {}
    override func broadcastResumed() { work.async { self.encoder?.requestKeyFrame() } }

    override func broadcastFinished() {
        running = false
        repeatTimer?.cancel()
        repeatTimer = nil
        socket?.close()
        work.sync {
            encoder?.invalidate()
            encoder = nil
            scaler = nil
            lastOut = nil
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, running, socket != nil else { return }
        // no máximo ~30 quadros/s, e descarta se o anterior ainda está sendo processado (memória)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAcceptAt < 1.0 / 25.0 { return } // ~24 quadros/s bastam para o mapa
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        queuedLock.lock()
        if queued >= 2 { queuedLock.unlock(); return } // o anterior ainda está sendo processado
        queued += 1
        queuedLock.unlock()
        lastAcceptAt = now
        work.async { [weak self] in
            guard let self = self else { return }
            self.busy = true
            self.handle(pb, orientation: orientation)
            self.busy = false
            self.queuedLock.lock(); self.queued -= 1; self.queuedLock.unlock()
        }
    }

    // ------------------------------------------------------------------ vídeo

    private func handle(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let s = settings
        if scaler == nil || scaler!.width != s.w || scaler!.height != s.h {
            scaler = FrameScaler(width: s.w, height: s.h)
            makeEncoder()
        }
        guard let out = scaler?.process(pb, orientation: orientation, fill: s.fill, flip: s.flip) else { return }
        lastOut = out
        encode(out)
    }

    private func repeatIfIdle() {
        guard running, let out = lastOut, !busy else { return }
        if CFAbsoluteTimeGetCurrent() - lastEncodeAt >= 0.1 { encode(out) }
    }

    private func encode(_ pb: CVPixelBuffer) {
        if encoder == nil || encoder!.rebuildNeeded { makeEncoder() }
        lastEncodeAt = CFAbsoluteTimeGetCurrent()
        encoder?.encode(pb, pts: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600))
    }

    private func makeEncoder() {
        encoder?.invalidate()
        let s = settings
        guard let e = H264Encoder(width: s.w, height: s.h, bitrate: s.bitrate, fps: 24) else {
            log("não consegui criar o codificador \(s.w)x\(s.h)")
            encoder = nil
            return
        }
        e.onFrame = { [weak self] data, key in self?.send(key ? FrameLink.keyFrame : FrameLink.frame, data) }
        e.onError = { [weak self] msg in self?.log(msg) }
        e.requestKeyFrame()
        encoder = e
        log("codificador \(s.w)x\(s.h) @ \(s.bitrate / 1000) kbps")
    }

    // ------------------------------------------------------------------ conexão com o app

    private func connectLoop() {
        Thread.detachNewThread { [weak self] in
            while let me = self, me.running {
                do {
                    let s = try TCPSocket.connect(host: FrameLink.host, port: FrameLink.port, timeout: 2)
                    me.socket = s
                    let hello = "{\"ext\":1}".data(using: .utf8)!
                    try s.write(FrameLink.pack(FrameLink.hello, [UInt8](hello)))
                    me.readLoop(s)
                } catch {
                    // app fechado? tenta de novo
                }
                me.socket = nil
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func readLoop(_ s: TCPSocket) {
        while running {
            guard let msg = try? FrameLink.read(s) else { break }
            let (type, body) = msg
            switch type {
            case FrameLink.settings:
                if let st = try? JSONDecoder().decode(FrameLink.Settings.self, from: Data(body)) {
                    work.async {
                        let changed = st.w != self.settings.w || st.h != self.settings.h || st.bitrate != self.settings.bitrate
                        self.settings = st
                        if changed { self.scaler = nil } // recria no próximo quadro
                        self.encoder?.requestKeyFrame()
                    }
                }
            case FrameLink.wantKey:
                work.async { self.encoder?.requestKeyFrame() }
            default: break
            }
        }
        s.close()
    }

    private func send(_ type: UInt8, _ body: [UInt8]) {
        guard let s = socket else { return }
        pendingLock.lock()
        // app não está dando conta (Wi-Fi lento): joga fora e recomeça num quadro-chave
        if pending > 6 && type == FrameLink.frame {
            pendingLock.unlock()
            work.async { self.encoder?.requestKeyFrame() }
            return
        }
        pending += 1
        pendingLock.unlock()
        let msg = FrameLink.pack(type, body)
        net.async {
            try? s.write(msg)
            self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock()
            if type != FrameLink.log {
                self.sentFrames += 1
                let now = CFAbsoluteTimeGetCurrent()
                if now - self.lastStats > 10 {
                    self.log("extensão: \(self.sentFrames) quadros em 10 s")
                    self.sentFrames = 0
                    self.lastStats = now
                }
            }
        }
    }

    private func log(_ text: String) {
        send(FrameLink.log, [UInt8](text.utf8))
    }
}
