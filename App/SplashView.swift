import SwiftUI

/// Abertura: moto acelerando de noite pela cidade, depois o nome do app.
struct SplashView: View {
    var onFinish: () -> Void
    @State private var start = Date()
    @State private var finished = false

    private static let duration = 2.9

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            ZStack {
                Canvas { g, size in draw(&g, size, t) }
                VStack(spacing: 10) {
                    Spacer()
                    Text("TRON RACING")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .kerning(5)
                        .foregroundColor(.white)
                        .shadow(color: UI.coral.opacity(0.8), radius: 14)
                    Text("ligando os motores…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(UI.dim)
                }
                .padding(.bottom, 90)
                .opacity(min(1, max(0, (t - 1.0) / 0.6)))
                .offset(y: CGFloat(max(0, 1.6 - t)) * 10)
            }
        }
        .ignoresSafeArea()
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            if !finished { finished = true; onFinish() }
        }
        .background(UI.bg)
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let road = h * 0.62
        // céu
        g.fill(Path(CGRect(origin: .zero, size: size)),
               with: .linearGradient(Gradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.06), Color(red: 0.07, green: 0.10, blue: 0.17)]),
                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: road)))
        // estrelas e lua
        for i in 0..<40 {
            let x = CGFloat((i * 97) % 389) / 389 * w
            let y = CGFloat((i * 53) % 211) / 211 * road * 0.55
            let tw = 0.4 + 0.6 * abs(sin(t * 2 + Double(i)))
            g.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(0.5 * tw)))
        }
        g.fill(Path(ellipseIn: CGRect(x: w * 0.74, y: road * 0.12, width: 46, height: 46)), with: .color(Color(red: 0.93, green: 0.92, blue: 0.85)))
        g.fill(Path(ellipseIn: CGRect(x: w * 0.74 + 12, y: road * 0.12 - 6, width: 46, height: 46)), with: .color(Color(red: 0.03, green: 0.05, blue: 0.09)))
        // cidade em duas camadas (a de perto passa mais rápido)
        MotoArt.drawSkyline(&g, baseY: road, width: w, offset: CGFloat(t * 60), scale: 0.8,
                            color: Color(red: 0.07, green: 0.10, blue: 0.15), windows: nil)
        MotoArt.drawSkyline(&g, baseY: road, width: w, offset: CGFloat(t * 170) + 200, scale: 1.1,
                            color: Color(red: 0.10, green: 0.14, blue: 0.20), windows: Color(red: 1, green: 0.85, blue: 0.5).opacity(0.25))
        // pista
        g.fill(Path(CGRect(x: 0, y: road, width: w, height: h - road)), with: .color(Color(red: 0.05, green: 0.06, blue: 0.08)))
        g.fill(Path(CGRect(x: 0, y: road, width: w, height: 3)), with: .color(UI.mint.opacity(0.35)))
        let laneY = road + (h - road) * 0.42
        let dash: CGFloat = 70, gap: CGFloat = 60
        var x = -CGFloat((t * 900).truncatingRemainder(dividingBy: Double(dash + gap)))
        while x < w {
            g.fill(Path(CGRect(x: x, y: laneY, width: dash, height: 6)), with: .color(.white.opacity(0.55)))
            x += dash + gap
        }
        // moto: entra pela esquerda e acelera
        let s = min(w / 360, 1.0)
        let enter = min(1, t / 0.9)
        let ease = 1 - pow(1 - enter, 3)
        let mx = -320 * s + (w * 0.5 - 150 * s + 320 * s) * CGFloat(ease) + CGFloat(max(0, t - 2.2)) * w * 1.6
        let bounce = CGFloat(sin(t * 28)) * 1.5
        let my = laneY - 150 * s + bounce
        // linhas de velocidade
        for i in 0..<9 {
            let ly = my + CGFloat(30 + i * 13) * s
            let len = CGFloat(60 + (i * 37) % 90)
            let phase = CGFloat((t * 1400 + Double(i) * 173).truncatingRemainder(dividingBy: Double(w + 200)))
            let lx = mx + 20 * s - phase * 0.6
            g.fill(Path(CGRect(x: lx - len, y: ly, width: len, height: 2)), with: .color(.white.opacity(0.18)))
        }
        // sombra
        g.fill(Path(ellipseIn: CGRect(x: mx + 30 * s, y: laneY + 10 * s, width: 240 * s, height: 16 * s)), with: .color(.black.opacity(0.5)))
        MotoArt.draw(&g, at: CGPoint(x: mx, y: my), scale: s, wheelAngle: t * 26)
    }
}
