import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// Gera o vídeo do mapa próprio para o painel. Com o iPhone desbloqueado usa o chip de vídeo
/// (10 quadros/s, liso); bloqueado, o iOS proíbe o chip, então codifica no processador (5 quadros/s).
final class MapStreamer {
    static let shared = MapStreamer()

    private let q = DispatchQueue(label: "tron.map", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var renderer: MapRenderer?
    private var hw: H264Encoder?
    private var sw: SoftEncoder?
    private var usingSoft = false
    private var hwBrokenAt = Date.distantPast
    private var forceKey = true
    private var tick = 0
    private var w = 800, h = 384
    private var panelActive = false
    private var previewActive = false
    private var lastLog = Date.distantPast
    private var sent = 0

    /// Entrega os quadros codificados (FrameHub manda ao painel).
    var onFrame: ((FrameHub.Frame) -> Void)?
    /// Prévia para a tela do app (~1 por segundo), na fila principal.
    var onPreview: ((CGImage) -> Void)?

    func startPanel(width: Int, height: Int) {
        q.async {
            if self.w != width || self.h != height || self.renderer == nil {
                self.w = width; self.h = height
                self.renderer = MapRenderer(width: width, height: height)
                self.hw = nil; self.sw = nil
            }
            self.panelActive = true
            self.forceKey = true
            Log.d("mapa próprio no painel (\(width)x\(height))")
            self.ensureTimer()
        }
    }

    func stopPanel() {
        q.async {
            guard self.panelActive else { return }
            self.panelActive = false
            self.hw?.invalidate(); self.hw = nil; self.sw = nil
            Log.d("mapa próprio parou de ir ao painel")
            self.ensureTimer()
        }
    }

    func setPreview(_ on: Bool) {
        q.async {
            self.previewActive = on
            if self.renderer == nil { self.renderer = MapRenderer(width: self.w, height: self.h) }
            self.ensureTimer()
        }
    }

    func requestKeyFrame() { q.async { self.forceKey = true } }

    private func ensureTimer() {
        let need = panelActive || previewActive
        if need && timer == nil {
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: 0.1)
            t.setEventHandler { [weak self] in self?.step() }
            t.resume()
            timer = t
        } else if !need, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    private func step() {
        tick += 1
        let foreground = AppForeground.isActive
        // bloqueado: metade dos quadros (o processador trabalha bem menos)
        if !foreground && tick % 2 != 0 { return }
        if !panelActive && tick % 5 != 0 { return } // só prévia: 2 por segundo
        guard let r = renderer else { return }
        let wantPreview = previewActive && tick % 10 == 0 && foreground
        guard let out = r.render(NavEngine.shared.snapshot(), makeImage: wantPreview) else { return }
        let (pb, img) = out
        if let img = img, let cb = onPreview { DispatchQueue.main.async { cb(img) } }
        guard panelActive else { return }

        let canHw = foreground && Date().timeIntervalSince(hwBrokenAt) > 3
        if canHw {
            if usingSoft { usingSoft = false; forceKey = true; Log.d("vídeo do mapa: chip de vídeo (tela ligada)") }
            if hw == nil || hw!.rebuildNeeded || hw!.width != w {
                hw?.invalidate()
                hw = H264Encoder(width: w, height: h, bitrate: 1_000_000, fps: 10)
                hw?.onFrame = { [weak self] data, key in self?.emit(data, key) }
                hw?.onError = { [weak self] msg in
                    self?.q.async { self?.hwBrokenAt = Date(); self?.hw = nil }
                    Log.d("vídeo do mapa: \(msg)")
                }
                forceKey = true
            }
            if forceKey { hw?.requestKeyFrame(); forceKey = false }
            hw?.encode(pb, pts: CMTime(value: CMTimeValue(tick), timescale: 10))
            if hw != nil { return }
        }
        // processador
        if !usingSoft { usingSoft = true; forceKey = true; Log.d("vídeo do mapa: processador (iPhone bloqueado)") }
        if sw == nil || sw!.width != w {
            sw = SoftEncoder(width: w, height: h, fps: 5, bitrate: 600_000)
            if sw == nil { Log.d("vídeo do mapa: não consegui criar o codificador em software"); return }
        }
        if let enc = sw!.encode(pb, forceKey: forceKey) {
            forceKey = false
            emit(enc.0, enc.1)
        }
    }

    private func emit(_ data: [UInt8], _ key: Bool) {
        onFrame?(FrameHub.Frame(data: data, key: key))
        sent += 1
        if Date().timeIntervalSince(lastLog) > 15 {
            Log.d("mapa: \(sent) quadros em 15 s (\(usingSoft ? "processador" : "chip de vídeo"))")
            sent = 0
            lastLog = Date()
        }
    }
}
