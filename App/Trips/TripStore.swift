import Foundation
import CoreLocation

struct TripPoint: Codable {
    let lat: Double
    let lon: Double
    let alt: Double
    let speed: Double   // m/s
    let t: TimeInterval // desde 1970
    var coord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// Um percurso do Diário de Bordo. Na lista (índice) os pontos vêm vazios; o traçado completo
/// fica num arquivo próprio e é lido só ao abrir o percurso.
struct Trip: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let start: Date
    var end: Date
    var distance: Double = 0        // metros
    var movingTime: Double = 0      // segundos
    var maxSpeed: Double = 0        // m/s
    var elevationGain: Double = 0   // metros
    var startPlace: String?
    var endPlace: String?
    var records: [String] = []
    var points: [TripPoint] = []

    var duration: Double { end.timeIntervalSince(start) }
    var avgSpeed: Double { movingTime > 0 ? distance / movingTime : 0 }

    var placeLine: String? {
        switch (startPlace, endPlace) {
        case let (a?, b?) where a == b: return "Início e fim em \(a)"
        case let (a?, b?): return "De \(a) para \(b)"
        case let (a?, nil): return "Saída de \(a)"
        default: return nil
        }
    }

    static func == (l: Trip, r: Trip) -> Bool {
        l.id == r.id && l.title == r.title && l.end == r.end && l.distance == r.distance && l.records == r.records
    }

    static func defaultTitle(_ d: Date) -> String {
        let h = Calendar.current.component(.hour, from: d)
        switch h {
        case 5..<12: return "Rolê da manhã"
        case 12..<18: return "Rolê da tarde"
        case 18..<24: return "Rolê da noite"
        default: return "Rolê de madrugada"
        }
    }
}

/// Grava os percursos (Diário de Bordo). Pode começar sozinho quando a moto está conectada e
/// andando, e para sozinho depois de um tempo parado ou desconectado.
final class TripRecorder: ObservableObject {
    static let shared = TripRecorder()

    @Published private(set) var recording = false
    @Published private(set) var current: Trip?
    @Published private(set) var trips: [Trip] = []
    @Published var autoRecord: Bool = UserDefaults.standard.object(forKey: "autoTrip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "autoTrip") }
    }

