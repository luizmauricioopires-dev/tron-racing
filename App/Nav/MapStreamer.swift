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
            t.schedule(deadline: .now(), repeating: 0.01)
            t.setEventHandler { [weak self] in self?.step() }
            t.resume()
            timer = t
        } else if !need, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    private var lastFrameAt = Date.distantPast
    private var renderMs = 0.0, encodeMs = 0.0, measured = 0, waits = 0
    private var lastFg: Bool?

    /// Sempre o codificador do processador: assim o vídeo não muda de formato quando o iPhone
    /// bloqueia ou desbloqueia (essa troca no meio da transmissão travava o painel).
    /// Quadro sob demanda: só desenha um novo quando o painel já levou o anterior (ou pede e não
    /// há nenhum pronto). Assim o painel sempre recebe o mapa "de agora", sem fila atrasada.
    /// O painel pediu quadro e não havia nenhum pronto: desenha já.
    func kick() { q.async { self.step(kicked: true) } }

    private func step(kicked: Bool = false) {
        tick += 1
        let foreground = AppForeground.isActive
        if lastFg != foreground {
            lastFg = foreground
            if panelActive { Log.d("mapa: \(foreground ? "tela ligada" : "iPhone bloqueado") (quadro sob demanda)") }
        }
        let now = Date()
        let interval = panelActive ? (foreground ? 0.05 : 0.1) : 0.5
        if now.timeIntervalSince(lastFrameAt) < interval - 0.01 { return }
        // já tem um quadro esperando o painel: não desenha outro (ele ficaria velho na fila)
        if panelActive && FrameHub.shared.backlog >= 1 && !forceKey { if !kicked { waits += 1 }; return }
        lastFrameAt = now
        guard let r = renderer else { return }
        let wantPreview = previewActive && foreground && tick % 20 == 0
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let out = r.render(NavEngine.shared.snapshot(), makeImage: wantPreview) else { return }
        renderMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let (pb, img) = out
        if let img = img, let cb = onPreview { DispatchQueue.main.async { cb(img) } }
        guard panelActive else { return }
        if sw == nil || sw!.width != w {
            sw = SoftEncoder(width: w, height: h, fps: 10, bitrate: 600_000)
            forceKey = true
            if sw == nil { Log.d("vídeo do mapa: não consegui criar o codificador"); return }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let enc = sw!.encode(pb, forceKey: forceKey)
        encodeMs += (CFAbsoluteTimeGetCurrent() - t1) * 1000
        measured += 1
        if let enc = enc {
            forceKey = false
            emit(enc.0, enc.1)
        }
    }

    private func emit(_ data: [UInt8], _ key: Bool) {
        onFrame?(FrameHub.Frame(data: data, key: key))
        sent += 1
        if Date().timeIntervalSince(lastLog) > 15 {
            let m = max(1, measured)
            Log.d("mapa: \(sent) quadros em 15 s (desenho \(Int(renderMs / Double(m))) ms, vídeo \(Int(encodeMs / Double(m))) ms, quadro pronto esperando o painel \(waits)x)")
            renderMs = 0; encodeMs = 0; measured = 0; waits = 0
            sent = 0
            lastLog = Date()
        }
    }
}
