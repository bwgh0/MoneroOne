import Foundation

/// GF(2^255 - 19) field arithmetic and Elligator2 for CPace.
/// Uses 8 × UInt32 limbs (little-endian).
enum Curve25519Field {

    // p = 2^255 - 19
    static let p: [UInt32] = [
        0xFFFFFFED, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
        0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    ]

    // sqrt(-1) mod p
    static let sqrtM1: [UInt32] = [
        0x4A0EA0B0, 0xC4EE1B27, 0xAD2FE478, 0x2F431806,
        0x3DFBD7A7, 0x2B4D0099, 0x4FC1DF0B, 0x2B832480
    ]

    // c4 = (p - 5) / 8 = 2^252 - 3
    static let c4: [UInt32] = [
        0xFFFFFFFD, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
        0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x0FFFFFFF
    ]

    static let zero: [UInt32] = [0, 0, 0, 0, 0, 0, 0, 0]
    static let one: [UInt32] = [1, 0, 0, 0, 0, 0, 0, 0]

    // MARK: - Encoding

    static func decode(_ data: Data) -> [UInt32] {
        var limbs = [UInt32](repeating: 0, count: 8)
        let bytes = [UInt8](data)
        for i in 0..<8 {
            let o = i * 4
            if o + 3 < bytes.count {
                limbs[i] = UInt32(bytes[o])
                    | (UInt32(bytes[o+1]) << 8)
                    | (UInt32(bytes[o+2]) << 16)
                    | (UInt32(bytes[o+3]) << 24)
            } else {
                for j in 0..<min(4, bytes.count - o) {
                    limbs[i] |= UInt32(bytes[o+j]) << (j * 8)
                }
            }
        }
        return limbs
    }

