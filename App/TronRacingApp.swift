import SwiftUI
import ReplayKit
import PhotosUI

@main
struct TronRacingApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @State private var showSplash = true

    init() {
        _ = NavEngine.shared          // liga o GPS à navegação
        _ = TripRecorder.shared       // retoma um percurso que estava gravando
        FrameHub.shared.startListening()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView()
                    .environmentObject(model)
                    .environmentObject(FrameHub.shared)
                    .environmentObject(NavEngine.shared)
                if showSplash {
                    SplashView { withAnimation(.easeOut(duration: 0.5)) { showSplash = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { p in AppForeground.isActive = (p == .active) }
    }
}

/// Estado da conexão com a moto.
final class AppModel: ObservableObject {
    @Published var dash: Dash? = Pairing.load()
    @Published var hotspot: Hotspot = Pairing.loadHotspot() { didSet { Pairing.saveHotspot(hotspot) } }
    @Published var status = "Toque em Conectar com a moto ligada."
    @Published var phase: DashLink.Phase = .idle
    @Published var connected = false
    @Published var message: String?

    init() {
        if hotspot.ssid.isEmpty { hotspot.ssid = "iPhone" }
        DashLink.shared.onState = { [weak self] text, phase in
            self?.status = text
            self?.phase = phase
            self?.connected = DashLink.shared.isRunning
        }
        DashLink.shared.onOpenHotspot = {
            // atalho direto para Ajustes > Acesso Pessoal; se o iOS recusar, abre ao menos os Ajustes
            guard let url = URL(string: "App-prefs:INTERNET_TETHERING") else { return }
            UIApplication.shared.open(url) { ok in
                Log.d("abrindo Ajustes > Acesso Pessoal: \(ok ? "ok" : "recusado")")
                if !ok, let s = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(s) }
            }
        }
    }

    func handleQr(_ raw: String) {
        switch Pairing.parse(raw) {
        case .ok(let d):
            if dash?.id != d.id { UserDefaults.standard.removeObject(forKey: BleLink.knownKey) }
            dash = d
            Pairing.save(d)
            message = "Painel \(d.name) pareado."
            Log.d("QR lido: painel \(d.name) (\(d.bleName ?? "-"))")
        case .oldPanel:
            message = "Esse painel é do modelo antigo (até 2024), que usa Wi-Fi Direct. O iPhone não tem Wi-Fi Direct, então só o Android conecta nele."
        case .invalid:
            message = "Esse QR não parece ser do painel da moto. Abra no painel a tela de conexão com o celular."
        }
    }

    func toggleConnection() {
        if DashLink.shared.isRunning {
            DashLink.shared.stop()
            connected = false
            return
        }
        guard let d = dash else { message = "Primeiro leia o QR do painel (em Ajustes, no canto de cima)."; return }
        guard hotspot.isComplete else { message = "Preencha o nome e a senha (8+ letras) do Acesso Pessoal em Ajustes."; return }
        phase = .searching
        connected = true
        // faz o iOS perguntar sobre a "Rede Local" logo de cara (sem ela o painel não recebe nada)
        DispatchQueue.global().async { _ = try? TCPSocket.connect(host: "172.20.10.14", port: Pxc.portWakeup, timeout: 0.3) }
        DashLink.shared.start(dash: d, hotspot: hotspot)
    }
}

// ====================================================================== tela inicial

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hub: FrameHub
    @EnvironmentObject var nav: NavEngine
    @StateObject private var broadcast = BroadcastTrigger()
    @State private var showNav = false
    @State private var showTrips = false
    @ObservedObject private var trips = TripRecorder.shared
    @State private var showSettings = false
    @State private var voiceOn = Voice.shared.enabled

    var body: some View {
        ZStack(alignment: .top) {
            UI.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    ZStack(alignment: .topTrailing) {
                        Image("HeroBrand").resizable().aspectRatio(contentMode: .fit)
                            .padding(.horizontal, -20)
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill").font(.system(size: 19)).foregroundColor(UI.dim)
                                .frame(width: 42, height: 42).background(Circle().fill(Color.white.opacity(0.06)))
                        }
                        .padding(.top, 6)
                    }
                    statusRow
                    Button { showNav = true } label: {
                        BigCard(color: UI.accent, icon: "location.north.line.fill", title: "Navegação",
                                subtitle: nav.navigating ? "Indo para \(nav.destination?.name ?? "destino")" : "Mapa próprio no painel")
                    }
                    .buttonStyle(.plain)
                    Button { showTrips = true } label: {
                        BigCard(color: UI.mint, icon: "book.closed.fill", title: "Diário de Bordo",
                                subtitle: trips.recording ? "Gravando · \(Geo.formatDistance(trips.current?.distance ?? 0))"
                                                          : "\(trips.trips.count) percursos · \(String(format: "%.0f", trips.monthSummary.km)) km no mês") {
                            if trips.recording { Circle().fill(UI.coral).frame(width: 12, height: 12) }
                        }
                    }
                    .buttonStyle(.plain)
                    Button { broadcast.fire() } label: {
                        BigCard(color: Color(red: 0.35, green: 0.62, blue: 1), icon: "rectangle.on.rectangle", title: "Espelhar Waze",
                                subtitle: hub.mirroring ? "Espelhando agora · toque para parar" : "A tela do iPhone no painel")
                    }
                    .buttonStyle(.plain)
                    Button { voiceOn.toggle(); Voice.shared.enabled = voiceOn } label: {
                        BigCard(color: UI.coral, icon: "camera.metering.spot", title: "Radares",
                                subtitle: "\(nav.radarCount) carregados · voz \(voiceOn ? "ligada" : "desligada")") {
                            Image(systemName: voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 20)).foregroundColor(UI.dim)
                        }
                    }
                    .buttonStyle(.plain)
                    Checkers(rows: 2, size: 8).frame(width: 160).padding(.top, 6)
                    Text("Mapa: Mapas da Apple · Radares: © OpenStreetMap. Não mexa no celular pilotando.")
                        .font(.system(size: 11)).foregroundColor(UI.dim.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
            }
            BroadcastTrigger.Host(trigger: broadcast).frame(width: 1, height: 1).opacity(0.02)
        }
        .fullScreenCover(isPresented: $showNav) { NavigationScreen().environmentObject(nav) }
        .sheet(isPresented: $showTrips) { TripsScreen() }
        .sheet(isPresented: $showSettings) {
            SettingsScreen().environmentObject(model).environmentObject(hub)
        }
        .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var statusRow: some View {
        let color: Color = model.phase == .video ? UI.mint : model.phase == .error ? UI.coral : UI.dim
        let icon = model.phase == .video ? "link" : model.phase == .idle ? "link.badge.plus" : "arrow.triangle.2.circlepath"
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 19, weight: .semibold)).foregroundColor(.white)
                Text(model.status).font(.system(size: 13)).foregroundColor(UI.dim).lineLimit(2)
            }
            Spacer()
            Button(model.connected ? "Desconectar" : "Conectar") { model.toggleConnection() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(model.connected ? UI.coral : .white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(model.connected ? Color.white.opacity(0.08) : UI.accent))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(UI.line))
    }

    private var title: String {
        switch model.phase {
        case .idle: return "Desconectado"
        case .searching: return "Conectando…"
        case .linking: return "Conectando ao painel…"
        case .video: return hub.mirroring ? "No painel: Waze" : "No painel: mapa"
        case .error: return "Atenção"
        }
    }
}

