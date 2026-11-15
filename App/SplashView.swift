import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

/// Abertura: o vídeo escolhido pela galeria (fica só no iPhone) com o TRON Racing por cima.
/// Sem vídeo, mostra a arte do Tron Racing.
struct SplashView: View {
    var onFinish: () -> Void
    @State private var titleOn = false
    @State private var finished = false
    @State private var player: AVPlayer? = IntroVideo.player()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player {
                PlayerLayerView(player: p).ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                Image("HeroBrand").resizable().aspectRatio(contentMode: .fit)
                    .opacity(titleOn ? 1 : 0)
                    .scaleEffect(titleOn ? 1 : 1.06)
            }
            if player != nil {
                VStack(spacing: 14) {
                    BrandTitle(size: 56, glow: Color(red: 1, green: 0.15, blue: 0.1))
                    Checkers(rows: 2, size: 9).frame(width: 220)
                }
                .opacity(titleOn ? 1 : 0)
                .scaleEffect(titleOn ? 1 : 0.92)
                .offset(y: -140)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9).delay(player == nil ? 0.1 : 0.6)) { titleOn = true }
            if let p = player {
                p.play()
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in end() }
            }
            // segurança: nunca prende o app na abertura
            DispatchQueue.main.asyncAfter(deadline: .now() + (player == nil ? 2.2 : 7)) { end() }
        }
        .onTapGesture { end() }
    }

    private func end() {
        guard !finished else { return }
        finished = true
        player?.pause()
        onFinish()
    }
}

/// O vídeo de abertura guardado no app.
enum IntroVideo {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("abertura.mp4")
    }
    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }
    static var withSound: Bool {
        get { UserDefaults.standard.bool(forKey: "introSound") }
        set { UserDefaults.standard.set(newValue, forKey: "introSound") }
    }

    static func player() -> AVPlayer? {
        guard exists else { return nil }
        let p = AVPlayer(url: file)
        p.isMuted = !withSound
        if withSound { try? AVAudioSession.sharedInstance().setCategory(.ambient) }
        return p
    }

    /// Copia o vídeo escolhido e converte para 1080p (abre mais rápido e ocupa menos).
    static func importVideo(from src: URL, done: @escaping (String?) -> Void) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("abertura-nova.mp4")
        try? FileManager.default.removeItem(at: tmp)
        let asset = AVURLAsset(url: src)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            done("Não consegui ler esse vídeo."); return
        }
        ex.outputURL = tmp
        ex.outputFileType = .mp4
        ex.shouldOptimizeForNetworkUse = true
        ex.exportAsynchronously {
            DispatchQueue.main.async {
                guard ex.status == .completed else { done("Falhou ao converter: \(ex.error?.localizedDescription ?? "?")"); return }
                try? FileManager.default.removeItem(at: file)
                do { try FileManager.default.moveItem(at: tmp, to: file); done(nil) }
                catch { done("Falhou ao salvar: \(error.localizedDescription)") }
            }
        }
    }

    static func remove() { try? FileManager.default.removeItem(at: file) }
}

/// Vídeo vindo da galeria (PhotosPicker).
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("escolhido-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

/// Vídeo preenchendo a tela (corta as sobras, sem faixas pretas).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        v.pl.player = player
        v.pl.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ v: V, context: Context) {}
}
