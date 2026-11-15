import SwiftUI
import ReplayKit

@main
struct TronRacingApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        FrameHub.shared.startListening()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .environmentObject(FrameHub.shared)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { p in AppForeground.isActive = (p == .active) }
    }
}

/// Estado da tela inicial.
final class AppModel: ObservableObject {
    @Published var dash: Dash? = Pairing.load()
    @Published var hotspot: Hotspot = Pairing.loadHotspot() { didSet { Pairing.saveHotspot(hotspot) } }
    @Published var status = "Pronto. Ligue a moto e toque em CONECTAR."
    @Published var phase: DashLink.Phase = .idle
    @Published var connected = false
    @Published var message: String?

    init() {
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
        guard let d = dash else { message = "Primeiro leia o QR do painel."; return }
        guard hotspot.isComplete else { message = "Preencha o nome e a senha (8+ letras) do Acesso Pessoal."; return }
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
    @State private var scanning = false
    @State private var showLog = false
    @State private var manualCode = ""

    var body: some View {
        ZStack {
            GridBackdrop()
            ScrollView {
                VStack(spacing: 18) {
                    Header()
                    StatusCard(phase: model.phase, text: model.status, mirroring: hub.mirroring, fps: hub.framesPerSec)

                    Button(model.connected ? "DESCONECTAR" : "CONECTAR") { model.toggleConnection() }
                        .buttonStyle(NeonButtonStyle(color: model.connected ? Tron.orange : Tron.cyan, filled: !model.connected))

                    mirrorCard
                    motoCard
                    hotspotCard
                    originalCard

                    Button("DIÁRIO DA CONEXÃO") { showLog = true }
                        .buttonStyle(NeonButtonStyle(color: Tron.dim))
                    Text("Projeto pessoal, sem relação com a Zontes ou a Carbit. Não mexa no celular pilotando.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Tron.dim)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 18)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $scanning) {
            ZStack(alignment: .bottom) {
                QRScannerView { code in
                    scanning = false
                    model.handleQr(code)
                }
                .ignoresSafeArea()
                Text("Aponte para o QR na tela da moto")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Tron.cyan)
                    .padding()
                    .background(Tron.ink.opacity(0.8))
                    .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showLog) { LogView() }
        .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // ------------------------------------------------------------------ cartões

    private var mirrorCard: some View {
        NeonCard(color: Tron.orange) {
            NeonTitle(text: "Waze no painel", color: Tron.orange)
            Text(hub.mirroring
                 ? "Espelhando a tela do iPhone. Abra o Waze, deite o celular e use normalmente."
                 : "Toque em ESPELHAR, escolha Tron Racing e Iniciar Transmissão. Depois abra o Waze.")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
            BroadcastButton(active: hub.mirroring)
            Toggle(isOn: Binding(get: { hub.currentSettings.fill }, set: { v in hub.update { $0.fill = v }; hub.objectWillChange.send() })) {
                label("Preencher a tela (corta as bordas)")
            }.tint(Tron.orange)
            Toggle(isOn: Binding(get: { hub.currentSettings.flip }, set: { v in hub.update { $0.flip = v }; hub.objectWillChange.send() })) {
                label("Inverter giro (se o Waze sair de cabeça para baixo)")
            }.tint(Tron.orange)
        }
    }

    private var motoCard: some View {
        NeonCard {
            NeonTitle(text: "Moto")
            HStack {
                Image(systemName: model.dash == nil ? "qrcode.viewfinder" : "checkmark.seal.fill")
                    .foregroundColor(model.dash == nil ? Tron.dim : Tron.cyan)
                    .font(.system(size: 26))
                VStack(alignment: .leading) {
                    Text(model.dash?.name ?? "Nenhum painel pareado")
                        .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(.white)
                    Text(model.dash?.bleName.map { "Bluetooth \($0)" } ?? "Abra no painel a tela do QR do celular")
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(Tron.dim)
                }
            }
            Button("LER QR DO PAINEL") { scanning = true }
                .buttonStyle(NeonButtonStyle())
            HStack(alignment: .bottom) {
                NeonField(label: "OU DIGITE O CÓDIGO (ID:CARBIT…)", text: $manualCode)
                Button("OK") { model.handleQr(manualCode); manualCode = "" }
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .foregroundColor(Tron.cyan)
                    .padding(.bottom, 10)
            }
        }
    }

    private var hotspotCard: some View {
        NeonCard {
            NeonTitle(text: "Acesso Pessoal")
            NeonField(label: "NOME DA REDE (Ajustes > Geral > Sobre > Nome)", text: $model.hotspot.ssid)
            NeonField(label: "SENHA (Ajustes > Acesso Pessoal)", text: $model.hotspot.password, secure: true)
            VStack(alignment: .leading, spacing: 6) {
                tip("Ligue \"Permitir Outros Acessarem\" e \"Maximizar Compatibilidade\".")
                tip("Na hora de conectar, deixe a tela do Acesso Pessoal aberta até o painel entrar.")
                tip("O painel só usa a rede; não gasta seus dados.")
            }
        }
    }

    private var originalCard: some View {
        NeonCard(color: Tron.dim) {
            NeonTitle(text: "Painel original", color: Tron.dim)
            Text("Para ver o painel da moto, aperte o botão de modo no guidão: o painel sai da projeção e volta sozinho para o Waze quando você apertar de novo. Para encerrar de vez, toque em DESCONECTAR.")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 13, design: .monospaced)).foregroundColor(.white.opacity(0.85))
    }

    private func tip(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(Tron.cyan).frame(width: 6, height: 6).padding(.top, 6).shadow(color: Tron.cyan, radius: 3)
            Text(s).font(.system(size: 12, design: .monospaced)).foregroundColor(Tron.dim)
        }
    }
}

// ====================================================================== peças

struct Header: View {
    @State private var sweep: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            Text("TRON RACING")
                .font(.system(size: 38, weight: .black, design: .rounded))
                .kerning(6)
                .foregroundColor(.white)
                .shadow(color: Tron.cyan, radius: 2)
                .shadow(color: Tron.cyan, radius: 10)
                .shadow(color: Tron.cyan.opacity(0.6), radius: 24)
            // rastro de luz que corre por baixo do nome
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Tron.cyan.opacity(0.25)).frame(height: 2)
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, Tron.orange, .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * 0.35, height: 3)
                        .shadow(color: Tron.orange, radius: 6)
                        .offset(x: (g.size.width * 1.35) * sweep - g.size.width * 0.35)
                }
            }
            .frame(height: 3)
            .clipped()
            Text("ZONTES  ·  ESPELHO DO PAINEL")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .kerning(3)
                .foregroundColor(Tron.dim)
        }
        .padding(.top, 24)
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { sweep = 1 }
        }
    }
}

