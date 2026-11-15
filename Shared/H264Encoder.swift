import Foundation
import VideoToolbox
import CoreMedia

/// Codificador H.264 em tempo real (VideoToolbox, o chip de vídeo do iPhone).
/// Entrega cada quadro em Annex-B (00 00 00 01 ...). Os quadros-chave já vêm com SPS/PPS na frente,
/// que é o que o painel espera antes de cada quadro-chave.
final class H264Encoder {
    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKey = true

    /// (dados Annex-B, é quadro-chave)
    var onFrame: (([UInt8], Bool) -> Void)?
    var onError: ((String) -> Void)?

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init?(width: Int, height: Int, bitrate: Int, fps: Int = 30) {
        self.width = width
        self.height = height
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let session = s else { return nil }
        let props: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, NSNumber(value: true)),
            // perfil Baseline: o mais simples, qualquer decodificador de painel entende
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, NSNumber(value: false)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            // teto de bytes por segundo: o painel do MotoNav fechou o vídeo com muito mais que 3 Mbps
            (kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bitrate * 3 / 2 / 8), NSNumber(value: 1)] as NSArray),
        ]
        for (k, v) in props { VTSessionSetProperty(session, key: k, value: v) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit { invalidate() }

    func requestKeyFrame() { lock.lock(); forceKey = true; lock.unlock() }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        let key = forceKey
        forceKey = false
        let s = session
        lock.unlock()
        guard let session = s else { return }
        let frameProps: CFDictionary? = key ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as NSDictionary as CFDictionary) : nil
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: frameProps, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self = self else { return }
            if status != noErr { self.onError?("codificador: erro \(status)"); return }
            guard let sample = sample else { return }
            self.output(sample)
        }
        if st != noErr {
            onError?("codificador recusou o quadro (\(st))")
            if st == -12903 { rebuildNeeded = true } // kVTInvalidSessionErr
        }
    }

    /// O iOS invalida a sessão quando o app vai para o segundo plano; quem usa recria o codificador.
    private(set) var rebuildNeeded = false

    func invalidate() {
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        if let s = s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    private func output(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
           let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool, notSync {
            isKey = false
        }
        var out = [UInt8]()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
                    out += H264Encoder.startCode
                    out += UnsafeBufferPointer(start: p, count: size)
                }
            }
        }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: total)
        let st = avcc.withUnsafeMutableBytes { p in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: p.baseAddress!)
        }
        guard st == kCMBlockBufferNoErr else { return }
        // AVCC (tamanho de 4 bytes antes de cada NAL) -> Annex-B (00 00 00 01 antes de cada NAL)
        var i = 0
        while i + 4 <= total {
            let n = Int(UInt32(avcc[i]) << 24 | UInt32(avcc[i + 1]) << 16 | UInt32(avcc[i + 2]) << 8 | UInt32(avcc[i + 3]))
            i += 4
            if n <= 0 || i + n > total { break }
            out += H264Encoder.startCode
            out += avcc[i..<(i + n)]
            i += n
        }
        onFrame?(out, isKey)
    }
}
