import Foundation

/// SHA-256 and HMAC-SHA-256 in plain Swift.
///
/// CryptoKit would be the right call in an app target. It is not available on Linux,
/// where this package's core is compiled and tested in CI, and vendoring the primitive
/// keeps the sidecar contract verifiable against published NIST and RFC 4231 vectors on
/// every platform rather than only on Apple ones. The implementation is the textbook
/// FIPS 180-4 construction; the tests are the point.
public enum Digest {

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static let blockLength = 64
    public static let digestLength = 32

    public static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]

        var padded = message
        padded.append(0x80)
        while padded.count % blockLength != 56 {
            padded.append(0)
        }
        // Bit length. `message.count` is bounded by addressable memory, so multiplying
        // by 8 in `UInt64` cannot overflow on any platform this ships to; the
        // saturating helper documents the assumption rather than relying on it.
        let bitLength = UInt64(message.count).multipliedReportingOverflow(by: 8)
        let lengthValue = bitLength.overflow ? UInt64.max : bitLength.partialValue
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: lengthValue >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset + blockLength <= padded.count {
            for i in 0..<16 {
                let base = offset + i * 4
                w[i] = (UInt32(padded[base]) << 24)
                    | (UInt32(padded[base + 1]) << 16)
                    | (UInt32(padded[base + 2]) << 8)
                    | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            offset += blockLength
        }

        var output = [UInt8]()
        output.reserveCapacity(digestLength)
        for value in h {
            output.append(UInt8(truncatingIfNeeded: value >> 24))
            output.append(UInt8(truncatingIfNeeded: value >> 16))
            output.append(UInt8(truncatingIfNeeded: value >> 8))
            output.append(UInt8(truncatingIfNeeded: value))
        }
        return output
    }

    public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var normalisedKey = key.count > blockLength ? sha256(key) : key
        if normalisedKey.count < blockLength {
            normalisedKey.append(contentsOf: [UInt8](repeating: 0, count: blockLength - normalisedKey.count))
        }

        var inner = [UInt8](repeating: 0, count: blockLength)
        var outer = [UInt8](repeating: 0, count: blockLength)
        for index in 0..<blockLength {
            inner[index] = normalisedKey[index] ^ 0x36
            outer[index] = normalisedKey[index] ^ 0x5c
        }

        let innerDigest = sha256(inner + message)
        return sha256(outer + innerDigest)
    }

    /// Value-independent comparison for equal-length inputs. Length is compared first and
    /// is deliberately *not* hidden — a caller that leaks it has already leaked the digest
    /// size, which is public. What this does hide is *where* two equal-length inputs
    /// diverge: a plain `==` on `[UInt8]` short-circuits on the first differing byte,
    /// leaking the length of a correct prefix to anyone who can time it.
    public static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func bytes(fromHex hex: String) -> [UInt8]? {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let value = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            output.append(value)
            index += 2
        }
        return output
    }

    @inline(__always)
    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
