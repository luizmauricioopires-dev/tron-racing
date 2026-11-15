import Foundation

/// Quadros "EC-BTP" do Bluetooth dos painéis novos (Zontes 2025+). Mesmo formato do MotoNav,
/// que aprendeu com o projeto aberto ZC-Panel:
///     0x24 | CMD | LEN | payload | XOR | 0x0A      LEN = payload + 4
enum EcBtp {
    static let start: UInt8 = 0x24
    static let end: UInt8 = 0x0A
    static let maxPayload = 251

    static let syncTime: UInt8 = 0x01       // painel pede a hora
    static let clientInfo: UInt8 = 0x30     // celular se apresenta
    static let buildNet: UInt8 = 0x50       // "como montamos a rede?" status 2 = hotspot do celular
    static let buildNetFinish: UInt8 = 0x51
    static let apInfo: UInt8 = 0x52         // celular manda nome/senha do hotspot
    static let carNetInfo: UInt8 = 0x53     // painel conta o IP que recebeu
    static let queryTime: UInt8 = 0x55      // painel pede a hora em texto
    static let handshakeResponse: UInt8 = 0x58

    struct Frame: CustomStringConvertible {
        let cmd: UInt8
        let payload: [UInt8]
        var text: String { String(decoding: payload, as: UTF8.self) }

        func field(_ name: String) -> String? {
            let pattern = "\"" + NSRegularExpression.escapedPattern(for: name) + "\"\\s*:\\s*(\"([^\"]*)\"|-?[0-9]+)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let t = text
            guard let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            if let r2 = Range(m.range(at: 2), in: t), !t[r2].isEmpty { return String(t[r2]) }
            if let r1 = Range(m.range(at: 1), in: t) { return String(t[r1]) }
            return nil
        }

        var description: String { String(format: "0x%02X ", cmd) + Pxc.preview(payload, max: 200) }
    }

    static func build(_ cmd: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= maxPayload)
        var out: [UInt8] = [start, cmd, UInt8(payload.count + 4)]
        out += payload
        var x: UInt8 = 0
        for b in out { x ^= b }
        out.append(x)
        out.append(end)
        return out
    }

    static func clientInfoFrame(_ phoneId: String) -> [UInt8] {
        let id = String(phoneId.filter { $0.isLetter || $0.isNumber }.prefix(32))
        return build(clientInfo, [UInt8]("{\"phoneType\":0,\"phoneID\":\"\(id)\"}".utf8))
    }

    /// nil se não couber num quadro.
    static func apInfoFrame(ssid: String, pwd: String, auth: String, phoneIp: String) -> [UInt8]? {
        let dict: [String: String] = ["ssid": ssid, "pwd": pwd, "auth": auth, "mac": "", "ip": phoneIp]
        guard let json = try? JSONSerialization.data(withJSONObject: dict, options: [.withoutEscapingSlashes]) else { return nil }
        if json.count > maxPayload { return nil }
        return build(apInfo, [UInt8](json))
    }

    /// Resposta ao 0x01: epoch em ms já somado ao fuso (sem horário de verão), 8 bytes LE.
    static func syncTimeFrame(_ now: Date = Date()) -> [UInt8] {
        let tz = TimeZone.current
        let raw = tz.secondsFromGMT(for: now) - Int(tz.daylightSavingTimeOffset(for: now))
        var v = Int64(now.timeIntervalSince1970 * 1000) + Int64(raw) * 1000
        var bytes = [UInt8]()
        for _ in 0..<8 { bytes.append(UInt8(v & 0xFF)); v >>= 8 }
        return build(syncTime, bytes)
    }

    /// Resposta ao 0x55: "dd.MM.yyyy HH:mm:ss:zzz".
    static func queryTimeFrame(_ now: Date = Date()) -> [UInt8] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM.yyyy HH:mm:ss:zzz"
        return build(queryTime, Array([UInt8](f.string(from: now).utf8).prefix(maxPayload)))
    }

    static func ips(_ f: Frame) -> [String] {
        let t = f.text
        guard let re = try? NSRegularExpression(pattern: "\"ip\"\\s*:\\s*\"([0-9]{1,3}(\\.[0-9]{1,3}){3})\"") else { return [] }
        return re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap {
            Range($0.range(at: 1), in: t).map { String(t[$0]) }
        }
    }

    /// Junta pedaços das notificações (um quadro pode vir picotado, ou vários juntos).
    final class Assembler {
        private var buf: [UInt8] = []
        private let lock = NSLock()

        func feed(_ chunk: [UInt8]) -> [Frame] {
            lock.lock(); defer { lock.unlock() }
            buf += chunk
            var frames: [Frame] = []
            var i = 0
            while true {
                while i < buf.count && buf[i] != EcBtp.start { i += 1 }
                if buf.count - i < 3 { break }
                let total = Int(buf[i + 2]) + 1
                if total < 5 { i += 1; continue }
                if buf.count - i < total { break }
                if let f = parse(i, total) { frames.append(f); i += total } else { i += 1 }
            }
            buf = Array(buf[i...])
            if buf.count > 1024 { buf.removeAll() }
            return frames
        }

        private func parse(_ off: Int, _ total: Int) -> Frame? {
            if buf[off + total - 1] != EcBtp.end { return nil }
            var x: UInt8 = 0
            for k in off..<(off + total - 2) { x ^= buf[k] }
            if x != buf[off + total - 2] { return nil }
            return Frame(cmd: buf[off + 1], payload: Array(buf[(off + 3)..<(off + total - 2)]))
        }
    }
}

