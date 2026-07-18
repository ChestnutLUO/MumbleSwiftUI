import CommonCrypto
import Foundation

/// OCB2-AES128 for Mumble's UDP voice channel — a faithful port of upstream
/// `CryptStateOCB2.cpp` (BSD-licensed, The Mumble Developers), including the
/// counter-cryptanalysis for the XEX* forgery attack described in section 9
/// of https://eprint.iacr.org/2019/311.
///
/// Wire format: `[1 byte: low byte of encrypt IV][3 bytes: truncated tag][ciphertext]`.
/// The IV is a 128-bit little-endian counter incremented once per packet.
///
/// Not thread-safe: confine each instance to one actor or queue.
public final class OCB2CryptState {
    public static let keySize = 16
    public static let blockSize = 16

    public struct Statistics: Equatable, Sendable {
        public var good: UInt32 = 0
        public var late: UInt32 = 0
        public var lost: UInt32 = 0
        public var resync: UInt32 = 0
    }

    private var rawKey: [UInt8]
    private var encryptIV: [UInt8]
    private var decryptIV: [UInt8]
    private var decryptHistory = [UInt8](repeating: 0, count: 0x100)

    public private(set) var statistics = Statistics()

    /// Key and both nonces as delivered in the server's `CryptSetup`:
    /// its `client_nonce` is our encrypt IV, `server_nonce` our decrypt IV.
    public init?(key: Data, encryptNonce: Data, decryptNonce: Data) {
        guard key.count == Self.keySize,
            encryptNonce.count == Self.blockSize,
            decryptNonce.count == Self.blockSize
        else { return nil }
        rawKey = [UInt8](key)
        encryptIV = [UInt8](encryptNonce)
        decryptIV = [UInt8](decryptNonce)
    }

    /// Our current encrypt IV — sent as `client_nonce` when the server
    /// requests a resync.
    public var encryptNonce: Data { Data(encryptIV) }

    /// Applies the server's current encrypt IV (`server_nonce` from a
    /// resync `CryptSetup`) as our decrypt IV.
    public func setDecryptNonce(_ nonce: Data) -> Bool {
        guard nonce.count == Self.blockSize else { return false }
        decryptIV = [UInt8](nonce)
        statistics.resync += 1
        return true
    }

    // MARK: - Packet API

    /// Encrypts one datagram payload; returns `4 + plain.count` wire bytes.
    public func encrypt(_ plain: Data) -> Data? {
        // First, increase our IV.
        for i in 0..<Self.blockSize {
            encryptIV[i] &+= 1
            if encryptIV[i] != 0 { break }
        }

        let source = [UInt8](plain)
        var encrypted = [UInt8](repeating: 0, count: source.count)
        var tag = [UInt8](repeating: 0, count: Self.blockSize)
        guard ocbEncrypt(plain: source, encrypted: &encrypted, nonce: encryptIV, tag: &tag)
        else { return nil }

        var out = Data(capacity: 4 + source.count)
        out.append(encryptIV[0])
        out.append(tag[0])
        out.append(tag[1])
        out.append(tag[2])
        out.append(contentsOf: encrypted)
        return out
    }

