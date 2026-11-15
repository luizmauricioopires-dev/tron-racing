import SwiftUI
import UIKit

/// Visual no estilo da arte do Tron Racing: grafite escuro, relevo discreto, letras largas
/// e um laranja de destaque para rotas e números.
enum UI {
    static let bg = Color(red: 0.047, green: 0.047, blue: 0.051)
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.102)
    static let card = Color(red: 0.125, green: 0.125, blue: 0.137)
    static let line = Color.white.opacity(0.07)
    static let text = Color.white
    static let dim = Color(red: 0.62, green: 0.63, blue: 0.66)
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.16)
    static let accentUI = UIColor(red: 1.0, green: 0.42, blue: 0.16, alpha: 1)
    static let mint = Color(red: 0.42, green: 0.86, blue: 0.62)
    static let coral = Color(red: 0.92, green: 0.30, blue: 0.26)
    static let coralUI = UIColor(red: 0.92, green: 0.30, blue: 0.26, alpha: 1)

    /// Letras largas (Orbitron, fonte livre OFL) no peso máximo.
    static func wide(_ size: CGFloat) -> Font {
        let wght = 0x77676874 // 'wght'
        let desc = UIFontDescriptor(name: "Orbitron-Regular", size: size)
            .addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: 900]])
        return Font(UIFont(descriptor: desc, size: size))
    }

    /// Manuscrito do "Racing" (Great Vibes, fonte livre OFL).
    static func script(_ size: CGFloat) -> Font { .custom("GreatVibes-Regular", size: size) }
}

/// Logotipo em texto: TRON (largo, inclinado) + Racing (manuscrito).
struct BrandTitle: View {
    var size: CGFloat = 54
    var glow: Color = .white

    var body: some View {
        VStack(alignment: .trailing, spacing: -size * 0.28) {
            Text("TRON")
                .font(UI.wide(size))
                .kerning(size * 0.06)
                .foregroundColor(.white)
                .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.22, d: 1, tx: size * 0.2, ty: 0))
                .shadow(color: glow.opacity(0.9), radius: size * 0.18)
                .shadow(color: glow.opacity(0.5), radius: size * 0.5)
            Text("Racing")
                .font(UI.script(size * 0.78))
                .foregroundColor(.white.opacity(0.95))
                .shadow(color: glow.opacity(0.7), radius: size * 0.12)
                .offset(x: size * 0.3)
        }
    }
}

/// Cartão grande da tela inicial: grafite, ícone em círculo claro, título e linha de apoio.
struct BigCard<Trailing: View>: View {
    let color: Color
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.white)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(color)
            }
            .frame(width: 58, height: 58)
            .shadow(color: color.opacity(0.35), radius: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 14)).foregroundColor(UI.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [UI.card, UI.surface], startPoint: .top, endPoint: .bottom))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 44).padding(.leading, 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(UI.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }
}

extension BigCard where Trailing == EmptyView {
    init(color: Color, icon: String, title: String, subtitle: String) {
        self.init(color: color, icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Faixa quadriculada (bandeira de chegada) que some aos poucos, como na arte.
struct Checkers: View {
    var rows = 2
    var size: CGFloat = 10
    var body: some View {
        Canvas { g, s in
            let cols = Int(s.width / size) + 1
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    let a = 0.55 * (1 - Double(c) / Double(cols))
                    g.fill(Path(CGRect(x: CGFloat(c) * size, y: CGFloat(r) * size, width: size - 1, height: size - 1)),
                           with: .color(.white.opacity(a)))
                }
            }
        }
        .frame(height: CGFloat(rows) * size)
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
