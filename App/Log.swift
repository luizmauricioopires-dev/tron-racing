import Foundation
import Combine

/// Diário da conexão. É o que você manda quando algo não funciona na moto.
final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var lines: [String] = []
    private let q = DispatchQueue(label: "tron.log")
    private var buf: [String] = []
    private var publishPending = false
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "pt_BR")
        return f
    }()

    static func d(_ s: String) { shared.add(s) }

    func add(_ s: String) {
        let line = fmt.string(from: Date()) + "  " + s
        print(line)
        q.async {
            self.buf.append(line)
            if self.buf.count > 4000 { self.buf.removeFirst(1000) }
            if !self.publishPending {
                self.publishPending = true
                // junta várias linhas numa atualização da tela
                self.q.asyncAfter(deadline: .now() + 0.3) {
                    self.publishPending = false
                    let snap = self.buf
                    DispatchQueue.main.async { self.lines = snap }
                }
            }
        }
    }

    func text() -> String {
        q.sync { buf.joined(separator: "\n") }
    }

    func clear() {
        q.async {
            self.buf.removeAll()
            DispatchQueue.main.async { self.lines = [] }
        }
    }
}