    /// Decrypts one received datagram; returns the plaintext, or nil for
    /// invalid, replayed, or too-old packets (IV state is restored).
    public func decrypt(_ crypted: Data) -> Data? {
        guard crypted.count >= 4 else { return nil }
        let source = [UInt8](crypted)
        let plainLength = source.count - 4

        let saveIV = decryptIV
        let ivByte = source[0]
        var restore = false

        var lost = 0
        var late = 0

        if ((decryptIV[0] &+ 1) & 0xFF) == ivByte {
            // In order as expected.
            if ivByte > decryptIV[0] {
                decryptIV[0] = ivByte
            } else if ivByte < decryptIV[0] {
                decryptIV[0] = ivByte
                incrementHighBytes(&decryptIV)
            } else {
                return nil
            }
        } else {
            // This is either out of order or a repeat.
            var diff = Int(ivByte) - Int(decryptIV[0])
            if diff > 128 {
                diff -= 256
            } else if diff < -128 {
                diff += 256
            }

            if ivByte < decryptIV[0] && diff > -30 && diff < 0 {
                // Late packet, but no wraparound.
                late = 1
                lost = -1
                decryptIV[0] = ivByte
                restore = true
            } else if ivByte > decryptIV[0] && diff > -30 && diff < 0 {
                // Last was 0x02, here comes 0xff from last round.
                late = 1
                lost = -1
                decryptIV[0] = ivByte
                decrementHighBytes(&decryptIV)
                restore = true
            } else if ivByte > decryptIV[0] && diff > 0 {
                // Lost a few packets, but beyond that we're good.
                lost = Int(ivByte) - Int(decryptIV[0]) - 1
                decryptIV[0] = ivByte
            } else if ivByte < decryptIV[0] && diff > 0 {
                // Lost a few packets, and wrapped around.
                lost = 256 - Int(decryptIV[0]) + Int(ivByte) - 1
                decryptIV[0] = ivByte
                incrementHighBytes(&decryptIV)
            } else {
                return nil
            }

            if decryptHistory[Int(decryptIV[0])] == decryptIV[1] {
                decryptIV = saveIV
                return nil
            }
        }

        var plain = [UInt8](repeating: 0, count: plainLength)
        var tag = [UInt8](repeating: 0, count: Self.blockSize)
        let ocbSuccess = ocbDecrypt(
            encrypted: Array(source[4...]), plain: &plain, nonce: decryptIV, tag: &tag)

        guard ocbSuccess, tag[0] == source[1], tag[1] == source[2], tag[2] == source[3] else {
            decryptIV = saveIV
            return nil
        }
        decryptHistory[Int(decryptIV[0])] = decryptIV[1]

        if restore {
            decryptIV = saveIV
        }

        statistics.good &+= 1
        applySaturating(&statistics.late, delta: late)
        applySaturating(&statistics.lost, delta: lost)

        return Data(plain)
    }

    // MARK: - OCB2 core

    func ocbEncrypt(
        plain: [UInt8],
        encrypted: inout [UInt8],
        nonce: [UInt8],
        tag: inout [UInt8],
        modifyPlainOnXEXStarAttack: Bool = true
    ) -> Bool {
        var success = true
        var delta = aesEncrypt(nonce)
        var checksum = [UInt8](repeating: 0, count: Self.blockSize)
        var offset = 0
        var len = plain.count

        while len > Self.blockSize {
            // Counter-cryptanalysis (eprint 2019/311 §9): an attack needs the
            // second-to-last block to be all zero except its last byte.
            var flipABit = false
            if len - Self.blockSize <= Self.blockSize {
                var sum: UInt8 = 0
                for i in 0..<(Self.blockSize - 1) {
                    sum |= plain[offset + i]
                }
                if sum == 0 {
                    if modifyPlainOnXEXStarAttack {
                        // Digital silence in Opus produces such blocks; flip a
                        // bit (inaudible) instead of dropping the packet.
                        flipABit = true
                    } else {
                        // Only used by tests to exercise decrypt's detection.
                        success = false
                    }
                }
            }

            times2(&delta)
            var tmp = xorBlock(delta, plain, offset)
            if flipABit { tmp[0] ^= 1 }
            tmp = aesEncrypt(tmp)
            for i in 0..<Self.blockSize {
                encrypted[offset + i] = delta[i] ^ tmp[i]
                checksum[i] ^= plain[offset + i]
            }
            if flipABit { checksum[0] ^= 1 }

            len -= Self.blockSize
            offset += Self.blockSize
        }

        times2(&delta)
        var tmp = [UInt8](repeating: 0, count: Self.blockSize)
        tmp[Self.blockSize - 1] = UInt8(truncatingIfNeeded: len &* 8)
        for i in 0..<Self.blockSize { tmp[i] ^= delta[i] }
        let pad = aesEncrypt(tmp)
        for i in 0..<len { tmp[i] = plain[offset + i] }
        for i in len..<Self.blockSize { tmp[i] = pad[i] }
        for i in 0..<Self.blockSize { checksum[i] ^= tmp[i] }
        for i in 0..<Self.blockSize { tmp[i] ^= pad[i] }
        for i in 0..<len { encrypted[offset + i] = tmp[i] }

        times3(&delta)
        for i in 0..<Self.blockSize { tmp[i] = delta[i] ^ checksum[i] }
        tag = aesEncrypt(tmp)

        return success
    }

