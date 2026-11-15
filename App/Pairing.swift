import Foundation

/// Painel pareado (pelo QR que aparece na tela da moto) e dados do Acesso Pessoal do iPhone.
struct Dash: Codable, Equatable {
    var id: String          // endereço Bluetooth (bm=) ou o do código CARBIT
    var name: String
    var bleName: String?    // "EC" + 8 letras, como o painel se anuncia no Bluetooth
}

struct Hotspot: Codable, Equatable {
    var ssid: String = ""
    var password: String = ""
    var isComplete: Bool { !ssid.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 8 }
}

enum QrResult {
    case ok(Dash)
    case oldPanel   // painel até 2024 (Wi-Fi Direct): o iPhone não tem Wi-Fi Direct
    case invalid
}

/// Os dois tipos de QR (mesma regra do MotoNav):
///  - até 2024: ...?modelid=…&action=8&ssid=…&mac=aa:bb:...&name=XXXX  -> Wi-Fi Direct (não dá no iPhone)
///  - 2025+:    ...?modelid=…&sn=…&action=128&bm=AA:BB:...  ou só "ID:CARBITxxxxxxxxxxxx" -> Bluetooth + hotspot
enum Pairing {
    private static let token = try! NSRegularExpression(pattern: "CARBIT([0-9A-Fa-f]{12})")

    static func parse(_ raw: String) -> QrResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenMac = firstToken(text).map(formatMac)
        if !text.contains("?") {
            guard let t = tokenMac else { return .invalid }
            return .ok(ble(nil, t, nil))
        }
        guard let comps = URLComponents(string: text) ?? URLComponents(string: text.replacingOccurrences(of: " ", with: "%20")) else {
            return tokenMac.map { .ok(ble(nil, $0, nil)) } ?? .invalid
        }
        func q(_ k: String) -> String? { comps.queryItems?.first { $0.name.lowercased() == k }?.value }
        if let m = q("mac"), normMac(m) != nil { return .oldPanel }
        let bm = q("bm").flatMap(normMac)
        let action = q("action").flatMap { Int($0) }
        if bm == nil && tokenMac == nil && (action == nil || (action! & 0x80) == 0) { return .invalid }
        if !text.lowercased().contains("carbit") && bm == nil { return .invalid }
        return .ok(ble(bm, tokenMac, q("name")))
    }

    private static func firstToken(_ s: String) -> String? {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = token.firstMatch(in: s, range: r), let g = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[g])
    }

    private static func ble(_ bm: String?, _ token: String?, _ name: String?) -> Dash {
        let id = bm ?? token ?? ""
        let hex = id.replacingOccurrences(of: ":", with: "").uppercased()
        let bleName = hex.count >= 8 ? "EC" + String(hex.suffix(8)) : nil
        return Dash(id: id, name: name ?? bleName ?? "Painel", bleName: bleName)
    }

    private static func normMac(_ v: String) -> String? {
        let s = v.lowercased().trimmingCharacters(in: .whitespaces)
        if s.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil { return s }
        if s.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil { return formatMac(s) }
        return nil
    }

    private static func formatMac(_ hex12: String) -> String {
        let h = Array(hex12.lowercased())
        return stride(from: 0, to: h.count, by: 2).map { String(h[$0..<min($0 + 2, h.count)]) }.joined(separator: ":")
    }

    // ------------------------------------------------------------------ guardar

    static func save(_ d: Dash?) {
        if let d = d, let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: "dash") }
        else { UserDefaults.standard.removeObject(forKey: "dash") }
    }

    static func load() -> Dash? {
        guard let data = UserDefaults.standard.data(forKey: "dash") else { return nil }
        return try? JSONDecoder().decode(Dash.self, from: data)
    }

    static func saveHotspot(_ h: Hotspot) {
        if let data = try? JSONEncoder().encode(h) { UserDefaults.standard.set(data, forKey: "hotspot") }
    }

    static func loadHotspot() -> Hotspot {
        guard let data = UserDefaults.standard.data(forKey: "hotspot"),
              let h = try? JSONDecoder().decode(Hotspot.self, from: data) else { return Hotspot() }
        return h
    }
}
