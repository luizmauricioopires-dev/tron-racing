import Foundation

/// Conversa entre a extensão de transmissão (que capta a tela com o Waze) e o app.
/// Vai por TCP no próprio iPhone (127.0.0.1), assim não precisa de App Group nem conta paga.
///
/// Mensagem: [UInt32 LE tamanho do resto][UInt8 tipo][conteúdo]
enum FrameLink {
    static let port: UInt16 = 10899
    static let host = "127.0.0.1"

    // extensão -> app
    static let keyFrame: UInt8 = 2      // quadro-chave já com SPS/PPS (Annex-B)
    static let frame: UInt8 = 3         // quadro comum (Annex-B)
    static let log: UInt8 = 4           // texto para o log do app
    static let hello: UInt8 = 5         // extensão começou (JSON com o tamanho da tela)

    // app -> extensão
    static let settings: UInt8 = 10     // JSON {"w":800,"h":480,"bitrate":2500000,"fill":false,"flip":false}
    static let wantKey: UInt8 = 11      // pede um quadro-chave já

    static func pack(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(body.count + 5)
        out.appendLE32(Int32(body.count + 1))
        out.append(type)
        out.append(contentsOf: body)
        return out
    }

    static func read(_ s: TCPSocket) throws -> (UInt8, [UInt8]) {
        let h = try s.readFully(4)
        let len = Int(h.le32(0))
        if len < 1 || len > 4 * 1024 * 1024 { throw SockError.sys("mensagem inválida (\(len))", EINVAL) }
        let rest = try s.readFully(len)
        return (rest[0], Array(rest[1...]))
    }

    struct Settings: Codable, Equatable {
        var w: Int = 800
        var h: Int = 480
        var bitrate: Int = 2_500_000
        var fill: Bool = false
        var flip: Bool = false
    }
}
