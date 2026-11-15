import Foundation
import MapKit
import CoreLocation

enum Maneuver: Equatable {
    case straight, left, right, slightLeft, slightRight, sharpLeft, sharpRight, uTurn, roundabout, arrive

    /// O MapKit só dá o texto da instrução ("Vire à direita na Rua X"); a seta sai das palavras.
    static func parse(_ text: String) -> Maneuver {
        let t = text.lowercased()
        if t.contains("chegou") || t.contains("destino") { return .arrive }
        if t.contains("retorno") { return .uTurn }
        if t.contains("rotatória") || t.contains("rotunda") || t.contains("rotatoria") { return .roundabout }
        let left = t.contains("esquerda"), right = t.contains("direita")
        let slight = t.contains("levemente") || t.contains("mantenha") || t.contains("saída") || t.contains("pegue a")
        let sharp = t.contains("acentuad") || t.contains("fechad")
        if left && !right { return sharp ? .sharpLeft : slight ? .slightLeft : .left }
        if right && !left { return sharp ? .sharpRight : slight ? .slightRight : .right }
        return .straight
    }

    var symbol: String {
        switch self {
        case .straight: return "arrow.up"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .uTurn: return "arrow.uturn.left"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .arrive: return "flag.checkered"
        }
    }
}

struct NavStep: Equatable {
    let index: Int
    let instruction: String
    let startAt: Double      // metros desde o início da rota onde a manobra acontece
    let maneuver: Maneuver
    let street: String
}

/// Navegação curva a curva: busca a rota no MapKit, acompanha a moto, recalcula se sair da rota,
/// fala as instruções e avisa radares. Funciona com o iPhone bloqueado.
final class NavEngine: NSObject, ObservableObject {
    static let shared = NavEngine()

    // ---- estado para a tela (fila principal)
    @Published private(set) var location: CLLocation?
    @Published private(set) var destination: MKMapItem?
    @Published private(set) var route: MKRoute?
    @Published private(set) var navigating = false
    @Published private(set) var calculating = false
    @Published private(set) var nextStep: NavStep?
    @Published private(set) var distanceToNext: Double = 0
    @Published private(set) var remainingDistance: Double = 0
    @Published private(set) var remainingTime: Double = 0
    @Published private(set) var radarAlert: RadarAlert?
    @Published private(set) var radarCount = RadarStore.shared.count
    @Published var errorText: String?

    // ---- dados da rota
    private var coords: [CLLocationCoordinate2D] = []
    private var cum: [Double] = []           // distância acumulada até cada ponto
    private var steps: [NavStep] = []
    private var progressIndex = 0
    private var progress = 0.0
    private var offRouteCount = 0
    private var lastReroute = Date.distantPast
    private var announced = Set<String>()
    private var spokenRadars = Set<Int64>()
    private var lastCourse: Double?

    /// Retrato do momento para quem desenha o painel (outra thread).
    struct Snapshot {
        var coord: CLLocationCoordinate2D?
        var course: Double?
        var speed: Double = 0            // m/s
        var fixTime = Date.distantPast
        var route: [CLLocationCoordinate2D] = []
        var progressIndex = 0
        var navigating = false
        var nextStep: NavStep?
        var distanceToNext: Double = 0
        var remainingDistance: Double = 0
        var remainingTime: Double = 0
        var radar: RadarAlert?
        var radars: [Radar] = []
        var destinationName: String?
    }
    private let snapLock = NSLock()
    private var snap = Snapshot()
    func snapshot() -> Snapshot { snapLock.lock(); defer { snapLock.unlock() }; return snap }

    private override init() {
        super.init()
        KeepAlive.shared.onLocation = { [weak self] l in self?.update(l) }
    }

    // ------------------------------------------------------------------ rota

    func preview(to item: MKMapItem) {
        destination = item
        calculate(to: item, reason: "prévia")
    }

    func start() {
        guard route != nil else { return }
        navigating = true
        announced.removeAll()
        KeepAlive.shared.start("nav")
        Log.d("navegação iniciada para \(destination?.name ?? "?")")
        if let s = nextStep { Voice.shared.say("Vamos lá. " + sentence(for: s, distance: distanceToNext)) }
        publish()
    }

    func stop() {
        navigating = false
        route = nil
        destination = nil
        coords = []; cum = []; steps = []
        nextStep = nil
        radarAlert = nil
        KeepAlive.shared.stop("nav")
        publish()
        Log.d("navegação encerrada")
    }

    private func calculate(to item: MKMapItem, reason: String) {
        calculating = true
        errorText = nil
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = item
        req.transportType = .automobile
        MKDirections(request: req).calculate { [weak self] resp, err in
            guard let self = self else { return }
            self.calculating = false
            guard let r = resp?.routes.first else {
                self.errorText = "Não achei rota: \(err?.localizedDescription ?? "sem resposta")"
                Log.d("rota (\(reason)): \(self.errorText ?? "")")
                return
            }
            self.load(r)
            Log.d("rota (\(reason)): \(Geo.formatDistance(r.distance)), \(Geo.formatDuration(r.expectedTravelTime)), \(self.steps.count) manobras")
        }
    }

