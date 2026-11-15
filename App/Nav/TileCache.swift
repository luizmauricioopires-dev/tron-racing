import Foundation
import CoreGraphics
import ImageIO

/// Pedaços (tiles) do mapa escuro da CARTO (dados © OpenStreetMap), guardados no iPhone.
/// Decodificados no processador, então funcionam com o iPhone bloqueado.
final class TileCache {
    static let shared = TileCache()

    private let mem = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var inflight = Set<String>()
    private var failedAt: [String: Date] = [:]
    private let dir: URL
    private let session: URLSession

    private init() {
        mem.countLimit = 120
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.httpAdditionalHeaders = ["User-Agent": "TronRacing/0.2 (app pessoal)"]
        session = URLSession(configuration: cfg)
    }

    /// Devolve o tile se já estiver no iPhone; senão pede para baixar e devolve nil por enquanto.
    func image(z: Int, x: Int, y: Int) -> CGImage? {
        let n = 1 << z
        let xx = ((x % n) + n) % n
        guard y >= 0 && y < n else { return nil }
        let key = "\(z)/\(xx)/\(y)"
        if let img = mem.object(forKey: key as NSString) { return img }
        let file = dir.appendingPathComponent("\(z)-\(xx)-\(y).png")
        if let data = try? Data(contentsOf: file), let img = Self.decode(data) {
            mem.setObject(img, forKey: key as NSString)
            return img
        }
        fetch(key: key, z: z, x: xx, y: y, file: file)
        return nil
    }

    private func fetch(key: String, z: Int, x: Int, y: Int, file: URL) {
        lock.lock()
        if inflight.contains(key) || (failedAt[key].map { Date().timeIntervalSince($0) < 30 } ?? false) || inflight.count > 12 {
            lock.unlock(); return
        }
        inflight.insert(key)
        lock.unlock()
        let sub = ["a", "b", "c", "d"][(x + y) % 4]
        let url = URL(string: "https://\(sub).basemaps.cartocdn.com/dark_all/\(z)/\(x)/\(y)@2x.png")!
        session.dataTask(with: url) { data, resp, _ in
            var ok = false
            if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200, let img = Self.decode(data) {
                try? data.write(to: file)
                self.mem.setObject(img, forKey: key as NSString)
                ok = true
            }
            self.lock.lock()
            self.inflight.remove(key)
            if !ok { self.failedAt[key] = Date() }
            self.lock.unlock()
        }.resume()
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
