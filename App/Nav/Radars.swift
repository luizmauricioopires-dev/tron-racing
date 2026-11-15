import Foundation
import CoreLocation

struct Radar: Codable, Hashable {
    let id: Int64
    let lat: Double
    let lon: Double
    let maxspeed: Int?
    var coord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct RadarAlert: Equatable {
    let radar: Radar
    let distance: Double
}

/// Radares fixos do OpenStreetMap (base aberta e colaborativa), baixados pela API Overpass e
/// guardados no iPhone para funcionar sem internet.
final class RadarStore {
    static let shared = RadarStore()

    private let lock = NSLock()
    private var byId: [Int64: Radar] = [:]
    private var lastCenter: CLLocationCoordinate2D?
    private var fetching = false
    private let file: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("radares.json")
    }()

    var count: Int { lock.lock(); defer { lock.unlock() }; return byId.count }
    var all: [Radar] { lock.lock(); defer { lock.unlock() }; return Array(byId.values) }

    private init() {
        if let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Radar].self, from: d) {
            for r in list { byId[r.id] = r }
        }
    }

    /// Sem rota: baixa um quadrado de ~30 km em volta, de novo a cada 10 km rodados.
    func refreshAround(_ c: CLLocationCoordinate2D) {
        lock.lock()
        let need = lastCenter.map { Geo.meters($0, c) > 10_000 } ?? true
        lock.unlock()
        guard need else { return }
        lock.lock(); lastCenter = c; lock.unlock()
        load(s: c.latitude - 0.14, w: c.longitude - 0.15, n: c.latitude + 0.14, e: c.longitude + 0.15)
    }

    /// Com rota: baixa o retângulo que cobre a rota inteira.
    func loadAlong(_ coords: [CLLocationCoordinate2D]) {
        guard let first = coords.first else { return }
        var s = first.latitude, n = first.latitude, w = first.longitude, e = first.longitude
        for c in coords {
            s = min(s, c.latitude); n = max(n, c.latitude)
            w = min(w, c.longitude); e = max(e, c.longitude)
        }
        // rota muito longa: o Overpass recusa áreas enormes, então fica só nos arredores
        if (n - s) * (e - w) > 4 { return }
        load(s: s - 0.01, w: w - 0.01, n: n + 0.01, e: e + 0.01)
    }

    private static let servers = ["https://overpass-api.de/api/interpreter",
                                  "https://overpass.kumi.systems/api/interpreter",
                                  "https://maps.mail.ru/osm/tools/overpass/api/interpreter"]

    private func load(s: Double, w: Double, n: Double, e: Double, attempt: Int = 0) {
        lock.lock()
        if fetching && attempt == 0 { lock.unlock(); return }
        fetching = true
        lock.unlock()
        let q = "[out:json][timeout:25];node[\"highway\"=\"speed_camera\"](\(s),\(w),\(n),\(e));out body;"
        var req = URLRequest(url: URL(string: Self.servers[attempt % Self.servers.count])!)
        req.httpMethod = "POST"
        req.setValue("TronRacing/0.2 (app pessoal)", forHTTPHeaderField: "User-Agent")
        req.httpBody = ("data=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).data(using: .utf8)
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let els = json["elements"] as? [[String: Any]] else {
                Log.d("radares: servidor \(attempt + 1) falhou (\(err?.localizedDescription ?? "resposta inválida"))")
                if attempt + 1 < Self.servers.count { self.load(s: s, w: w, n: n, e: e, attempt: attempt + 1) }
                else { self.lock.lock(); self.fetching = false; self.lastCenter = nil; self.lock.unlock() }
                return
            }
            defer { self.lock.lock(); self.fetching = false; self.lock.unlock() }
            var added = 0
            self.lock.lock()
            for el in els {
                guard let id = el["id"] as? Int64 ?? (el["id"] as? Int).map(Int64.init),
                      let lat = el["lat"] as? Double, let lon = el["lon"] as? Double else { continue }
                let tags = el["tags"] as? [String: String] ?? [:]
                let max = tags["maxspeed"].flatMap { Int($0.filter(\.isNumber)) }
                if self.byId[id] == nil { added += 1 }
                self.byId[id] = Radar(id: id, lat: lat, lon: lon, maxspeed: max)
            }
            let list = Array(self.byId.values)
            self.lock.unlock()
            Log.d("radares: \(els.count) na área (\(added) novos, \(list.count) no total)")
            if let d = try? JSONEncoder().encode(list) { try? d.write(to: self.file) }
            DispatchQueue.main.async { NavEngine.shared.radarsChanged() }
        }.resume()
    }

    /// Radar à frente: até 600 m, no sentido em que a moto vai e (se houver rota) perto dela.
    func ahead(of c: CLLocationCoordinate2D, course: Double?, route: [CLLocationCoordinate2D], fromIndex: Int) -> RadarAlert? {
        guard let course = course else { return nil }
        var best: RadarAlert?
        for r in all {
            let d = Geo.meters(c, r.coord)
            if d > 600 || d < 5 { continue }
            if Geo.angleDiff(Geo.bearing(c, r.coord), course) > 35 { continue }
            if !route.isEmpty && !Self.isNear(r.coord, route: route, from: fromIndex, within: 40) { continue }
            if best == nil || d < best!.distance { best = RadarAlert(radar: r, distance: d) }
        }
        return best
    }

    private static func isNear(_ p: CLLocationCoordinate2D, route: [CLLocationCoordinate2D], from: Int, within: Double) -> Bool {
        let start = max(0, from - 2)
        guard start < route.count - 1 else { return false }
        var travelled = 0.0
        for i in start..<(route.count - 1) {
            let (d, _) = Geo.project(p, route[i], route[i + 1])
            if d < within { return true }
            travelled += Geo.meters(route[i], route[i + 1])
            if travelled > 1500 { break }
        }
        return false
    }
}
