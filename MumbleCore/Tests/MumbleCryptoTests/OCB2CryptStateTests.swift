import Foundation
import Testing
@testable import MumbleCrypto

@Suite("OCB2-AES128 crypt state")
struct OCB2CryptStateTests {
    private let key = Data((0..<16).map { UInt8($0) })
    private let nonce = Data([
        0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 0x99, 0x88,
        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
    ])

    private func makeState(
        encryptNonce: Data? = nil, decryptNonce: Data? = nil
    ) -> OCB2CryptState {
        OCB2CryptState(
            key: key,
            encryptNonce: encryptNonce ?? nonce,
            decryptNonce: decryptNonce ?? nonce
        )!
    }

    // Known-answer tests from draft-krovetz-ocb-00, as used by upstream
    // TestCrypt::testvectors (key = nonce = 000102...0f).
    @Test("OCB2 known-answer test: empty message tag")
    func katEmpty() {
        let state = OCB2CryptState(key: key, encryptNonce: key, decryptNonce: key)!
        var encrypted = [UInt8]()
        var tag = [UInt8](repeating: 0, count: 16)
        #expect(state.ocbEncrypt(plain: [], encrypted: &encrypted, nonce: [UInt8](key), tag: &tag))
        #expect(
            tag == [
                0xBF, 0x31, 0x08, 0x13, 0x07, 0x73, 0xAD, 0x5E,
                0xC7, 0x0E, 0xC6, 0x9E, 0x78, 0x75, 0xA7, 0xB0,
            ])
    }

    @Test("OCB2 known-answer test: 40-byte message ciphertext and tag")
    func kat40Bytes() {
        let state = OCB2CryptState(key: key, encryptNonce: key, decryptNonce: key)!
        let source = (0..<40).map { UInt8($0) }
        var encrypted = [UInt8](repeating: 0, count: 40)
        var tag = [UInt8](repeating: 0, count: 16)
        #expect(
            state.ocbEncrypt(plain: source, encrypted: &encrypted, nonce: [UInt8](key), tag: &tag))
        #expect(
            tag == [
                0x9D, 0xB0, 0xCD, 0xF8, 0x80, 0xF7, 0x3E, 0x3E,
                0x10, 0xD4, 0xEB, 0x32, 0x17, 0x76, 0x66, 0x88,
            ])
        #expect(
            encrypted == [
                0xF7, 0x5D, 0x6B, 0xC8, 0xB4, 0xDC, 0x8D, 0x66, 0xB8, 0x36,
                0xA2, 0xB0, 0x8B, 0x32, 0xA6, 0x36, 0x9F, 0x1C, 0xD3, 0xC5,
                0x22, 0x8D, 0x79, 0xFD, 0x6C, 0x26, 0x7F, 0x5F, 0x6A, 0xA7,
                0xB2, 0x31, 0xC7, 0xDF, 0xB9, 0xD5, 0x99, 0x51, 0xAE, 0x9C,
            ])
    }

    @Test("ocb encrypt/decrypt round-trips at every length 0..<128")
    func authcryptSweep() {
        for length in 0..<128 {
            let state = makeState()
            let source = (0..<length).map { UInt8(truncatingIfNeeded: $0 + 1) }
            var encrypted = [UInt8](repeating: 0, count: length)
            var encTag = [UInt8](repeating: 0, count: 16)
            var decrypted = [UInt8](repeating: 0, count: length)
            var decTag = [UInt8](repeating: 0, count: 16)

            #expect(
                state.ocbEncrypt(
                    plain: source, encrypted: &encrypted, nonce: [UInt8](nonce), tag: &encTag),
                "length \(length)")
            #expect(
                state.ocbDecrypt(
                    encrypted: encrypted, plain: &decrypted, nonce: [UInt8](nonce), tag: &decTag),
                "length \(length)")
            #expect(encTag == decTag, "length \(length)")
            #expect(decrypted == source, "length \(length)")
        }
    }

    @Test("packet round trip through full CryptState")
    func packetRoundTrip() {
        let alice = makeState()
        let bob = makeState()

        for i in 0..<64 {
            let plain = Data("voice packet \(i)".utf8)
            let wire = alice.encrypt(plain)
            #expect(wire != nil)
            #expect(wire?.count == plain.count + 4)
            let decrypted = bob.decrypt(wire!)
            #expect(decrypted == plain)
        }
        #expect(bob.statistics.good == 64)
        #expect(bob.statistics.lost == 0)
    }

    @Test("tampered ciphertext and tag are rejected, IV restored")
    func tamperRejected() {
        let alice = makeState()
        let bob = makeState()

        var wire = alice.encrypt(Data("hello".utf8))!
        wire[5] ^= 0x01
        #expect(bob.decrypt(wire) == nil)

        // Original packet still decrypts — decrypt IV was restored.
        wire[5] ^= 0x01
        #expect(bob.decrypt(wire) == Data("hello".utf8))
    }

    @Test("replayed packet is rejected")
    func replayRejected() {
        let alice = makeState()
        let bob = makeState()

        let first = alice.encrypt(Data("one".utf8))!
        let second = alice.encrypt(Data("two".utf8))!
        #expect(bob.decrypt(first) != nil)
        #expect(bob.decrypt(second) != nil)
        // Replay of an already-seen packet must fail.
        #expect(bob.decrypt(first) == nil)
    }

    @Test("out-of-order packets within the window decrypt")
    func reordered() {
        let alice = makeState()
        let bob = makeState()

        var packets: [Data] = []
        for i in 0..<8 {
            packets.append(alice.encrypt(Data("packet \(i)".utf8))!)
        }
        // Deliver 0,1, then 3 before 2, then the rest.
        #expect(bob.decrypt(packets[0]) != nil)
        #expect(bob.decrypt(packets[1]) != nil)
        #expect(bob.decrypt(packets[3]) != nil)
        #expect(bob.decrypt(packets[2]) == Data("packet 2".utf8))
        #expect(bob.statistics.late == 1)
        for i in 4..<8 {
            #expect(bob.decrypt(packets[i]) != nil)
        }
    }

    @Test("packet loss is tracked and stream recovers")
    func lossTracked() {
        let alice = makeState()
        let bob = makeState()

        #expect(bob.decrypt(alice.encrypt(Data("a".utf8))!) != nil)
        _ = alice.encrypt(Data("dropped 1".utf8))
        _ = alice.encrypt(Data("dropped 2".utf8))
        #expect(bob.decrypt(alice.encrypt(Data("b".utf8))!) != nil)
        #expect(bob.statistics.lost == 2)
        #expect(bob.statistics.good == 2)
    }

    @Test("IV low-byte wraparound survives 600 packets")
    func wraparound() {
        let alice = makeState()
        let bob = makeState()
        for i in 0..<600 {
            let plain = Data("wrap \(i)".utf8)
            #expect(bob.decrypt(alice.encrypt(plain)!) == plain, "packet \(i)")
        }
    }

    @Test("digital-silence blocks encrypt via bit flip and still round-trip tag-valid")
    func silenceCountermeasure() {
        let alice = makeState()
        let bob = makeState()

        // Two blocks; second-to-last block all zeros triggers the XEX*
        // countermeasure path (flipABit) in ocb_encrypt.
        let silence = Data(repeating: 0, count: 32)
        let wire = alice.encrypt(silence)!
        let decrypted = bob.decrypt(wire)
        // The flipped bit lands in the first byte of the first block.
        #expect(decrypted != nil)
        #expect(decrypted?.count == 32)
        var expected = [UInt8](repeating: 0, count: 32)
        expected[0] = 1
        #expect(decrypted == Data(expected))
    }

    @Test("XEX* forgery attack is detected by decrypt")
    func xexstarAttackDetected() {
        // Port of upstream TestCrypt::xexstarAttack.
        let state = makeState()
        var source = [UInt8](repeating: 0, count: 32)
        source[15] = 16 * 8  // len(secondBlock) in bits
        for i in 16..<32 { source[i] = 42 }

        var encrypted = [UInt8](repeating: 0, count: 32)
        var encTag = [UInt8](repeating: 0, count: 16)
        // With the countermeasure disabled, encrypting the malicious
        // plaintext must be refused.
        #expect(
            !state.ocbEncrypt(
                plain: source, encrypted: &encrypted, nonce: [UInt8](nonce), tag: &encTag,
                modifyPlainOnXEXStarAttack: false))

        // Perform the forgery anyway.
        encrypted[15] ^= 16 * 8
        for i in 0..<16 {
            encTag[i] = source[16 + i] ^ encrypted[16 + i]
        }

        var decrypted = [UInt8](repeating: 0, count: 16)
        var decTag = [UInt8](repeating: 0, count: 16)
        let decryptAccepted = state.ocbDecrypt(
            encrypted: Array(encrypted[0..<16]), plain: &decrypted, nonce: [UInt8](nonce),
            tag: &decTag)

        // The forged tag matches (the attack is real)...
        #expect(encTag == decTag)
        // ...but the countermeasure detects and refuses it.
        #expect(!decryptAccepted)
    }

    @Test("resync updates decrypt IV and counts")
    func resync() {
        let alice = makeState()
        let bob = makeState()

        // Simulate bob missing >256 packets: fully desynced.
        for i in 0..<300 {
            _ = alice.encrypt(Data("lost \(i)".utf8))
        }
        // Resync: alice's current encrypt IV becomes bob's decrypt IV.
        #expect(bob.setDecryptNonce(alice.encryptNonce))
        #expect(bob.statistics.resync == 1)

        let plain = Data("after resync".utf8)
        #expect(bob.decrypt(alice.encrypt(plain)!) == plain)
    }
}
