import Foundation
import Security

/// Identidade do celular perante o painel (igual ao MotoNav): par RSA-1024 gerado no próprio
/// iPhone; mandamos a chave pública (X.509, base64) e o HUID do painel "cifrado" com a privada.
/// O painel não confere esse valor, mas o campo precisa existir.
enum RsaIdentity {
    private static let tag = "br.com.monteiro.tronracing.rsa".data(using: .utf8)!

    private static func privateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let k = item {
            return (k as! SecKey)
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 1024,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
            ],
        ]
        var err: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attrs as CFDictionary, &err)
    }

    /// Chave pública no formato que o Java usa (SubjectPublicKeyInfo DER), em base64.
    static func publicKey() -> String {
        guard let priv = privateKey(), let pub = SecKeyCopyPublicKey(priv),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { return "" }
        return (spkiHeader(for: pkcs1.count) + pkcs1).base64EncodedString()
    }

    /// Mesmo resultado do "RSA/ECB/PKCS1Padding" com a chave privada no Java.
    static func encryptHuid(_ huid: String) -> String {
        guard !huid.isEmpty, let priv = privateKey() else { return "" }
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(priv, .rsaSignatureDigestPKCS1v15Raw,
                                              Data(huid.utf8) as CFData, &err) as Data? else { return "" }
        return sig.base64EncodedString()
    }

    static func phoneUuid() -> String {
        if let u = UserDefaults.standard.string(forKey: "phoneUuid") { return u }
        let u = UUID().uuidString.lowercased()
        UserDefaults.standard.set(u, forKey: "phoneUuid")
        return u
    }

    /// SEQUENCE { SEQUENCE { rsaEncryption OID, NULL }, BIT STRING { chave PKCS#1 } }
    private static func spkiHeader(for keyLen: Int) -> Data {
        func derLen(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            if n < 0x100 { return [0x81, UInt8(n)] }
            return [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        }
        let algo: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString: [UInt8] = [0x03] + derLen(keyLen + 1) + [0x00]
        let inner = algo.count + bitString.count + keyLen
        return Data([0x30] + derLen(inner) + algo + bitString)
    }
}
