import Foundation
import VideoToolbox
import CoreVideo
import ImageIO

/// Transforma a tela do iPhone (retrato, ~1170x2532) no quadro do painel (800x480):
/// gira conforme o iPhone está deitado e reduz, com faixas pretas ("caber") ou cortando as bordas
/// ("preencher"). Tudo no hardware de vídeo, sem passar pela CPU, para caber no limite de memória
/// da extensão (50 MB).
final class FrameScaler {
    let width: Int
    let height: Int
    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var scaledPool: CVPixelBufferPool?   // tamanho antes de girar
    private var scaledW = 0, scaledH = 0
    private var outPool: CVPixelBufferPool?      // tamanho final do painel
    private var lastMode = ""

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        VTPixelRotationSessionCreate(kCFAllocatorDefault, &rotation)
        outPool = FrameScaler.makePool(width, height)
    }

    deinit {
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
        if let r = rotation { VTPixelRotationSessionInvalidate(r) }
    }

    static func makePool(_ w: Int, _ h: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                attrs as CFDictionary, &pool)
        return pool
    }

    /// Quantos graus no sentido horário girar para a imagem ficar em pé.
    /// A orientação vem da ReplayKit no padrão EXIF (6 = girar 90° horário; 8 = 90° anti-horário).
    static func degrees(for o: CGImagePropertyOrientation, flip: Bool) -> Int {
        var d: Int
        switch o {
        case .right, .rightMirrored: d = 90
        case .left, .leftMirrored: d = 270
        case .down, .downMirrored: d = 180
        default: d = 0
        }
        if flip && (d == 90 || d == 270) { d = (d + 180) % 360 }
        return d
    }

    func process(_ src: CVPixelBuffer, orientation: CGImagePropertyOrientation, fill: Bool, flip: Bool) -> CVPixelBuffer? {
        guard let transfer = transfer, let outPool = outPool else { return nil }
        let deg = FrameScaler.degrees(for: orientation, flip: flip)
        let sideways = deg == 90 || deg == 270
        // primeiro reduz (barato) e só depois gira o quadro pequeno
        let tw = sideways ? height : width
        let th = sideways ? width : height

        let mode = fill ? "fill" : "fit"
        if mode != lastMode {
            lastMode = mode
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: (fill ? kVTScalingMode_CropSourceToCleanAperture : kVTScalingMode_Letterbox))
        }
        if fill { setCleanAperture(src, targetW: tw, targetH: th) }

        let target: CVPixelBuffer?
        if sideways {
            if scaledPool == nil || scaledW != tw || scaledH != th {
                scaledPool = FrameScaler.makePool(tw, th); scaledW = tw; scaledH = th
            }
            target = FrameScaler.buffer(scaledPool)
        } else {
            target = FrameScaler.buffer(outPool)
        }
        guard let scaled = target else { return nil }
        if !fill { FrameScaler.clearBlack(scaled) }
        guard VTPixelTransferSessionTransferImage(transfer, from: src, to: scaled) == noErr else { return nil }
        if deg == 0 { return scaled }

        guard let rotation = rotation, let out = FrameScaler.buffer(outPool) else { return nil }
        let key: CFString = deg == 90 ? kVTRotation_CW90 : (deg == 180 ? kVTRotation_180 : kVTRotation_CCW90)
        VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: key)
        guard VTPixelRotationSessionRotateImage(rotation, scaled, out) == noErr else { return nil }
        return out
    }

    /// "Preencher": marca no quadro de origem só o miolo com a proporção do painel.
    private func setCleanAperture(_ src: CVPixelBuffer, targetW: Int, targetH: Int) {
        let sw = Double(CVPixelBufferGetWidth(src)), sh = Double(CVPixelBufferGetHeight(src))
        let want = Double(targetW) / Double(targetH)
        var cw = sw, ch = sh
        if sw / sh > want { cw = sh * want } else { ch = sw / want }
        let dict: [String: Any] = [
            kCVImageBufferCleanApertureWidthKey as String: cw,
            kCVImageBufferCleanApertureHeightKey as String: ch,
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey as String: 0,
        ]
        CVBufferSetAttachment(src, kCVImageBufferCleanApertureKey, dict as CFDictionary, .shouldPropagate)
    }

    private static func buffer(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    /// Pinta de preto (Y=0, CbCr=128) para as faixas do modo "caber" não mostrarem sobra antiga.
    private static func clearBlack(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            memset(y, 0, CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * CVPixelBufferGetHeightOfPlane(pb, 0))
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
        }
    }
}
