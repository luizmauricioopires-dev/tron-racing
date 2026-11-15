import SwiftUI
import UIKit

/// Visual neon: fundo quase preto, grade em perspectiva, ciano para o que está ligado e laranja
/// para alertas.
enum Tron {
    static let cyanUI = UIColor(red: 0.30, green: 0.93, blue: 1.0, alpha: 1)
    static let orangeUI = UIColor(red: 1.0, green: 0.55, blue: 0.12, alpha: 1)

    static let cyan = Color(cyanUI)
    static let orange = Color(orangeUI)
    static let ink = Color(red: 0.01, green: 0.02, blue: 0.04)
    static let panel = Color(red: 0.03, green: 0.07, blue: 0.10)
    static let dim = Color(red: 0.45, green: 0.62, blue: 0.70)

    /// Grade em perspectiva (o "chão" que corre) + horizonte brilhante. `phase` 0...1 anima as linhas.
    static func drawBackdrop(in ctx: CGContext, size: CGSize, phase: CGFloat) {
        let w = size.width, h = size.height
        ctx.setFillColor(UIColor(red: 0.005, green: 0.01, blue: 0.02, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let horizon = h * 0.62
        // brilho do horizonte
        let colors = [cyanUI.withAlphaComponent(0.35).cgColor, cyanUI.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: horizon - h * 0.25), options: [])
        }
        ctx.setShadow(offset: .zero, blur: 6, color: cyanUI.cgColor)
        ctx.setStrokeColor(cyanUI.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.2)
        // linhas que fogem para o centro
        let vx = w / 2
        for i in -12...12 {
            let x = vx + CGFloat(i) * w * 0.12
            ctx.move(to: CGPoint(x: vx + CGFloat(i) * w * 0.012, y: horizon))
            ctx.addLine(to: CGPoint(x: x, y: h))
        }
        // linhas horizontais, cada vez mais próximas do horizonte
        for k in 0..<12 {
            let t = (CGFloat(k) + phase) / 12
            let y = horizon + (h - horizon) * t * t
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(cyanUI.cgColor)
        ctx.setLineWidth(2.5)
        ctx.move(to: CGPoint(x: 0, y: horizon)); ctx.addLine(to: CGPoint(x: w, y: horizon))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}

/// Fundo animado das telas do app.
struct GridBackdrop: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Canvas { gc, size in
                let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
                gc.withCGContext { ctx in Tron.drawBackdrop(in: ctx, size: size, phase: phase) }
            }
        }
        .ignoresSafeArea()
    }
}

/// Caixa com borda neon.
struct NeonCard<Content: View>: View {
    var color: Color = Tron.cyan
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tron.panel.opacity(0.88)))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color, lineWidth: 1.5)
                    .shadow(color: color, radius: 6)
            )
            .overlay(alignment: .topLeading) { cornerTick(color) }
    }

    private func cornerTick(_ c: Color) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 18)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 18, y: 0))
        }
        .stroke(c, lineWidth: 4)
        .shadow(color: c, radius: 4)
    }
}

struct NeonTitle: View {
    let text: String
    var color: Color = Tron.cyan
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .heavy, design: .monospaced))
            .kerning(3)
            .foregroundColor(color)
            .shadow(color: color, radius: 4)
    }
}

/// Botão grande com contorno neon.
struct NeonButtonStyle: ButtonStyle {
    var color: Color = Tron.cyan
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .heavy, design: .monospaced))
            .kerning(2)
            .foregroundColor(filled ? Tron.ink : color)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 3).fill(filled ? color : Color.clear)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 2))
            .shadow(color: color.opacity(configuration.isPressed ? 1 : 0.7), radius: configuration.isPressed ? 14 : 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Campo de texto no estilo do app.
struct NeonField: View {
    let label: String
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(Tron.dim)
            Group {
                if secure { SecureField("", text: $text) } else { TextField("", text: $text) }
            }
            .font(.system(size: 16, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .overlay(Rectangle().frame(height: 1.5).foregroundColor(Tron.cyan.opacity(0.7)), alignment: .bottom)
        }
    }
}
