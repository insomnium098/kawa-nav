//
//  KawaProtocol.swift
//
//  Kawasaki BLE5 meter protocol, as used by Rideology The App Motorcycle v2.11.13.
//  See docs/PROTOCOL.md in this repository for where each value comes from.
//
//  Ported from KawaNav (Darthbob/kawa-nav), KawaProtocol.java. Pure, no platform dependency.
//

import Foundation

public struct KawaProtocol {
    // MARK: - GATT UUIDs
    // Note: CoreBluetooth accepts either a CBUUID string or Foundation UUID for the standard
    // 16-bit CCCD. The vendor ones are 128-bit. We expose the raw strings so the BLE wrapper
    // can build CBUUIDs from them.
    public static let serviceUUID = "92FAEC07-C075-4B7C-A6C2-BBD1D1A150F5"
    public static let writeCharUUID = "ACF1B15C-10F9-4942-A32D-F9E019B95402"
    public static let notifyCharUUIDs = [
        "3AABBB34-EAC0-40F5-9D50-3A1EE6787136",
        "02FAD1BD-358E-441C-B296-FE874AF38A7E",
        "5E119EBA-35A7-4463-A7AF-7FA40A302350",
    ]
    public static let cccdUUID = "00002902"

    // MARK: - Names
    public static let flagNames = ["Navigating", "Rerouting", "Arrived", "No navigation"]
    public static let unitNames = ["km", "m", "mile", "ft", "yd"]
    public static let turnNone = 0xFF
    public static let cameraTurn = 43

    public static let turnNames = [
        "Straight", "Left", "Right", "Sharp left", "Sharp right",
        "Slight left", "Slight right", "U-turn left", "U-turn right",
        "Fork left", "Fork right", "Fork middle",
        "Ramp on left", "Ramp on right", "Exit left", "Exit right",
        "Merge left", "Merge right",
        "Rbt CW exit 1", "Rbt CW exit 2", "Rbt CW exit 3", "Rbt CW exit 4",
        "Rbt CW exit 5", "Rbt CW exit 6", "Rbt CW exit 7", "Rbt CW exit 8",
        "Rbt CW exit 9", "Rbt CW exit 10", "Rbt CW exit 11", "Rbt CW exit 12",
        "Rbt CCW exit 1", "Rbt CCW exit 2", "Rbt CCW exit 3", "Rbt CCW exit 4",
        "Rbt CCW exit 5", "Rbt CCW exit 6", "Rbt CCW exit 7", "Rbt CCW exit 8",
        "Rbt CCW exit 9", "Rbt CCW exit 10", "Rbt CCW exit 11", "Rbt CCW exit 12",
        "Departure", "Destination",
        "Waypoint 1", "Waypoint 2", "Waypoint 3", "Waypoint 4",
        "Waypoint 5", "Waypoint 6", "Waypoint 7", "Waypoint 8",
        "Waypoint 9", "Waypoint 10", "Waypoint 11", "Waypoint 12",
    ]

    public static let maxDistance = 0xFFFFFF

    // MARK: - Turn-by-turn frame (35 bytes)
    /// "NaviControlPoint" frame (oh/b.java, case NAVI_CONTROL_POINT).
    public static func naviFrame(flag: Int, turn: Int, unit: Int, distance: Int) -> [UInt8] {
        let d = max(0, min(maxDistance, distance))
        var b = [UInt8](repeating: 0xFF, count: 35)
        b[0] = 20
        b[1] = 8
        b[2] = 0
        b[5] = 5
        b[6] = 0x70
        b[7] = UInt8((flag & 0x0F) << 4)
        b[13] = UInt8((unit & 0x0F) << 4)
        b[15] = 5
        b[16] = 0x71
        b[17] = UInt8(turn)
        b[18] = UInt8((d >> 16) & 0xFF)
        b[19] = UInt8((d >> 8) & 0xFF)
        b[20] = UInt8(d & 0xFF)
        return b
    }

    /// Frame that tells the meter navigation has ended.
    public static func clearFrame() -> [UInt8] {
        naviFrame(flag: 3, turn: turnNone, unit: 0x0F, distance: 0)
    }

