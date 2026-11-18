import UIKit
import CoreVideo

/// Modo Pista: estrada neon com pôr do sol, piloto que deita na curva e o ângulo de inclinação.
/// Para rodar liso: céu, sol, montanhas e brilhos são desenhados uma vez em imagens prontas;
/// a cada quadro só a estrada, as faixas, os postes e o piloto são desenhados.
/// Tudo o que importa fica na parte de cima (a de baixo fica sob os mostradores da moto).
final class TrackRenderer {
    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?
    private var travel = 0.0
    private var bend = 0.0
    private var lastAt = Date()

    private static let acc = UIColor(red: 0x3A / 255.0, green: 0xA0 / 255.0, blue: 1, alpha: 1)
    private static let gray = UIColor(red: 0.78, green: 0.8, blue: 0.84, alpha: 1)

    private var sky: CGImage?
    private var sun: CGImage?
    private var hills: CGImage?
    private var glow: CGImage?
    private var redGlow: CGImage?
    private var builtFor: CGFloat = -1

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                attrs as CFDictionary, &pool)
    }

    static var safeFraction: CGFloat {
        CGFloat(min(max(UserDefaults.standard.object(forKey: "safeFrac") as? Double ?? 0.62, 0.4), 1.0))
    }

    func render(_ s: NavEngine.Snapshot, now: Date = Date(), makeImage: Bool = false) -> (CVPixelBuffer, CGImage?)? {
        guard let pool = pool else { return nil }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut)
        guard let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let W = CGFloat(width), H = CGFloat(height)
        let safe = H * Self.safeFraction
        let hz = safe * 0.34
        if builtFor != safe { buildStatic(safe: safe) }

        // movimento
        let dt = min(0.2, max(0, now.timeIntervalSince(lastAt)))
        lastAt = now
        let kmh = s.speed * 3.6
        LeanSensor.shared.setMoving(kmh > 15)
        let sensor = LeanSensor.shared.read()
        let lean = sensor.ok ? sensor.lean : 0
        travel += s.speed * dt / 9
        bend += (max(-1, min(1, lean / 40)) - bend) * min(1, dt * 6)
        let b = CGFloat(bend)

        // fundo
        ctx.setFillColor(UIColor(red: 7 / 255, green: 4 / 255, blue: 16 / 255, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let sky = sky { draw(ctx, sky, CGRect(x: 0, y: 0, width: W, height: hz)) }
        if let sun = sun {
            let R = safe * 0.26
            let sx = W / 2 - b * W * 0.18
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: hz))
            draw(ctx, sun, CGRect(x: sx - R, y: hz - R, width: 2 * R, height: R))
            ctx.restoreGState()
        }
        if let hills = hills {
            let sh = -b * W * 0.3
            draw(ctx, hills, CGRect(x: -W * 0.5 + sh, y: hz - hz * 0.45, width: W * 2, height: hz * 0.45 + 2))
        }
        ctx.setStrokeColor(UIColor(red: 1, green: 0.47, blue: 0.78, alpha: 0.67).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: 0, y: hz)); ctx.addLine(to: CGPoint(x: W, y: hz)); ctx.strokePath()

        // estrada (curva para o lado em que a moto deita)
        func cX(_ z: CGFloat) -> CGFloat { W / 2 + b * W * 0.55 * (1 - z) * (1 - z) }
        func yA(_ z: CGFloat) -> CGFloat { hz + (H - hz) * z * z }
        func hw(_ z: CGFloat) -> CGFloat { W * (0.015 + 0.42 * z * z) }
        let st = 20
        let road = CGMutablePath()
        for i in 0...st { let z = CGFloat(i) / CGFloat(st); let p = CGPoint(x: cX(z) - hw(z), y: yA(z)); i == 0 ? road.move(to: p) : road.addLine(to: p) }
        for i in stride(from: st, through: 0, by: -1) { let z = CGFloat(i) / CGFloat(st); road.addLine(to: CGPoint(x: cX(z) + hw(z), y: yA(z))) }
        road.closeSubpath()
        ctx.addPath(road)
        ctx.setFillColor(UIColor(red: 18 / 255, green: 14 / 255, blue: 34 / 255, alpha: 1).cgColor)
        ctx.fillPath()

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for side in [-1.0, 1.0] as [CGFloat] {
            let edge = CGMutablePath()
            for i in 0...st { let z = CGFloat(i) / CGFloat(st); let p = CGPoint(x: cX(z) + side * hw(z), y: yA(z)); i == 0 ? edge.move(to: p) : edge.addLine(to: p) }
            ctx.addPath(edge); ctx.setStrokeColor(Self.acc.withAlphaComponent(0.27).cgColor); ctx.setLineWidth(H * 0.022); ctx.strokePath()
            ctx.addPath(edge); ctx.setStrokeColor(Self.acc.cgColor); ctx.setLineWidth(H * 0.007); ctx.strokePath()
        }

        // faixa do meio andando com a velocidade
        let off = CGFloat(travel.truncatingRemainder(dividingBy: 1))
        for i in 0..<9 {
            let z0 = min(1, (CGFloat(i) + off) / 9), z1 = min(1, (CGFloat(i) + off + 0.45) / 9)
            if z1 <= z0 { continue }
            let w0 = hw(z0) * 0.035, w1 = hw(z1) * 0.035
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cX(z0) - w0, y: yA(z0))); p.addLine(to: CGPoint(x: cX(z0) + w0, y: yA(z0)))
            p.addLine(to: CGPoint(x: cX(z1) + w1, y: yA(z1))); p.addLine(to: CGPoint(x: cX(z1) - w1, y: yA(z1))); p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(UIColor(red: 1, green: 0.9, blue: 0.55, alpha: min(1, (90 + 165 * z1) / 255)).cgColor)
            ctx.fillPath()
        }

        // postes com luz
        for i in 0..<6 {
            let z = min(1, (CGFloat(i) + off) / 6)
            if z < 0.08 { continue }
            let y = yA(z), ph = safe * 0.16 * z * z + 2
            for side in [-1.0, 1.0] as [CGFloat] {
                let x = cX(z) + side * hw(z) * 1.18
                ctx.setStrokeColor(Self.acc.withAlphaComponent(min(1, (80 + 175 * z) / 255)).cgColor)
                ctx.setLineWidth(max(1.5, H * 0.008 * z))
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y - ph)); ctx.strokePath()
                if let g = glow { let r = H * 0.03 * z + 1; draw(ctx, g, CGRect(x: x - r, y: y - ph - r, width: 2 * r, height: 2 * r)) }
            }
        }

        drawRider(ctx, cx: W / 2, ground: safe * 0.99, u: safe * 0.5, lean: CGFloat(lean))
        drawHud(ctx, s, now: now, safe: safe, kmh: kmh, sensor: sensor)
        let img = makeImage ? ctx.makeImage() : nil
        return (pb, img)
    }

    // ------------------------------------------------------------------ partes prontas

    private func buildStatic(safe: CGFloat) {
        builtFor = safe
        let W = CGFloat(width)
        let hz = safe * 0.34
        sky = image(CGSize(width: W, height: hz)) { ctx, sz in
            self.linear(ctx, CGRect(origin: .zero, size: sz), [
                (0, UIColor(red: 10 / 255, green: 5 / 255, blue: 28 / 255, alpha: 1)),
                (0.5, UIColor(red: 52 / 255, green: 12 / 255, blue: 66 / 255, alpha: 1)),
                (1, UIColor(red: 150 / 255, green: 36 / 255, blue: 92 / 255, alpha: 1))])
        }
        let R = safe * 0.26
        sun = image(CGSize(width: 2 * R, height: R)) { ctx, sz in
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: 0, y: 0, width: 2 * R, height: 2 * R))
            ctx.clip()
            self.linear(ctx, CGRect(x: 0, y: 0, width: 2 * R, height: R), [
                (0, UIColor(red: 1, green: 210 / 255, blue: 90 / 255, alpha: 1)),
                (1, UIColor(red: 1, green: 70 / 255, blue: 140 / 255, alpha: 1))])
            ctx.restoreGState()
            ctx.setBlendMode(.clear)
            for i in 0..<5 {
                let y = R - R * 0.1 - CGFloat(i) * R * 0.17
                ctx.fill(CGRect(x: 0, y: y, width: 2 * R, height: R * (0.03 + 0.014 * CGFloat(4 - i))))
            }
        }
        let hh = hz * 0.45
        hills = image(CGSize(width: 2 * W, height: hh + 2)) { ctx, _ in
            let peaks: [CGFloat] = [0, 0.06, 0.13, 0.2, 0.28, 0.35, 0.42, 0.5, 0.57, 0.64, 0.71, 0.78, 0.86, 0.93, 1]
            let hs: [CGFloat] = [0.3, 0.35, 0.7, 0.45, 0.2, 0.25, 0.6, 0.4, 0.75, 0.3, 0.55, 0.35, 0.65, 0.4, 0.3]
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: hh))
            for (x, h) in zip(peaks, hs) { p.addLine(to: CGPoint(x: x * 2 * W, y: hh - h * hh)) }
            p.addLine(to: CGPoint(x: 2 * W, y: hh)); p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(UIColor(red: 20 / 255, green: 8 / 255, blue: 34 / 255, alpha: 1).cgColor); ctx.fillPath()
            ctx.addPath(p); ctx.setStrokeColor(Self.acc.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1.6); ctx.strokePath()
        }
        glow = radialSprite(Self.acc, 0.8)
        redGlow = radialSprite(UIColor(red: 1, green: 0.16, blue: 0.2, alpha: 1), 0.8)
    }

    private func radialSprite(_ c: UIColor, _ a: CGFloat) -> CGImage? {
        image(CGSize(width: 64, height: 64)) { ctx, _ in
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let g = CGGradient(colorsSpace: cs, colors: [c.withAlphaComponent(a).cgColor, c.withAlphaComponent(0).cgColor] as CFArray,
                                     locations: [0, 1]) else { return }
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: 32, y: 32), startRadius: 0, endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
        }
    }

    /// Imagem desenhada com origem no canto de cima (igual ao quadro do painel).
    private func image(_ size: CGSize, _ body: (CGContext, CGSize) -> Void) -> CGImage? {
        let w = max(1, Int(size.width.rounded(.up))), h = max(1, Int(size.height.rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx, size)
        return ctx.makeImage()
    }

    /// Desenha uma imagem pronta no quadro (que está com o eixo y virado).
    private func draw(_ ctx: CGContext, _ img: CGImage, _ r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    private func linear(_ ctx: CGContext, _ r: CGRect, _ stops: [(CGFloat, UIColor)]) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let g = CGGradient(colorsSpace: cs, colors: stops.map { $0.1.cgColor } as CFArray, locations: stops.map { $0.0 }) else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        ctx.restoreGState()
    }

    // ------------------------------------------------------------------ piloto

    private func rr(_ ctx: CGContext, _ r: CGRect, _ rad: CGFloat, _ c: UIColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(rad, r.width / 2), cornerHeight: min(rad, r.height / 2), transform: nil))
        ctx.setFillColor(c.cgColor)
        ctx.fillPath()
    }

    private func poly(_ ctx: CGContext, _ pts: [CGPoint], _ c: UIColor) {
        ctx.addLines(between: pts); ctx.closePath()
        ctx.setFillColor(c.cgColor); ctx.fillPath()
    }

    private func drawRider(_ ctx: CGContext, cx: CGFloat, ground gr: CGFloat, u: CGFloat, lean: CGFloat) {
        func C(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        // sombra
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.43).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - u * 0.2, y: gr - u * 0.03, width: u * 0.4, height: u * 0.06))
        ctx.saveGState()
        ctx.translateBy(x: cx, y: gr)
        ctx.rotate(by: max(-55, min(55, lean)) * .pi / 180)
        ctx.translateBy(x: -cx, y: -gr)
        // pneu
        let tire = CGRect(x: cx - u * 0.075, y: gr - u * 0.36, width: u * 0.15, height: u * 0.36)
        rr(ctx, tire, u * 0.07, C(14, 14, 18))
        ctx.addPath(CGPath(roundedRect: tire, cornerWidth: u * 0.07, cornerHeight: u * 0.07, transform: nil))
        ctx.setStrokeColor(C(70, 74, 84).cgColor); ctx.setLineWidth(u * 0.012); ctx.strokePath()
        // rabeta e lanterna
        poly(ctx, [CGPoint(x: cx - u * 0.2, y: gr - u * 0.5), CGPoint(x: cx + u * 0.2, y: gr - u * 0.5),
                   CGPoint(x: cx + u * 0.13, y: gr - u * 0.33), CGPoint(x: cx - u * 0.13, y: gr - u * 0.33)], C(40, 44, 54))
        if let g = redGlow { draw(ctx, g, CGRect(x: cx - u * 0.2, y: gr - u * 0.62, width: u * 0.4, height: u * 0.4)) }
        rr(ctx, CGRect(x: cx - u * 0.11, y: gr - u * 0.45, width: u * 0.22, height: u * 0.05), u * 0.02, C(255, 60, 70))
        rr(ctx, CGRect(x: cx + u * 0.12, y: gr - u * 0.3, width: u * 0.08, height: u * 0.1), u * 0.03, C(120, 126, 138))
        // banco
        poly(ctx, [CGPoint(x: cx - u * 0.24, y: gr - u * 0.5), CGPoint(x: cx + u * 0.24, y: gr - u * 0.5),
                   CGPoint(x: cx + u * 0.19, y: gr - u * 0.66), CGPoint(x: cx - u * 0.19, y: gr - u * 0.66)], C(28, 30, 38))
        // braços e luvas
        ctx.setStrokeColor(C(36, 40, 52).cgColor); ctx.setLineWidth(u * 0.07); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: cx - u * 0.15, y: gr - u * 0.86)); ctx.addLine(to: CGPoint(x: cx - u * 0.3, y: gr - u * 0.66))
        ctx.move(to: CGPoint(x: cx + u * 0.15, y: gr - u * 0.86)); ctx.addLine(to: CGPoint(x: cx + u * 0.3, y: gr - u * 0.66))
        ctx.strokePath()
        ctx.setFillColor(C(15, 15, 18).cgColor)
        for s in [-1.0, 1.0] as [CGFloat] {
            ctx.fillEllipse(in: CGRect(x: cx + s * u * 0.31 - u * 0.04, y: gr - u * 0.69, width: u * 0.08, height: u * 0.08))
        }
        // jaqueta azul com faixa
        rr(ctx, CGRect(x: cx - u * 0.17, y: gr - u * 0.93, width: u * 0.34, height: u * 0.29), u * 0.08, Self.acc)
        ctx.setFillColor(UIColor(red: 10 / 255, green: 12 / 255, blue: 20 / 255, alpha: 0.59).cgColor)
        ctx.fill(CGRect(x: cx - u * 0.03, y: gr - u * 0.91, width: u * 0.06, height: u * 0.25))
        // capacete
        let hy = gr - u * 1.0
        let helmet = CGRect(x: cx - u * 0.12, y: hy - u * 0.12, width: u * 0.24, height: u * 0.24)
        ctx.setFillColor(C(200, 204, 214).cgColor); ctx.fillEllipse(in: helmet)
        ctx.setFillColor(C(236, 238, 244).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - u * 0.1, y: hy - u * 0.11, width: u * 0.12, height: u * 0.1))
        ctx.saveGState()
        ctx.addEllipse(in: helmet); ctx.clip()
        ctx.setFillColor(Self.acc.cgColor)
        ctx.fill(CGRect(x: cx - u * 0.022, y: hy - u * 0.12, width: u * 0.044, height: u * 0.24))
        ctx.restoreGState()
        ctx.restoreGState()
    }

    // ------------------------------------------------------------------ textos

    private func drawHud(_ ctx: CGContext, _ s: NavEngine.Snapshot, now: Date, safe: CGFloat,
                         kmh: Double, sensor: (lean: Double, maxLeft: Double, maxRight: Double, ok: Bool)) {
        let W = CGFloat(width), H = CGFloat(height)
        let k = H / 384
        text("\(Int(kmh.rounded()))", 54 * k, .heavy, .white, CGRect(x: W * 0.03, y: 6 * k, width: 200 * k, height: 62 * k))
        text("km/h", 16 * k, .bold, Self.acc, CGRect(x: W * 0.03 + 2, y: 62 * k, width: 120 * k, height: 20 * k))
        if sensor.ok {
            text("máx ◀ \(Int(sensor.maxLeft.rounded()))°   \(Int(sensor.maxRight.rounded()))° ▶", 16 * k, .semibold, Self.gray,
                 CGRect(x: W * 0.03, y: 84 * k, width: 260 * k, height: 22 * k))
            let deg = abs(sensor.lean)
            if deg >= 3 {
                let col = deg >= 40 ? UIColor(red: 1, green: 0.43, blue: 0.35, alpha: 1)
                    : (deg >= 25 ? UIColor(red: 1, green: 0.78, blue: 0.35, alpha: 1) : .white)
                let right = sensor.lean > 0
                let lab = right ? "\(Int(deg.rounded()))° ▶" : "◀ \(Int(deg.rounded()))°"
                let cx = W / 2 + (right ? 1 : -1) * W * 0.17
                text(lab, 30 * k, .heavy, col, CGRect(x: cx - 90 * k, y: safe * 0.6 - 26 * k, width: 180 * k, height: 38 * k), align: .center)
            }
        } else {
            text("Prenda o iPhone em pé na moto", 15 * k, .semibold, Self.gray, CGRect(x: W * 0.03, y: 84 * k, width: 320 * k, height: 22 * k))
        }

        // canto direito: radar tem prioridade; senão próxima manobra; e o relógio
        if let a = s.radar {
            let r = CGRect(x: W - 232 * k, y: 10 * k, width: 222 * k, height: 50 * k)
            rr(ctx, r, 14 * k, UIColor(red: 0.86, green: 0.25, blue: 0.22, alpha: 1))
            let lim = a.radar.maxspeed.map { "RADAR \($0)" } ?? "RADAR"
            text("\(lim) · \(Geo.formatDistance(a.distance))", 21 * k, .heavy, .white, r.insetBy(dx: 12 * k, dy: 12 * k), align: .center)
        } else {
            text(Geo.clock(now), 38 * k, .heavy, .white, CGRect(x: W - 210 * k, y: 8 * k, width: 196 * k, height: 46 * k), align: .right)
        }
        if s.navigating {
            let arrow: String
            switch s.nextStep?.maneuver ?? .straight {
            case .left, .slightLeft, .sharpLeft: arrow = "↰"
            case .right, .slightRight, .sharpRight: arrow = "↱"
            case .uTurn: arrow = "↶"
            default: arrow = "↑"
            }
            text("\(arrow) \(Geo.formatDistance(s.distanceToNext))", 24 * k, .heavy, .white,
                 CGRect(x: W - 260 * k, y: 62 * k, width: 246 * k, height: 30 * k), align: .right)
            if let st = s.nextStep?.street {
                text(st, 15 * k, .semibold, Self.gray, CGRect(x: W - 300 * k, y: 92 * k, width: 286 * k, height: 20 * k), align: .right)
            }
        }
        drawWatermark(ctx, safe: safe)
    }

    private static let instaLogo = UIImage(named: "InstaLogo")

    private func drawWatermark(_ ctx: CGContext, safe: CGFloat) {
        let d = UserDefaults.standard
        guard d.object(forKey: "wmOn") as? Bool ?? true else { return }
        let handle = (d.string(forKey: "wmText") ?? "@vlog.tron").trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { return }
        let kk = CGFloat(min(max(d.object(forKey: "wmScale") as? Double ?? 1.0, 0.6), 2.0))
        let fs = 17 * kk
        let tw = (handle as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fs, weight: .bold)]).width
        let h = 34 * kk
        let r = CGRect(x: 12, y: safe - 10 - h, width: tw + 50 * kk, height: h)
        rr(ctx, r, h / 2, UIColor.black.withAlphaComponent(0.55))
        let logo = CGRect(x: r.minX + 4 * kk, y: r.minY + 4 * kk, width: 26 * kk, height: 26 * kk)
        Self.instaLogo?.draw(in: logo)
        text(handle, fs, .bold, .white, CGRect(x: logo.maxX + 7 * kk, y: r.midY - fs * 0.66, width: tw + 6, height: fs * 1.35))
    }

    private func text(_ s: String, _ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor, _ rect: CGRect,
                      align: NSTextAlignment = .left) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: para]
        (s as NSString).draw(in: rect, withAttributes: attrs)
    }
}
