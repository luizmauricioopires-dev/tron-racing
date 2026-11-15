import Foundation
import Darwin

/// Sockets TCP bloqueantes (BSD), no mesmo estilo de threads do MotoNav (Android).
/// Usado pelo app (conversa com o painel) e pela extensão (manda o vídeo para o app).

enum SockError: Error, CustomStringConvertible {
    case sys(String, Int32)
    case closed
    case timeout

    var description: String {
        switch self {
        case .sys(let what, let code): return "\(what): \(String(cString: strerror(code))) (\(code))"
        case .closed: return "conexão fechada"
        case .timeout: return "tempo esgotado"
        }
    }

    var isRefused: Bool {
        if case .sys(_, let c) = self { return c == ECONNREFUSED }
        return false
    }
}

private func makeAddr(_ ip: String?, _ port: UInt16) -> sockaddr_in? {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    if let ip = ip {
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
    } else {
        a.sin_addr.s_addr = INADDR_ANY
    }
    return a
}

private func ipString(_ a: sockaddr_in) -> String {
    var addr = a.sin_addr
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}

private func withSockaddr<T>(_ a: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &a) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

private func setCommonOptions(_ fd: Int32) {
    var one: Int32 = 1
    // sem isso, escrever num socket que o painel fechou mata o app (SIGPIPE)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}

final class TCPSocket {
    let fd: Int32
    let peerIP: String
    let peerPort: UInt16
    let localIP: String
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var _closed = false

    var isClosed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _closed }

    init(fd: Int32) {
        self.fd = fd
        setCommonOptions(fd)
        var peer = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &peer) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        peerIP = ipString(peer)
        peerPort = UInt16(bigEndian: peer.sin_port)
        var local = sockaddr_in(); var len2 = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len2) }
        }
        localIP = ipString(local)
    }

    deinit { close() }

    /// Conecta com prazo. `bindIP` força a saída por uma interface (a do hotspot).
    static func connect(host: String, port: UInt16, bindIP: String? = nil, timeout: TimeInterval) throws -> TCPSocket {
        guard var addr = makeAddr(host, port) else { throw SockError.sys("endereço inválido \(host)", EINVAL) }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw SockError.sys("socket", errno) }
        setCommonOptions(fd)
        if let b = bindIP, var la = makeAddr(b, 0) {
            let r = withSockaddr(&la) { Darwin.bind(fd, $0, $1) }
            if r != 0 { let e = errno; Darwin.close(fd); throw SockError.sys("bind \(b)", e) }
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withSockaddr(&addr) { Darwin.connect(fd, $0, $1) }
        if r != 0 {
            let e = errno
            if e != EINPROGRESS { Darwin.close(fd); throw SockError.sys("connect", e) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(timeout * 1000))
            if pr <= 0 { Darwin.close(fd); throw SockError.timeout }
            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { Darwin.close(fd); throw SockError.sys("connect", err) }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return TCPSocket(fd: fd)
    }

    /// 0 = sem prazo.
    func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func readFully(_ n: Int) throws -> [UInt8] {
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { p in recv(fd, p.baseAddress! + off, n - off, 0) }
            if r == 0 { throw SockError.closed }
            if r < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK { throw SockError.timeout }
                throw SockError.sys("recv", e)
            }
            off += r
        }
        return buf
    }

    /// Lê o que houver (até `max`). Vazio = fechado.
    func readSome(max: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let r = buf.withUnsafeMutableBytes { p in recv(fd, p.baseAddress!, max, 0) }
            if r == 0 { return [] }
            if r < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK { throw SockError.timeout }
                throw SockError.sys("recv", e)
            }
            return Array(buf[0..<r])
        }
    }

    func write(_ data: [UInt8]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        var off = 0
        while off < data.count {
            let r = data.withUnsafeBytes { p in send(fd, p.baseAddress! + off, data.count - off, 0) }
            if r < 0 {
                let e = errno
                if e == EINTR { continue }
                throw SockError.sys("send", e)
            }
            off += r
        }
    }

    func write(_ data: Data) throws { try write([UInt8](data)) }

    func close() {
        stateLock.lock()
        if _closed { stateLock.unlock(); return }
        _closed = true
        stateLock.unlock()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

final class TCPServer {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(port: UInt16, bindIP: String? = nil) throws {
        self.port = port
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw SockError.sys("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard var a = makeAddr(bindIP, port) else { Darwin.close(fd); throw SockError.sys("endereço", EINVAL) }
        let r = withSockaddr(&a) { Darwin.bind(fd, $0, $1) }
        if r != 0 { let e = errno; Darwin.close(fd); throw SockError.sys("bind porta \(port)", e) }
        if listen(fd, 16) != 0 { let e = errno; Darwin.close(fd); throw SockError.sys("listen", e) }
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// Espera uma conexão; devolve nil se o servidor foi fechado. Olha a cada 1 s se foi fechado.
    func accept() -> TCPSocket? {
        while !isClosed {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 1000)
            if pr <= 0 { continue }
            let c = Darwin.accept(fd, nil, nil)
            if c >= 0 { return TCPSocket(fd: c) }
            if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
            return nil
        }
        return nil
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        Darwin.close(fd)
    }
}

/// Fila bloqueante simples (equivalente ao LinkedBlockingQueue do Android).
final class BlockingQueue<T> {
    private var items: [T] = []
    private let cond = NSCondition()
    private let capacity: Int

    init(capacity: Int = Int.max) { self.capacity = capacity }

    /// false se a fila estiver cheia.
    @discardableResult
    func offer(_ item: T) -> Bool {
        cond.lock(); defer { cond.unlock() }
        if items.count >= capacity { return false }
        items.append(item)
        cond.signal()
        return true
    }

    func poll(timeout: TimeInterval) -> T? {
        cond.lock(); defer { cond.unlock() }
        let until = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !cond.wait(until: until) { break }
        }
        return items.isEmpty ? nil : items.removeFirst()
    }

    func pollNow() -> T? {
        cond.lock(); defer { cond.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    func clear() { cond.lock(); items.removeAll(); cond.unlock() }

    var count: Int { cond.lock(); defer { cond.unlock() }; return items.count }

    func removeAll(where pred: (T) -> Bool) { cond.lock(); items.removeAll(where: pred); cond.unlock() }
    func contains(where pred: (T) -> Bool) -> Bool { cond.lock(); defer { cond.unlock() }; return items.contains(where: pred) }
}

/// Bytes little-endian.
extension Array where Element == UInt8 {
    mutating func appendLE32(_ v: Int32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendLE16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    func le32(_ at: Int) -> Int32 {
        Int32(bitPattern: UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24)
    }
    func le16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
