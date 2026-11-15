import Foundation
import CoreVideo
import CoreMedia
import UIKit

/// Recebe o vídeo já codificado da extensão de transmissão (a tela com o Waze) e guarda para o
/// painel buscar. Sem transmissão, gera uma tela de espera neon pedindo para iniciar o espelhamento.
final class FrameHub: ObservableObject {
    static let shared = FrameHub()

    struct Frame { let data: [UInt8]; let key: Bool }

    @Published private(set) var mirroring = false
    @Published private(set) var framesPerSec = 0

    let frames = BlockingQueue<Frame>(capacity: 90)
    private var server: TCPServer?
    private var ext: TCPSocket?
    private let lock = NSLock()
    private var settings: FrameLink.Settings
    private var counter = 0
    private var counterAt = Date()

    // tela de espera
    private var standbyEncoder: H264Encoder?
    private var standbyTimer: DispatchSourceTimer?
    private let standbyQueue = DispatchQueue(label: "tron.standby")
    private var wanted = false // o painel está pedindo vídeo?

    private init() {
        var s = FrameLink.Settings()
        s.fill = UserDefaults.standard.bool(forKey: "fill")
        s.flip = UserDefaults.standard.bool(forKey: "flip")
        settings = s
    }

    var currentSettings: FrameLink.Settings { lock.lock(); defer { lock.unlock() }; return settings }

    /// Abre a porta local que a extensão usa. Chamar uma vez, ao abrir o app.
    func startListening() {
        guard server == nil else { return }
        do {
            let srv = try TCPServer(port: FrameLink.port, bindIP: FrameLink.host)
            server = srv
            Thread.detachNewThread { [weak self] in
                while let s = srv.accept() {
                    self?.handleExtension(s)
                }
            }
        } catch {
            Log.d("espelhamento: não consegui abrir a porta local \(FrameLink.port): \(error)")
        }
    }

