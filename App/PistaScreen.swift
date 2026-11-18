import SwiftUI

/// Modo Pista no app: liga/desliga no painel, mostra a inclinação ao vivo e zera o sensor.
struct PistaScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var onPanel = UserDefaults.standard.string(forKey: "panelScreen") == "pista"
    @State private var lean = 0.0, maxL = 0.0, maxR = 0.0
    @State private var ok = false
    @State private var msg: String?
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    gauge
                    Toggle(isOn: $onPanel) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mostrar no painel").font(.system(size: 17, weight: .semibold))
                            Text("Troca o mapa pela estrada neon com o ângulo. A navegação e os radares continuam valendo.")
                                .font(.system(size: 13)).foregroundColor(UI.dim)
                        }
                    }
                    .tint(UI.accent)
                    .onChange(of: onPanel) { UserDefaults.standard.set($0 ? "pista" : "mapa", forKey: "panelScreen") }
                    .padding(16).background(RoundedRectangle(cornerRadius: 18).fill(UI.surface))

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            LeanSensor.shared.calibrate()
                            msg = "Zerado. Esse é o \"em pé\" da moto."
                        } label: {
                            Label("Zerar com a moto em pé", systemImage: "scope").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(UI.accent)
                        Button {
                            LeanSensor.shared.resetMax()
                            msg = "Máximas zeradas."
                        } label: {
                            Label("Zerar as máximas", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.white)
                        Text(msg ?? "Prenda o iPhone na moto (em pé ou deitado de lado, nunca com a tela para cima), deixe a moto reta, sem o descanso, e toque em Zerar. As máximas só contam acima de 15 km/h.")
                            .font(.system(size: 13)).foregroundColor(UI.dim)
                    }
                    .padding(16).background(RoundedRectangle(cornerRadius: 18).fill(UI.surface))
                }
                .padding(20)
            }
            .background(UI.bg.ignoresSafeArea())
            .navigationTitle("Modo Pista")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { LeanSensor.shared.start() }
        .onDisappear { LeanSensor.shared.stop() }
        .onReceive(tick) { _ in
            let r = LeanSensor.shared.read()
            lean = r.lean; maxL = r.maxLeft; maxR = r.maxRight; ok = r.ok
        }
    }

    private var gauge: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().trim(from: 0.5, to: 1)
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 220, height: 220)
                VStack(spacing: 0) {
                    Capsule().fill(Color(red: 0.23, green: 0.63, blue: 1)).frame(width: 6, height: 104)
                    Spacer().frame(height: 116)
                }
                .frame(height: 220)
                .rotationEffect(.degrees(max(-60, min(60, lean))))
                .animation(.easeOut(duration: 0.1), value: lean)
            }
            .frame(width: 240, height: 122, alignment: .top)
            .clipped()
            Text(ok ? "\(Int(abs(lean).rounded()))°" + (abs(lean) < 3 ? "" : (lean > 0 ? " ▶" : " ◀")) : "—")
                .font(UI.wide(44)).foregroundColor(.white)
            HStack {
                VStack { Text("◀ ESQ").font(.system(size: 12, weight: .bold)).foregroundColor(UI.dim); Text("\(Int(maxL.rounded()))°").font(UI.wide(24)) }
                Spacer()
                Text("MÁXIMAS").font(.system(size: 12, weight: .bold)).kerning(1).foregroundColor(UI.dim)
                Spacer()
                VStack { Text("DIR ▶").font(.system(size: 12, weight: .bold)).foregroundColor(UI.dim); Text("\(Int(maxR.rounded()))°").font(UI.wide(24)) }
            }
            .foregroundColor(.white)
            if !ok {
                Text("Coloque o iPhone em pé (a tela não pode ficar virada para cima).")
                    .font(.system(size: 13)).foregroundColor(UI.coral).multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [UI.card, UI.surface], startPoint: .top, endPoint: .bottom)))
    }
}