struct StatusCard: View {
    let phase: DashLink.Phase
    let text: String
    let mirroring: Bool
    let fps: Int
    @State private var spin = false

    private var color: Color {
        switch phase {
        case .video: return Tron.cyan
        case .error: return Tron.orange
        case .idle: return Tron.dim
        default: return Tron.cyan
        }
    }

    private var title: String {
        switch phase {
        case .idle: return "DESLIGADO"
        case .searching: return "PROCURANDO"
        case .linking: return "CONECTANDO"
        case .video: return "NO AR"
        case .error: return "ATENÇÃO"
        }
    }

    var body: some View {
        NeonCard(color: color) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(color.opacity(0.25), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: phase == .video ? 1 : 0.28)
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .shadow(color: color, radius: 6)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                    Image(systemName: phase == .video ? "bolt.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundColor(color)
                        .font(.system(size: 20, weight: .bold))
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .kerning(3)
                        .foregroundColor(color)
                        .shadow(color: color, radius: 5)
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    if mirroring {
                        Text("WAZE  ·  \(fps) qps")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(Tron.orange)
                    }
                }
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true } }
    }
}

/// O iOS só deixa iniciar a transmissão de tela pelo botão dele (RPSystemBroadcastPickerView).
/// Ele fica escondido e o nosso botão neon "aperta" o dele.
struct BroadcastButton: View {
    let active: Bool
    @State private var picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))

    var body: some View {
        ZStack {
            PickerHost(picker: picker).frame(width: 1, height: 1).opacity(0.02)
            Button(active ? "PARAR ESPELHAMENTO" : "ESPELHAR TELA") {
                for case let b as UIButton in picker.subviews { b.sendActions(for: .allTouchEvents) }
            }
            .buttonStyle(NeonButtonStyle(color: Tron.orange, filled: !active))
        }
    }

    struct PickerHost: UIViewRepresentable {
        let picker: RPSystemBroadcastPickerView
        func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
            picker.preferredExtension = "br.com.monteiro.tronracing.broadcast"
            picker.showsMicrophoneButton = false
            return picker
        }
        func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {}
    }
}

struct LogView: View {
    @ObservedObject var log = Log.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(line.contains("falh") || line.contains("erro") ? Tron.orange : Tron.cyan.opacity(0.9))
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: log.lines.count) { n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            .background(Tron.ink)
            .navigationTitle("Diário")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: log.text()) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .bottomBar) { Button("Limpar") { log.clear() } }
            }
        }
    }
}