    static func encode(_ limbs: [UInt32]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            let o = i * 4
            bytes[o]   = UInt8(limbs[i] & 0xFF)
            bytes[o+1] = UInt8((limbs[i] >> 8) & 0xFF)
            bytes[o+2] = UInt8((limbs[i] >> 16) & 0xFF)
            bytes[o+3] = UInt8((limbs[i] >> 24) & 0xFF)
        }
        return Data(bytes)
    }

    // MARK: - Arithmetic

    /// a + b mod p
    static func add(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var r = [UInt32](repeating: 0, count: 8)
        var carry: UInt64 = 0
        for i in 0..<8 {
            carry += UInt64(a[i]) + UInt64(b[i])
            r[i] = UInt32(carry & 0xFFFFFFFF)
            carry >>= 32
        }
        if carry != 0 || gte(r, p) {
            r = subNoMod(r, p)
        }
        return r
    }

    /// a - b mod p
    static func sub(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var r = [UInt32](repeating: 0, count: 8)
        var borrow: Int64 = 0
        for i in 0..<8 {
            let diff = Int64(a[i]) - Int64(b[i]) - borrow
            if diff < 0 {
                r[i] = UInt32(truncatingIfNeeded: diff &+ 0x1_0000_0000)
                borrow = 1
            } else {
                r[i] = UInt32(diff)
                borrow = 0
            }
        }
        if borrow != 0 {
            var carry: UInt64 = 0
            for i in 0..<8 {
                carry += UInt64(r[i]) + UInt64(p[i])
                r[i] = UInt32(carry & 0xFFFFFFFF)
                carry >>= 32
            }
        }
        return r
    }

    /// a * b mod p
    static func mul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var r = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 {
            var carry: UInt64 = 0
            for j in 0..<8 {
                let prod = UInt64(a[i]) * UInt64(b[j]) + UInt64(r[i+j]) + carry
                r[i+j] = UInt32(prod & 0xFFFFFFFF)
                carry = prod >> 32
            }
            r[i+8] = UInt32(carry)
        }
        return reduce16(r)
    }

    /// a^2 mod p
    static func square(_ a: [UInt32]) -> [UInt32] {
        return mul(a, a)
    }

    /// p - a mod p
    static func negate(_ a: [UInt32]) -> [UInt32] {
        if isZero(a) { return a }
        return subNoMod(p, a)
    }

    /// a^exp mod p
    static func pow(_ base: [UInt32], _ exp: [UInt32]) -> [UInt32] {
        var result = one
        var b = base
        for i in 0..<8 {
            var word = exp[i]
            for _ in 0..<32 {
                if word & 1 == 1 {
                    result = mul(result, b)
                }
                b = square(b)
                word >>= 1
            }
        }
        return result
    }

    /// a^(p-2) mod p (modular inverse)
    static func inverse(_ a: [UInt32]) -> [UInt32] {
        let pMinus2 = subNoMod(p, [2, 0, 0, 0, 0, 0, 0, 0])
        return pow(a, pMinus2)
    }

    static func eq(_ a: [UInt32], _ b: [UInt32]) -> Bool { a == b }
    static func isZero(_ a: [UInt32]) -> Bool { a.allSatisfy { $0 == 0 } }

    // MARK: - Reduction

    /// Reduce 16-limb product mod p using 2^256 ≡ 38 (mod p)
    private static func reduce16(_ r: [UInt32]) -> [UInt32] {
        var low = Array(r[0..<8])
        let high = Array(r[8..<16])

        var carry: UInt64 = 0
        for i in 0..<8 {
            carry += UInt64(low[i]) + UInt64(high[i]) * 38
            low[i] = UInt32(carry & 0xFFFFFFFF)
            carry >>= 32
        }

        while carry > 0 {
            var c2: UInt64 = carry * 38
            for i in 0..<8 {
                c2 += UInt64(low[i])
                low[i] = UInt32(c2 & 0xFFFFFFFF)
                c2 >>= 32
            }
            carry = c2
        }

        if gte(low, p) { low = subNoMod(low, p) }
        return low
    }

    // MARK: - Helpers

    private static func gte(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: 7, through: 0, by: -1) {
            if a[i] > b[i] { return true }
            if a[i] < b[i] { return false }
        }
        return true
    }

    private static func subNoMod(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var r = [UInt32](repeating: 0, count: 8)
        var borrow: Int64 = 0
        for i in 0..<8 {
            let diff = Int64(a[i]) - Int64(b[i]) - borrow
            if diff < 0 {
                r[i] = UInt32(truncatingIfNeeded: diff &+ 0x1_0000_0000)
                borrow = 1
            } else {
                r[i] = UInt32(diff)
                borrow = 0
            }
        }
        return r
    }

    private static func fromUInt32(_ v: UInt32) -> [UInt32] {
        [v, 0, 0, 0, 0, 0, 0, 0]
    }

    // MARK: - Elligator2

    /// Map 32-byte hash to Curve25519 u-coordinate via RFC 9380 Elligator2.
    static func elligator2(_ input: Data) -> Data {
        var inputBytes = [UInt8](input.prefix(32))
        while inputBytes.count < 32 { inputBytes.append(0) }
        inputBytes[31] &= 0x7F  // decodeUCoordinate: clear top bit

        let u = decode(Data(inputBytes))
        let j = fromUInt32(486662)
        let c3 = sqrtM1

        var tv1 = square(u)
        tv1 = add(tv1, tv1)
        let xd = add(tv1, one)
        let x1n = negate(j)
        var tv2 = square(xd)
        let gxd = mul(tv2, xd)
        var gx1 = mul(j, tv1)
        gx1 = mul(gx1, x1n)
        gx1 = add(gx1, tv2)
        gx1 = mul(gx1, x1n)
        var tv3 = square(gxd)
        tv2 = square(tv3)
        tv3 = mul(tv3, gxd)
        tv3 = mul(tv3, gx1)
        tv2 = mul(tv2, tv3)
        var y11 = pow(tv2, c4)
        y11 = mul(y11, tv3)
        let y12 = mul(y11, c3)
        tv2 = square(y11)
        tv2 = mul(tv2, gxd)
        let e1 = eq(tv2, gx1)
        let y1 = e1 ? y11 : y12
        let x2n = mul(x1n, tv1)
        tv2 = square(y1)
        tv2 = mul(tv2, gxd)
        let e3 = eq(tv2, gx1)
        let xn = e3 ? x1n : x2n
        let x = mul(xn, inverse(xd))

        return encode(x)
    }
}
