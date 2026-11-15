import SwiftUI
import UIKit

/// Visual clássico escuro: fundo quase preto, cartões grandes arredondados em azul-ardósia,
/// verde-petróleo e coral, ícones em círculo branco.
enum UI {
    static let bg = Color(red: 0.043, green: 0.055, blue: 0.078)
    static let surface = Color(red: 0.086, green: 0.106, blue: 0.141)
    static let slate = Color(red: 0.231, green: 0.322, blue: 0.443)
    static let teal = Color(red: 0.227, green: 0.427, blue: 0.416)
    static let coral = Color(red: 0.733, green: 0.361, blue: 0.341)
    static let text = Color.white
    static let dim = Color(red: 0.60, green: 0.65, blue: 0.72)
    static let mint = Color(red: 0.62, green: 0.89, blue: 0.80)
    static let coralUI = UIColor(red: 0.88, green: 0.40, blue: 0.36, alpha: 1)
}

/// Cartão grande da tela inicial (como no app original do painel, só que escuro).
struct BigCard<Trailing: View>: View {
    let color: Color
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.white)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(color)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 15)).foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(color))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }
}

extension BigCard where Trailing == EmptyView {
    init(color: Color, icon: String, title: String, subtitle: String) {
        self.init(color: color, icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A moto desenhada (lado direito para a frente). Unidades: ~300 x 170.
enum MotoArt {
    static func draw(_ g: inout GraphicsContext, at o: CGPoint, scale s: CGFloat, wheelAngle: Double, headlight: Bool = true) {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        let dark = Color(red: 0.12, green: 0.13, blue: 0.20)
        let coral = Color(red: 0.91, green: 0.42, blue: 0.37)
        let coralDark = Color(red: 0.78, green: 0.32, blue: 0.29)

        if headlight {
            var beam = Path()
            beam.move(to: P(250, 70)); beam.addLine(to: P(430, 40)); beam.addLine(to: P(430, 120)); beam.closeSubpath()
            g.fill(beam, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.7).opacity(0.45), .clear]),
                                                startPoint: P(250, 70), endPoint: P(430, 70)))
        }
        // escapamento e balança
        var exhaust = Path(); exhaust.move(to: P(118, 116)); exhaust.addLine(to: P(52, 104))
        g.stroke(exhaust, with: .color(Color(white: 0.55)), style: StrokeStyle(lineWidth: 8 * s, lineCap: .round))
        var swing = Path(); swing.move(to: P(120, 112)); swing.addLine(to: P(70, 125))
        g.stroke(swing, with: .color(dark), style: StrokeStyle(lineWidth: 9 * s, lineCap: .round))
        var fork = Path(); fork.move(to: P(220, 66)); fork.addLine(to: P(238, 125))
        g.stroke(fork, with: .color(dark), style: StrokeStyle(lineWidth: 8 * s, lineCap: .round))

        for c in [P(70, 125), P(238, 125)] { wheel(&g, c, 42 * s, wheelAngle) }

