import Foundation
import CoreLocation
import CoreGraphics

/// Contas de mapa: distâncias curtas em metros, rumo, projeção Web Mercator (a dos tiles).
enum Geo {
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (dx, dy) = delta(a, b)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Diferença em metros (leste, norte) de a até b. Boa para distâncias de alguns km.
    static func delta(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (Double, Double) {
        let lat = (a.latitude + b.latitude) / 2 * .pi / 180
        return ((b.longitude - a.longitude) * 111_320 * cos(lat), (b.latitude - a.latitude) * 110_540)
    }

    /// Rumo de a para b, em graus (0 = norte, 90 = leste).
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (dx, dy) = delta(a, b)
        let d = atan2(dx, dy) * 180 / .pi
        return d < 0 ? d + 360 : d
    }

    /// Menor diferença entre dois rumos (0...180).
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Anda `meters` a partir de `c` no rumo `course`.
    static func move(_ c: CLLocationCoordinate2D, meters: Double, course: Double) -> CLLocationCoordinate2D {
        let r = course * .pi / 180
        let lat = c.latitude + meters * cos(r) / 110_540
        let lon = c.longitude + meters * sin(r) / (111_320 * cos(c.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Posição em pixels do "mundo" no zoom z, com tiles de `tile` pixels.
    static func world(_ c: CLLocationCoordinate2D, z: Int, tile: Double) -> CGPoint {
        let n = tile * pow(2, Double(z))
        let x = (c.longitude + 180) / 360 * n
        let s = sin(max(-85.05, min(85.05, c.latitude)) * .pi / 180)
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * n
        return CGPoint(x: x, y: y)
    }

    /// Ponto mais próximo de p no segmento a-b: (distância em metros, fração 0...1 ao longo de a-b).
    static func project(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (Double, Double) {
        let (bx, by) = delta(a, b)
        let (px, py) = delta(a, p)
        let len2 = bx * bx + by * by
        var t = len2 > 0 ? (px * bx + py * by) / len2 : 0
        t = max(0, min(1, t))
        let dx = px - bx * t, dy = py - by * t
        return ((dx * dx + dy * dy).squareRoot(), t)
    }

    static func formatDistance(_ m: Double) -> String {
        if m >= 1000 {
            let km = m / 1000
            return km >= 10 ? "\(Int(km.rounded())) km" : String(format: "%.1f km", km).replacingOccurrences(of: ".", with: ",")
        }
        if m >= 100 { return "\(Int((m / 50).rounded()) * 50) m" }
        return "\(max(0, Int((m / 10).rounded()) * 10)) m"
    }

    static func formatDuration(_ s: Double) -> String {
        let min = Int((s / 60).rounded())
        if min < 60 { return "\(max(1, min)) min" }
        return "\(min / 60) h \(min % 60) min"
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