/// Enquadramento dos pacotes do painel no Wi-Fi (portas 10930 e 10922):
/// cabeçalho de 16 bytes little-endian = [cmd][tamanhoTotal][cmd xor tamanhoTotal][0] + payload.
/// A resposta de um comando X é sempre X+1.
enum Pxc {
    static let portWakeup: UInt16 = 10930   // painel escuta; o celular conecta
    static let portPxc: UInt16 = 10922      // celular escuta; painel conecta (C2P e P2C)
    static let portRvCtrl: UInt16 = 10921   // celular escuta; controle do vídeo
    static let portRvData: UInt16 = 10920   // celular escuta; vídeo H.264

    static let connC2P: Int32 = 0x00010000
    static let connP2C: Int32 = 0x00020000

    static let cmdWakeup: Int32 = 0x70000010
    static let cmdClientInfo: Int32 = 0x00010010
    static let cmdCheckSn: Int32 = 0x000103E0
    static let cmdKeepalive: Int32 = 0x70000000
    static let cmdP2cDisplay: Int32 = 0x00020020
    static let cmdUnsupported: Int32 = Int32(bitPattern: 0x80000010)

    struct Packet {
        let cmd: Int32
        let payload: [UInt8]
        var text: String { String(decoding: payload, as: UTF8.self) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any] ?? [:] }
    }

    static func read(_ s: TCPSocket) throws -> Packet {
        let h = try s.readFully(16)
        let cmd = h.le32(0), len = h.le32(4), magic = h.le32(8)
        if (cmd ^ len) != magic || len < 16 || len > 1024 * 1024 {
            throw SockError.sys("cabeçalho fora do formato PXC: \(h.hex)", EINVAL)
        }
        return Packet(cmd: cmd, payload: try s.readFully(Int(len) - 16))
    }

    static func write(_ s: TCPSocket, _ cmd: Int32, _ payload: [UInt8] = []) throws {
        let len = Int32(16 + payload.count)
        var out = [UInt8]()
        out.reserveCapacity(Int(len))
        out.appendLE32(cmd); out.appendLE32(len); out.appendLE32(cmd ^ len); out.appendLE32(0)
        out += payload
        try s.write(out)
    }

    static func write(_ s: TCPSocket, _ cmd: Int32, json: [String: Any]) throws {
        let d = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        try write(s, cmd, [UInt8](d))
    }

    /// Comandos para os quais o app oficial NÃO responde.
    static func expectsNoReply(_ cmd: Int32) -> Bool {
        cmd == 262160 || cmd == 196656 || cmd == 196640 || cmd == 196672 || cmd == 66224 ||
            (UInt32(bitPattern: cmd) & 0xFF000000) == 0x60000000
    }

    static func hex(_ cmd: Int32) -> String { String(format: "0x%08X", UInt32(bitPattern: cmd)) }

    static func preview(_ payload: [UInt8], max: Int = 400) -> String {
        if payload.isEmpty { return "(vazio)" }
        let s = String(decoding: payload, as: UTF8.self)
        let ok = s.filter { $0.isLetter || $0.isNumber || " {}[]\":,._-/\\+=\n\r\t".contains($0) }.count
        if Double(ok) >= Double(s.count) * 0.9 { return String(s.prefix(max)).replacingOccurrences(of: "\n", with: " ") }
        return "[\(payload.count) bytes] " + Array(payload.prefix(32)).hex
    }
}
