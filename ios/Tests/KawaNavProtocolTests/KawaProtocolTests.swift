//
//  KawaProtocolTests.swift
//
//  Unit tests for the pure protocol layer. They pin the port to the frames documented in
//  docs/PROTOCOL.md (real captures from a Z900), so a regression in the decode logic is caught
//  here. Run with: swift test   (from the ios/ directory, on macOS or Linux).
//

import XCTest
@testable import KawaNavProtocol

final class FrameReaderTests: XCTestCase {
    func testU8AndBounds() {
        let v: [UInt8] = [0x12, 0xFF, 0x00, 0x80]
        XCTAssertEqual(FrameReader.u8(v, 0), 0x12)
        XCTAssertEqual(FrameReader.u8(v, 1), 0xFF)
        XCTAssertEqual(FrameReader.u8(v, 3), 0x80)
        XCTAssertEqual(FrameReader.u8(v, 4), -1)   // past the end
        XCTAssertEqual(FrameReader.u8(v, -1), -1)
    }

    func testBe16Be24Be32() {
        let v: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9A]
        XCTAssertEqual(FrameReader.be16(v, 0), 0x1234)
        XCTAssertEqual(FrameReader.be24(v, 0), 0x123456)
        XCTAssertEqual(FrameReader.be32(v, 1), 0x3456789A)
        XCTAssertEqual(FrameReader.be16(v, 4), -1)   // past the end
    }

    func testBits() {
        let v: [UInt8] = [0b10110100]
        XCTAssertEqual(FrameReader.bits(v, 0, 0xC0), 0b10)   // bits 7-6
        XCTAssertEqual(FrameReader.bits(v, 0, 0x30), 0b11)   // bits 5-4
        XCTAssertEqual(FrameReader.bits(v, 0, 0x0C), 0b01)   // bits 3-2
        XCTAssertEqual(FrameReader.bits(v, 0, 0x03), 0b00)   // bits 1-0
    }

    func testBlockPresentAndInPresentBlock() {
        // block at offset 5: marker 05, id 70, 8 data bytes
        let v: [UInt8] = [0x14, 0x08, 0, 0xFF, 0xFF, 0x05, 0x70, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        XCTAssertTrue(FrameReader.blockPresent(v, 5))
        XCTAssertEqual(FrameReader.blockId(v, 5), 0x70)
        XCTAssertTrue(FrameReader.inPresentBlock(v, 7))
        // absent block (marker FF)
        let v2: [UInt8] = [0x14, 0x08, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertFalse(FrameReader.blockPresent(v2, 5))
        XCTAssertFalse(FrameReader.inPresentBlock(v2, 7))
    }

    func testTextChunks() {
        // 05 01 "ABC\0\0\0\0\0" then 05 02 "DE\0\0\0\0\0\0"
        var v: [UInt8] = [0, 0, 0, 0xFF, 0xFF]
        v += [0x05, 0x01, 0x41, 0x42, 0x43, 0, 0, 0, 0, 0]
        v += [0x05, 0x02, 0x44, 0x45, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(FrameReader.textChunks(v), "ABCDE")
    }
}

final class KawaProtocolTests: XCTestCase {
    func testNaviFrameRightIn250m() {
        // From docs/PROTOCOL.md: "right in 250 m" (35 bytes, 10 of padding after the distance block)
        let frame = KawaProtocol.naviFrame(flag: 0, turn: 2, unit: 1, distance: 250)
        XCTAssertEqual(KawaProtocol.hex(frame),
            "14 08 00 FF FF 05 70 00 FF FF FF FF FF 10 FF 05 71 02 00 00 FA FF FF FF FF FF FF FF FF FF FF FF FF FF FF")
    }

    func testNaviFrameLeftIn80m() {
        // "left in 80 m" (35 bytes)
        let frame = KawaProtocol.naviFrame(flag: 0, turn: 1, unit: 1, distance: 80)
        XCTAssertEqual(KawaProtocol.hex(frame),
            "14 08 00 FF FF 05 70 00 FF FF FF FF FF 10 FF 05 71 01 00 00 50 FF FF FF FF FF FF FF FF FF FF FF FF FF FF")
    }

    func testNaviFrameRoundaboutExit2() {
        // "roundabout exit 2 400m" (35 bytes)
        let frame = KawaProtocol.naviFrame(flag: 0, turn: 31, unit: 1, distance: 400)
        XCTAssertEqual(KawaProtocol.hex(frame),
            "14 08 00 FF FF 05 70 00 FF FF FF FF FF 10 FF 05 71 1F 00 01 90 FF FF FF FF FF FF FF FF FF FF FF FF FF FF")
    }

    func testClearFrame() {
        // "clear / no navigation" (35 bytes)
        let frame = KawaProtocol.clearFrame()
        XCTAssertEqual(KawaProtocol.hex(frame),
            "14 08 00 FF FF 05 70 30 FF FF FF FF FF F0 FF 05 71 FF 00 00 00 FF FF FF FF FF FF FF FF FF FF FF FF FF FF")
    }

    func testMeterIndicationFrame() {
        // battery=3 (full), voice=0, headset=1 (on), ridingLog=1 (recording)
        let frame = KawaProtocol.meterIndicationFrame(battery: 3, voice: 0, headset: 1, ridingLog: 1)
        XCTAssertEqual(frame.count, 15)
        XCTAssertEqual(frame[0], 19)   // 0x13
        XCTAssertEqual(frame[1], 12)   // 0x0C
        XCTAssertEqual(frame[7], 0x30) // (3<<4)|0
        XCTAssertEqual(frame[8], 0x11) // (1<<4)|1
    }

    func testBatteryLevel() {
        XCTAssertEqual(KawaProtocol.batteryLevel(5), 0)
        XCTAssertEqual(KawaProtocol.batteryLevel(10), 0)
        XCTAssertEqual(KawaProtocol.batteryLevel(20), 1)
        XCTAssertEqual(KawaProtocol.batteryLevel(50), 2)
        XCTAssertEqual(KawaProtocol.batteryLevel(90), 3)
        XCTAssertEqual(KawaProtocol.batteryLevel(-1), KawaProtocol.batteryNone)
        XCTAssertEqual(KawaProtocol.batteryLevel(50, charging: true), 9)   // 7 + 2
    }

    func testPhoneNameFrame() {
        // "iPhone" = 6 chars
        let frame = KawaProtocol.phoneNameFrame("iPhone")
        XCTAssertEqual(frame.count, 35)
        XCTAssertEqual(frame[0], 11)
        XCTAssertEqual(frame[1], 32)
        XCTAssertEqual(frame[5], 5)
        XCTAssertEqual(frame[6], 1)
        // first part bytes 7..12 = "iPhone" (P is uppercase, 0x50)
        XCTAssertEqual(Array(frame[7...12]), [0x69, 0x50, 0x68, 0x6F, 0x6E, 0x65])
    }

    func testStartupSequenceReadOnly() {
        let frames = KawaProtocol.startup(level: KawaProtocol.initRead, phoneModel: "Test", askExt: true)
        // Order: 03, 40, 1A, 1D, 47, 0B, 41, 1B, 48, 1E, 45  (no 08 in read-only level)
        let ids = frames.map { Int($0[0]) }
        XCTAssertEqual(ids, [0x03, 0x40, 0x1A, 0x1D, 0x47, 0x0B, 0x41, 0x1B, 0x48, 0x1E, 0x45])
    }

    func testStartupSequenceFull() {
        let frames = KawaProtocol.startup(level: KawaProtocol.initFull, phoneModel: "Test", askExt: true)
        let ids = frames.map { Int($0[0]) }
        // Full adds the 0x08 meter init before the 0x45 riding-log request.
        XCTAssertEqual(ids, [0x03, 0x40, 0x1A, 0x1D, 0x47, 0x0B, 0x41, 0x1B, 0x48, 0x1E, 0x08, 0x45])
    }

    func testHexRoundTrip() {
        let bytes = KawaProtocol.parseHex("14 08 00 ff")!
        XCTAssertEqual(bytes, [0x14, 0x08, 0x00, 0xFF])
        XCTAssertNil(KawaProtocol.parseHex("123"))   // odd length
        XCTAssertNil(KawaProtocol.parseHex("zz"))
    }
}

final class DecoderTests: XCTestCase {
    let dec = Decoder()

    func testAck() {
        // ACK: 20 06 xx 40 00 ...  (request 0x40, result 0)
        let f = dec.decode([0x20, 0x06, 0, 0x40, 0, 0, 0]) as? Ack
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.cmd, 0x40)
        XCTAssertTrue(f?.accepted() ?? false)
    }

    func testModelInfoVin() {
        // 03 20 00 FF FF 02 71 "ML5ER500" 02 72 "FADA5555" 02 73 "8\0..."
        var v: [UInt8] = [0x03, 0x20, 0, 0xFF, 0xFF]
        v += [0x02, 0x71] + Array("ML5ER500".utf8)
        v += [0x02, 0x72] + Array("FADA5555".utf8)
        v += [0x02, 0x73] + Array("8".utf8) + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let f = dec.decode(v) as? ModelInfo
        XCTAssertEqual(f?.model, "ML5ER500")
        XCTAssertEqual(f?.vin, "ML5ER500FADA55558")
    }

    func testGeneralCaps() {
        // 0x1A: build a frame with turn-by-turn supported (navi nibble != 15).
        var v = [UInt8](repeating: 0xFF, count: 15)
        v[0] = 0x1A; v[1] = 12
        v[7] = 0x00            // clock gate 0, shift-lamp mode 0
        v[12] = 0x00           // navi nibble 0 => turn-by-turn supported
        v[13] = 0x00           // indicator subcaps 0
        let f = dec.decode(v) as? GeneralCaps
        XCTAssertTrue(f?.turnByTurn ?? false)
        XCTAssertTrue(f?.statusIcons ?? false)
    }

    func testInfoConfigGatesTelemetry() {
        // 0x40 config: wheel speed nibble (byte 9, bits 3-2) = 0 => mode 0.
        var v = [UInt8](repeating: 0xFF, count: 35)
        v[0] = 0x40; v[1] = 32
        v[5] = 0x05; v[6] = 0x00
        v[9] = 0x00   // wheel speed mode 0
        let cfg = dec.decode(v) as? InfoConfig
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.flag(InfoConfig.WHEEL_SPEED), 0)
        XCTAssertTrue(cfg?.supported(InfoConfig.WHEEL_SPEED) ?? false)
    }

    func testTelemetrySpeedMode0() {
        // 0x4A frame: wheel speed bytes 9-10 = 0x0B 0x84 (= 2948) => 2948 * 0.01220703125 = 36.0 km/h
        dec.info = {
            var v = [UInt8](repeating: 0xFF, count: 35)
            v[0] = 0x40; v[1] = 32; v[5] = 0x05; v[6] = 0x00; v[9] = 0x00
            return (dec.decode(v) as? InfoConfig)!
        }()
        var v = [UInt8](repeating: 0xFF, count: 25)
        v[0] = 0x4A; v[1] = 22
        v[5] = 0x05; v[6] = 0x00     // block 1 present
        v[9] = 0x0B; v[10] = 0x84    // speed
        let t = dec.decode(v) as? Telemetry
        XCTAssertEqual(t?.speedKmh ?? 0, 36.0, accuracy: 0.1)
    }

    func testTelemetryRpmMode0() {
        // 0x40 config first: engine speed nibble (byte 9, bits 1-0) = 0 => mode 0.
        dec.info = {
            var c = [UInt8](repeating: 0xFF, count: 35)
            c[0] = 0x40; c[1] = 32; c[5] = 0x05; c[6] = 0x00
            c[9] = 0x00   // wheel speed mode 0, engine speed mode 0
            return (dec.decode(c) as? InfoConfig)!
        }()
        // rpm bytes 11-12: (0x04 & 0x7F) << 8 | 0x00 = 1024 rpm (mode 0 reads the raw 15-bit)
        var v = [UInt8](repeating: 0xFF, count: 25)
        v[0] = 0x4A; v[1] = 22; v[5] = 0x05; v[6] = 0x00
        v[11] = 0x04; v[12] = 0x00
        let t = dec.decode(v) as? Telemetry
        XCTAssertEqual(t?.rpm ?? -1, 1024)
    }

    func testTelemetryGear() {
        var v = [UInt8](repeating: 0xFF, count: 25)
        v[0] = 0x4A; v[1] = 22; v[5] = 0x05; v[6] = 0x00
        v[13] = 0x03   // gear 3
        let t = dec.decode(v) as? Telemetry
        XCTAssertEqual(t?.gear ?? -1, 3)
    }

    func testVehicleInfoOdometer() {
        // 0x41: odometer byte 27 (low 4 bits)<<16 | be16(28). 27=0x01 -> 0x01<<16 | 0x10 0x2C
        dec.info = {
            var c = [UInt8](repeating: 0xFF, count: 35)
            c[0] = 0x40; c[1] = 32; c[5] = 0x05; c[6] = 0x00
            c[27] = 0x00   // odometer present (nibble 0)
            c[33] = 0x00   // no valid-bit for odometer (so value counts)
            return (dec.decode(c) as? InfoConfig)!
        }()
        var v = [UInt8](repeating: 0xFF, count: 55)
        v[0] = 0x41; v[1] = 52
        v[5] = 0x05; v[6] = 0x00     // block 1
        v[25] = 0x05; v[26] = 0x00   // block 3 (holds odometer at 27-29)
        v[27] = 0x01                 // high nibble = 1
        v[28] = 0x10; v[29] = 0x2C   // low 16 = 0x102C = 4140
        // value = 0x01<<16 | 0x102C = 65536 + 4140 = 69676 km
        let info = dec.decode(v) as? VehicleInfo
        XCTAssertEqual(info?.odometerKm ?? -1, 69676)
    }

    func testLogExtInstantFuel() {
        // 0x45 instant fuel: byte 27 low 2 bits <<8 | byte 28. 27=0x03, 28=0x88 -> (3<<8)|0x88 = 936 -> 93.6? no, *0.1=93.6
        dec.info = {
            var c = [UInt8](repeating: 0xFF, count: 35)
            c[0] = 0x40; c[1] = 32; c[5] = 0x05; c[6] = 0x00
            c[31] = 0x00   // instant fuel nibble 0 (present0)
            c[33] = 0x00   // no valid bit
            return (dec.decode(c) as? InfoConfig)!
        }()
        var v = [UInt8](repeating: 0xFF, count: 55)
        v[0] = 0x45; v[1] = 52
        v[25] = 0x05; v[26] = 0x00   // block 3
        v[27] = 0x03                 // low 2 bits = 3, valid bit (bit 4) clear
        v[28] = 0x88                 // low byte
        // fuel = (3<<8) | 0x88 = 768 + 136 = 904 -> 90.4 km/L? *0.1 = 90.4
        let ext = dec.decode(v) as? LogExt
        XCTAssertEqual(ext?.instantFuel ?? 0, 90.4, accuracy: 0.01)
    }

    func testGeneralSettingsClock() {
        var v = [UInt8](repeating: 0xFF, count: 15)
        v[0] = 0x1B; v[1] = 12
        v[5] = 0x05; v[6] = 0x0A     // block 0x0A
        v[7] = 0x00                  // result 0
        v[8] = 0x00                  // shift lamp: status 0, level 0
        v[9] = 0x15                  // day 21
        v[10] = 0x01                 // month 1
        v[11] = 0x1A                 // year 2026 (2026 - 2000 = 26 = 0x1A)
        v[12] = 0x14                 // hour 20
        v[13] = 0x28                 // minute 40
        v[14] = 0x30                 // second 48
        let g = dec.decode(v) as? GeneralSettings
        XCTAssertEqual(g?.day ?? -1, 21)
        XCTAssertEqual(g?.month ?? -1, 1)
        XCTAssertEqual(g?.year ?? -1, 2026)
        XCTAssertEqual(g?.hour ?? -1, 20)
        XCTAssertEqual(g?.minute ?? -1, 40)
        XCTAssertEqual(g?.second ?? -1, 48)
    }

    func testVehicleSettingsKtrc() {
        // 0x48 block 0x09: byte 18 = KTRC (bits 6-3) | riding mode (bits 2-0).
        // KTRC wire 2 (level 1), riding mode 1 (Sport) => 0b0001_0001 = 0x11
        var v = [UInt8](repeating: 0xFF, count: 20)
        v[0] = 0x48; v[1] = 20
        v[5] = 0x05; v[6] = 0x09
        v[18] = 0x11
        // no tuning config: hasTuning returns true when cfg nil
        let s = dec.decode(v) as? VehicleSettings
        XCTAssertEqual(s?.ktrc ?? -1, 2)
        XCTAssertEqual(s?.ridingMode ?? -1, 1)
    }

    func testShortRidingLogFrameDropped() {
        // A 0x4A frame whose header says 85 bytes but is only 20 long must be dropped.
        var v = [UInt8](repeating: 0xFF, count: 20)
        v[0] = 0x4A
        v[1] = 82   // length - 3 = 82 => 85 bytes expected
        XCTAssertNil(dec.decode(v))
    }

    func testImuSuspAbsentAllFF() {
        var v = [UInt8](repeating: 0xFF, count: 45)
        v[0] = 0x4B; v[1] = 42
        let im = dec.decode(v) as? ImuSusp
        XCTAssertEqual(im?.frontWheelKmh, nil)
        XCTAssertEqual(im?.tcsLevelHigh ?? -1, -1)
    }
}

