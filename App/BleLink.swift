import Foundation
import CoreBluetooth

/// Painéis novos (Zontes 2025+). Sequência igual ao MotoNav:
///  1. acha o painel no Bluetooth LE (nome "EC" + 8 letras, ou serviço b360) e conecta;
///  2. CLIENT_INFO (0x30) e BUILD_NET (0x50) até o painel responder status=2 ("o celular cria a rede");
///  3. diferença do iPhone: o app não consegue criar o hotspot sozinho. Você liga o Acesso Pessoal
///     e o app manda o nome/senha que você cadastrou (0x52);
///  4. o painel entra no Acesso Pessoal e conta o IP dele (0x53); 0x51 fecha.
/// Depois disso o Bluetooth fica ligado só para o painel pedir a hora.
///
/// Os métodos bloqueiam: chame `provision` numa thread de trabalho, nunca na principal.
final class BleLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    static let service = CBUUID(string: "0000B360-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    static let serial = CBUUID(string: "0000B362-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    private static let scanSeconds: TimeInterval = 20
    private static let netInfoSeconds: TimeInterval = 75
    static let knownKey = "panelPeripheral"

    struct Result { let panelIp: String; let phoneIp: String }

    private let dash: Dash
    private let hotspot: Hotspot
    private let alive: () -> Bool
    private let queue = DispatchQueue(label: "tron.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var serialChar: CBCharacteristic?
    private let events = BlockingQueue<String>()
    private let frames = BlockingQueue<EcBtp.Frame>()
    private let assembler = EcBtp.Assembler()
    private let writeLock = NSLock()
    private var closed = false
    private var provisioned = false
    private var lostAt: Date?

    // busca
    private var match: CBPeripheral?
    private var best: (CBPeripheral, Int)?
    private var seen = Set<UUID>()

    /// Onde parou (vai para o log).
    private(set) var why = ""
    private(set) var found = false
    var onLost: (() -> Void)?

    init(dash: Dash, hotspot: Hotspot, alive: @escaping () -> Bool) {
        self.dash = dash
        self.hotspot = hotspot
        self.alive = alive
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    private func fail(_ msg: String) -> Result? {
        if !alive() || closed { why = ""; return nil }
        why = msg
        Log.d("BLE: \(msg)")
        return nil
    }

    func provision(state: (String) -> Void, openHotspot: () -> Void) -> Result? {
        // o CoreBluetooth leva um instante para dizer se o Bluetooth está ligado
        let until = Date().addingTimeInterval(5)
        while central.state == .unknown || central.state == .resetting, Date() < until { Thread.sleep(forTimeInterval: 0.1) }
        switch central.state {
        case .poweredOn: break
        case .unauthorized:
            state("Libere o Bluetooth para o Tron Racing em Ajustes > Privacidade > Bluetooth.")
            return fail("Bluetooth não autorizado")
        default:
            state("Ligue o Bluetooth do iPhone (a moto conecta por ele).")
            return fail("Bluetooth desligado (estado \(central.state.rawValue))")
        }
        guard hotspot.isComplete else {
            state("Cadastre o nome e a senha do Acesso Pessoal.")
            return fail("Acesso Pessoal não cadastrado")
        }
        // painel já conhecido: conecta direto pelo identificador, sem busca. Funciona com o app em
        // segundo plano (a busca em segundo plano o iOS restringe).
        var linked = false
        if let k = knownPeripheral() {
            state("Conectando na moto pelo Bluetooth...")
            Log.d("BLE: tentando o painel já conhecido (\(k.name ?? k.identifier.uuidString))")
            linked = connect(k, attempts: 2)
        }
        if !linked {
            if !alive() { return nil }
            state("Procurando a moto no Bluetooth (ligue a moto e abra a tela do QR no painel)...")
            guard let dev = findDevice() else {
                return fail("painel \(dash.bleName ?? "") não apareceu no Bluetooth em \(Int(BleLink.scanSeconds)) s")
            }
            if !alive() { return nil }
            state("Moto encontrada. Conectando no Bluetooth...")
            guard connect(dev, attempts: 4) else { return fail("achou o painel, mas a conexão Bluetooth (b362) falhou") }
        }
        found = true
        if let p = peripheral { UserDefaults.standard.set(p.identifier.uuidString, forKey: BleLink.knownKey) }
        guard handshake() else { return fail(why.isEmpty ? "painel não respondeu status=2 ao BUILD_NET" : why) }
        if !alive() { return nil }

        let phoneIp = Net.hotspotAddress() ?? Net.hotspotPhoneIp
        guard let ap = EcBtp.apInfoFrame(ssid: hotspot.ssid, pwd: hotspot.password, auth: "WPA2", phoneIp: phoneIp) else {
            return fail("nome/senha do Acesso Pessoal grandes demais")
        }
        Log.d("Acesso Pessoal: \"\(hotspot.ssid)\", iPhone em \(phoneIp)")
        frames.clear()
        // o iPhone só deixa a rede visível com a tela do Acesso Pessoal aberta: abre os Ajustes agora
        state("Abrindo Ajustes > Acesso Pessoal. FIQUE NESSA TELA até o painel entrar (até 1 min).")
        openHotspot()
        Thread.sleep(forTimeInterval: 4)
        if !alive() { return nil }
        guard write(ap, label: "AP_INFO (hotspot, senha oculta)") else { return fail("falhou ao mandar o hotspot (0x52)") }
        guard let ip = waitPanelIp(phoneIp: phoneIp) else {
            return fail("hotspot enviado, mas o painel não entrou no Acesso Pessoal em \(Int(BleLink.netInfoSeconds)) s " +
                        "(confira nome/senha e ligue \"Maximizar Compatibilidade\")")
        }
        if peripheral != nil && lostAt == nil {
            _ = write(EcBtp.build(EcBtp.buildNetFinish), label: "BUILD_NET_FINISH")
            _ = write(EcBtp.syncTimeFrame(), label: "hora (0x01)")
            startTimeResponder()
        }
        provisioned = true
        return Result(panelIp: ip, phoneIp: Net.hotspotAddress() ?? phoneIp)
    }

    /// Manda a hora do iPhone para o painel (o relógio da moto conta do zero desde a ignição).
    @discardableResult
    func sendTime() -> Bool {
        guard peripheral != nil, serialChar != nil, lostAt == nil, !closed else { return false }
        return write(EcBtp.syncTimeFrame(), label: "hora do iPhone (\(Geo.clock(Date())))")
    }

    func close() {
        if closed { return }
        closed = true
        provisioned = false
        queue.sync {
            if central.isScanning { central.stopScan() }
            if let p = peripheral { central.cancelPeripheralConnection(p) }
        }
        peripheral = nil
        Log.d("BLE: Bluetooth encerrado")
    }

    // ------------------------------------------------------------------ busca

    private func isPanelName(_ n: String?) -> Bool {
        guard let n = n?.uppercased() else { return false }
        if let want = dash.bleName?.uppercased() { return n == want }
        return false
    }

    private func looksLikePanel(_ n: String?, _ uuids: [CBUUID]) -> Bool {
        if let n = n?.uppercased(), n.range(of: "^EC[0-9A-F]{8}$", options: .regularExpression) != nil { return true }
        return uuids.contains(BleLink.service)
    }

    private func findDevice() -> CBPeripheral? {
        // painel já conectado ao iPhone (por outro app, ex. Carbit): o painel para de se anunciar
        let connected = queue.sync { central.retrieveConnectedPeripherals(withServices: [BleLink.service]) }
        if let p = connected.first(where: { isPanelName($0.name) }) ?? (dash.bleName == nil ? connected.first : nil) {
            Log.d("BLE: o painel já está conectado ao iPhone (outro app?): usando essa conexão")
            return p
        }
        queue.sync { match = nil; best = nil; seen.removeAll() }
        events.clear()
        queue.sync {
            // com o app em segundo plano o iOS só deixa buscar por serviço
            let services: [CBUUID]? = AppForeground.isActive ? nil : [BleLink.service]
            central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        let started = Date()
        let deadline = started.addingTimeInterval(BleLink.scanSeconds)
        while alive(), Date() < deadline {
            if events.poll(timeout: 0.25) == "match" { break }
            // sem nome conhecido, o 1º painel "parecido" serve depois de 5 s
            if dash.bleName == nil, queue.sync(execute: { best != nil }), Date().timeIntervalSince(started) > 5 { break }
        }
        queue.sync { central.stopScan() }
        if let m = queue.sync(execute: { match }) { return m }
        let b = queue.sync { best?.0 }
        if dash.bleName == nil { return b }
        if let b = b { Log.d("BLE: o painel do QR (\(dash.bleName ?? "")) não apareceu; há outro painel por perto (\(b.name ?? "?"))") }
        if alive() {
            let n = queue.sync { seen.count }
            Log.d("BLE: o painel não se anunciou; a busca viu \(n) aparelhos Bluetooth" +
                  (n == 0 ? " (Bluetooth do iPhone com problema?)" : " (o painel pode estar conectado a outro celular ou ao app Carbit)"))
        }
        return nil
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        seen.insert(p.identifier)
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if isPanelName(name) {
            if match == nil { Log.d("BLE: painel encontrado \(name ?? "") (rssi \(RSSI))") }
            match = p
            events.offer("match")
            return
        }
        if looksLikePanel(name, uuids) {
            let r = RSSI.intValue
            if best == nil || r > best!.1 {
                if best?.0.identifier != p.identifier { Log.d("BLE: painel parecido \(name ?? "?") (rssi \(r))") }
                best = (p, r)
            }
        }
    }

    // ------------------------------------------------------------------ GATT

    private func knownPeripheral() -> CBPeripheral? {
        guard let s = UserDefaults.standard.string(forKey: BleLink.knownKey), let id = UUID(uuidString: s) else { return nil }
        return queue.sync { central.retrievePeripherals(withIdentifiers: [id]).first }
    }

    private func connect(_ p: CBPeripheral, attempts: Int) -> Bool {
        for attempt in 1...attempts {
            if !alive() { return false }
            events.clear()
            serialChar = nil
            lostAt = nil
            peripheral = p
            queue.sync {
                p.delegate = self
                central.connect(p, options: nil)
            }
            if waitEvent("conn:true", 15) {
                Thread.sleep(forTimeInterval: 0.6)
                queue.sync { p.discoverServices([BleLink.service]) }
                if waitEvent("chr", 12), serialChar != nil {
                    queue.sync { p.setNotifyValue(true, for: serialChar!) }
                    if waitEvent("notify", 5) {
                        let mtu = p.maximumWriteValueLength(for: .withoutResponse) + 3
                        Log.d("BLE: conectado (MTU \(mtu)), notificações ativas")
                        return true
                    }
                    Log.d("BLE: não consegui ativar as notificações")
                } else {
                    Log.d("BLE: serviço b360/b362 não encontrado (tentativa \(attempt))")
                }
            } else {
                Log.d("BLE: conexão falhou (tentativa \(attempt))")
            }
            queue.sync { central.cancelPeripheralConnection(p) }
            Thread.sleep(forTimeInterval: 1.5)
        }
        return false
    }

    private func handshake() -> Bool {
        frames.clear()
        _ = write(EcBtp.clientInfoFrame("TronRacing"), label: "CLIENT_INFO")
        if waitFrame(4, { $0.cmd == EcBtp.clientInfo || $0.cmd == EcBtp.handshakeResponse }) == nil {
            Log.d("BLE: painel não respondeu ao CLIENT_INFO; seguindo")
        }
        _ = write(EcBtp.syncTimeFrame(), label: "hora (0x01)")
        // status -1 = painel ainda "pensando"; repete até 6x
        for attempt in 1...6 {
            if !alive() { return false }
            guard write(EcBtp.build(EcBtp.buildNet), label: "BUILD_NET") else { return false }
            let r = waitFrame(4, { $0.cmd == EcBtp.buildNet })
            let status = r?.field("status").flatMap { Int($0) }
            Log.d("BLE: BUILD_NET tentativa \(attempt): status=\(status.map { String($0) } ?? "nenhum")")
            switch status {
            case 2: return true
            case -1, nil: Thread.sleep(forTimeInterval: 1)
            default:
                why = "BUILD_NET status=\(status!) (só o 2 = hotspot do celular é suportado): \(r?.text.prefix(150) ?? "")"
                return false
            }
        }
        return false
    }

    private func write(_ frame: [UInt8], label: String) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let p = peripheral, let c = serialChar else { return false }
        let withResp = c.properties.contains(.write)
        let type: CBCharacteristicWriteType = withResp ? .withResponse : .withoutResponse
        let maxLen = max(20, p.maximumWriteValueLength(for: type))
        var off = 0
        while off < frame.count {
            let end = min(off + maxLen, frame.count)
            let chunk = Data(frame[off..<end])
            events.removeAll { $0 == "write" }
            queue.sync { p.writeValue(chunk, for: c, type: type) }
            if withResp && !waitEvent("write", 3) {
                Log.d("BLE -> \(label) (\(frame.count) bytes) sem confirmação")
            } else if !withResp {
                Thread.sleep(forTimeInterval: 0.02)
            }
            off = end
        }
        Log.d("BLE -> \(label) (\(frame.count) bytes)")
        return true
    }

    private func waitEvent(_ name: String, _ seconds: TimeInterval) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while true {
            let left = until.timeIntervalSinceNow
            if left <= 0 { return false }
            guard let e = events.poll(timeout: left) else { return false }
            if e == name { return true }
            if e.hasPrefix("conn:false") { return false }
        }
    }

    private func waitFrame(_ seconds: TimeInterval, _ match: (EcBtp.Frame) -> Bool) -> EcBtp.Frame? {
        let until = Date().addingTimeInterval(seconds)
        while alive() {
            let left = until.timeIntervalSinceNow
            if left <= 0 { return nil }
            guard let f = frames.poll(timeout: min(left, 0.5)) else { continue }
            if answerTime(f) { continue }
            if match(f) { return f }
            Log.d("BLE <- \(f)")
        }
        return nil
    }

    /// O painel pode pedir a hora a qualquer momento.
    private func answerTime(_ f: EcBtp.Frame) -> Bool {
        switch f.cmd {
        case EcBtp.syncTime: _ = write(EcBtp.syncTimeFrame(), label: "hora (0x01)"); return true
        case EcBtp.queryTime: _ = write(EcBtp.queryTimeFrame(), label: "hora em texto (0x55)"); return true
        default: return false
        }
    }

    private func startTimeResponder() {
        Thread.detachNewThread { [weak self] in
            while let me = self, !me.closed {
                guard let f = me.frames.poll(timeout: 1) else { continue }
                if !me.answerTime(f) { Log.d("BLE <- \(f)") }
            }
        }
    }

    /// Espera o painel entrar no Acesso Pessoal: pelo 0x53 no Bluetooth ou achando ele na rede.
    private func waitPanelIp(phoneIp: String) -> String? {
        let lock = NSLock()
        var foundIp: String?
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return foundIp }
        func set(_ ip: String) { lock.lock(); if foundIp == nil { foundIp = ip }; lock.unlock() }
        let until = Date().addingTimeInterval(BleLink.netInfoSeconds)
        var stop = false
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 3)
            var round = 0
            while get() == nil, !stop, let me = self, me.alive(), !me.closed, Date() < until {
                round += 1
                if let ip = BleLink.probeHotspot(until: until) {
                    Log.d("Acesso Pessoal: painel achado na rede em \(ip) (busca \(round))")
                    set(ip)
                } else {
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
        defer { stop = true }
        var lostLogged = false
        while alive(), !closed, Date() < until {
            if let ip = get() { return ip }
            if lostAt != nil && !lostLogged {
                lostLogged = true
                Log.d("BLE: Bluetooth caiu depois do hotspot; continuo procurando o painel no Acesso Pessoal")
            }
            guard let f = frames.poll(timeout: 0.3) else { continue }
            if answerTime(f) { continue }
            if f.cmd != EcBtp.carNetInfo { Log.d("BLE <- \(f)"); continue }
            guard let ip = EcBtp.ips(f).first else { Log.d("BLE: 0x53 sem IP: \(f)"); continue }
            Log.d("BLE <- painel entrou no Acesso Pessoal com IP \(ip)")
            set(ip)
            return get()
        }
        return get()
    }

    /// Tenta a porta 10930 nos endereços da rede do Acesso Pessoal (172.20.10.2 a .14).
    /// "Conexão recusada" também vale: o aparelho existe e só ainda não abriu a porta.
    static func probeHotspot(until: Date) -> String? {
        guard let mine = Net.hotspotAddress(), mine.hasPrefix("172.20.10.") else { return nil }
        let lock = NSLock()
        var hit: String?
        let group = DispatchGroup()
        for host in 2...14 {
            let ip = "172.20.10.\(host)"
            if ip == mine { continue }
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if Date() > until { return }
                do {
                    let s = try TCPSocket.connect(host: ip, port: Pxc.portWakeup, bindIP: mine, timeout: 0.8)
                    s.close()
                    lock.lock(); if hit == nil { hit = ip }; lock.unlock()
                } catch let e as SockError where e.isRefused {
                    lock.lock(); if hit == nil { hit = ip }; lock.unlock()
                } catch {}
            }
        }
        group.wait()
        return hit
    }

    // ------------------------------------------------------------------ delegados

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.d("BLE: estado do Bluetooth \(central.state.rawValue)")
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { events.offer("conn:true") }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Log.d("BLE: falha ao conectar: \(error?.localizedDescription ?? "?")")
        events.offer("conn:false")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Log.d("BLE: desconectado (\(error?.localizedDescription ?? "sem erro"))")
        if serialChar != nil && lostAt == nil { lostAt = Date() }
        events.offer("conn:false")
        if provisioned && !closed { onLost?() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == BleLink.service }) else {
            Log.d("BLE: serviços vistos: \(p.services?.map { $0.uuid.uuidString }.joined(separator: " ") ?? "nenhum")")
            events.offer("chr")
            return
        }
        p.discoverCharacteristics([BleLink.serial], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        serialChar = s.characteristics?.first(where: { $0.uuid == BleLink.serial })
        events.offer("chr")
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let e = error { Log.d("BLE: notificação recusada: \(e.localizedDescription)") }
        events.offer(error == nil ? "notify" : "notify-fail")
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) { events.offer("write") }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        for f in assembler.feed([UInt8](v)) { frames.offer(f) }
    }
}

/// O app está na tela? (atualizado pela interface; a busca Bluetooth muda em segundo plano)
enum AppForeground {
    private static let lock = NSLock()
    private static var _active = true
    static var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set {
            lock.lock(); let changed = _active != newValue; _active = newValue; lock.unlock()
            if changed { Log.d(newValue ? "app na tela" : "app em segundo plano (iPhone bloqueado ou outro app)") }
        }
    }
}
