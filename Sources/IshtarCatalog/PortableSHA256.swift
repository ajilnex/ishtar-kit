import Foundation

/// SHA-256 (FIPS 180-4) en Swift pur, pour les systèmes sans CryptoKit — l'outil
/// `ishtar` du serveur, sous Linux (WP-34). Même usage que `CryptoKit.SHA256` :
/// `update(data:)` par blocs, puis `finalize()` ; ou `hash(data:)` d'un coup.
///
/// Sur macOS, CryptoKit reste le seul moteur des empreintes (invariant n° 3) :
/// ce type n'y sert qu'aux tests, qui le comparent à CryptoKit octet pour octet.
public struct PortableSHA256: Sendable {
    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    /// Octets en attente d'un bloc complet (moins de 64).
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() { buffer.reserveCapacity(64) }

    public mutating func update(data: Data) {
        data.withUnsafeBytes { update(bytes: $0) }
    }

    public mutating func update(bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        var index = 0
        // Compléter d'abord le bloc entamé.
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[0 ..< take])
            index = take
            if buffer.count == 64 {
                buffer.withUnsafeBytes { Self.compress(&state, $0.baseAddress!) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        // Puis les blocs entiers, sans copie.
        while bytes.count - index >= 64 {
            Self.compress(&state, bytes.baseAddress! + index)
            index += 64
        }
        if index < bytes.count { buffer.append(contentsOf: bytes[index...]) }
    }

    /// L'empreinte (32 octets). Le hacheur n'est pas modifié.
    public func finalize() -> [UInt8] {
        var copy = self
        let bits = length &* 8
        var tail: [UInt8] = [0x80]
        let padding = (copy.buffer.count + 1 + 8) % 64
        tail += [UInt8](repeating: 0, count: padding == 0 ? 0 : 64 - padding)
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        tail.withUnsafeBytes { raw in
            // `update` compterait ces octets dans la longueur : on les injecte à la main.
            var all = copy.buffer
            all.append(contentsOf: raw)
            all.withUnsafeBytes { block in
                var offset = 0
                while offset < block.count {
                    Self.compress(&copy.state, block.baseAddress! + offset)
                    offset += 64
                }
            }
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in copy.state {
            digest += [UInt8(word >> 24), UInt8(truncatingIfNeeded: word >> 16),
                       UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
        return digest
    }

    public static func hash(data: Data) -> [UInt8] {
        var hasher = PortableSHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    /// Un bloc de 64 octets. Le tableau de travail vit sur la pile : les gros
    /// fichiers comptent des millions de blocs.
    private static func compress(_ h: inout [UInt32], _ p: UnsafeRawPointer) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            compress(&h, p, w)
        }
    }

    private static func compress(_ h: inout [UInt32], _ p: UnsafeRawPointer, _ w: UnsafeMutableBufferPointer<UInt32>) {
        for i in 0 ..< 16 {
            let b = p.advanced(by: i * 4)
            w[i] = UInt32(b.load(as: UInt8.self)) << 24 | UInt32(b.load(fromByteOffset: 1, as: UInt8.self)) << 16
                | UInt32(b.load(fromByteOffset: 2, as: UInt8.self)) << 8 | UInt32(b.load(fromByteOffset: 3, as: UInt8.self))
        }
        for i in 16 ..< 64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0 ..< 64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
}