    private func handleExtension(_ s: TCPSocket) {
        lock.lock()
        ext?.close()
        ext = s
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            Log.d("espelhamento: transmissão de tela conectada")
            DispatchQueue.main.async { self.mirroring = true }
            self.stopStandby()
            self.frames.clear()
            self.pushSettings()
            while true {
                guard let msg = try? FrameLink.read(s) else { break }
                let (type, body) = msg
                switch type {
                case FrameLink.keyFrame, FrameLink.frame:
                    self.push(Frame(data: body, key: type == FrameLink.keyFrame))
                case FrameLink.log:
                    Log.d("[transmissão] " + String(decoding: body, as: UTF8.self))
                default: break
                }
            }
            s.close()
            self.lock.lock()
            let current = self.ext === s
            if current { self.ext = nil }
            self.lock.unlock()
            if current {
                Log.d("espelhamento: transmissão de tela parou")
                DispatchQueue.main.async { self.mirroring = false }
                self.frames.clear()
                if self.wanted { self.startStandby() }
            }
        }
    }

    private func push(_ f: Frame) {
        if !frames.offer(f) {
            // painel parou de consumir: recomeça num quadro-chave
            frames.clear()
            requestKeyFrame()
        }
        counter += 1
        let now = Date()
        if now.timeIntervalSince(counterAt) >= 1 {
            let c = counter
            counter = 0
            counterAt = now
            DispatchQueue.main.async { self.framesPerSec = c }
        }
    }

    // ------------------------------------------------------------------ comandos

    func update(_ change: (inout FrameLink.Settings) -> Void) {
        lock.lock()
        change(&settings)
        let s = settings
        lock.unlock()
        UserDefaults.standard.set(s.fill, forKey: "fill")
        UserDefaults.standard.set(s.flip, forKey: "flip")
        pushSettings()
    }

    private func pushSettings() {
        lock.lock()
        let s = settings, e = ext
        lock.unlock()
        guard let e = e, let json = try? JSONEncoder().encode(s) else { return }
        try? e.write(FrameLink.pack(FrameLink.settings, [UInt8](json)))
    }

    func requestKeyFrame() {
        lock.lock(); let e = ext; lock.unlock()
        if let e = e { try? e.write(FrameLink.pack(FrameLink.wantKey, [])) }
        else { standbyQueue.async { self.standbyEncoder?.requestKeyFrame() } }
    }

    /// O painel abriu o vídeo e disse o tamanho/bitrate que quer.
    func panelWantsVideo(width: Int, height: Int, bitrate: Int) {
        wanted = true
        update { $0.w = width; $0.h = height; $0.bitrate = min(bitrate, 3_000_000) }
        lock.lock(); let hasExt = ext != nil; lock.unlock()
        if !hasExt { startStandby() }
        requestKeyFrame()
    }

    func panelStoppedVideo() {
        wanted = false
        stopStandby()
    }

    // ------------------------------------------------------------------ tela de espera

    private func startStandby() {
        standbyQueue.async {
            guard self.standbyTimer == nil else { return }
            let s = self.currentSettings
            self.standbyEncoder = H264Encoder(width: s.w, height: s.h, bitrate: 1_000_000, fps: 5)
            self.standbyEncoder?.onFrame = { [weak self] data, key in self?.push(Frame(data: data, key: key)) }
            self.standbyEncoder?.onError = { msg in Log.d("tela de espera: \(msg)") }
            let t = DispatchSource.makeTimerSource(queue: self.standbyQueue)
            t.schedule(deadline: .now(), repeating: 0.2)
            var n = 0
            t.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.standbyEncoder?.rebuildNeeded == true {
                    self.standbyEncoder = H264Encoder(width: s.w, height: s.h, bitrate: 1_000_000, fps: 5)
                    self.standbyEncoder?.onFrame = { [weak self] data, key in self?.push(Frame(data: data, key: key)) }
                }
                if n % 5 == 0 { self.standbyEncoder?.requestKeyFrame() }
                if let pb = StandbyArt.render(width: s.w, height: s.h, tick: n) {
                    self.standbyEncoder?.encode(pb, pts: CMTime(value: CMTimeValue(n), timescale: 5))
                }
                n += 1
            }
            t.resume()
            self.standbyTimer = t
            Log.d("tela de espera no painel (inicie o espelhamento para ver o Waze)")
        }
    }

    private func stopStandby() {
        standbyQueue.async {
            self.standbyTimer?.cancel()
            self.standbyTimer = nil
            self.standbyEncoder?.invalidate()
            self.standbyEncoder = nil
        }
    }
}

/// Desenho da tela de espera no painel: grade neon e o nome do app.
enum StandbyArt {
    static func render(width: Int, height: Int, tick: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // o CGContext desenha de baixo para cima; vira para desenhar como no UIKit
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let w = CGFloat(width), h = CGFloat(height)
        Tron.drawBackdrop(in: ctx, size: CGSize(width: w, height: h), phase: CGFloat(tick % 20) / 20)

        let title = NSAttributedString(string: "TRON RACING", attributes: [
            .font: UIFont.systemFont(ofSize: h * 0.13, weight: .black),
            .foregroundColor: Tron.cyanUI,
            .kern: h * 0.02,
        ])
        let ts = title.size()
        ctx.setShadow(offset: .zero, blur: 18, color: Tron.cyanUI.cgColor)
        title.draw(at: CGPoint(x: (w - ts.width) / 2, y: h * 0.28))
        let pulse = 0.55 + 0.45 * abs(sin(Double(tick) / 4))
        let sub = NSAttributedString(string: "Abra o Waze e toque em ESPELHAR no app", attributes: [
            .font: UIFont.systemFont(ofSize: h * 0.055, weight: .semibold),
            .foregroundColor: Tron.orangeUI.withAlphaComponent(CGFloat(pulse)),
        ])
        let ss = sub.size()
        ctx.setShadow(offset: .zero, blur: 10, color: Tron.orangeUI.cgColor)
        sub.draw(at: CGPoint(x: (w - ss.width) / 2, y: h * 0.52))
        return buf
    }
}