    func ocbDecrypt(
        encrypted: [UInt8],
        plain: inout [UInt8],
        nonce: [UInt8],
        tag: inout [UInt8]
    ) -> Bool {
        var success = true
        var delta = aesEncrypt(nonce)
        var checksum = [UInt8](repeating: 0, count: Self.blockSize)
        var offset = 0
        var len = encrypted.count

        while len > Self.blockSize {
            times2(&delta)
            var tmp = xorBlock(delta, encrypted, offset)
            tmp = aesDecrypt(tmp)
            for i in 0..<Self.blockSize {
                plain[offset + i] = delta[i] ^ tmp[i]
                checksum[i] ^= plain[offset + i]
            }
            len -= Self.blockSize
            offset += Self.blockSize
        }

        times2(&delta)
        var tmp = [UInt8](repeating: 0, count: Self.blockSize)
        tmp[Self.blockSize - 1] = UInt8(truncatingIfNeeded: len &* 8)
        for i in 0..<Self.blockSize { tmp[i] ^= delta[i] }
        let pad = aesEncrypt(tmp)
        tmp = [UInt8](repeating: 0, count: Self.blockSize)
        for i in 0..<len { tmp[i] = encrypted[offset + i] }
        for i in 0..<Self.blockSize { tmp[i] ^= pad[i] }
        for i in 0..<Self.blockSize { checksum[i] ^= tmp[i] }
        for i in 0..<len { plain[offset + i] = tmp[i] }

        // Counter-cryptanalysis (eprint 2019/311 §9): in an attack the
        // decrypted last block equals `delta ^ len(128)`; len only affects
        // the final byte, so compare all the others.
        if tmp[0..<(Self.blockSize - 1)] == delta[0..<(Self.blockSize - 1)] {
            success = false
        }

        times3(&delta)
        for i in 0..<Self.blockSize { tmp[i] = delta[i] ^ checksum[i] }
        tag = aesEncrypt(tmp)

        return success
    }

    // MARK: - Primitives

    /// Multiplication by 2 in GF(2^128) on a big-endian block.
    private func times2(_ block: inout [UInt8]) {
        let carry = block[0] >> 7
        for i in 0..<(Self.blockSize - 1) {
            block[i] = (block[i] << 1) | (block[i + 1] >> 7)
        }
        block[Self.blockSize - 1] = (block[Self.blockSize - 1] << 1) ^ (carry &* 0x87)
    }

    /// Multiplication by 3: `x ^ times2(x)`.
    private func times3(_ block: inout [UInt8]) {
        var doubled = block
        times2(&doubled)
        for i in 0..<Self.blockSize {
            block[i] ^= doubled[i]
        }
    }

    private func xorBlock(_ a: [UInt8], _ b: [UInt8], _ bOffset: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.blockSize)
        for i in 0..<Self.blockSize {
            out[i] = a[i] ^ b[bOffset + i]
        }
        return out
    }

    private func aesEncrypt(_ block: [UInt8]) -> [UInt8] {
        aesTransform(block, operation: CCOperation(kCCEncrypt))
    }

    private func aesDecrypt(_ block: [UInt8]) -> [UInt8] {
        aesTransform(block, operation: CCOperation(kCCDecrypt))
    }

    private func aesTransform(_ block: [UInt8], operation: CCOperation) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.blockSize)
        var moved = 0
        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            rawKey, rawKey.count,
            nil,
            block, block.count,
            &out, out.count,
            &moved
        )
        precondition(
            status == kCCSuccess && moved == Self.blockSize,
            "single-block AES-ECB cannot fail with valid key/block sizes")
        return out
    }

    private func incrementHighBytes(_ iv: inout [UInt8]) {
        for i in 1..<Self.blockSize {
            iv[i] &+= 1
            if iv[i] != 0 { break }
        }
    }

    private func decrementHighBytes(_ iv: inout [UInt8]) {
        for i in 1..<Self.blockSize {
            let old = iv[i]
            iv[i] &-= 1
            if old != 0 { break }
        }
    }

    private func applySaturating(_ counter: inout UInt32, delta: Int) {
        if delta > 0 {
            counter &+= UInt32(delta)
        } else if Int(counter) > abs(delta) {
            counter -= UInt32(abs(delta))
        }
    }
}
