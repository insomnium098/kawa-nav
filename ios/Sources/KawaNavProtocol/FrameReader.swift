//
//  FrameReader.swift
//
//  Bounds-checked reads from meter frames. Frames are a 5-byte header ([0] type, [1] length - 3,
//  [2] counter, [3..4] echoed request or FF) followed by 10-byte blocks: [marker][block id][8 data
//  bytes], marker 05 for data, FF when the block is absent.
//
//  Ported from KawaNav (Darthbob/kawa-nav), FrameReader.java. Pure, no platform dependency.
//

import Foundation

public enum FrameReader {
    /// Marker byte of a present data block.
    public static let blockMarker: UInt8 = 0x05

    /// Unsigned byte, -1 past the end.
    public static func u8(_ v: [UInt8], _ i: Int) -> Int {
        (i >= 0 && i < v.count) ? Int(v[i]) : -1
    }

    /// Big-endian unsigned 16 bit, -1 past the end.
    public static func be16(_ v: [UInt8], _ i: Int) -> Int {
        guard i >= 0, i + 1 < v.count else { return -1 }
        return Int(v[i]) << 8 | Int(v[i + 1])
    }

    /// Big-endian unsigned 24 bit, -1 past the end.
    public static func be24(_ v: [UInt8], _ i: Int) -> Int {
        guard i >= 0, i + 2 < v.count else { return -1 }
        return Int(v[i]) << 16 | Int(v[i + 1]) << 8 | Int(v[i + 2])
    }

    /// Big-endian unsigned 32 bit, -1 past the end.
    public static func be32(_ v: [UInt8], _ i: Int) -> Int {
        guard i >= 0, i + 3 < v.count else { return -1 }
        return Int(v[i]) << 24 | Int(v[i + 1]) << 16 | Int(v[i + 2]) << 8 | Int(v[i + 3])
    }

    /// The bits of byte `i` under `mask`, shifted down to the low bits; -1 past the end.
    public static func bits(_ v: [UInt8], _ i: Int, _ mask: Int) -> Int {
        let b = u8(v, i)
        guard b >= 0 else { return -1 }
        // numberOfTrailingZeros on a positive mask == index of its low bit
        let tz = mask.nonzeroBitCount == 0 ? 0 : mask.trailingZeroBitCount
        return (b & mask) >> tz
    }

    /// The block starting at `offset` (5, 15, 25…) is present: its marker is 05.
    public static func blockPresent(_ v: [UInt8], _ offset: Int) -> Bool {
        u8(v, offset) == Int(blockMarker)
    }

    /// Block id of the block at `offset`, -1 if absent.
    public static func blockId(_ v: [UInt8], _ offset: Int) -> Int {
        blockPresent(v, offset) ? u8(v, offset + 1) : -1
    }

    /// All bytes from `from` to `to` (exclusive) are FF, or past the end.
    public static func allFF(_ v: [UInt8], _ from: Int, _ to: Int) -> Bool {
        for i in from..<min(to, v.count) {
            if v[i] != 0xFF { return false }
        }
        return true
    }

    /// Start (marker index) of the 10-byte block holding byte `i`.
    public static func blockOf(_ i: Int) -> Int {
        i < 5 ? -1 : 5 + (i - 5) / 10 * 10
    }

    /// Byte `i` lies in a present block.
    public static func inPresentBlock(_ v: [UInt8], _ i: Int) -> Bool {
        i < v.count && blockPresent(v, blockOf(i))
    }

    /// UTF-8 text of the `05 <n> <8 bytes>` chunks from byte 5 on, in chunk order; zero/FF padding dropped.
    public static func textChunks(_ v: [UInt8]) -> String {
        var out = Data()
        var i = 5
        while i + 1 < v.count {
            if v[i] != blockMarker { i += 10; continue }
            for k in (i + 2)..<min(i + 10, v.count) {
                let b = v[k]
                if b != 0 && b != 0xFF { out.append(b) }
            }
            i += 10
        }
        return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
