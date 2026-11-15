import Foundation
import Darwin

/// Endereços de rede do iPhone.
enum Net {
    /// O Acesso Pessoal do iPhone sempre usa 172.20.10.1 para o próprio iPhone (rede 172.20.10.0/28).
    static let hotspotPhoneIp = "172.20.10.1"

    /// IP do iPhone na interface do Acesso Pessoal (bridge100). Ela só existe quando alguém entrou.
    static func hotspotAddress() -> String? {
        var result: String?
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("172.20.10.") { return ip }
            if name.hasPrefix("bridge") && result == nil { result = ip }
        }
        return result
    }
}