        // carenagem
        var body = Path()
        body.move(to: P(26, 76))
        body.addLine(to: P(62, 66)); body.addLine(to: P(114, 72)); body.addLine(to: P(142, 56))
        body.addQuadCurve(to: P(204, 56), control: P(176, 40))
        body.addLine(to: P(232, 50)); body.addQuadCurve(to: P(256, 74), control: P(256, 56))
        body.addLine(to: P(236, 90)); body.addLine(to: P(202, 98)); body.addLine(to: P(176, 120))
        body.addLine(to: P(126, 122)); body.addLine(to: P(100, 98)); body.addLine(to: P(58, 90))
        body.closeSubpath()
        g.fill(body, with: .linearGradient(Gradient(colors: [coral, coralDark]), startPoint: P(140, 40), endPoint: P(140, 122)))
        // banco
        var seat = Path()
        seat.move(to: P(60, 64)); seat.addLine(to: P(116, 70)); seat.addLine(to: P(110, 80)); seat.addLine(to: P(64, 76)); seat.closeSubpath()
        g.fill(seat, with: .color(dark))
        // motor
        g.fill(Path(roundedRect: CGRect(x: o.x + 128 * s, y: o.y + 92 * s, width: 50 * s, height: 26 * s), cornerRadius: 6 * s), with: .color(Color(red: 0.17, green: 0.18, blue: 0.25)))
        g.fill(Path(ellipseIn: CGRect(x: o.x + 142 * s, y: o.y + 96 * s, width: 18 * s, height: 18 * s)), with: .color(UI.mint))
        // para-brisa e farol
        var shield = Path()
        shield.move(to: P(206, 56)); shield.addLine(to: P(226, 32)); shield.addLine(to: P(236, 36)); shield.addLine(to: P(228, 56)); shield.closeSubpath()
        g.fill(shield, with: .color(UI.mint.opacity(0.85)))
        g.fill(Path(ellipseIn: CGRect(x: o.x + 244 * s, y: o.y + 64 * s, width: 12 * s, height: 10 * s)), with: .color(Color(red: 1, green: 0.93, blue: 0.6)))
        // guidão
        var bar = Path(); bar.move(to: P(214, 52)); bar.addLine(to: P(202, 42))
        g.stroke(bar, with: .color(dark), style: StrokeStyle(lineWidth: 6 * s, lineCap: .round))
    }

    private static func wheel(_ g: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ angle: Double) {
        g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(red: 0.10, green: 0.11, blue: 0.16)))
        let rim = r * 0.72
        g.stroke(Path(ellipseIn: CGRect(x: c.x - rim, y: c.y - rim, width: 2 * rim, height: 2 * rim)),
                 with: .color(Color(red: 0.55, green: 0.59, blue: 0.66)), lineWidth: r * 0.16)
        var spokes = Path()
        for k in 0..<5 {
            let a = angle + Double(k) * 2 * .pi / 5
            spokes.move(to: c)
            spokes.addLine(to: CGPoint(x: c.x + cos(a) * rim, y: c.y + sin(a) * rim))
        }
        g.stroke(spokes, with: .color(Color(red: 0.55, green: 0.59, blue: 0.66)), lineWidth: r * 0.08)
        g.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.2, y: c.y - r * 0.2, width: r * 0.4, height: r * 0.4)), with: .color(Color(red: 0.12, green: 0.13, blue: 0.2)))
    }

    /// Prédios de fundo (sempre iguais, para a cidade não "pular").
    static let skyline: [(CGFloat, CGFloat)] = {
        var seed: UInt64 = 7
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        return (0..<24).map { _ in (40 + rnd() * 50, 50 + rnd() * 120) }
    }()

    static func drawSkyline(_ g: inout GraphicsContext, baseY: CGFloat, width: CGFloat, offset: CGFloat, scale: CGFloat,
                            color: Color, windows: Color?) {
        let total = skyline.reduce(0) { $0 + $1.0 * scale + 6 * scale }
        var x = -(offset.truncatingRemainder(dividingBy: total))
        while x < width {
            for (w0, h0) in skyline {
                let w = w0 * scale, h = h0 * scale
                if x + w > 0 && x < width {
                    g.fill(Path(CGRect(x: x, y: baseY - h, width: w, height: h)), with: .color(color))
                    if let win = windows {
                        var wy = baseY - h + 8 * scale
                        while wy < baseY - 10 * scale {
                            var wx = x + 6 * scale
                            while wx < x + w - 8 * scale {
                                g.fill(Path(CGRect(x: wx, y: wy, width: 5 * scale, height: 3 * scale)), with: .color(win))
                                wx += 11 * scale
                            }
                            wy += 9 * scale
                        }
                    }
                }
                x += w + 6 * scale
                if x > width { break }
            }
        }
    }
}

/// Ilustração da tela inicial: cidade à noite, celular com o mapa e a moto na frente.
struct HeroArt: View {
    var body: some View {
        Canvas { g, size in
            let w = size.width, h = size.height
            let base = h * 0.92
            MotoArt.drawSkyline(&g, baseY: base, width: w, offset: 30, scale: 0.9, color: Color(red: 0.10, green: 0.16, blue: 0.20), windows: UI.mint.opacity(0.18))
            // celular
            let phone = CGRect(x: w / 2 - 44, y: h * 0.04, width: 88, height: 150)
            g.fill(Path(roundedRect: phone, cornerRadius: 14), with: .color(UI.mint))
            let screen = phone.insetBy(dx: 6, dy: 12)
            g.fill(Path(roundedRect: screen, cornerRadius: 4), with: .color(Color(red: 0.14, green: 0.18, blue: 0.24)))
            var roads = Path()
            roads.move(to: CGPoint(x: screen.minX, y: screen.minY + 40)); roads.addLine(to: CGPoint(x: screen.maxX, y: screen.minY + 12))
            roads.move(to: CGPoint(x: screen.minX + 18, y: screen.maxY)); roads.addLine(to: CGPoint(x: screen.maxX - 10, y: screen.minY))
            roads.move(to: CGPoint(x: screen.minX, y: screen.maxY - 30)); roads.addLine(to: CGPoint(x: screen.maxX, y: screen.maxY - 50))
            g.stroke(roads, with: .color(Color.white.opacity(0.25)), lineWidth: 5)
            // alfinete
            let pin = CGPoint(x: screen.midX + 4, y: screen.minY + 52)
            var drop = Path()
            drop.addArc(center: pin, radius: 14, startAngle: .degrees(150), endAngle: .degrees(30), clockwise: false)
            drop.addLine(to: CGPoint(x: pin.x, y: pin.y + 30)); drop.closeSubpath()
            g.fill(drop, with: .color(UI.coral))
            g.fill(Path(ellipseIn: CGRect(x: pin.x - 5, y: pin.y - 5, width: 10, height: 10)), with: .color(.white))
            // chão e moto
            g.fill(Path(CGRect(x: 0, y: base, width: w, height: h - base)), with: .color(Color(red: 0.08, green: 0.10, blue: 0.13)))
            let s = min(w / 340, 0.95)
            MotoArt.draw(&g, at: CGPoint(x: w / 2 - 150 * s, y: base - 168 * s), scale: s, wheelAngle: 0.4, headlight: false)
        }
    }
}

/// Campo de texto escuro.
struct DarkField: View {
    let label: String
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(UI.dim)
            Group {
                if secure { SecureField("", text: $text) } else { TextField("", text: $text) }
            }
            .font(.system(size: 17))
            .foregroundColor(.white)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        }
    }
}
