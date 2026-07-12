import Testing
import Foundation
import CommonCrypto
@testable import ClawdIsland

@Suite struct ClaudeAPIServiceTests {

    /// AES-128-CBC encrypt with the exact IV (16 × 0x20) and PKCS7 padding that
    /// `ClaudeAPIService.decrypt` expects, so we can round-trip against it.
    private func aesCBCEncrypt(_ plaintext: Data, key: Data) -> Data {
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { ob in
            plaintext.withUnsafeBytes { pb in key.withUnsafeBytes { kb in iv.withUnsafeBytes { ib in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        kb.baseAddress, 16, ib.baseAddress,
                        pb.baseAddress, plaintext.count,
                        ob.baseAddress, ob.count, &moved)
            }}}
        }
        precondition(status == kCCSuccess, "test encrypt failed")
        out.removeSubrange(moved..<out.count)
        return out
    }

    /// A "v10" Chromium cookie blob: literal "v10" prefix + AES-128-CBC ciphertext.
    private func v10Blob(_ plaintext: Data, key: Data) -> Data {
        Data("v10".utf8) + aesCBCEncrypt(plaintext, key: key)
    }

    private let key = Data("0123456789abcdef".utf8)   // any 16-byte key; decrypt uses what we pass

    @Test func decryptsV10RoundTrip() async {
        let plaintext = "sk-session-cookie-value-123"
        let blob = v10Blob(Data(plaintext.utf8), key: key)
        let service = ClaudeAPIService()
        #expect(await service.decrypt(blob, key: key) == plaintext)
    }

    @Test func decryptsV10WithLeading32ByteHash() async {
        // Newer Chromium prepends a 32-byte domain hash inside the plaintext. Use a hash made of
        // 0xFF bytes so the full plaintext is not valid UTF-8 — that forces decrypt to fall through
        // to its dropFirst(32) path (a valid-UTF-8 hash would wrongly decode without stripping).
        let value = "real-cookie-value"
        let hash = Data(repeating: 0xFF, count: 32)
        let blob = v10Blob(hash + Data(value.utf8), key: key)
        let service = ClaudeAPIService()
        #expect(await service.decrypt(blob, key: key) == value)
    }

    @Test func nonV10FallsBackToPlainUTF8() async {
        // No "v10" prefix → decrypt returns the bytes decoded as UTF-8 verbatim (Firefox-style /
        // legacy plaintext), never touching the AES path.
        let plaintext = "plaintext-cookie"
        let service = ClaudeAPIService()
        #expect(await service.decrypt(Data(plaintext.utf8), key: key) == plaintext)
    }
}
