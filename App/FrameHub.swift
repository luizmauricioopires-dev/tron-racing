import Foundation

/// Junta as duas fontes de vídeo do painel:
///  - transmissão de tela ativa (extensão): espelha o iPhone (Waze);
///  - sem transmissão: o mapa próprio do Tron Racing (funciona até com o iPhone bloqueado).
final class FrameHub: ObservableObject {
    static let shared = FrameHub()

    struct Frame { let data: [UInt8]; let key: Bool }

    @Published private(set) var mirroring = false
    @Published private(set) var framesPerSec = 0

    /// Fila curta: se o painel atrasa, descarta e recomeça num quadro-chave (melhor pular que atrasar).
    let frames = BlockingQueue<Frame>(capacity: 8)
    private var overflows = 0
    private var overflowLogAt = Date.distantPast
    private var server: TCPServer?
    private var ext: TCPSocket?
    private let lock = NSLock()
    private var settings: FrameLink.Settings
    private var counter = 0
    private var counterAt = Date()
    private var wanted = false // o painel está pedindo vídeo?

    private init() {
        var s = FrameLink.Settings()
        s.fill = UserDefaults.standard.bool(forKey: "fill")
        s.flip = UserDefaults.standard.bool(forKey: "flip")
        settings = s
        MapStreamer.shared.onFrame = { [weak self] f in self?.pushMap(f) }
    }

    var currentSettings: FrameLink.Settings { lock.lock(); defer { lock.unlock() }; return settings }
    private var hasExt: Bool { lock.lock(); defer { lock.unlock() }; return ext != nil }

    /// Abre a porta local que a extensão usa. Chamar uma vez, ao abrir o app.
    func startListening() {
        guard server == nil else { return }
        do {
            let srv = try TCPServer(port: FrameLink.port, bindIP: FrameLink.host)
            server = srv
            Thread.detachNewThread { [weak self] in
                while let s = srv.accept() { self?.handleExtension(s) }
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
            MapStreamer.shared.stopPanel()
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
                Log.d("espelhamento: transmissão de tela parou; volta o mapa próprio")
                DispatchQueue.main.async { self.mirroring = false }
                self.frames.clear()
                if self.wanted {
                    let st = self.currentSettings
                    MapStreamer.shared.startPanel(width: st.w, height: st.h)
                }
            }
        }
    }

    /// Quadros do mapa próprio: ignorados enquanto o Waze estiver sendo espelhado.
    private func pushMap(_ f: Frame) {
        if hasExt { return }
        push(f)
    }

    func push(_ f: Frame) {
        if !frames.offer(f) {
            frames.clear()
            if f.key { frames.offer(f) } else { requestKeyFrame() }
            overflows += 1
            if Date().timeIntervalSince(overflowLogAt) > 10 {
                Log.d("vídeo: painel atrasou, \(overflows) vez(es) pulei quadros velhos para não atrasar o mapa")
                overflowLogAt = Date()
                overflows = 0
            }
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
        else { MapStreamer.shared.requestKeyFrame() }
    }

    /// O painel abriu o vídeo e disse o tamanho/bitrate que quer.
    func panelWantsVideo(width: Int, height: Int, bitrate: Int) {
        wanted = true
        update { $0.w = width; $0.h = height; $0.bitrate = min(bitrate, 1_200_000) }
        if !hasExt { MapStreamer.shared.startPanel(width: width, height: height) }
        requestKeyFrame()
    }

    func panelStoppedVideo() {
        wanted = false
        MapStreamer.shared.stopPanel()
    }
}
