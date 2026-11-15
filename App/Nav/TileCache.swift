import Foundation
import CoreGraphics
import ImageIO
import MapKit
import UIKit

/// Pedaços (tiles) do mapa para o painel, gerados a partir do Mapas da Apple em modo escuro
/// (MKMapSnapshotter, liberado para apps, sem chave). Cada foto cobre 2x2 tiles para os nomes de
/// rua cortarem menos; tudo fica guardado no iPhone e é lido no processador (funciona bloqueado).
final class TileCache {
    static let shared = TileCache()
    static let tilePx = 320

    private let mem = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var inflight = Set<String>()
    private var queue: [(Int, Int, Int)] = []   // blocos (z, bx, by) esperando
    private var failedAt: [String: Date] = [:]
    private let dir: URL
    private let maxConcurrent = 2

    private init() {
        mem.countLimit = 140
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles-apple", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // o fundo antigo (CARTO) ficou com marca d'água: apaga
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles")
        try? FileManager.default.removeItem(at: old)
    }

    /// Devolve o tile se já estiver no iPhone; senão pede para gerar e devolve nil por enquanto.
    func image(z: Int, x: Int, y: Int) -> CGImage? {
        let n = 1 << z
        let xx = ((x % n) + n) % n
        guard y >= 0 && y < n else { return nil }
        let key = "\(z)/\(xx)/\(y)" as NSString
        if let img = mem.object(forKey: key) { return img }
        if let data = try? Data(contentsOf: file(z, xx, y)), let img = Self.decode(data) {
            mem.setObject(img, forKey: key)
            return img
        }
        request(z: z, x: xx, y: y, front: true)
        return nil
    }

    /// Gera antes os tiles ao longo da rota (com a tela ligada), para o mapa estar pronto
    /// mesmo com o iPhone bloqueado.
    func prefetch(route: [CLLocationCoordinate2D]) {
        var seen = Set<String>()
        var last: CLLocationCoordinate2D?
        for c in route {
            if let l = last, Geo.meters(l, c) < 150 { continue }
            last = c
            for z in [16, 15] {
                let p = Geo.world(c, z: z, tile: 1)
                let x = Int(p.x), y = Int(p.y)
                for dy in -1...1 { for dx in -1...1 {
                    let k = "\(z)/\((x + dx) & ~1)/\((y + dy) & ~1)"
                    if seen.insert(k).inserted, !FileManager.default.fileExists(atPath: file(z, x + dx, y + dy).path) {
                        request(z: z, x: x + dx, y: y + dy, front: false)
                    }
                } }
            }
        }
        Log.d("mapa: preparando \(seen.count) blocos ao longo da rota")
    }

    private func file(_ z: Int, _ x: Int, _ y: Int) -> URL { dir.appendingPathComponent("\(z)-\(x)-\(y).png") }

    private func request(z: Int, x: Int, y: Int, front: Bool) {
        let bx = x & ~1, by = y & ~1
        let key = "\(z)/\(bx)/\(by)"
        lock.lock()
        if inflight.contains(key) || queue.contains(where: { $0 == (z, bx, by) }) ||
            (failedAt[key].map { Date().timeIntervalSince($0) < 20 } ?? false) {
            lock.unlock(); return
        }
        if front { queue.insert((z, bx, by), at: 0) } else { queue.append((z, bx, by)) }
        if queue.count > 400 { queue.removeLast(queue.count - 400) }
        lock.unlock()
        pump()
    }

    private func pump() {
        lock.lock()
        guard inflight.count < maxConcurrent, !queue.isEmpty else { lock.unlock(); return }
        let (z, bx, by) = queue.removeFirst()
        let key = "\(z)/\(bx)/\(by)"
        inflight.insert(key)
        lock.unlock()
        DispatchQueue.main.async { self.snapshot(z: z, bx: bx, by: by, key: key) }
    }

    private func snapshot(z: Int, bx: Int, by: Int, key: String) {
        let world = MKMapSize.world.width
        let t = world / pow(2, Double(z))
        let opt = MKMapSnapshotter.Options()
        opt.mapRect = MKMapRect(x: Double(bx) * t, y: Double(by) * t, width: 2 * t, height: 2 * t)
        opt.size = CGSize(width: 2 * TileCache.tilePx, height: 2 * TileCache.tilePx)
        opt.traitCollection = UITraitCollection(traitsFrom: [UITraitCollection(displayScale: 1),
                                                             UITraitCollection(userInterfaceStyle: .dark)])
        opt.mapType = .mutedStandard
        opt.pointOfInterestFilter = .excludingAll
        opt.showsBuildings = false
        MKMapSnapshotter(options: opt).start(with: DispatchQueue.global(qos: .utility)) { snap, err in
            var ok = false
            if let img = snap?.image.cgImage {
                let px = img.width / 2
                for j in 0..<2 {
                    for i in 0..<2 {
                        guard let part = img.cropping(to: CGRect(x: i * px, y: j * px, width: px, height: px)) else { continue }
                        let x = bx + i, y = by + j
                        if let png = UIImage(cgImage: part).pngData() { try? png.write(to: self.file(z, x, y)) }
                        self.mem.setObject(part, forKey: "\(z)/\(x)/\(y)" as NSString)
                    }
                }
                ok = true
            } else {
                Log.d("mapa: não consegui gerar o bloco \(key): \(err?.localizedDescription ?? "?")")
            }
            self.lock.lock()
            self.inflight.remove(key)
            if !ok { self.failedAt[key] = Date() }
            self.lock.unlock()
            self.pump()
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
