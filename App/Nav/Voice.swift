import Foundation
import AVFoundation

/// Voz em português para as curvas e os radares. Abaixa a música enquanto fala e sai no fone do
/// capacete se ele estiver conectado. Funciona com o iPhone bloqueado (modo de áudio em segundo plano).
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Voice()
    private let synth = AVSpeechSynthesizer()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "voice") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voice") }
    }

    private override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        Log.d("voz: \(text)")
        guard enabled else { return }
        DispatchQueue.main.async {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try? s.setActive(true)
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "pt-BR")
            u.rate = 0.52
            self.synth.speak(u)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !s.isSpeaking {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
