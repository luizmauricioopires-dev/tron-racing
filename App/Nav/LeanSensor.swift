import Foundation
import CoreMotion

/// Inclinação da moto (graus; positivo = deitando para a direita) pelo sensor de movimento do
/// iPhone, que precisa estar preso na moto. A referência ("moto em pé") é a direção para cima
/// na tela do iPhone; fica salva e pode ser zerada nos Ajustes.
final class LeanSensor {
    static let shared = LeanSensor()

    private let mm = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var refX = 0.0, refY = 1.0
    private var hasRef = false
    private var needCal = false
    private var value = 0.0
    private var maxL = 0.0, maxR = 0.0
    private var usable = true
    private var users = 0
    private var moving = false

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "leanRefX") != nil {
            refX = d.double(forKey: "leanRefX"); refY = d.double(forKey: "leanRefY"); hasRef = true
        }
    }

    var isAvailable: Bool { mm.isDeviceMotionAvailable }

    func start() {
        lock.lock(); users += 1; let first = users == 1; lock.unlock()
        guard first, mm.isDeviceMotionAvailable else { return }
        mm.deviceMotionUpdateInterval = 1.0 / 30
        mm.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            if let g = m?.gravity { self?.update(g) }
        }
        Log.d("modo pista: sensor de inclinação ligado")
    }

    func stop() {
        lock.lock(); users = max(0, users - 1); let last = users == 0; lock.unlock()
        if last { mm.stopDeviceMotionUpdates() }
    }

    /// Moto em pé agora: vira o zero. Também zera as máximas.
    func calibrate() {
        lock.lock(); needCal = true; maxL = 0; maxR = 0; value = 0; lock.unlock()
    }

    /// Máximas só contam andando (subir na moto ou o descanso lateral não valem).
    func setMoving(_ m: Bool) { lock.lock(); moving = m; lock.unlock() }

    func resetMax() { lock.lock(); maxL = 0; maxR = 0; lock.unlock() }

    /// (inclinação atual, máxima à esquerda, máxima à direita, leitura válida)
    func read() -> (lean: Double, maxLeft: Double, maxRight: Double, ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (value, maxL, maxR, usable && hasRef)
    }

    private func update(_ g: CMAcceleration) {
        // "para cima" no plano da tela do iPhone
        let ux = -g.x, uy = -g.y
        let n = (ux * ux + uy * uy).squareRoot()
        lock.lock()
        defer { lock.unlock() }
        usable = n > 0.35 // iPhone deitado (tela para cima) não serve
        guard usable else { return }
        if !hasRef || needCal {
            refX = ux / n; refY = uy / n; hasRef = true; needCal = false
            let d = UserDefaults.standard
            d.set(refX, forKey: "leanRefX"); d.set(refY, forKey: "leanRefY")
        }
        // direita do piloto = "para cima" de referência girado 90° no sentido horário
        let rx = refY, ry = -refX
        let along = ux * rx + uy * ry
        let up = ux * refX + uy * refY
        let deg = atan2(-along, up) * 180 / .pi
        value = value * 0.75 + deg * 0.25
        guard moving, abs(value) < 65 else { return }
        if value < 0 { maxL = max(maxL, -value) } else { maxR = max(maxR, value) }
    }
}
