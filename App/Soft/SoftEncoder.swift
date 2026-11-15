import Foundation
import CoreVideo

/// Codificador H.264 no processador (OpenH264). Mais lento que o chip de vídeo, mas funciona com o
/// iPhone bloqueado, quando o iOS proíbe o uso do chip de vídeo para apps em segundo plano.
final class SoftEncoder {
    let width: Int
    let height: Int
    private let handle: OpaquePointer
    private var out = [UInt8](repeating: 0, count: 1_500_000)

    init?(width: Int, height: Int, fps: Float, bitrate: Int) {
        guard let h = sh264_create(Int32(width), Int32(height), fps, Int32(bitrate)) else { return nil }
        self.width = width
        self.height = height
        handle = h
    }

    deinit { sh264_destroy(handle) }

    /// Espera um CVPixelBuffer BGRA do mesmo tamanho. Devolve (Annex-B, quadro-chave) ou nil.
    func encode(_ pb: CVPixelBuffer, forceKey: Bool) -> ([UInt8], Bool)? {
        guard CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var key: Int32 = 0
        let cap = out.count
        let n = out.withUnsafeMutableBufferPointer { o in
            sh264_encode_bgra(handle, base.assumingMemoryBound(to: UInt8.self), Int32(stride),
                              forceKey ? 1 : 0, o.baseAddress, Int32(cap), &key)
        }
        if n <= 0 { return nil }
        return (Array(out[0..<Int(n)]), key != 0)
    }
}