/// O iOS só deixa iniciar a transmissão de tela pelo botão dele: fica escondido e o cartão o aciona.
final class BroadcastTrigger: ObservableObject {
    let picker: RPSystemBroadcastPickerView = {
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        p.preferredExtension = "br.com.monteiro.tronracing.broadcast"
        p.showsMicrophoneButton = false
        return p
    }()

    func fire() {
        for case let b as UIButton in picker.subviews { b.sendActions(for: .allTouchEvents) }
    }

    struct Host: UIViewRepresentable {
        let trigger: BroadcastTrigger
        func makeUIView(context: Context) -> UIView {
            let v = UIView()
            v.addSubview(trigger.picker)
            return v
        }
        func updateUIView(_ v: UIView, context: Context) {}
    }
}

// ====================================================================== ajustes

struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hub: FrameHub
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var manualCode = ""
    @State private var voiceOn = Voice.shared.enabled
    @State private var pickedVideo: PhotosPickerItem?
    @State private var videoStatus: String?
    @State private var introSound = IntroVideo.withSound
    @State private var clockMsg: String?
    @State private var wmOn = UserDefaults.standard.object(forKey: "wmOn") as? Bool ?? true
    @State private var wmText = UserDefaults.standard.string(forKey: "wmText") ?? "@vlog.tron"
    @State private var wmScale = UserDefaults.standard.object(forKey: "wmScale") as? Double ?? 1.0

    private func importVideo(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        videoStatus = "Preparando o vídeo…"
        Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { videoStatus = "Não consegui abrir esse vídeo."; return }
                IntroVideo.importVideo(from: movie.url) { err in
                    videoStatus = err ?? "Pronto! Feche e abra o app para ver a abertura."
                    try? FileManager.default.removeItem(at: movie.url)
                }
            } catch {
                videoStatus = "Não consegui abrir esse vídeo: \(error.localizedDescription)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Moto") {
                        HStack(spacing: 12) {
                            Image(systemName: model.dash == nil ? "qrcode.viewfinder" : "checkmark.seal.fill")
                                .font(.system(size: 26)).foregroundColor(model.dash == nil ? UI.dim : UI.mint)
                            VStack(alignment: .leading) {
                                Text(model.dash?.name ?? "Nenhum painel pareado").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                                Text(model.dash == nil ? "Abra no painel a tela do QR do celular" : "Bluetooth \(model.dash?.bleName ?? "-")")
                                    .font(.system(size: 13)).foregroundColor(UI.dim)
                            }
                        }
                        Button { scanning = true } label: {
                            Label("Ler QR do painel", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(UI.accent)
                        HStack(alignment: .bottom) {
                            DarkField(label: "Ou digite o código (ID:CARBIT…)", text: $manualCode)
                            Button("OK") { model.handleQr(manualCode); manualCode = "" }.padding(.bottom, 12)
                        }
                    }
                    section("Marca no painel (para seus vídeos)") {
                        Toggle("Mostrar no mapa do painel", isOn: $wmOn).onChange(of: wmOn) { UserDefaults.standard.set($0, forKey: "wmOn") }
                        DarkField(label: "Seu perfil", text: $wmText)
                            .onChange(of: wmText) { UserDefaults.standard.set($0, forKey: "wmText") }
                        HStack {
                            Text("Tamanho").foregroundColor(.white)
                            Slider(value: $wmScale, in: 0.6...2.0, step: 0.1)
                                .tint(UI.accent)
                                .onChange(of: wmScale) { UserDefaults.standard.set($0, forKey: "wmScale") }
                            Text("\(Int((wmScale * 100).rounded()))%").font(.system(size: 14, weight: .semibold).monospacedDigit())
                                .foregroundColor(UI.dim).frame(width: 48, alignment: .trailing)
                        }
                        HStack(spacing: 7 * wmScale) {
                            Image("InstaLogo").resizable().frame(width: 26 * wmScale, height: 26 * wmScale)
                            Text(wmText).font(.system(size: 17 * wmScale, weight: .bold)).foregroundColor(.white).lineLimit(1)
                        }
                        .padding(.leading, 4 * wmScale).padding(.trailing, 14 * wmScale).padding(.vertical, 4 * wmScale)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Prévia de como aparece no canto de baixo do mapa do painel.").font(.system(size: 13)).foregroundColor(UI.dim)
                    }
                    section("Relógio da moto") {
                        Button {
                            clockMsg = DashLink.shared.syncClock() ? "Hora do iPhone enviada ao painel." : "Conecte à moto primeiro."
                        } label: {
                            Label("Acertar o relógio agora", systemImage: "clock.arrow.2.circlepath").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(UI.accent)
                        Text(clockMsg ?? "O app acerta sozinho ao conectar.")
                            .font(.system(size: 13)).foregroundColor(UI.dim)
                    }
                    section("Acesso Pessoal") {
                        DarkField(label: "Nome da rede (igualzinho, ex.: iPhone)", text: $model.hotspot.ssid)
                        DarkField(label: "Senha do Acesso Pessoal", text: $model.hotspot.password, secure: true)
                        Text("Ligue \"Permitir Outros Acessarem\" e \"Maximizar Compatibilidade\". O app abre essa tela sozinho na hora de conectar: fique nela até o painel entrar.")
                            .font(.system(size: 13)).foregroundColor(UI.dim)
                    }
                    section("Espelhar Waze") {
                        Toggle("Preencher a tela (corta as bordas)", isOn: Binding(get: { hub.currentSettings.fill },
                                                                                  set: { v in hub.update { $0.fill = v }; hub.objectWillChange.send() }))
                        Toggle("Inverter giro (se sair de cabeça para baixo)", isOn: Binding(get: { hub.currentSettings.flip },
                                                                                             set: { v in hub.update { $0.flip = v }; hub.objectWillChange.send() }))
                        Text("Deite o celular com o Waze aberto (rotação desbloqueada) para ocupar o painel inteiro.")
                            .font(.system(size: 13)).foregroundColor(UI.dim)
                    }
                    section("Vídeo de abertura") {
                        PhotosPicker(selection: $pickedVideo, matching: .videos) {
                            Label(IntroVideo.exists ? "Trocar o vídeo" : "Escolher vídeo da galeria", systemImage: "film")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(UI.accent)
                        .onChange(of: pickedVideo) { item in importVideo(item) }
                        if let s = videoStatus { Text(s).font(.system(size: 13)).foregroundColor(UI.dim) }
                        if IntroVideo.exists {
                            Toggle("Com som", isOn: $introSound).onChange(of: introSound) { IntroVideo.withSound = $0 }
                            Button("Remover vídeo", role: .destructive) { IntroVideo.remove(); videoStatus = "Removido: a abertura volta a ser a arte." }
                        }
                        Text("O vídeo fica só neste iPhone (não vai para o GitHub nem para o IPA). O TRON Racing aparece por cima.")
                            .font(.system(size: 13)).foregroundColor(UI.dim)
                    }
                    section("Voz") {
                        Toggle("Falar curvas e radares", isOn: $voiceOn).onChange(of: voiceOn) { Voice.shared.enabled = $0 }
                    }
                    NavigationLink { LogView() } label: {
                        HStack { Image(systemName: "doc.text.magnifyingglass"); Text("Diário da conexão"); Spacer(); Image(systemName: "chevron.right") }
                            .foregroundColor(.white).padding(16)
                            .background(RoundedRectangle(cornerRadius: 16).fill(UI.surface))
                    }
                }
                .padding(20)
                .tint(UI.accent)
            }
            .background(UI.bg.ignoresSafeArea())
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Pronto") { dismiss() } } }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $scanning) {
            ZStack(alignment: .bottom) {
                QRScannerView { code in scanning = false; model.handleQr(code) }.ignoresSafeArea()
                Text("Aponte para o QR na tela da moto")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    .padding().background(Capsule().fill(Color.black.opacity(0.7))).padding(.bottom, 40)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.system(size: 12, weight: .bold)).kerning(1).foregroundColor(UI.dim)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(UI.surface))
                .foregroundColor(.white)
        }
    }
}

// ====================================================================== diário

struct LogView: View {
    @ObservedObject var log = Log.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(line.contains("falh") || line.contains("erro") ? UI.coral : UI.mint.opacity(0.9))
                            .id(i)
                    }
                }
                .padding(10)
            }
            .onChange(of: log.lines.count) { n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
        .background(UI.bg)
        .navigationTitle("Diário")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: log.text()) { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .bottomBar) { Button("Limpar") { log.clear() } }
        }
    }
}
