import Foundation
import UIKit

/// Conexão com o painel da moto (painéis 2025+: Bluetooth + Acesso Pessoal do iPhone).
/// Mesma ordem do MotoNav: Bluetooth -> painel entra no hotspot -> wakeup na 10930 ->
/// painel conecta de volta nas portas 10922 (controle), 10921 e 10920 (vídeo).
final class DashLink {
    static let shared = DashLink()

    enum Phase: Equatable { case idle, searching, linking, video, error }

    /// (texto para a tela, fase)
    var onState: ((String, Phase) -> Void)?
    /// Abre Ajustes > Acesso Pessoal (a rede do iPhone só fica visível com essa tela aberta).
    var onOpenHotspot: (() -> Void)?

    private let lock = NSLock()
    private var running = false
    private var sessionStarted = false
    private var sessionGen = 0
    private var c2pOpenedGen = -1
    private var panelIp: String?
    private var phoneIp: String?
    private var ble: BleLink?
    private var servers: [TCPServer] = []
    private var sockets: [TCPSocket] = []
    private var videoConns = 0
    private var lastP2cRxAt = Date.distantPast
    private var searchUntil = Date.distantPast
    private let rv = RvServer()
    private var dash: Dash?
    private var hotspot = Hotspot()

    private static let packageName = "br.com.monteiro.tronracing"

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func state(_ s: String, _ p: Phase) {
        Log.d("estado: \(s)")
        DispatchQueue.main.async { self.onState?(s, p) }
    }

    // ------------------------------------------------------------------ ligar/desligar

    func start(dash: Dash, hotspot: Hotspot) {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        sessionStarted = false
        self.dash = dash
        self.hotspot = hotspot
        searchUntil = Date().addingTimeInterval(300)
        lock.unlock()
        Log.d("=== Tron Racing: conectando ao painel \(dash.name) (\(dash.bleName ?? "sem nome BLE")) — iOS \(UIDevice.current.systemVersion)")
        KeepAlive.shared.start()
        startServers()
        startBle()
    }

    func stop() {
        lock.lock()
        if !running { lock.unlock(); return }
        running = false
        sessionStarted = false
        sessionGen += 1
        let srv = servers, socks = sockets, b = ble
        servers = []; sockets = []; ble = nil; panelIp = nil
        lock.unlock()
        srv.forEach { $0.close() }
        socks.forEach { $0.close() }
        b?.close()
        FrameHub.shared.panelStoppedVideo()
        KeepAlive.shared.stop()
        state("Desconectado. O painel volta para a tela original da moto.", .idle)
    }

    /// Conexão caiu (moto desligada, saiu do alcance): fecha tudo e procura de novo.
    /// Reconexões rápidas seguidas (só pelo Wi-Fi). Zera quando o vídeo volta.
    private var quickStreak = 0