    // MARK: - Status icon frame (15 bytes)
    /// Status icon frame, 15 bytes (oh/b.java, case METER_INDICATION). Rideology sends it every 5 s.
    public static func meterIndicationFrame(battery: Int, voice: Int, headset: Int, ridingLog: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0xFF, count: 15)
        b[0] = 19
        b[1] = 12
        b[2] = 0
        b[5] = 5
        b[6] = 0
        b[7] = UInt8(((battery & 0x0F) << 4) | (voice & 0x0F))
        b[8] = UInt8(((headset & 0x0F) << 4) | (ridingLog & 0x0F))
        return b
    }

    // MARK: - Phone name (35 bytes)
    public static let phoneNameBytes = 24

    /// Phone name frame, 35 bytes (ne/c.java case 20). UTF-8 name in up to three 8-byte parts.
    public static func phoneNameFrame(_ name: String) -> [UInt8] {
        let text = phoneNameData(name)
        var b = [UInt8](repeating: 0, count: 35)
        b[0] = 11
        b[1] = 32
        b[2] = 0
        b[3] = 0xFF
        b[4] = 0xFF
        for part in 0..<3 where part * 8 < text.count {
            let base = 7 + part * 10
            b[5 + part * 10] = 5
            b[6 + part * 10] = UInt8(part + 1)
            let start = part * 8
            let end = min(8, text.count - start)
            for k in 0..<end {
                b[base + k] = text[start + k]
            }
        }
        return b
    }

    /// The name as UTF-8, without characters beyond `phoneNameBytes` (cut at a character).
    public static func phoneNameData(_ name: String) -> [UInt8] {
        var s = name
        var text = (s as NSString).data(using: String.Encoding.utf8.rawValue)!
        while text.count > phoneNameBytes {
            s = String(s.dropLast())
            text = (s as NSString).data(using: String.Encoding.utf8.rawValue)!
        }
        return [UInt8](text)
    }

    // MARK: - Battery
    public static let batteryNone = 15

    /// Battery percentage to Ble5Value.j, same thresholds as Rideology.
    public static func batteryLevel(_ percent: Double) -> Int {
        if percent <= 0 { return batteryNone }
        if percent <= 10 { return 0 }
        if percent <= 30 { return 1 }
        if percent <= 70 { return 2 }
        return 3
    }

    /// Battery percentage to Ble5Value.j, charging (7..10).
    public static func batteryLevel(_ percent: Double, charging: Bool) -> Int {
        let level = batteryLevel(percent)
        return charging && level != batteryNone ? 7 + level : level
    }

    // MARK: - Frame type ids
    public static let capabilities = 0x1A
    public static let capabilitiesRequest: [UInt8] = [0x1A, 0, 0]

    /// Payload-less read request `<id> 00 00`.
    public static func readRequest(_ id: Int) -> [UInt8] {
        [UInt8(id), 0, 0]
    }

    // MARK: - Requests

    /// A request frame of `length` bytes, FF-filled, with header `id, length - 3, counter, FF, FF`.
    private static func request(id: Int, length: Int, counter: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0xFF, count: length)
        b[0] = UInt8(id)
        b[1] = UInt8(length - 3)
        b[2] = UInt8(counter)
        return b
    }

    /// Asks for one settings block: `05 <block> 00` at `offset`.
    private static func readBlock(_ b: inout [UInt8], offset: Int, block: Int) {
        b[offset] = 5
        b[offset + 1] = UInt8(block)
        b[offset + 2] = 0
    }

    // Frame ids (mirror BikeFrames)
    public static let generalSettings: Int = 0x1B
    public static let serviceIndicator: Int = 0x1E
    public static let vehicleSettings: Int = 0x48

    /// 0x1B: reads the general settings (meter clock, shift lamp), block 0x0A. 15 bytes.
    public static func generalSettingsRead() -> [UInt8] {
        var b = request(id: generalSettings, length: 15, counter: 0)
        readBlock(&b, offset: 5, block: 0x0A)
        return b
    }

    /// 0x48: reads the vehicle settings (riding mode, power, KTRC, KQS…), block 0x09. 45 bytes.
    public static func vehicleSettingsRead() -> [UInt8] {
        var b = request(id: vehicleSettings, length: 45, counter: 0)
        readBlock(&b, offset: 5, block: 0x09)
        return b
    }

    /// 0x1B write: block 0x0A becomes 0x4A and byte 7 becomes 1; shift-lamp byte, then the time.
    public static func generalSettingsWrite(lampStatus: Int, lampLevel: Int, day: Int, month: Int,
                                            year: Int, hour: Int, minute: Int, second: Int) -> [UInt8] {
        var b = request(id: generalSettings, length: 15, counter: 0)
        b[5] = 5
        b[6] = 0x4A
        b[7] = 1
        b[8] = UInt8(((lampStatus & 3) << 6) | (lampLevel & 0x3F))
        b[9] = UInt8(day & 0x3F)
        b[10] = UInt8(month & 0x0F)
        b[11] = UInt8(year - 2000)
        b[12] = UInt8(hour & 0x1F)
        b[13] = UInt8(minute & 0x3F)
        b[14] = UInt8(second & 0x3F)
        return b
    }

    /// 0x1B write that changes only the shift lamp: time fields "leave unchanged"; year = 0x2F.
    public static func shiftLampWrite(lampStatus: Int, lampLevel: Int) -> [UInt8] {
        var b = request(id: generalSettings, length: 15, counter: 0)
        b[5] = 5
        b[6] = 0x4A
        b[7] = 1
        b[8] = UInt8(((lampStatus & 3) << 6) | (lampLevel & 0x3F))
        b[9] = 0xFF
        b[10] = 0xFF
        b[11] = 0x2F
        b[12] = 0xFF
        b[13] = 0xFF
        b[14] = 0xFF
        return b
    }

    /// 0x1E: reads the three maintenance reminders, blocks 0x0C, 0x0D, 0x0E. 45 bytes, counter 01.
    public static func serviceIndicatorRead() -> [UInt8] {
        var b = request(id: serviceIndicator, length: 45, counter: 1)
        readBlock(&b, offset: 5, block: 0x0C)
        readBlock(&b, offset: 15, block: 0x0D)
        readBlock(&b, offset: 25, block: 0x0E)
        return b
    }

    /// 0x08 "meter indication init" exactly as Rideology sends it.
    public static func meterInitFrame() -> [UInt8] {
        [0x08, 0x0C, 0x00, 0xFF, 0xFF, 0x0A, 0x08, 0x01, 0x78, 0x03, 0xE8, 0x00, 0xC8, 0x00, 0x64]
    }

    // MARK: - Connect sequence

    public static let initNone = 0
    public static let initRead = 1
    public static let initFull = 2

    /// The requests sent after connecting, in Rideology's order.
    /// `level`: initNone (only capabilities), initRead (informational reads), initFull (adds 0x08).
    /// `phoneModel`: when non-empty, the 0x0B phone name frame is included.
    /// `askExt`: whether to request the riding-log extension (0x45).
    public static func startup(level: Int, phoneModel: String?, askExt: Bool = true) -> [[UInt8]] {
        var l: [[UInt8]] = []
        if level == initNone {
            l.append(capabilitiesRequest)
            if let m = phoneModel, !m.isEmpty {
                l.append(phoneNameFrame(m))
            }
            return l
        }
        let full = level >= initFull
        let modelInfo = 0x03
        let infoConfig = 0x40
        let serviceConfig = 0x1D
        let tuningConfig = 0x47
        let vehicleInfo = 0x41
        let ridingLogExt = 0x45

        l.append(readRequest(modelInfo))
        l.append(readRequest(infoConfig))
        l.append(capabilitiesRequest)
        l.append(readRequest(serviceConfig))
        l.append(readRequest(tuningConfig))
        if let m = phoneModel, !m.isEmpty {
            l.append(phoneNameFrame(m))
        }
        l.append(readRequest(vehicleInfo))
        l.append(generalSettingsRead())
        l.append(vehicleSettingsRead())
        l.append(serviceIndicatorRead())
        if full {
            l.append(meterInitFrame())
        }
        if full || askExt {
            l.append(readRequest(ridingLogExt))
        }
        return l
    }

    // MARK: - Hex helpers
    public static func hex(_ data: [UInt8]) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parses "14 08 00 ff" / "140800ff" into bytes, or nil.
    public static func parseHex(_ s: String) -> [UInt8]? {
        let clean = s.filter { $0.isHexDigit }
        guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}