// A fake Io for the request-queue tests.
final class FakeIo: BikeRequests.Io {
    var sent: [[UInt8]] = []
    var nowMs: Int64 = 0
    var scheduled: [(BikeRequests.ScheduledWork, Int64)] = []
    func send(_ frame: [UInt8], _ label: String) -> Bool { sent.append(frame); return true }
    func now() -> Int64 { nowMs }
    func schedule(_ r: BikeRequests.ScheduledWork, _ delayMs: Int64) {
        r.cancelled = false
        scheduled.append((r, delayMs))
        // deliberately not performed: the test drives completion via onFrame
    }
    func cancel(_ r: BikeRequests.ScheduledWork) { r.cancelled = true }
    func log(_ line: String) {}
}

final class BikeRequestsTests: XCTestCase {
    func testRequestAnsweredByData() {
        let io = FakeIo()
        let q = BikeRequests(io)
        var done = false
        let req = BikeRequests.Request([0x41, 0, 0], "vehicle info", .dataOrAck, .startup,
            BikeRequests.ClosureDone { _, ok, _ in done = ok })
        q.submit(req)
        // the 0x41 answer completes it
        q.onFrame([0x41, 0x54, 0, 0xFF, 0xFF, 0x05, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(done)
    }

    func testRequestAnsweredByAck() {
        let io = FakeIo()
        let q = BikeRequests(io)
        var done = false
        let req = BikeRequests.Request([0x1A, 0, 0], "caps", .dataOrAck, .startup,
            BikeRequests.ClosureDone { _, ok, _ in done = ok })
        q.submit(req)
        q.onFrame([0x20, 0x06, 0, 0x1A, 0, 0, 0])   // ACK naming 0x1A
        XCTAssertTrue(done)
    }

    func testRejectedRequestRemembered() {
        let io = FakeIo()
        let q = BikeRequests(io)
        let req = BikeRequests.Request([0x42, 0, 0], "EV info", .dataOrAck, .poll,
            BikeRequests.ClosureDone { _, _, _ in })
        q.submit(req)
        q.onFrame([0x20, 0x06, 0, 0x42, 1, 0, 0])   // ACK result 1 = rejected
        XCTAssertTrue(q.unsupported(0x42))
    }

    func testUnsupportedNotRequeued() {
        let io = FakeIo()
        let q = BikeRequests(io)
        let a = BikeRequests.Request([0x40, 0, 0], "a", .dataOrAck, .poll, nil)
        let b = BikeRequests.Request([0x40, 0, 0], "b", .dataOrAck, .poll, nil)
        q.submit(a)
        XCTAssertFalse(q.submitIfIdle(b))   // same frame type already queued/running
    }
}