    private func onSessionLost() {
        lock.lock()
        guard running, sessionStarted else { lock.unlock(); return }
        // 1ª tentativa: o painel costuma continuar no Acesso Pessoal; só acorda ele de novo pelo
        // Wi-Fi (1 a 3 s), sem refazer o Bluetooth e sem abrir os Ajustes.
        if let ip = panelIp, quickStreak < 1 {
            quickStreak += 1
            sessionGen += 1
            let socks = sockets
            sockets = []
            lock.unlock()
            socks.forEach { $0.close() }
            FrameHub.shared.panelStoppedVideo()
            state("Conexão piscou. Reconectando direto pelo Wi-Fi...", .linking)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.sendWakeup(ip, quick: true) }
            return
        }
        sessionStarted = false
        sessionGen += 1
        let socks = sockets, b = ble
        sockets = []; ble = nil; panelIp = nil
        searchUntil = Date().addingTimeInterval(180)
        lock.unlock()
        socks.forEach { $0.close() }
        b?.close()
        FrameHub.shared.panelStoppedVideo()
        state("Conexão com o painel caiu. Procurando de novo...", .searching)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self.startBle() }
    }

    // ------------------------------------------------------------------ Bluetooth

    private var bleBusy = false

    private func startBle() {
        lock.lock()
        guard running, !bleBusy, let d = dash else { lock.unlock(); return }
        bleBusy = true
        let hs = hotspot
        lock.unlock()
        Thread.detachNewThread {
            defer { self.lock.lock(); self.bleBusy = false; self.lock.unlock() }
            while self.isRunning && !self.started {
                if Date() > self.searchUntilValue {
                    self.state("Moto não encontrada (desligada?). Toque em Conectar para procurar de novo.", .error)
                    DispatchQueue.main.async { self.stop() }
                    return
                }
                let link = BleLink(dash: d, hotspot: hs) { [weak self] in self?.isRunning ?? false }
                self.lock.lock(); self.ble = link; self.lock.unlock()
                if let r = link.provision(state: { self.state($0, .searching) },
                                          openHotspot: { DispatchQueue.main.async { self.onOpenHotspot?() } }),
                   self.isRunning {
                    link.onLost = { [weak self] in
                        // roda fora da fila do Bluetooth (fechar o BLE lá dentro travaria)
                        DispatchQueue.global().async { self?.bleLost() }
                    }
                    self.lock.lock()
                    self.sessionGen += 1
                    self.sessionStarted = true
                    self.panelIp = r.panelIp
                    self.phoneIp = r.phoneIp
                    self.lock.unlock()
                    self.state("Painel entrou no Acesso Pessoal (\(r.panelIp)). Acordando o painel...", .linking)
                    self.sendWakeup(r.panelIp)
                    return
                }
                if !link.why.isEmpty { self.state("Tentando de novo: \(link.why)", .searching) }
                link.close()
                self.lock.lock(); if self.ble === link { self.ble = nil }; self.lock.unlock()
                if self.isRunning { Thread.sleep(forTimeInterval: 4) }
            }
        }
    }

    private var started: Bool { lock.lock(); defer { lock.unlock() }; return sessionStarted }
    private var searchUntilValue: Date { lock.lock(); defer { lock.unlock() }; return searchUntil }

    /// Depois que o painel entrou no hotspot, o Bluetooth só serve para acertar a hora; quem diz se a
    /// moto desligou é o Wi-Fi.
    private func bleLost() {
        let now = Date()
        lock.lock(); let p2c = lastP2cRxAt; let vc = videoConns; lock.unlock()
        if now.timeIntervalSince(rv.lastPollAt) < 5 || now.timeIntervalSince(p2c) < 6 || vc > 0 {
            Log.d("Bluetooth do painel caiu, mas o Wi-Fi continua: mantendo a conexão")
        } else {
            Log.d("Bluetooth do painel caiu e o Wi-Fi está parado (moto desligada?)")
            onSessionLost()
        }
    }

    // ------------------------------------------------------------------ relógio

    /// O painel descarta a hora recebida no começo quando monta o vídeo: manda de novo depois.
    private var clockSyncedGen = -1

    private func syncClockLater() {
        lock.lock()
        let gen = sessionGen
        if clockSyncedGen == gen { lock.unlock(); return }
        clockSyncedGen = gen
        lock.unlock()
        for delay in [2.0, 8.0, 30.0] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                guard self.isRunning, self.currentGen == gen else { return }
                self.syncClock()
            }
        }
    }

    /// Acerta o relógio da moto com a hora do iPhone (também pelo botão nos Ajustes).
    @discardableResult
    func syncClock() -> Bool {
        lock.lock(); let b = ble; lock.unlock()
        let ok = b?.sendTime() ?? false
        if !ok { Log.d("relógio: sem Bluetooth com o painel agora") }
        return ok
    }

    // ------------------------------------------------------------------ wakeup (10930)

    private func wakeupBody() -> [String: Any] { ["phoneType": "Android", "packageName": DashLink.packageName] }

    private func sendWakeup(_ panel: String, quick: Bool = false) {
        lock.lock(); let gen = sessionGen; let local = phoneIp; lock.unlock()
        for attempt in 1...(quick ? 8 : 20) {
            if !isRunning || gen != currentGen { return }
            do {
                let s = try TCPSocket.connect(host: panel, port: Pxc.portWakeup, bindIP: local, timeout: 3)
                defer { s.close() }
                s.setReadTimeout(5)
                try Pxc.write(s, Pxc.cmdWakeup, json: wakeupBody())
                Log.d("10930 -> wakeup enviado (\(DashLink.packageName))")
                let resp = try Pxc.read(s)
                Log.d("10930 <- \(Pxc.hex(resp.cmd)) \(Pxc.preview(resp.payload))")
                let ok = "\(resp.json["status"] ?? "")".lowercased()
                if ok == "true" || ok == "1" {
                    state("Painel aceitou. Esperando ele abrir o vídeo...", .linking)
                } else {
                    state("Painel respondeu status=\(ok). Veja o diário.", .error)
                }
                reprobeIfSilent(panel, gen: gen, tries: quick ? 1 : 3)
                return
            } catch {
                if attempt <= 3 || attempt % 5 == 0 { Log.d("wakeup tentativa \(attempt) falhou: \(error)") }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        state("O painel não respondeu na porta 10930. Tentando de novo...", .searching)
        onSessionLost()
    }

    private var currentGen: Int { lock.lock(); defer { lock.unlock() }; return sessionGen }

    /// Às vezes o painel aceita o wakeup e não conecta de volta: manda de novo (até 3 vezes).
    private func reprobeIfSilent(_ panel: String, gen: Int, tries: Int = 3) {
        for i in 1...tries {
            Thread.sleep(forTimeInterval: 8)
            lock.lock(); let opened = c2pOpenedGen == gen; let g = sessionGen; lock.unlock()
            if !isRunning || g != gen || opened { return }
            Log.d("painel não conectou de volta em 8 s; wakeup de novo (\(i)/\(tries))")
            do {
                let s = try TCPSocket.connect(host: panel, port: Pxc.portWakeup, bindIP: phoneIp, timeout: 3)
                defer { s.close() }
                s.setReadTimeout(5)
                try Pxc.write(s, Pxc.cmdWakeup, json: wakeupBody())
                Log.d("10930 <- " + Pxc.preview(try Pxc.read(s).payload))
            } catch {
                Log.d("wakeup de novo falhou: \(error)")
            }
        }
        lock.lock(); let opened = c2pOpenedGen == gen; let g = sessionGen; lock.unlock()
        if isRunning && g == gen && !opened {
            state("O painel aceitou o app mas não abriu a conexão. Tentando de novo...", .searching)
            onSessionLost()
        }
    }

    // ------------------------------------------------------------------ servidores

    private func startServers() {
        listen(Pxc.portPxc) { s in try self.handlePxc(s) }
        listen(Pxc.portRvCtrl) { s in
            self.state("Painel abriu o controle de vídeo.", .linking)
            try self.rv.handleCtrl(s)
        }
        listen(Pxc.portRvData) { s in
            self.lock.lock(); self.videoConns += 1; self.lock.unlock()
            defer {
                self.lock.lock(); self.videoConns -= 1; let n = self.videoConns; self.lock.unlock()
                if n == 0 { self.watchVideo() }
            }
            self.state("No ar! O painel está recebendo o vídeo.", .video)
            self.lock.lock(); self.quickStreak = 0; self.lock.unlock()
            self.syncClockLater()
            try self.rv.handleData(s)
        }
    }

    private func listen(_ port: UInt16, _ handler: @escaping (TCPSocket) throws -> Void) {
        let srv: TCPServer
        do { srv = try TCPServer(port: port) } catch {
            Log.d("servidor \(port): \(error)")
            state("Não consegui abrir a porta \(port) (\(error)).", .error)
            return
        }
        lock.lock(); servers.append(srv); lock.unlock()
        Log.d("ouvindo na porta \(port)")
        Thread.detachNewThread {
            while let s = srv.accept() {
                // segurança: só o painel (no Acesso Pessoal) pode conversar
                self.lock.lock(); let expected = self.panelIp; self.lock.unlock()
                guard let ip = expected, s.peerIP == ip else {
                    Log.d("porta \(port): conexão recusada de \(s.peerIP) (não é o painel)")
                    s.close()
                    continue
                }
                self.lock.lock(); self.sockets.append(s); self.lock.unlock()
                Log.d("porta \(port) <- conexão de \(s.peerIP):\(s.peerPort)")
                Thread.detachNewThread {
                    do { try handler(s) } catch { Log.d("porta \(port) (\(s.peerPort)) fechou: \(error)") }
                    s.close()
                    self.lock.lock(); self.sockets.removeAll { $0 === s }; self.lock.unlock()
                }
            }
        }
    }

    /// Saiu da projeção pelo botão do guidão? O painel fecha o vídeo e reabre ao voltar.
    /// Se não voltar em 60 s, refaz a conexão.
    private func watchVideo() {
        let gen = currentGen
        Log.d("painel fechou o vídeo (tela original da moto?): aguardando voltar")
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            self.lock.lock(); let vc = self.videoConns; let ok = self.running && self.sessionStarted && gen == self.sessionGen; self.lock.unlock()
            if ok && vc == 0 {
                Log.d("painel não reabriu o vídeo em 60 s: refazendo a conexão")
                self.onSessionLost()
            }
        }
        state("Painel mostrando a tela original da moto. Aperte o botão do guidão para voltar ao Waze.", .linking)
    }

    /// 10922: o 1º pacote diz o tipo do canal; respondemos tipo+1.
    private func handlePxc(_ s: TCPSocket) throws {
        let first = try Pxc.read(s)
        Log.d("10922 <- canal \(Pxc.hex(first.cmd))")
        try Pxc.write(s, first.cmd + 1)
        startPhoneHeartbeat(s)
        switch first.cmd {
        case Pxc.connC2P:
            lock.lock(); c2pOpenedGen = sessionGen; let myGen = sessionGen; lock.unlock()
            // sem nada por 12 s = moto desligada (o TCP não fecha sozinho)
            s.setReadTimeout(12)
            // só derruba a sessão se ainda for a mesma (fechar sockets velhos não conta)
            defer { if currentGen == myGen { onSessionLost() } }
            try c2pLoop(s)
        case Pxc.connP2C:
            try p2cLoop(s)
        default:
            while isRunning { let p = try Pxc.read(s); Log.d("10922/\(Pxc.hex(first.cmd)) <- \(Pxc.hex(p.cmd)) \(Pxc.preview(p.payload))") }
        }
    }

    /// Painéis novos fecham a sessão se o celular não mandar sinal de vida a cada 2 s.
    private func startPhoneHeartbeat(_ s: TCPSocket) {
        Thread.detachNewThread {
            while self.isRunning && !s.isClosed {
                Thread.sleep(forTimeInterval: 2)
                do { try Pxc.write(s, Pxc.cmdKeepalive) } catch { return }
            }
        }
    }

    private func c2pLoop(_ s: TCPSocket) throws {
        state("Painel abriu o canal de controle.", .linking)
        var silentLogged = false
        while isRunning {
            let p: Pxc.Packet
            do {
                p = try Pxc.read(s)
            } catch SockError.timeout {
                // painel novo às vezes fica mudo no C2P com o vídeo rodando: se o vídeo/P2C anda, está vivo
                lock.lock(); let p2c = lastP2cRxAt; lock.unlock()
                let now = Date()
                // só desiste depois de 25 s sem NADA do painel (vídeo, P2C ou C2P)
                let quiet = min(now.timeIntervalSince(rv.lastPollAt), now.timeIntervalSince(p2c))
                if quiet < 25 {
                    if !silentLogged { Log.d("C2P mudo há 12 s, mas o painel segue respondendo: mantendo"); silentLogged = true }
                    if quiet > 8 { Log.d("painel quieto há \(Int(quiet)) s; aguardando (desiste aos 25 s)") }
                    continue
                }
                Log.d("painel sem responder há \(Int(quiet)) s: refazendo a conexão")
                throw SockError.timeout
            }
            let c = p.cmd
            Log.d("C2P <- \(Pxc.hex(c)) " + (c == 0x000104A0 ? "(dados do fabricante, ocultos)" : Pxc.preview(p.payload)))
            if c % 2 != 0 { continue }
            switch c {
            case Pxc.cmdClientInfo:
                let hu = p.json
                try Pxc.write(s, c + 1, json: clientInfoReply(hu))
                Log.d("C2P -> CLIENT_INFO respondido")
                state("Painel \(hu["HUName"] ?? "") se apresentou.", .linking)
            case _ where Pxc.expectsNoReply(c):
                break
            case 0x00010450:
                try Pxc.write(s, c + 1, timeJson()) // resposta vazia zera o relógio da moto
                Log.d("C2P -> hora do iPhone (\(Geo.clock(Date())))")
            case 0x00010600:
                // o painel manda a hora dele e pergunta a certa: responde sempre com a do iPhone
                try Pxc.write(s, c + 1, timeSyncReply(p.payload))
                Log.d("C2P -> sincronização de hora respondida com a do iPhone")
            case 0x00010500, 0x00010200, Pxc.cmdKeepalive, Pxc.cmdCheckSn, 0x00010040, 0x000104A0, 0x00010430, 0x00010630:
                try Pxc.write(s, c + 1)
            default:
                try Pxc.write(s, Pxc.cmdUnsupported)
                Log.d("C2P -> não suportado \(Pxc.hex(c))")
            }
        }
    }

    private func p2cLoop(_ s: TCPSocket) throws {
        var n = 0
        while isRunning {
            let p = try Pxc.read(s)
            lock.lock(); lastP2cRxAt = Date(); lock.unlock()
            let routine = p.cmd == Pxc.cmdP2cDisplay + 1 || p.cmd == Pxc.cmdKeepalive + 1
            if !routine || n % 10 == 0 { Log.d("P2C <- \(Pxc.hex(p.cmd)) \(Pxc.preview(p.payload))") }
            n += 1
        }
    }

    private func clientInfoReply(_ hu: [String: Any]) -> [String: Any] {
        let huid = hu["HUID"] as? String ?? ""
        return [
            "pxcVersion": "1.0.2",
            "phoneUUID": RsaIdentity.phoneUuid(),
            "phoneBrand": "Apple",
            "phoneModel": "iPhone",
            "phoneOsVersion": "33",
            "phoneOs": "Android",
            "package": DashLink.packageName,
            "versionCode": 1,
            "token": 0,
            "pubkey": RsaIdentity.publicKey(),
            "encryptedHUID": RsaIdentity.encryptHuid(huid),
            "bluetoothName": "Tron Racing",
            "supportH264IFrame": true,
            "supportFunction": hu["supportFunction"] as? Int ?? 0,
            "supportSyncCorrectTime": false, // senão alguns painéis zeram o relógio
        ]
    }

    private func timeJson() -> [UInt8] {
        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let dt = f.string(from: now) + String(format: ":%03d", Int(ms % 1000))
        let d = (try? JSONSerialization.data(withJSONObject: ["time": ms, "dateTime": dt])) ?? Data()
        return [UInt8](d)
    }

    /// Resposta ao 0x10600: mesmo cabeçalho de 16 bytes + "yyyy-MM-dd HH:mm:ss.SSS000000".
    private func timeSyncReply(_ req: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 45)
        for i in 0..<min(16, req.count) { out[i] = req[i] }
        var bike = ""
        if req.count > 16 {
            bike = String(decoding: req[16..<min(45, req.count)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} "))
        }
        if !bike.isEmpty { Log.d("C2P <- hora que o painel tinha: \(bike)") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let stamp = f.string(from: Date()) + "000000"
        let a = [UInt8](stamp.utf8)
        for i in 0..<min(29, a.count) { out[16 + i] = a[i] }
        return out
    }
}