    private var autoStarted = false
    private var last: CLLocation?
    private var altRef: Double?
    private var stillSince: Date?
    private var disconnectedSince: Date?
    private var lastSave = Date()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("percursos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var indexFile: URL { dir.appendingPathComponent("indice.json") }

    private init() {
        if let d = try? Data(contentsOf: indexFile), let list = try? JSONDecoder().decode([Trip].self, from: d) {
            trips = list.sorted { $0.start > $1.start }
        }
        // percurso que estava gravando quando o app foi fechado
        if let d = try? Data(contentsOf: dir.appendingPathComponent("atual.json")), let t = try? JSONDecoder().decode(Trip.self, from: d) {
            current = t
            finish(t)
        }
    }

    // ------------------------------------------------------------------ gravar

    func start(auto: Bool = false) {
        guard !recording else { return }
        let now = Date()
        current = Trip(id: UUID(), title: Trip.defaultTitle(now), start: now, end: now)
        recording = true
        autoStarted = auto
        last = nil; altRef = nil; stillSince = nil; disconnectedSince = nil
        KeepAlive.shared.start("trip")
        Log.d("diário: gravação iniciada\(auto ? " (automática)" : "")")
        if !auto { Voice.shared.say("Gravando o percurso") }
    }

    func stop() {
        guard recording, let t = current else { return }
        recording = false
        KeepAlive.shared.stop("trip")
        finish(t)
    }

    /// Chamado a cada posição do GPS (pela navegação).
    func add(_ l: CLLocation) {
        let kmh = max(0, l.speed) * 3.6
        if !recording {
            if autoRecord && DashLink.shared.isRunning && kmh > 15 && l.horizontalAccuracy < 30 { start(auto: true) }
            return
        }
        guard var t = current else { return }
        let now = l.timestamp
        // parada automática
        if autoStarted {
            if kmh < 5 { stillSince = stillSince ?? now } else { stillSince = nil }
            if DashLink.shared.isRunning { disconnectedSince = nil } else { disconnectedSince = disconnectedSince ?? now }
            if let s = stillSince, now.timeIntervalSince(s) > 8 * 60 { Log.d("diário: parado há 8 min, encerrando"); stop(); return }
            if let s = disconnectedSince, now.timeIntervalSince(s) > 3 * 60 { Log.d("diário: moto desconectada, encerrando"); stop(); return }
        }
        guard l.horizontalAccuracy >= 0 && l.horizontalAccuracy <= 25 else { return }
        if let p = last {
            let d = l.distance(from: p)
            let dt = min(5, max(0, now.timeIntervalSince(p.timestamp)))
            if d < 4 && kmh < 5 { t.end = now; current = t; return } // parado: não enche de pontos
            if d < 300 { t.distance += d }
            if kmh >= 5 { t.movingTime += dt }
        }
        if l.speed >= 0 && (l.speedAccuracy < 0 || l.speedAccuracy < 3) { t.maxSpeed = max(t.maxSpeed, l.speed) }
        if l.verticalAccuracy > 0 && l.verticalAccuracy < 15 {
            if let r = altRef {
                if l.altitude - r > 3 { t.elevationGain += l.altitude - r; altRef = l.altitude }
                else if l.altitude < r { altRef = l.altitude }
            } else { altRef = l.altitude }
        }
        t.points.append(TripPoint(lat: l.coordinate.latitude, lon: l.coordinate.longitude, alt: l.altitude,
                                  speed: max(0, l.speed), t: now.timeIntervalSince1970))
        t.end = now
        last = l
        current = t
        if Date().timeIntervalSince(lastSave) > 30 { // guarda o andamento (se o app fechar, nada se perde)
            lastSave = Date()
            if let d = try? JSONEncoder().encode(t) { try? d.write(to: dir.appendingPathComponent("atual.json")) }
        }
    }

    private func finish(_ trip: Trip) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("atual.json"))
        current = nil
        guard trip.distance > 300, trip.points.count > 5 else {
            Log.d("diário: percurso curto demais, descartado")
            return
        }
        var t = trip
        t.records = records(for: t)
        let pts = t.points
        save(t, points: pts)
        Log.d("diário: salvo \(t.title) — \(Geo.formatDistance(t.distance))")
        if !t.records.isEmpty { Voice.shared.say("Parabéns! " + t.records[0]) }
        geocode(t.id, first: pts.first?.coord, last: pts.last?.coord)
    }

    private func records(for t: Trip) -> [String] {
        guard !trips.isEmpty else { return ["Seu primeiro percurso no Diário de Bordo!"] }
        var r: [String] = []
        if t.distance > (trips.map(\.distance).max() ?? 0) { r.append("Seu maior percurso: \(Geo.formatDistance(t.distance))") }
        if t.maxSpeed > (trips.map(\.maxSpeed).max() ?? 0) { r.append("Nova velocidade máxima: \(Int((t.maxSpeed * 3.6).rounded())) km/h") }
        if t.elevationGain > (trips.map(\.elevationGain).max() ?? 0) && t.elevationGain > 50 { r.append("Maior subida acumulada: \(Int(t.elevationGain)) m") }
        if t.movingTime > (trips.map(\.movingTime).max() ?? 0) { r.append("Mais tempo rodando: \(Geo.formatDuration(t.movingTime))") }
        return r
    }

    // ------------------------------------------------------------------ arquivos

    private func save(_ t: Trip, points: [TripPoint]) {
        var summary = t
        summary.points = []
        if let i = trips.firstIndex(where: { $0.id == t.id }) { trips[i] = summary } else { trips.insert(summary, at: 0) }
        if let d = try? JSONEncoder().encode(points) { try? d.write(to: dir.appendingPathComponent("\(t.id.uuidString).json")) }
        saveIndex()
    }

    private func saveIndex() {
        if let d = try? JSONEncoder().encode(trips) { try? d.write(to: indexFile) }
    }

    func points(for t: Trip) -> [TripPoint] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(t.id.uuidString).json")) else { return [] }
        return (try? JSONDecoder().decode([TripPoint].self, from: d)) ?? []
    }

    func rename(_ t: Trip, to title: String) {
        guard let i = trips.firstIndex(where: { $0.id == t.id }), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        trips[i].title = title
        saveIndex()
    }

    func delete(_ t: Trip) {
        trips.removeAll { $0.id == t.id }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(t.id.uuidString).json"))
        saveIndex()
    }

    /// Nome do bairro/cidade de saída e chegada.
    private func geocode(_ id: UUID, first: CLLocationCoordinate2D?, last: CLLocationCoordinate2D?) {
        guard let a = first else { return }
        func name(_ p: CLPlacemark?) -> String? { p?.subLocality ?? p?.locality ?? p?.name }
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: a.latitude, longitude: a.longitude)) { pa, _ in
            let startName = name(pa?.first)
            let finish: (String?) -> Void = { endName in
                DispatchQueue.main.async {
                    guard let i = self.trips.firstIndex(where: { $0.id == id }) else { return }
                    self.trips[i].startPlace = startName
                    self.trips[i].endPlace = endName
                    self.saveIndex()
                }
            }
            guard let b = last, Geo.meters(a, b) > 500 else { finish(startName); return }
            // o iOS limita geocodificações seguidas: espera um pouco
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: b.latitude, longitude: b.longitude)) { pb, _ in
                    finish(name(pb?.first))
                }
            }
        }
    }

    // ------------------------------------------------------------------ totais

    var monthSummary: (km: Double, rides: Int, hours: Double) {
        let cal = Calendar.current
        let now = Date()
        let month = trips.filter { cal.isDate($0.start, equalTo: now, toGranularity: .month) }
        return (month.reduce(0) { $0 + $1.distance } / 1000, month.count, month.reduce(0) { $0 + $1.movingTime } / 3600)
    }
}
