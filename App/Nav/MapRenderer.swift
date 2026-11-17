import UIKit
import CoreVideo
import CoreLocation

/// Desenha a tela do painel (mapa escuro girando com a moto, rota, seta da próxima curva,
/// velocidade e radar) usando só o processador, para funcionar com o iPhone bloqueado.
final class MapRenderer {
    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?
    private var heading: Double = 0
    private let tile = Double(TileCache.tilePx) // pixels por tile

    // cores
    private static let bg = UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
    private static let card = UIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 0.94)
    private static let routeIn = UIColor(red: 0.24, green: 0.55, blue: 1.0, alpha: 1)
    private static let routeOut = UIColor(red: 0.04, green: 0.16, blue: 0.34, alpha: 1)
    private static let user = UIColor(red: 0.22, green: 0.84, blue: 1.0, alpha: 1)
    private static let red = UIColor(red: 0.86, green: 0.25, blue: 0.22, alpha: 1)
    private static let gray = UIColor(red: 0.62, green: 0.68, blue: 0.76, alpha: 1)

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
        let panelW: CGFloat = s.navigating ? min(270, W * 0.34) : 0
        let anchor = CGPoint(x: panelW + (W - panelW) / 2, y: H * 0.70)
        ctx.setFillColor(Self.bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        if let fix = s.coord {
            // entre uma leitura do GPS e outra (1 por segundo), adianta a moto pela velocidade
            var c = fix
            let age = now.timeIntervalSince(s.fixTime)
            if let course = s.course, s.speed > 1.5, age > 0, age < 2 { c = Geo.move(fix, meters: s.speed * age, course: course) }
            if let course = s.course { heading = Self.smooth(heading, course, 0.35) }
            let z = s.speed * 3.6 > 75 ? 15 : 16
            let center = Geo.world(c, z: z, tile: tile)
            let angle = CGFloat(-heading * .pi / 180)
            let radius = hypot(max(anchor.x, W - anchor.x), max(anchor.y, H - anchor.y)) + 4

            ctx.saveGState()
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: angle)
            ctx.translateBy(x: -center.x, y: -center.y)
            drawCanvas(ctx, center: center, radius: radius, z: z)
            drawRoute(ctx, s, from: c, center: center, radius: radius, z: z)
            ctx.restoreGState()

            for r in s.radars where Geo.meters(c, r.coord) < 1500 {
                let w = Geo.world(r.coord, z: z, tile: tile)
                let dx = w.x - center.x, dy = w.y - center.y
                let p = CGPoint(x: anchor.x + dx * cos(angle) - dy * sin(angle), y: anchor.y + dx * sin(angle) + dy * cos(angle))
                if p.x > panelW && p.x < W && p.y > 0 && p.y < H { drawRadarPin(ctx, at: p, limit: r.maxspeed) }
            }
            drawUser(ctx, at: anchor)
            text("Mapas da Apple", 9, .regular, Self.gray.withAlphaComponent(0.7),
                 in: CGRect(x: W - 210, y: H - 104, width: 200, height: 12), align: .right)
        } else {
            text("Aguardando GPS…", 24, .semibold, Self.gray, in: CGRect(x: 0, y: H / 2 - 16, width: W, height: 32), align: .center)
        }

        if s.navigating { drawNavPanel(ctx, s, width: panelW) } else { drawClock(ctx, now) }
        drawWatermark(ctx, left: panelW)
        drawSpeed(ctx, s)
        if let a = s.radar { drawRadarBanner(ctx, a) }

        let img = makeImage ? ctx.makeImage() : nil
        return (pb, img)
    }

    // ------------------------------------------------------------------ mapa

    // Mapa montado de uma vez numa imagem grande (sem girar); a cada quadro só giramos essa
    // imagem pronta. Bem mais leve do que redesenhar todos os pedaços girando.
    private var canvas: CGImage?
    private var canvasCenter = CGPoint.zero
    private var canvasZ = -1
    private var canvasComplete = false
    private var canvasBuiltAt = Date.distantPast
    private let canvasSize: CGFloat = 1792

    private func drawCanvas(_ ctx: CGContext, center: CGPoint, radius: CGFloat, z: Int) {
        let half = canvasSize / 2
        let moved = hypot(center.x - canvasCenter.x, center.y - canvasCenter.y)
        let needsRebuild = canvas == nil || canvasZ != z || moved > half - radius - 8 ||
            (!canvasComplete && Date().timeIntervalSince(canvasBuiltAt) > 1)
        if needsRebuild { buildCanvas(center: CGPoint(x: center.x.rounded(), y: center.y.rounded()), z: z) }
        guard let img = canvas else { return }
        let rect = CGRect(x: canvasCenter.x - half, y: canvasCenter.y - half, width: canvasSize, height: canvasSize)
        ctx.saveGState()
        ctx.interpolationQuality = .low
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private func buildCanvas(center: CGPoint, z: Int) {
        let n = Int(canvasSize)
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        c.setFillColor(Self.bg.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        // coordenadas como no painel (y para baixo), com origem no canto da imagem
        c.translateBy(x: 0, y: CGFloat(n))
        c.scaleBy(x: 1, y: -1)
        let half = canvasSize / 2
        let origin = CGPoint(x: center.x - half, y: center.y - half)
        let t = CGFloat(tile)
        let x0 = Int(floor(origin.x / t)), x1 = Int(floor((origin.x + canvasSize) / t))
        let y0 = Int(floor(origin.y / t)), y1 = Int(floor((origin.y + canvasSize) / t))
        var complete = true
        c.interpolationQuality = .medium
        for ty in y0...y1 {
            for tx in x0...x1 {
                guard let img = TileCache.shared.image(z: z, x: tx, y: ty) else { complete = false; continue }
                let r = CGRect(x: CGFloat(tx) * t - origin.x, y: CGFloat(ty) * t - origin.y, width: t, height: t)
                c.saveGState()
                c.translateBy(x: r.minX, y: r.maxY)
                c.scaleBy(x: 1, y: -1)
                c.draw(img, in: CGRect(x: 0, y: 0, width: t + 0.5, height: t + 0.5))
                c.restoreGState()
            }
        }
        canvas = c.makeImage()
        canvasCenter = center
        canvasZ = z
        canvasComplete = complete
        canvasBuiltAt = Date()
    }

    private func drawRoute(_ ctx: CGContext, _ s: NavEngine.Snapshot, from c: CLLocationCoordinate2D,
                           center: CGPoint, radius: CGFloat, z: Int) {
        guard s.route.count > 1 else { return }
        let path = CGMutablePath()
        path.move(to: Geo.world(c, z: z, tile: tile))
        let start = min(s.progressIndex + 1, s.route.count - 1)
        var wasNear = false
        for i in start..<s.route.count {
            let p = Geo.world(s.route[i], z: z, tile: tile)
            path.addLine(to: p)
            let far = hypot(p.x - center.x, p.y - center.y) > radius * 4
            if !far { wasNear = true } else if wasNear { break }
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(Self.routeOut.cgColor)
        ctx.setLineWidth(15)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(Self.routeIn.cgColor)
        ctx.setLineWidth(9)
        ctx.strokePath()
    }

    private func drawUser(_ ctx: CGContext, at p: CGPoint) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x, y: p.y - 20))
        path.addLine(to: CGPoint(x: p.x + 14, y: p.y + 15))
        path.addLine(to: CGPoint(x: p.x, y: p.y + 7))
        path.addLine(to: CGPoint(x: p.x - 14, y: p.y + 15))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setStrokeColor(Self.user.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(9)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(Self.user.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    private func drawRadarPin(_ ctx: CGContext, at p: CGPoint, limit: Int?) {
        let r = CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(Self.red.cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: r.insetBy(dx: 2, dy: 2))
        text(limit.map(String.init) ?? "R", 11, .heavy, .black, in: CGRect(x: r.minX, y: r.midY - 7, width: r.width, height: 14), align: .center)
    }

    // ------------------------------------------------------------------ informações

    private func roundRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, _ color: UIColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    private func drawNavPanel(_ ctx: CGContext, _ s: NavEngine.Snapshot, width pw: CGFloat) {
        let H = CGFloat(height)
        let box = CGRect(x: 10, y: 10, width: pw - 16, height: H - 20)
        roundRect(ctx, box, 18, Self.card)
        let m = s.nextStep?.maneuver ?? .straight
        drawManeuver(ctx, m, in: CGRect(x: box.minX + 14, y: box.minY + 16, width: 82, height: 82))
        text(Geo.formatDistance(s.distanceToNext), 38, .heavy, .white,
             in: CGRect(x: box.minX + 104, y: box.minY + 34, width: box.width - 110, height: 46))
        let street = s.nextStep?.street ?? (s.destinationName ?? "Siga em frente")
        text(street, 21, .semibold, Self.gray, in: CGRect(x: box.minX + 16, y: box.minY + 112, width: box.width - 28, height: 84), lines: 3)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.1).cgColor)
        ctx.fill(CGRect(x: box.minX + 16, y: box.maxY - 92, width: box.width - 32, height: 1.5))
        let eta = Date().addingTimeInterval(s.remainingTime)
        text("Chegada " + Geo.clock(eta), 21, .bold, .white, in: CGRect(x: box.minX + 16, y: box.maxY - 80, width: box.width - 28, height: 28))
        text("\(Geo.formatDuration(s.remainingTime)) · \(Geo.formatDistance(s.remainingDistance))", 17, .medium, Self.gray,
             in: CGRect(x: box.minX + 16, y: box.maxY - 46, width: box.width - 28, height: 24))
    }

    private func drawClock(_ ctx: CGContext, _ now: Date) {
        let r = CGRect(x: 12, y: 12, width: 132, height: 54)
        roundRect(ctx, r, 16, Self.card)
        text(Geo.clock(now), 30, .bold, .white, in: CGRect(x: r.minX, y: r.minY + 9, width: r.width, height: 36), align: .center)
    }

    private func drawSpeed(_ ctx: CGContext, _ s: NavEngine.Snapshot) {
        let W = CGFloat(width), H = CGFloat(height)
        let kmh = Int((s.speed * 3.6).rounded())
        let c = CGPoint(x: W - 56, y: H - 56)
        let r = CGRect(x: c.x - 42, y: c.y - 42, width: 84, height: 84)
        ctx.setFillColor(Self.card.cgColor)
        ctx.fillEllipse(in: r)
        let over = s.radar?.radar.maxspeed.map { kmh > $0 + 3 } ?? false
        ctx.setStrokeColor((over ? Self.red : UIColor.white.withAlphaComponent(0.18)).cgColor)
        ctx.setLineWidth(over ? 5 : 3)
        ctx.strokeEllipse(in: r.insetBy(dx: 2, dy: 2))
        text("\(kmh)", 32, .heavy, over ? Self.red : .white, in: CGRect(x: r.minX, y: c.y - 25, width: r.width, height: 38), align: .center)
        text("km/h", 12, .semibold, Self.gray, in: CGRect(x: r.minX, y: c.y + 12, width: r.width, height: 16), align: .center)
    }

    private func drawRadarBanner(_ ctx: CGContext, _ a: RadarAlert) {
        let W = CGFloat(width)
        let r = CGRect(x: W - 252, y: 12, width: 240, height: 62)
        roundRect(ctx, r, 16, Self.red)
        let badge = CGRect(x: r.minX + 9, y: r.minY + 9, width: 44, height: 44)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: badge)
        ctx.setStrokeColor(UIColor(red: 0.55, green: 0.08, blue: 0.06, alpha: 1).cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: badge.insetBy(dx: 2, dy: 2))
        text(a.radar.maxspeed.map(String.init) ?? "!", 18, .heavy, .black,
             in: CGRect(x: badge.minX, y: badge.midY - 11, width: badge.width, height: 22), align: .center)
        text("RADAR", 14, .heavy, UIColor.white.withAlphaComponent(0.85), in: CGRect(x: r.minX + 64, y: r.minY + 8, width: 160, height: 18))
        text(Geo.formatDistance(a.distance), 26, .heavy, .white, in: CGRect(x: r.minX + 64, y: r.minY + 25, width: 170, height: 32))
    }

    // ------------------------------------------------------------------ marca (para os vídeos)

    private static let camIcon = UIImage(systemName: "camera.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))?.withTintColor(.white, renderingMode: .alwaysOriginal)

    private func drawWatermark(_ ctx: CGContext, left: CGFloat) {
        let d = UserDefaults.standard
        guard d.object(forKey: "wmOn") as? Bool ?? true else { return }
        let handle = (d.string(forKey: "wmText") ?? "@vlog.tron").trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { return }
        let font = UIFont.systemFont(ofSize: 17, weight: .bold)
        let tw = (handle as NSString).size(withAttributes: [.font: font]).width
        let H = CGFloat(height)
        let r = CGRect(x: left + 12, y: H - 46, width: tw + 50, height: 34)
        roundRect(ctx, r, 17, UIColor.black.withAlphaComponent(0.55))
        let badge = CGRect(x: r.minX + 5, y: r.minY + 5, width: 24, height: 24)
        roundRect(ctx, badge, 7, UIColor(red: 1.0, green: 0.42, blue: 0.16, alpha: 1))
        Self.camIcon?.draw(in: badge.insetBy(dx: 4, dy: 5))
        text(handle, 17, .bold, .white, in: CGRect(x: badge.maxX + 8, y: r.minY + 6, width: tw + 6, height: 22))
    }

    // ------------------------------------------------------------------ setas

    private func drawManeuver(_ ctx: CGContext, _ m: Maneuver, in box: CGRect) {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height) }
        let lw = box.width * 0.13
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let path = CGMutablePath()
        var head: (CGPoint, CGFloat)?
        switch m {
        case .straight:
            path.move(to: P(0.5, 0.92)); path.addLine(to: P(0.5, 0.3)); head = (P(0.5, 0.12), -.pi / 2)
        case .left, .right:
            let s: CGFloat = m == .right ? 1 : -1
            path.move(to: P(0.5 - 0.12 * s, 0.92)); path.addLine(to: P(0.5 - 0.12 * s, 0.55))
            path.addQuadCurve(to: P(0.5 + 0.08 * s, 0.33), control: P(0.5 - 0.12 * s, 0.33))
            path.addLine(to: P(0.5 + 0.2 * s, 0.33)); head = (P(0.5 + 0.38 * s, 0.33), s > 0 ? 0 : .pi)
        case .slightLeft, .slightRight:
            let s: CGFloat = m == .slightRight ? 1 : -1
            path.move(to: P(0.5 - 0.1 * s, 0.92)); path.addLine(to: P(0.5 - 0.1 * s, 0.6))
            path.addLine(to: P(0.5 + 0.14 * s, 0.32)); head = (P(0.5 + 0.27 * s, 0.17), s > 0 ? -.pi / 4 : -3 * .pi / 4)
        case .sharpLeft, .sharpRight:
            let s: CGFloat = m == .sharpRight ? 1 : -1
            path.move(to: P(0.5 - 0.15 * s, 0.92)); path.addLine(to: P(0.5 - 0.15 * s, 0.22))
            path.addLine(to: P(0.5 + 0.12 * s, 0.55)); head = (P(0.5 + 0.25 * s, 0.71), s > 0 ? .pi / 4 : 3 * .pi / 4)
        case .uTurn:
            path.move(to: P(0.66, 0.92)); path.addLine(to: P(0.66, 0.42))
            path.addArc(center: P(0.5, 0.42), radius: 0.16 * box.width, startAngle: 0, endAngle: .pi, clockwise: true)
            path.addLine(to: P(0.34, 0.6)); head = (P(0.34, 0.8), .pi / 2)
        case .roundabout:
            path.addEllipse(in: CGRect(x: box.minX + 0.32 * box.width, y: box.minY + 0.27 * box.height, width: 0.36 * box.width, height: 0.36 * box.height))
            path.move(to: P(0.5, 0.95)); path.addLine(to: P(0.5, 0.64))
            path.move(to: P(0.63, 0.32)); path.addLine(to: P(0.72, 0.22)); head = (P(0.83, 0.11), -.pi / 4)
        case .arrive:
            path.move(to: P(0.32, 0.92)); path.addLine(to: P(0.32, 0.12))
            let flag = CGMutablePath()
            flag.move(to: P(0.32, 0.12)); flag.addLine(to: P(0.82, 0.28)); flag.addLine(to: P(0.32, 0.46)); flag.closeSubpath()
            ctx.addPath(flag); ctx.fillPath()
        }
        ctx.addPath(path)
        ctx.strokePath()
        if let h = head {
            let (tip, ang) = h
            let len = box.width * 0.3, half = box.width * 0.2
            let back = CGPoint(x: tip.x - cos(ang) * len, y: tip.y - sin(ang) * len)
            let tri = CGMutablePath()
            tri.move(to: tip)
            tri.addLine(to: CGPoint(x: back.x + cos(ang + .pi / 2) * half, y: back.y + sin(ang + .pi / 2) * half))
            tri.addLine(to: CGPoint(x: back.x - cos(ang + .pi / 2) * half, y: back.y - sin(ang + .pi / 2) * half))
            tri.closeSubpath()
            ctx.addPath(tri)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // ------------------------------------------------------------------ utilidades

    private func text(_ s: String, _ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor, in rect: CGRect,
                      lines: Int = 1, align: NSTextAlignment = .left) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        let str = NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
        str.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private static func smooth(_ from: Double, _ to: Double, _ k: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        let r = (from + d * k).truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}