    private func load(_ r: MKRoute) {
        route = r
        let n = r.polyline.pointCount
        let pts = r.polyline.points()
        coords = (0..<n).map { pts[$0].coordinate }
        cum = [0]
        for i in 1..<max(1, coords.count) { cum.append(cum[i - 1] + Geo.meters(coords[i - 1], coords[i])) }
        var acc = 0.0
        steps = []
        for (i, s) in r.steps.enumerated() {
            let text = s.instructions.trimmingCharacters(in: .whitespaces)
            if i > 0 && !text.isEmpty {
                steps.append(NavStep(index: i, instruction: text, startAt: acc, maneuver: Maneuver.parse(text), street: Self.street(text)))
            }
            acc += s.distance
        }
        // a soma das etapas pode diferir um pouco do traçado: ajusta na mesma proporção
        if let total = cum.last, acc > 0 {
            let k = total / acc
            steps = steps.map { NavStep(index: $0.index, instruction: $0.instruction, startAt: $0.startAt * k, maneuver: $0.maneuver, street: $0.street) }
        }
        progressIndex = 0
        progress = 0
        offRouteCount = 0
        announced.removeAll()
        RadarStore.shared.loadAlong(coords)
        TileCache.shared.prefetch(route: coords)
        if let l = location { update(l) } else { refreshStep() }
    }

    private static func street(_ text: String) -> String {
        for sep in [" na ", " no ", " pela ", " pelo ", " em direção a ", " em ", " para "] {
            if let r = text.range(of: sep, options: .backwards) {
                let s = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if s.count > 2 { return s }
            }
        }
        return text
    }

    func radarsChanged() {
        radarCount = RadarStore.shared.count
        publish()
    }

    // ------------------------------------------------------------------ GPS

    private func update(_ l: CLLocation) {
        location = l
        if l.course >= 0 && l.speed > 1.5 { lastCourse = l.course }
        if coords.count > 1 { track(l) } else { RadarStore.shared.refreshAround(l.coordinate) }
        checkRadar(l)
        publish(l)
    }

    private func track(_ l: CLLocation) {
        let p = l.coordinate
        // procura o trecho mais próximo perto de onde estávamos (rápido e sem pular para trás)
        let from = max(0, progressIndex - 3)
        let to = min(coords.count - 1, progressIndex + 80)
        var bestD = Double.greatestFiniteMagnitude, bestI = progressIndex, bestT = 0.0
        for i in from..<to {
            let (d, t) = Geo.project(p, coords[i], coords[i + 1])
            if d < bestD { bestD = d; bestI = i; bestT = t }
        }
        if bestD < 60 {
            offRouteCount = 0
            progressIndex = bestI
            progress = cum[bestI] + (cum[bestI + 1] - cum[bestI]) * bestT
        } else if l.horizontalAccuracy < 50 {
            offRouteCount += 1
        }
        if navigating && offRouteCount >= 3 && Date().timeIntervalSince(lastReroute) > 12, let dest = destination {
            lastReroute = Date()
            offRouteCount = 0
            Voice.shared.say("Recalculando")
            calculate(to: dest, reason: "fora da rota")
            return
        }
        refreshStep()
        let remaining = max(0, (cum.last ?? 0) - progress)
        if navigating && remaining < 30 {
            Voice.shared.say("Você chegou ao destino")
            stop()
            return
        }
        guard navigating, let s = nextStep else { return }
        // avisos de voz: ~400 m, ~120 m e "agora"
        let d = distanceToNext
        let stages: [(String, Double, Double)] = [("far", 450, 300), ("near", 140, 80), ("now", 35, 0)]
        for (name, hi, lo) in stages where d <= hi && d >= lo {
            let key = "\(s.index)-\(name)"
            if !announced.contains(key) {
                announced.insert(key)
                Voice.shared.say(name == "now" ? "Agora, " + Self.lowerFirst(s.instruction) : sentence(for: s, distance: d))
            }
        }
    }

    private func refreshStep() {
        let next = steps.first { $0.startAt > progress + 3 }
        nextStep = next
        distanceToNext = next.map { $0.startAt - progress } ?? max(0, (cum.last ?? 0) - progress)
        remainingDistance = max(0, (cum.last ?? 0) - progress)
        if let r = route, let total = cum.last, total > 0 {
            remainingTime = r.expectedTravelTime * remainingDistance / total
        }
    }

    private func sentence(for s: NavStep, distance: Double) -> String {
        let d = distance >= 1000 ? Geo.formatDistance(distance).replacingOccurrences(of: "km", with: "quilômetros")
                                 : "\(Int((distance / 50).rounded()) * 50) metros"
        return "Em \(d), " + Self.lowerFirst(s.instruction)
    }

    private static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    private func checkRadar(_ l: CLLocation) {
        let course = (l.course >= 0 && l.speed > 2) ? l.course : nil
        let alert = RadarStore.shared.ahead(of: l.coordinate, course: course, route: navigating ? coords : [], fromIndex: progressIndex)
        radarAlert = alert
        if let a = alert, a.distance < 500, !spokenRadars.contains(a.radar.id) {
            spokenRadars.insert(a.radar.id)
            let limit = a.radar.maxspeed.map { ", limite \($0)" } ?? ""
            Voice.shared.say("Radar em \(Int((a.distance / 50).rounded()) * 50) metros\(limit)")
        }
        if spokenRadars.count > 200 { spokenRadars.removeAll() }
    }

    private func publish(_ l: CLLocation? = nil) {
        snapLock.lock()
        if let l = l ?? location {
            snap.coord = l.coordinate
            snap.speed = max(0, l.speed)
            snap.fixTime = l.timestamp
        }
        snap.course = lastCourse
        snap.route = coords
        snap.progressIndex = progressIndex
        snap.navigating = navigating
        snap.nextStep = nextStep
        snap.distanceToNext = distanceToNext
        snap.remainingDistance = remainingDistance
        snap.remainingTime = remainingTime
        snap.radar = radarAlert
        snap.destinationName = destination?.name
        snapLock.unlock()
        // lista de radares: só quando muda (pode ser grande)
        let rs = RadarStore.shared.all
        snapLock.lock(); snap.radars = rs; snapLock.unlock()
    }
}
