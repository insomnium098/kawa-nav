//
//  BikeFrames.swift
//
//  Frames the BLE5 meter sends: vehicle data, riding log, settings, answers. Byte layouts follow
//  Zen3515/homeassistant-kawasaki-rideology-ble (kawi_ble5_client.py, Apache-2.0), which mirrors
//  Rideology's Ble5Value classes; see docs/PROTOCOL.md for what is verified on which bike.
//
//  Missing values are `nil` (Optionals) — the Java original used NaN for decimals and -1 for ints.
//  Ported from KawaNav (Darthbob/kawa-nav), BikeFrames.java.
//

import Foundation

// MARK: - Frame type ids

public struct BikeFrames {
    public static let modelInfo = 0x03
    public static let meterInit = 0x08
    public static let phoneModel = 0x0B
    public static let meterIndication = 0x13
    public static let navigation = 0x14
    public static let generalCaps = 0x1A
    public static let generalSettings = 0x1B
    public static let serviceConfig = 0x1D
    public static let serviceIndicator = 0x1E
    public static let ack = 0x20
    public static let status = 0x30
    public static let infoConfig = 0x40
    public static let vehicleInfo = 0x41
    public static let emcInfo = 0x42
    public static let ridingLogExt = 0x45
    public static let tuningConfig = 0x47
    public static let vehicleSettings = 0x48
    public static let ridingLog = 0x4A
    public static let ridingLogHigh = 0x4B

    /// Short name of a frame type, for logs and the debug card.
    public static func name(_ id: Int) -> String {
        switch id {
        case modelInfo: return "model info"
        case meterInit: return "meter indication init"
        case phoneModel: return "phone model"
        case meterIndication: return "meter indication"
        case navigation: return "navigation"
        case generalCaps: return "general setting capability"
        case generalSettings: return "general settings"
        case serviceConfig: return "maintenance config"
        case serviceIndicator: return "maintenance"
        case ack: return "ack"
        case status: return "status"
        case infoConfig: return "vehicle info config"
        case vehicleInfo: return "vehicle info"
        case emcInfo: return "EV/HEV info"
        case ridingLogExt: return "riding log ext"
        case tuningConfig: return "tuning config"
        case vehicleSettings: return "vehicle settings"
        case ridingLog: return "riding log"
        case ridingLogHigh: return "riding log high"
        default: return String(format: "0x%02X", id)
        }
    }
}

/// Any frame from the meter; subclasses decode the types KawaNav knows.
public class Frame {
    public let raw: [UInt8]
    public let id: Int
    init(_ raw: [UInt8]) {
        self.raw = raw
        self.id = raw.isEmpty ? -1 : Int(raw[0])
    }
}

// MARK: - answers

/// 0x20: the meter took (or refused) a request. Byte 3 is the request's frame type, byte 4 the result.
public final class Ack: Frame {
    public let cmd: Int
    public let result: Int
    init(_ v: [UInt8]) {
        cmd = FrameReader.u8(v, 3)
        result = FrameReader.u8(v, 4)
        super.init(v)
    }
    public func accepted() -> Bool { result == 0 }
}

/// 0x30: result of a settings block request, or a text echo.
public final class Status: Frame {
    public let block: Int
    public let result: Int
    public let text: String?
    init(_ v: [UInt8]) {
        let blockResult = FrameReader.u8(v, 1) == 0x0C && FrameReader.blockPresent(v, 5)
        self.block = blockResult ? FrameReader.u8(v, 6) : -1
        self.result = blockResult ? FrameReader.u8(v, 7) : -1
        self.text = (!blockResult && FrameReader.u8(v, 1) == 0x20) ? FrameReader.textChunks(v) : nil
        super.init(v)
    }
}

/// 0x03: VIN in ASCII chunks `02 71 <8>`, `02 72 <8>`, `02 73 <1…>`.
public final class ModelInfo: Frame {
    public let model: String?
    public let vin: String?
    init(_ v: [UInt8]) {
        var parts = [String?, String?, String?]
        var i = 5
        while i + 1 < v.count {
            let tag = FrameReader.u8(v, i + 1)
            if FrameReader.u8(v, i) != 0x02 || tag < 0x71 || tag > 0x73 { i += 10; continue }
            var sb = ""
            for k in (i + 2)..<min(i + 10, v.count) {
                let c = Int(v[k])
                if c == 0xFF || c == 0 { break }
                if c >= 0x20 && c < 0x7F { sb.append(UnicodeScalar(c)!) }
            }
            parts[tag - 0x71] = sb.trimmingCharacters(in: .whitespaces)
            i += 10
        }
        self.model = (parts[0]?.isEmpty ?? true) ? nil : parts[0]
        let all = (parts[0] ?? "") + (parts[1] ?? "") + (parts[2] ?? "")
        self.vin = (self.model != nil && parts[1] != nil && (all.count == 17 || all.count == 13)) ? all : nil
        super.init(v)
    }
}

// MARK: - capabilities

/// 0x1A: what the meter can show and which general settings (clock, shift lamp) it takes.
public final class GeneralCaps: Frame {
    public let valid: Bool
    public let clockGate: Int
    public let shiftLampMode: Int
    public let shiftLampMin: Int
    public let shiftLampMax: Int
    public let shiftLampSettable: Bool
    public let clockSettable: [Bool]
    public let meterIndication: Int
    public let navi: Int
    public let indicatorSubcaps: [Int]
    public let turnByTurn: Bool
    public let statusIcons: Bool

    init(_ v: [UInt8]) {
        var clockSettable = [Bool](repeating: false, count: 6)
        var subcaps = [Int](repeating: 0, count: 4)
        let valid = v.count < 15 || !retryRequired(v, 5, 6, 14)
        let clockGate = FrameReader.bits(v, 7, 0xC0)
        let shiftLampMode = FrameReader.bits(v, 7, 0x03)
        let shiftLampMax = FrameReader.u8(v, 8)
        let shiftLampMin = FrameReader.u8(v, 9)
        let shiftLampSettable = valid && (shiftLampMode == 0 || shiftLampMode == 3)
            && shiftLampMin >= 1 && shiftLampMax <= 61 && shiftLampMin <= shiftLampMax
        let clock: [[Int]] = [[10, 0xC0], [10, 0x30], [10, 0x0C], [10, 0x03], [11, 0xC0], [11, 0x30]]
        for i in 0..<6 {
            clockSettable[i] = clockGate == 0 && FrameReader.bits(v, clock[i][0], clock[i][1]) == 0
        }
        let meterIndication = FrameReader.bits(v, 11, 0x0F)
        let navi = FrameReader.bits(v, 12, 0xF0)
        subcaps[0] = FrameReader.bits(v, 12, 0x0C)
        subcaps[1] = FrameReader.bits(v, 12, 0x03)
        subcaps[2] = FrameReader.bits(v, 13, 0xC0)
        subcaps[3] = FrameReader.bits(v, 13, 0x30)
        let turnByTurn = navi != 15
        var noIcons = meterIndication == 15
        for s in subcaps { noIcons = noIcons && (s == 3) }
        let statusIcons = !noIcons

        self.valid = valid
        self.clockGate = clockGate
        self.shiftLampMode = shiftLampMode
        self.shiftLampMin = shiftLampMin
        self.shiftLampMax = shiftLampMax
        self.shiftLampSettable = shiftLampSettable
        self.clockSettable = clockSettable
        self.meterIndication = meterIndication
        self.navi = navi
        self.indicatorSubcaps = subcaps
        self.turnByTurn = turnByTurn
        self.statusIcons = statusIcons
        super.init(v)
    }

    public func clockSettable() -> Bool {
        for b in self.clockSettable where !b { return false }
        return true
    }
}

/// Rideology's "retry" check on config frames: a block is there but its flag byte says the data is not ready.
func retryRequired(_ v: [UInt8], _ a: Int, _ b: Int, _ flag: Int) -> Bool {
    (FrameReader.u8(v, a) != 0xFF || FrameReader.u8(v, b) != 0xFF) && (FrameReader.u8(v, flag) & 1) == 0
}

/// One 2-bit (or 4-bit) support flag of a config frame.
public struct Flag {
    public let name: String
    let index: Int
    let mask: Int
    init(_ name: String, _ index: Int, _ mask: Int) {
        self.name = name
        self.index = index
        self.mask = mask
    }
}

/// 0x40: which vehicle-info and riding-log values this bike has (Ble5Value.i). 0 or 1: yes, 3: no.
public final class InfoConfig: Frame {
    public static let TOTAL_DISTANCE = Flag("total distance", 7, 0xC0)
    public static let TOTAL_FUEL = Flag("total fuel consumed", 7, 0x30)
    public static let FUEL_RATE = Flag("engine fuel rate", 7, 0x0C)
    public static let ECU_BATTERY = Flag("ECU battery", 7, 0x03)
    public static let WATER_TEMP = Flag("water temperature", 8, 0xC0)
    public static let OIL_TEMP = Flag("oil temperature", 8, 0x30)
    public static let INTAKE_TEMP = Flag("intake air temperature", 8, 0x0C)
    public static let BOOST_TEMP = Flag("boost temperature", 8, 0x03)
    public static let BOOST_PRESSURE = Flag("boost pressure", 9, 0xC0)
    public static let FUEL_INJECTION = Flag("fuel injection", 9, 0x30)
    public static let WHEEL_SPEED = Flag("wheel speed", 9, 0x0C)
    public static let ENGINE_SPEED = Flag("engine speed", 9, 0x03)
    public static let GEAR = Flag("gear", 10, 0xF0)
    public static let THROTTLE = Flag("throttle", 10, 0x0C)
    public static let ACCELERATION = Flag("acceleration", 10, 0x03)
    public static let LEAN = Flag("lean angle", 11, 0xC0)
    public static let WHEELIE = Flag("wheelie flag", 11, 0x30)
    public static let WHEELIE_ANGLE = Flag("wheelie angle", 11, 0x0C)
    public static let TCS_HB = Flag("TCS level high", 11, 0x03)
    public static let TCS_LB = Flag("TCS level low", 12, 0xC0)
    public static let RIDER_TORQUE = Flag("rider torque request", 12, 0x30)
    public static let ENGINE_TORQUE_REQUEST = Flag("engine torque request", 12, 0x0C)
    public static let ENGINE_TORQUE = Flag("engine torque", 12, 0x03)
    public static let ODOMETER = Flag("odometer", 27, 0xC0)
    public static let FUEL_GAUGE = Flag("fuel gauge", 27, 0x30)
    public static let AVG_MILEAGE = Flag("average mileage", 27, 0x0C)
    public static let METER_BATTERY = Flag("meter battery", 27, 0x03)
    public static let TRIP_A = Flag("trip A", 28, 0xC0)
    public static let TRIP_B = Flag("trip B", 28, 0x30)
    public static let AVG_SPEED = Flag("average speed", 28, 0x0C)
    public static let OUTSIDE_TEMP = Flag("outside temperature", 28, 0x03)
    public static let RANGE_SYMBOL = Flag("range symbol", 29, 0xC0)
    public static let RANGE = Flag("range", 29, 0x30)
    public static let FUEL_CONSUMPTION = Flag("fuel consumption", 29, 0x0C)
    public static let TOTAL_TIME = Flag("total time", 29, 0x03)
    public static let INSTANT_FUEL = Flag("instant fuel consumption", 31, 0x0C)
    public static let MAX_LEAN_LEFT = Flag("max lean left", 32, 0xC0)
    public static let MAX_LEAN_RIGHT = Flag("max lean right", 32, 0x30)
    public static let ODOMETER_VALID = Flag("odometer valid bit", 33, 0x80)
    public static let METER_BATTERY_VALID = Flag("meter battery valid bit", 33, 0x40)
    public static let AVG_MILEAGE_VALID = Flag("average mileage valid bit", 33, 0x20)
    public static let INSTANT_FUEL_VALID = Flag("instant fuel valid bit", 33, 0x10)
    public static let TRIP_A_VALID = Flag("trip A valid bit", 33, 0x08)
    public static let TRIP_B_VALID = Flag("trip B valid bit", 33, 0x04)
    public static let AVG_SPEED_VALID = Flag("average speed valid bit", 33, 0x02)
    public static let OUTSIDE_TEMP_VALID = Flag("outside temperature valid bit", 33, 0x01)
    public static let RANGE_VALID = Flag("range valid bit", 34, 0x40)
    public static let TOTAL_TIME_VALID = Flag("total time valid bit", 34, 0x20)

    public static let all = [TOTAL_DISTANCE, TOTAL_FUEL, FUEL_RATE, ECU_BATTERY, WATER_TEMP, OIL_TEMP,
        INTAKE_TEMP, BOOST_TEMP, BOOST_PRESSURE, FUEL_INJECTION, WHEEL_SPEED, ENGINE_SPEED, GEAR, THROTTLE,
        ACCELERATION, LEAN, WHEELIE, WHEELIE_ANGLE, TCS_HB, TCS_LB, RIDER_TORQUE, ENGINE_TORQUE_REQUEST,
        ENGINE_TORQUE, ODOMETER, FUEL_GAUGE, AVG_MILEAGE, METER_BATTERY, TRIP_A, TRIP_B, AVG_SPEED,
        OUTSIDE_TEMP, RANGE_SYMBOL, RANGE, FUEL_CONSUMPTION, TOTAL_TIME, INSTANT_FUEL, MAX_LEAN_LEFT,
        MAX_LEAN_RIGHT, OUTSIDE_TEMP_VALID]

    public let valid: Bool

    init(_ v: [UInt8]) {
        valid = v.count >= 35 && !(retryRequired(v, 5, 6, 14) || retryRequired(v, 15, 16, 24)
            || retryRequired(v, 25, 26, 34))
        super.init(v)
    }

    /// The flag's value (0..3, 0..15 for the gear), -1 past the end.
    public func flag(_ f: Flag) -> Int {
        FrameReader.bits(raw, f.index, f.mask)
    }

    /// The bike has this value.
    public func supported(_ f: Flag) -> Bool {
        let x = flag(f)
        return x == 0 || x == 1
    }
}

// MARK: - config gating helpers

/// True unless the config is known and says the bike does not have the value.
func hasInfo(_ cfg: InfoConfig?, _ f: Flag) -> Bool {
    cfg == nil || cfg!.supported(f)
}

/// The bike has the value and its 0x40 nibble is exactly 0.
func present0(_ cfg: InfoConfig?, _ f: Flag) -> Bool {
    cfg == nil || cfg!.flag(f) == 0
}

/// The config is known and its flag is exactly 0 (the strict reading Rideology uses for these).
func zeroInfo(_ cfg: InfoConfig?, _ f: Flag) -> Bool {
    cfg != nil && cfg!.flag(f) == 0
}

/// A value's "valid" bit: when the config says the bike sends one (f is 0), the bit must be 0.
func validBit(_ v: [UInt8], _ i: Int, _ bit: Int, _ cfg: InfoConfig?, _ f: Flag) -> Bool {
    if !zeroInfo(cfg, f) { return true }
    return FrameReader.inPresentBlock(v, i) && (FrameReader.u8(v, i) & (1 << bit)) == 0
}

/// 0x47: which vehicle settings this bike has (Ble5Value.y).
public final class TuningConfig: Frame {
    public static let ECU = Flag("ECU tuning", 7, 0x30)
    public static let KTRC = Flag("KTRC", 8, 0xC0)
    public static let RIDING_MODE = Flag("riding mode", 8, 0x30)
    public static let KQS = Flag("KQS", 8, 0x0C)
    public static let KEBC = Flag("KEBC", 8, 0x03)
    public static let POWER = Flag("power mode", 9, 0xC0)
    public static let METER = Flag("meter tuning", 17, 0xC0)
    public static let KECS_PRELOAD = Flag("KECS preload", 19, 0x30)
    public static let KECS_MODE = Flag("KECS mode", 19, 0x0C)
    public static let KECS_LOAD = Flag("KECS load", 19, 0x03)
    public static let KECS_FR_COM = Flag("KECS front compression", 20, 0xC0)
    public static let KECS_FR_TEN = Flag("KECS front rebound", 20, 0x30)
    public static let KECS_RR_COM = Flag("KECS rear compression", 20, 0x0C)
    public static let KECS_RR_TEN = Flag("KECS rear rebound", 20, 0x03)
    public static let all = [ECU, KTRC, RIDING_MODE, KQS, KEBC, POWER, METER, KECS_PRELOAD, KECS_MODE,
        KECS_LOAD, KECS_FR_COM, KECS_FR_TEN, KECS_RR_COM, KECS_RR_TEN]

    public let valid: Bool

    init(_ v: [UInt8]) {
        valid = !(retryRequired(v, 5, 6, 14) || retryRequired(v, 15, 16, 24))
        super.init(v)
    }

    public func flag(_ f: Flag) -> Int {
        FrameReader.bits(raw, f.index, f.mask)
    }

    public func supported(_ f: Flag) -> Bool {
        let x = flag(f)
        if f == TuningConfig.KTRC { return x >= 0 && x <= 2 }
        if f == TuningConfig.ECU || f == TuningConfig.METER || f == TuningConfig.RIDING_MODE || f == TuningConfig.POWER {
            return x == 0 || x == 1
        }
        return x == 0
    }

    public func any() -> Bool {
        for f in all where f != TuningConfig.ECU && f != TuningConfig.METER && supported(f) { return true }
        return false
    }
}

func hasTuning(_ cfg: TuningConfig?, _ f: Flag) -> Bool {
    cfg == nil || cfg!.supported(f)
}

// MARK: - vehicle data

/// Byte `i` exists and its block is present.
private func inBlock(_ v: [UInt8], _ i: Int) -> Bool {
    FrameReader.inPresentBlock(v, i)
}

/// 0x41: snapshot of the meter (Ble5Value MC info), answer to `41 00 00`. 85 bytes.
public final class VehicleInfo: Frame {
    public let totalFuelL: Double?
    public let ecuBatteryV: Double?
    public let avgMileage: Double?
    public let meterBatteryV: Double?
    public let tripAKm: Double?
    public let tripBKm: Double?
    public let outsideC: Double?
    public let fuelConsumption: Double?
    public let odometerKm: Int
    public let fuelBars: Int
    public let avgSpeedKmh: Int
    public let rangeSymbol: Int
    public let rangeKm: Int
    public let totalTime: Int
    public let maxLeanLeft: Int
    public let maxLeanRight: Int

    init(_ v: [UInt8], _ c: InfoConfig?) {
        var totalFuelL: Double?; var ecuBatteryV: Double?; var avgMileage: Double?
        var meterBatteryV: Double?; var tripAKm: Double?; var tripBKm: Double?
        var outsideC: Double?; var fuelConsumption: Double?
        var odometerKm = -1; var fuelBars = -1; var avgSpeedKmh = -1
        var rangeSymbol = -1; var rangeKm = -1; var totalTime = -1

        if inBlock(v, 10) && hasInfo(c, InfoConfig.TOTAL_FUEL) && FrameReader.be32(v, 7) != 0xFFFFFFFF {
            totalFuelL = Double(FrameReader.be32(v, 7)) * 0.01
        }
        if inBlock(v, 14) && hasInfo(c, InfoConfig.ECU_BATTERY) && FrameReader.u8(v, 14) != 0xFF {
            ecuBatteryV = Double(FrameReader.u8(v, 14)) * 20.0 / 256.0
        }
        let odo = inBlock(v, 29) && present0(c, InfoConfig.ODOMETER)
            ? (FrameReader.u8(v, 27) & 0x0F) << 16 | FrameReader.be16(v, 28) : -1
        if odo != 0xFFFFF && validBit(v, 27, 6, c, InfoConfig.ODOMETER_VALID) { odometerKm = odo }
        let bars = inBlock(v, 30) && hasInfo(c, InfoConfig.FUEL_GAUGE) ? FrameReader.u8(v, 30) & 0x0F : -1
        fuelBars = bars == 0x0F ? -1 : bars
        let mileage = inBlock(v, 33) && present0(c, InfoConfig.AVG_MILEAGE)
            ? (FrameReader.u8(v, 32) & 0x03) << 8 | FrameReader.u8(v, 33) : -1
        if mileage >= 0 && mileage != 0x3FF && validBit(v, 27, 4, c, InfoConfig.AVG_MILEAGE_VALID) {
            avgMileage = Double(mileage) * 0.1
        }
        let meterBattery = inBlock(v, 34) && present0(c, InfoConfig.METER_BATTERY) ? FrameReader.u8(v, 34) : -1
        if meterBattery >= 0 && meterBattery != 0xFF && validBit(v, 27, 5, c, InfoConfig.METER_BATTERY_VALID) {
            meterBatteryV = Double(meterBattery) * 0.1
        }
        let tripA = inBlock(v, 39) && hasInfo(c, InfoConfig.TRIP_A)
            ? (FrameReader.u8(v, 37) & 0x01) << 16 | FrameReader.be16(v, 38) : -1
        if tripA >= 0 && tripA != 0x1FFFF && validBit(v, 37, 7, c, InfoConfig.TRIP_A_VALID) {
            tripAKm = Double(tripA) * 0.1
        }
        let tripB = inBlock(v, 42) && hasInfo(c, InfoConfig.TRIP_B)
            ? (FrameReader.u8(v, 40) & 0x01) << 16 | FrameReader.be16(v, 41) : -1
        if tripB >= 0 && tripB != 0x1FFFF && validBit(v, 37, 6, c, InfoConfig.TRIP_B_VALID) {
            tripBKm = Double(tripB) * 0.1
        }
        let avgSpeed = inBlock(v, 43) && hasInfo(c, InfoConfig.AVG_SPEED) ? FrameReader.u8(v, 43) : -1
        if avgSpeed != 0xFF && validBit(v, 37, 5, c, InfoConfig.AVG_SPEED_VALID) { avgSpeedKmh = avgSpeed }
        if inBlock(v, 44) && hasInfo(c, InfoConfig.OUTSIDE_TEMP) && FrameReader.u8(v, 44) != 0xFF {
            outsideC = Double(FrameReader.u8(v, 44) - 60)
        }
        if inBlock(v, 47) && hasInfo(c, InfoConfig.RANGE_SYMBOL) { rangeSymbol = (FrameReader.u8(v, 47) & 0x30) >> 4 }
        let range = inBlock(v, 48) && hasInfo(c, InfoConfig.RANGE)
            ? (FrameReader.u8(v, 47) & 0x03) << 8 | FrameReader.u8(v, 48) : -1
        if range != 0x3FF && validBit(v, 47, 7, c, InfoConfig.RANGE_VALID) { rangeKm = range }
        let consumption = inBlock(v, 50) && hasInfo(c, InfoConfig.FUEL_CONSUMPTION)
            ? (FrameReader.u8(v, 49) & 0x03) << 8 | FrameReader.u8(v, 50) : -1
        if consumption >= 0 && consumption != 0x3FF { fuelConsumption = Double(consumption) * 0.1 }
        let time = inBlock(v, 52) && hasInfo(c, InfoConfig.TOTAL_TIME)
            ? (FrameReader.u8(v, 51) & 0x1F) << 8 | FrameReader.u8(v, 52) : -1
        if time != 0x1FFF && validBit(v, 47, 6, c, InfoConfig.TOTAL_TIME_VALID) { totalTime = time }
        self.totalFuelL = totalFuelL
        self.ecuBatteryV = ecuBatteryV
        self.avgMileage = avgMileage
        self.meterBatteryV = meterBatteryV
        self.tripAKm = tripAKm
        self.tripBKm = tripBKm
        self.outsideC = outsideC
        self.fuelConsumption = fuelConsumption
        self.odometerKm = odometerKm
        self.fuelBars = fuelBars
        self.avgSpeedKmh = avgSpeedKmh
        self.rangeSymbol = rangeSymbol
        self.rangeKm = rangeKm
        self.totalTime = totalTime
        self.maxLeanLeft = VehicleInfo.lean(v, 53, 3, c, InfoConfig.MAX_LEAN_LEFT)
        self.maxLeanRight = VehicleInfo.lean(v, 54, 2, c, InfoConfig.MAX_LEAN_RIGHT)
        super.init(v)
    }

    private static func lean(_ v: [UInt8], _ i: Int, _ validBitOf47: Int, _ c: InfoConfig?, _ f: Flag) -> Int {
        guard inBlock(v, i), zeroInfo(c, f), inBlock(v, 47),
              (FrameReader.u8(v, 47) & (1 << validBitOf47)) == 0 else { return -1 }
        let deg = FrameReader.u8(v, i) & 0x7F
        return deg == 127 ? -1 : deg
    }
}

/// 0x45: riding log extension: temperatures, distance, TPMS. 55 bytes.
public final class LogExt: Frame {
    public let totalDistanceKm: Double?
    public let fuelRate: Double?
    public let waterC: Double?
    public let oilC: Double?
    public let intakeC: Double?
    public let instantFuel: Double?
    public let tyreFrontKpa: Double?
    public let tyreRearKpa: Double?
    public let tpmsWarnings: Int
    public let odometerKm: Int
    public let fuelBars: Int
    public let avgMileage: Double?
    public let meterBatteryV: Double?
    public let odometerValid: Int
    public let meterBatteryValid: Int
    public let avgMileageValid: Int
    public let instantFuelValid: Int

    init(_ v: [UInt8], _ c: InfoConfig?) {
        var totalDistanceKm: Double?; var fuelRate: Double?; var waterC: Double?
        var oilC: Double?; var intakeC: Double?; var instantFuel: Double?
        var tyreFrontKpa: Double?; var tyreRearKpa: Double?
        var odometerKm = -1; var fuelBars = -1; var avgMileage: Double?; var meterBatteryV: Double?
        var odometerValid = -1; var meterBatteryValid = -1; var avgMileageValid = -1; var instantFuelValid = -1
        var tpmsWarnings = -1

        let dist = inBlock(v, 10) && hasInfo(c, InfoConfig.TOTAL_DISTANCE) ? FrameReader.be32(v, 7) : -1
        if dist >= 0 && dist != 0xFFFFFFFF { totalDistanceKm = Double(dist) * 0.1 }
        if inBlock(v, 12) && hasInfo(c, InfoConfig.FUEL_RATE) && FrameReader.be16(v, 11) != 0xFFFF {
            fuelRate = Double(FrameReader.be16(v, 11)) * 0.02
        }
        waterC = LogExt.temp(v, 17, 40, c, InfoConfig.WATER_TEMP)
        oilC = LogExt.temp(v, 19, 60, c, InfoConfig.OIL_TEMP)
        intakeC = LogExt.temp(v, 20, 40, c, InfoConfig.INTAKE_TEMP)
        let fuelValid = LogExt.current(v, 27, 4, c, InfoConfig.INSTANT_FUEL_VALID)
        let fuel = inBlock(v, 28) && present0(c, InfoConfig.INSTANT_FUEL) && FrameReader.u8(v, 27) != 0xFF && fuelValid
            ? (FrameReader.u8(v, 27) & 0x03) << 8 | FrameReader.u8(v, 28) : -1
        if fuel >= 0 && fuel != 0x3FF { instantFuel = Double(fuel) * 0.1 }
        if zeroInfo(c, InfoConfig.INSTANT_FUEL_VALID) && inBlock(v, 27) {
            instantFuelValid = (FrameReader.u8(v, 27) & 0x10) >> 4
        }
        let tpms = v.count > 49 && FrameReader.u8(v, 45) != 0xFF && FrameReader.u8(v, 46) != 0xFF
        if tpms {
            if FrameReader.u8(v, 47) != 0xFF { tyreFrontKpa = Double(FrameReader.u8(v, 47)) * 1.373 + 100 }
            if FrameReader.u8(v, 48) != 0xFF { tyreRearKpa = Double(FrameReader.u8(v, 48)) * 1.373 + 100 }
            tpmsWarnings = FrameReader.u8(v, 49) & 0x0F
        }
        let odo = v.count > 59 && present0(c, InfoConfig.ODOMETER)
            ? ((FrameReader.u8(v, 57) & 0x0F) << 16) | FrameReader.be16(v, 58) : -1
        if odo >= 0 && odo != 0xFFFFF && LogExt.current(v, 57, 6, c, InfoConfig.ODOMETER_VALID) { odometerKm = odo }
        let bars = v.count > 60 && hasInfo(c, InfoConfig.FUEL_GAUGE) ? FrameReader.u8(v, 60) & 0x0F : -1
        fuelBars = bars == 0x0F ? -1 : bars
        let mileage = v.count > 63 && present0(c, InfoConfig.AVG_MILEAGE)
            ? ((FrameReader.u8(v, 62) & 0x03) << 8) | FrameReader.u8(v, 63) : -1
        if mileage >= 0 && mileage != 0x3FF && LogExt.current(v, 57, 4, c, InfoConfig.AVG_MILEAGE_VALID) {
            avgMileage = Double(mileage) * 0.1
        }
        let meter = v.count > 64 && present0(c, InfoConfig.METER_BATTERY) ? FrameReader.u8(v, 64) : -1
        if meter >= 0 && meter != 0xFF && LogExt.current(v, 57, 5, c, InfoConfig.METER_BATTERY_VALID) {
            meterBatteryV = Double(meter) * 0.1
        }
        if v.count > 57 && zeroInfo(c, InfoConfig.ODOMETER_VALID) { odometerValid = (FrameReader.u8(v, 57) & 0x40) >> 6 }
        if v.count > 57 && zeroInfo(c, InfoConfig.METER_BATTERY_VALID) { meterBatteryValid = (FrameReader.u8(v, 57) & 0x20) >> 5 }
        if v.count > 57 && zeroInfo(c, InfoConfig.AVG_MILEAGE_VALID) { avgMileageValid = (FrameReader.u8(v, 57) & 0x10) >> 4 }

        self.totalDistanceKm = totalDistanceKm
        self.fuelRate = fuelRate
        self.waterC = waterC
        self.oilC = oilC
        self.intakeC = intakeC
        self.instantFuel = instantFuel
        self.tyreFrontKpa = tyreFrontKpa
        self.tyreRearKpa = tyreRearKpa
        self.odometerKm = odometerKm
        self.fuelBars = fuelBars
        self.avgMileage = avgMileage
        self.meterBatteryV = meterBatteryV
        self.odometerValid = odometerValid
        self.meterBatteryValid = meterBatteryValid
        self.avgMileageValid = avgMileageValid
        self.instantFuelValid = instantFuelValid
        self.tpmsWarnings = tpmsWarnings
        super.init(v)
    }

    private static func current(_ v: [UInt8], _ i: Int, _ bit: Int, _ c: InfoConfig?, _ f: Flag) -> Bool {
        if !zeroInfo(c, f) { return true }
        return v.count > i && (FrameReader.u8(v, i) & (1 << bit)) == 0
    }

    private static func temp(_ v: [UInt8], _ i: Int, _ offset: Int, _ c: InfoConfig?, _ f: Flag) -> Double? {
        guard inBlock(v, i), c != nil, c!.supported(f),
              FrameReader.u8(v, i) != 0xFF, FrameReader.u8(v, i) != 0 else { return nil }
        return Double(FrameReader.u8(v, i) - offset)
    }
}

/// 0x4A: live riding data (speed, rpm, gear, throttle, lean…), streamed by the meter.
public final class Telemetry: Frame {
    public let speedKmh: Double?
    public let speedKmhAlt: Double?
    public let rpm: Int
    public let rpmAlt: Int
    public let gear: Int
    public let throttlePct: Double?
    public let fuelInjection: Double?
    public let accelG: Double?
    public let leanDeg: Double?
    public let wheelie: Int
    public let wheelieDeg: Double?
    public let tcsHigh: Int
    public let tcsLow: Int
    public let brakeFrontBar: Double?
    public let abs: Int
    public let riderTorque: Int
    public let engineTorqueRequest: Int
    public let engineTorque: Int
    public let brakeFrontMaster: Int
    public let brakeRearMaster: Int
    public let brakeRearCaliper: Int
    public let absTarget: Int
    public let absIndicator: Int
    public let absSwitching: Int
    public let damping: Int
    public let suspCalibration: Int
    public let suspStatus: Int
    public let suspEcu: Int
    public let cruiseOn: Int
    public let cruiseMode: Int
    public let wheelSpeedSetting: Int

    init(_ v: [UInt8], _ c: InfoConfig?) {
        var speedKmh: Double?; var speedKmhAlt: Double?; var throttlePct: Double?
        var fuelInjection: Double?; var accelG: Double?; var leanDeg: Double?
        var wheelieDeg: Double?; var brakeFrontBar: Double?
        var rpm = -1; var rpmAlt = -1; var gear = -1; var wheelie = -1
        var tcsHigh = -1; var tcsLow = -1; var abs = -1
        var riderTorque = -1; var engineTorqueRequest = -1; var engineTorque = -1
        var brakeFrontMaster = -1; var brakeRearMaster = -1; var brakeRearCaliper = -1
        var absTarget = -1; var absIndicator = -1; var absSwitching = -1
        var damping = -1; var suspCalibration = -1; var suspStatus = -1; var suspEcu = -1
        var cruiseOn = -1; var cruiseMode = -1; var wheelSpeedSetting = -1

        let blk1 = Telemetry.fullBlock(v, 5)
        let blk2 = Telemetry.fullBlock(v, 15)

        let speedMode = Telemetry.mode(c, InfoConfig.WHEEL_SPEED)
        if blk1 && speedMode >= 0 {
            let raw9 = Double(((FrameReader.u8(v, 9) & 0x01) << 8) | FrameReader.u8(v, 10))
            let scaled = Double(FrameReader.be16(v, 9)) * 0.01220703125
            if speedMode == 1 { speedKmh = raw9; speedKmhAlt = scaled }
            else { speedKmh = scaled; speedKmhAlt = raw9 }
        }

        let rpmMode = Telemetry.mode(c, InfoConfig.ENGINE_SPEED)
        if blk1 && rpmMode >= 0 {
            let raw15 = ((FrameReader.u8(v, 11) & 0x7F) << 8) | FrameReader.u8(v, 12)
            let quarter = FrameReader.be16(v, 11) / 4
            if rpmMode == 1 { rpm = quarter; rpmAlt = raw15 }
            else { rpm = raw15; rpmAlt = quarter }
        }

        let gearByte = blk1 ? FrameReader.u8(v, 13) : 0xFF
        if gearByte != 0xFF && (gearByte & 0x0F) != 0x0F && hasInfo(c, InfoConfig.GEAR) { gear = gearByte & 0x0F }

        let thrMode = Telemetry.mode(c, InfoConfig.THROTTLE)
        if blk1 && thrMode == 1 {
            throttlePct = Double(FrameReader.u8(v, 14)) * 0.3921568627
        } else if blk1 && thrMode == 0 && FrameReader.u8(v, 14) <= 128 {
            throttlePct = Double(FrameReader.u8(v, 14)) * 0.78125
        }

        let fiMode = Telemetry.mode(c, InfoConfig.FUEL_INJECTION)
        if blk1 && fiMode >= 0 {
            fuelInjection = Double(FrameReader.be16(v, 7)) * 1e-4 * (fiMode == 1 ? 100.0 / 140.0 : 1)
        }

        let accMode = Telemetry.mode(c, InfoConfig.ACCELERATION)
        if blk2 && accMode >= 0 && (FrameReader.u8(v, 17) != 0xFF || FrameReader.u8(v, 18) != 0xFF) {
            let rawAcc = Double(((FrameReader.u8(v, 17) & 0x01) << 8) | FrameReader.u8(v, 18)) * 0.01
            accelG = rawAcc - (accMode == 1 ? 0 : 2.0)
        }

        let leanMode = Telemetry.mode(c, InfoConfig.LEAN)
        if blk2 && leanMode >= 0 && (FrameReader.u8(v, 19) != 0xFF || FrameReader.u8(v, 20) != 0xFF) {
            if leanMode == 1 {
                leanDeg = Double(((FrameReader.u8(v, 19) & 0x0F) << 8) | FrameReader.u8(v, 20)) * 0.1
            } else {
                leanDeg = Double(((FrameReader.u8(v, 19) & 0x07) << 8) | FrameReader.u8(v, 20)) * 0.1953125 - 100.0
            }
        }

        let wheelieBits = blk2 ? FrameReader.u8(v, 21) : 0xFF
        if wheelieBits != 0xFF && (wheelieBits & 0x03) != 0x03 && present0(c, InfoConfig.WHEELIE) {
            wheelie = wheelieBits & 0x03
        }

        let whMode = Telemetry.mode(c, InfoConfig.WHEELIE_ANGLE)
        if blk2 && whMode >= 0 && (FrameReader.u8(v, 22) != 0xFF || FrameReader.u8(v, 23) != 0xFF) {
            wheelieDeg = Double(((FrameReader.u8(v, 22) & (whMode == 1 ? 0x0F : 0x07)) << 8) | FrameReader.u8(v, 23))
                * (whMode == 1 ? 0.1 : 0.09765625)
        }

        let tcsByte = blk2 && v.count > 24 ? FrameReader.u8(v, 24) : 0xFF
        if tcsByte != 0xFF && present0(c, InfoConfig.TCS_HB) { tcsHigh = (tcsByte & 0xF0) >> 4 }
        if tcsByte != 0xFF && present0(c, InfoConfig.TCS_LB) { tcsLow = tcsByte & 0x0F }

        let absPresent = v.count > 37 && Telemetry.blockOk(v, 35)
        if absPresent && FrameReader.u8(v, 37) != 0xFF { abs = FrameReader.u8(v, 37) }
        if absPresent && v.count > 39 && FrameReader.u8(v, 39) != 0xFF {
            brakeFrontBar = Double(FrameReader.u8(v, 39)) * 0.1953125
        }
        brakeFrontMaster = Telemetry.pressure(v, 38, absPresent)
        brakeRearMaster = Telemetry.pressure(v, 40, absPresent)
        brakeRearCaliper = Telemetry.pressure(v, 41, absPresent)

        let blk3 = v.count > 32 && Telemetry.blockOk(v, 25)
        riderTorque = Telemetry.torque(v, 27, blk3, Telemetry.mode(c, InfoConfig.RIDER_TORQUE))
        engineTorqueRequest = Telemetry.torque(v, 29, blk3, Telemetry.mode(c, InfoConfig.ENGINE_TORQUE_REQUEST))
        engineTorque = Telemetry.torque(v, 31, blk3, Telemetry.mode(c, InfoConfig.ENGINE_TORQUE))

        let blk5 = v.count > 48 && Telemetry.blockOk(v, 45)
        if blk5 && FrameReader.u8(v, 47) != 0xFF {
            absTarget = (FrameReader.u8(v, 47) & 0xE0) >> 5
            absIndicator = FrameReader.u8(v, 47) & 0x07
        }
        if blk5 && FrameReader.u8(v, 48) != 0xFF { absSwitching = FrameReader.u8(v, 48) & 0x01 }

        let blk8 = v.count > 78 && Telemetry.blockOk(v, 75)
        if blk8 && FrameReader.u8(v, 77) != 0xFF { damping = FrameReader.u8(v, 77) }
        let suspBits = blk8 ? FrameReader.u8(v, 78) : 0xFF
        if suspBits != 0xFF {
            suspCalibration = (suspBits & 0x04) >> 2
            suspStatus = (suspBits & 0x02) >> 1
            suspEcu = suspBits & 0x01
        }

        let blk9 = v.count > 87 && Telemetry.blockOk(v, 85)
        let cruise = blk9 ? FrameReader.u8(v, 87) : 0xFF
        if cruise != 0xFF {
            cruiseOn = (cruise & 0x02) >> 1
            cruiseMode = cruise & 0x01
        }
        if blk9 && v.count > 88 && FrameReader.u8(v, 88) != 0xFF { wheelSpeedSetting = FrameReader.u8(v, 88) }

        self.speedKmh = speedKmh; self.speedKmhAlt = speedKmhAlt
        self.rpm = rpm; self.rpmAlt = rpmAlt
        self.gear = gear; self.throttlePct = throttlePct
        self.fuelInjection = fuelInjection; self.accelG = accelG
        self.leanDeg = leanDeg; self.wheelie = wheelie; self.wheelieDeg = wheelieDeg
        self.tcsHigh = tcsHigh; self.tcsLow = tcsLow
        self.brakeFrontBar = brakeFrontBar; self.abs = abs
        self.riderTorque = riderTorque; self.engineTorqueRequest = engineTorqueRequest
        self.engineTorque = engineTorque
        self.brakeFrontMaster = brakeFrontMaster; self.brakeRearMaster = brakeRearMaster
        self.brakeRearCaliper = brakeRearCaliper
        self.absTarget = absTarget; self.absIndicator = absIndicator; self.absSwitching = absSwitching
        self.damping = damping; self.suspCalibration = suspCalibration
        self.suspStatus = suspStatus; self.suspEcu = suspEcu
        self.cruiseOn = cruiseOn; self.cruiseMode = cruiseMode
        self.wheelSpeedSetting = wheelSpeedSetting
        super.init(v)
    }

    private static func pressure(_ v: [UInt8], _ i: Int, _ block: Bool) -> Int {
        guard block, v.count > i, FrameReader.u8(v, i) != 0xFF else { return -1 }
        return FrameReader.u8(v, i)
    }

    private static func torque(_ v: [UInt8], _ i: Int, _ block: Bool, _ mode: Int) -> Int {
        if !block || mode < 0 || (FrameReader.u8(v, i) == 0xFF && FrameReader.u8(v, i + 1) == 0xFF) { return -1 }
        if mode == 1 { return ((FrameReader.u8(v, i) & 0x0F) << 8) | FrameReader.u8(v, i + 1) }
        return Int(Double((FrameReader.u8(v, i) & 0x3F) << 8 | FrameReader.u8(v, i + 1)) * 0.2)
    }

    private static func fullBlock(_ v: [UInt8], _ offset: Int) -> Bool {
        blockOk(v, offset) && v.count >= offset + 9
    }

    private static func blockOk(_ v: [UInt8], _ offset: Int) -> Bool {
        v.count > offset + 1 && FrameReader.u8(v, offset) != 0xFF && FrameReader.u8(v, offset + 1) != 0xFF
    }

    private static func mode(_ c: InfoConfig?, _ f: Flag) -> Int {
        let x = c == nil ? -1 : c!.flag(f)
        return x >= 0 && x <= 1 ? x : -1
    }
}

/// 0x4B: suspension stroke and IMU axes (all FF on bikes without them).
public final class ImuSusp: Frame {
    public let rearStrokeMm: Double?
    public let frontStrokeMm: Double?
    public let rearStrokeSpeed: Double?
    public let frontStrokeSpeed: Double?
    public let axG: Double?
    public let ayG: Double?
    public let azG: Double?
    public let rate1: Double?
    public let rate2: Double?
    public let rate3: Double?
    public let frontWheelKmh: Double?
    public let rearWheelKmh: Double?
    public let tcsLevelHigh: Int
    public let tcsLevelLow: Int
    public let kqsDown: Int
    public let kqsUp: Int
    public let wheelieFlag: Int
    public let rawX: Double?
    public let rawY: Double?
    public let rawZ: Double?
    public let longitudinalG: Double?
    public let verticalG: Double?
    public let lateralG: Double?

    init(_ v: [UInt8]) {
        var rearStrokeMm: Double?; var frontStrokeMm: Double?
        var rearStrokeSpeed: Double?; var frontStrokeSpeed: Double?
        var axG: Double?; var ayG: Double?; var azG: Double?
        var rate1: Double?; var rate2: Double?; var rate3: Double?
        var frontWheelKmh: Double?; var rearWheelKmh: Double?
        var tcsLevelHigh = -1; var tcsLevelLow = -1; var kqsDown = -1; var kqsUp = -1; var wheelieFlag = -1
        var longitudinalG: Double?; var verticalG: Double?; var lateralG: Double?
        var rawX: Double?; var rawY: Double?; var rawZ: Double?

        let susp = ImuSusp.present(v, 5, 6, 14)
        if susp {
            rearStrokeMm = Double(FrameReader.be16(v, 7)) * 0.015625
            frontStrokeMm = Double(FrameReader.be16(v, 9)) * 0.015625
            rearStrokeSpeed = Double(FrameReader.be16(v, 11)) * 0.001
            frontStrokeSpeed = Double(FrameReader.be16(v, 13)) * 0.001
        }
        ayG = ImuSusp.axis(v, 15, 16, 22, 21)
        axG = ImuSusp.axis(v, 25, 26, 32, 31)
        azG = ImuSusp.axis(v, 35, 36, 42, 41)
        rawX = axG; rawY = ayG; rawZ = azG
        if let x = axG, let y = ayG {
            longitudinalG = ImuSusp.longitudinal(x, y)
            verticalG = ImuSusp.vertical(x, y)
        }
        if let z = azG { lateralG = ImuSusp.lateral(z) }
        rate1 = ImuSusp.rate(v, 15, 16, 18, 17)
        rate2 = ImuSusp.rate(v, 25, 26, 28, 27)
        rate3 = ImuSusp.rate(v, 35, 36, 38, 37)

        let blk5 = v.count > 46 && !(FrameReader.u8(v, 45) == 0xFF && FrameReader.u8(v, 46) == 0xFF)
        let wheels = blk5 && (FrameReader.u8(v, 47) != 0xFF || FrameReader.u8(v, 48) != 0xFF)
        if wheels && v.count > 48 { frontWheelKmh = Double(FrameReader.be16(v, 47)) * 400.0 / 32768.0 }
        if wheels && v.count > 50 && (FrameReader.u8(v, 49) != 0xFF || FrameReader.u8(v, 50) != 0xFF) {
            rearWheelKmh = Double(FrameReader.be16(v, 49)) * 400.0 / 32768.0
        }
        let flags = blk5 && v.count > 51 ? FrameReader.u8(v, 51) : 0xFF
        if flags != 0xFF {
            tcsLevelHigh = (flags & 0xE0) >> 5
            tcsLevelLow = (flags & 0x1C) >> 2
            kqsDown = (flags & 0x02) >> 1
            kqsUp = flags & 0x01
        }
        if blk5 && v.count > 52 && FrameReader.u8(v, 52) != 0xFF { wheelieFlag = FrameReader.u8(v, 52) & 0x01 }

        self.rearStrokeMm = rearStrokeMm; self.frontStrokeMm = frontStrokeMm
        self.rearStrokeSpeed = rearStrokeSpeed; self.frontStrokeSpeed = frontStrokeSpeed
        self.axG = axG; self.ayG = ayG; self.azG = azG
        self.rate1 = rate1; self.rate2 = rate2; self.rate3 = rate3
        self.frontWheelKmh = frontWheelKmh; self.rearWheelKmh = rearWheelKmh
        self.tcsLevelHigh = tcsLevelHigh; self.tcsLevelLow = tcsLevelLow
        self.kqsDown = kqsDown; self.kqsUp = kqsUp; self.wheelieFlag = wheelieFlag
        self.longitudinalG = longitudinalG; self.verticalG = verticalG; self.lateralG = lateralG
        self.rawX = rawX; self.rawY = rawY; self.rawZ = rawZ
        super.init(v)
    }

    private static let sin45 = sqrt(0.5)
    public static func longitudinal(_ x: Double, _ y: Double) -> Double { (x - y) * sin45 }
    public static func vertical(_ x: Double, _ y: Double) -> Double { -(x + y) * sin45 }
    public static func lateral(_ z: Double) -> Double { z }

    private static func rate(_ v: [UInt8], _ a: Int, _ b: Int, _ hi: Int, _ lo: Int) -> Double? {
        guard present(v, a, b, max(hi, lo)) else { return nil }
        let x = FrameReader.u8(v, hi) << 8 | FrameReader.u8(v, lo)
        return x == 0 ? nil : Double(x) * 163.84 / 32768.0 - 163.84
    }

    private static func present(_ v: [UInt8], _ a: Int, _ b: Int, _ last: Int) -> Bool {
        v.count > last && FrameReader.u8(v, a) != 0xFF && FrameReader.u8(v, b) != 0xFF
    }

    private static func axis(_ v: [UInt8], _ a: Int, _ b: Int, _ hi: Int, _ lo: Int) -> Double? {
        guard present(v, a, b, max(hi, lo)) else { return nil }
        let x = FrameReader.u8(v, hi) << 8 | FrameReader.u8(v, lo)
        return x == 0 ? nil : Double(x) * 4.1768 / 32768.0 - 4.1768
    }
}

// MARK: - settings

/// 0x1B: meter clock and shift lamp, answer to the general settings read (block 0x0A).
public final class GeneralSettings: Frame {
    public let result: Int
    public let shiftLampStatus: Int
    public let shiftLampLevel: Int
    public let day: Int
    public let month: Int
    public let year: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    init(_ v: [UInt8], _ caps: GeneralCaps?) {
        var result = -1; var shiftLampStatus = -1; var shiftLampLevel = -1
        var day = -1; var month = -1; var year = -1; var hour = -1; var minute = -1; var second = -1
        let b = FrameReader.blockPresent(v, 5) && v.count >= 15
        if b { result = FrameReader.u8(v, 7) }
        let shift = b ? FrameReader.u8(v, 8) : 0xFF
        let lamp = shift != 0xFF && (caps == nil || caps!.shiftLampSettable)
        if lamp {
            shiftLampStatus = (shift >> 6) & 3
            let level = shift & 0x3F
            if level >= 1 && level <= 61 { shiftLampLevel = level }
        }
        day = GeneralSettings.field(b, v, 9, 0x3F, 1, 31, caps, 0)
        month = GeneralSettings.field(b, v, 10, 0x0F, 1, 12, caps, 1)
        let y = b ? FrameReader.u8(v, 11) : 0xFF
        if y != 0xFF && (caps == nil || caps!.clockSettable[2]) { year = 2000 + y }
        hour = GeneralSettings.field(b, v, 12, 0x1F, 0, 23, caps, 3)
        minute = GeneralSettings.field(b, v, 13, 0x3F, 0, 59, caps, 4)
        second = GeneralSettings.field(b, v, 14, 0x3F, 0, 59, caps, 5)
        self.result = result
        self.shiftLampStatus = shiftLampStatus
        self.shiftLampLevel = shiftLampLevel
        self.day = day
        self.month = month
        self.year = year
        self.hour = hour
        self.minute = minute
        self.second = second
        super.init(v)
    }

    private static func field(_ b: Bool, _ v: [UInt8], _ i: Int, _ mask: Int, _ min: Int, _ max: Int,
                              _ caps: GeneralCaps?, _ clockField: Int) -> Int {
        guard b, (caps == nil || caps!.clockSettable[clockField]) else { return -1 }
        let x = FrameReader.u8(v, i) & mask
        return x >= min && x <= max ? x : -1
    }

    public func shiftLampRpm() -> Int {
        shiftLampLevel < 0 ? -1 : (shiftLampLevel - 1) * 250 + 3000
    }
}

/// 0x48: the bike's ride settings (block 0x09).
public final class VehicleSettings: Frame {
    public let meterCapability: Int
    public let ecuCapability: Int
    public let ktrc: Int
    public let ridingMode: Int
    public let kqs: Int
    public let kebc: Int
    public let power: Int
    public let kecsPreload: Int
    public let kecsMode: Int
    public let kecsLoad: Int
    public let kecsFrontCom: Int
    public let kecsFrontTen: Int
    public let kecsRearCom: Int
    public let kecsRearTen: Int

    init(_ v: [UInt8], _ t: TuningConfig?) {
        var meterCapability = -1; var ecuCapability = -1
        var ktrc = -1; var ridingMode = -1; var kqs = -1; var kebc = -1; var power = -1
        var kecsPreload = -1; var kecsMode = -1; var kecsLoad = -1
        var kecsFrontCom = -1; var kecsFrontTen = -1; var kecsRearCom = -1; var kecsRearTen = -1
        let ok = v.count >= 20
        if ok && hasTuning(t, TuningConfig.METER) && FrameReader.u8(v, 7) != 0xFF { meterCapability = FrameReader.u8(v, 7) }
        if ok && hasTuning(t, TuningConfig.ECU) && FrameReader.u8(v, 17) != 0xFF { ecuCapability = FrameReader.u8(v, 17) }
        let b18 = ok && FrameReader.u8(v, 18) != 0xFF
        if b18 && hasTuning(t, TuningConfig.KTRC) { ktrc = (FrameReader.u8(v, 18) & 0x78) >> 3 }
        if b18 && hasTuning(t, TuningConfig.RIDING_MODE) { ridingMode = FrameReader.u8(v, 18) & 0x07 }
        let b19 = ok && FrameReader.u8(v, 19) != 0xFF
        if b19 && hasTuning(t, TuningConfig.KQS) { kqs = (FrameReader.u8(v, 19) & 0x60) >> 5 }
        if b19 && hasTuning(t, TuningConfig.KEBC) { kebc = (FrameReader.u8(v, 19) & 0x0C) >> 2 }
        if b19 && hasTuning(t, TuningConfig.POWER) { power = FrameReader.u8(v, 19) & 0x03 }
        let b10 = ok && FrameReader.u8(v, 10) != 0xFF
        if b10 && hasTuning(t, TuningConfig.KECS_PRELOAD) { kecsPreload = (FrameReader.u8(v, 10) & 0x38) >> 3 }
        if b10 && hasTuning(t, TuningConfig.KECS_MODE) { kecsMode = FrameReader.u8(v, 10) & 0x07 }
        if ok && FrameReader.u8(v, 11) != 0xFF && hasTuning(t, TuningConfig.KECS_LOAD) { kecsLoad = FrameReader.u8(v, 11) & 0x0F }
        let b12 = ok && FrameReader.u8(v, 12) != 0xFF
        if b12 && hasTuning(t, TuningConfig.KECS_FR_COM) { kecsFrontCom = (FrameReader.u8(v, 12) & 0xF0) >> 4 }
        if b12 && hasTuning(t, TuningConfig.KECS_FR_TEN) { kecsFrontTen = FrameReader.u8(v, 12) & 0x0F }
        let b13 = ok && FrameReader.u8(v, 13) != 0xFF
        if b13 && hasTuning(t, TuningConfig.KECS_RR_COM) { kecsRearCom = (FrameReader.u8(v, 13) & 0xF0) >> 4 }
        if b13 && hasTuning(t, TuningConfig.KECS_RR_TEN) { kecsRearTen = FrameReader.u8(v, 13) & 0x0F }
        self.meterCapability = meterCapability
        self.ecuCapability = ecuCapability
        self.ktrc = ktrc
        self.ridingMode = ridingMode
        self.kqs = kqs
        self.kebc = kebc
        self.power = power
        self.kecsPreload = kecsPreload
        self.kecsMode = kecsMode
        self.kecsLoad = kecsLoad
        self.kecsFrontCom = kecsFrontCom
        self.kecsFrontTen = kecsFrontTen
        self.kecsRearCom = kecsRearCom
        self.kecsRearTen = kecsRearTen
        super.init(v)
    }
}

// MARK: - maintenance

/// 0x1D: which maintenance reminders the meter keeps (Ble5Value.u).
public final class ServiceConfig: Frame {
    private static let layout: [[Int]] = [
        [7, 0xC0, 8, 0xC0, 8, 0x30, 8, 0x0C, 8, 0x03, 9, 0x30],
        [7, 0x30, 9, 0x0C, 9, 0x03, 10, 0xC0, 10, 0x30, 10, 0x03],
        [7, 0x0C, 11, 0xC0, 11, 0x30, 11, 0x0C, 11, 0x03, 12, 0x30],
    ]
    public static let capability = 0, notify = 1, month = 2, day = 3, year = 4, distance = 5
    public let valid: Bool

    init(_ v: [UInt8]) {
        valid = v.count >= 15 && FrameReader.blockPresent(v, 5)
        super.init(v)
    }

    public func has(_ which: Int, _ field: Int) -> Bool {
        let l = ServiceConfig.layout[which]
        let x = FrameReader.bits(raw, l[field * 2], l[field * 2 + 1])
        return field == ServiceConfig.capability ? (x == 0 || x == 1) : x == 0
    }

    public func supported(_ which: Int) -> Bool {
        for f in 0...ServiceConfig.distance where !has(which, f) { return false }
        return true
    }
}

/// 0x1E: the maintenance reminders: Kawasaki service, the rider's own, oil change.
public final class ServiceIndicator: Frame {
    public static let kawasaki = 0, rider = 1, oil = 2
    public static let names = ["Kawasaki service", "Rider setting", "Oil change"]

    public final class Reminder {
        public let supported: Bool
        public let notify: Int
        public let day: Int
        public let month: Int
        public let year: Int
        public let distanceKm: Int

        init(_ v: [UInt8], _ base: Int, _ c: ServiceConfig?, _ which: Int) {
            let cfg = (c != nil && c!.valid) ? c : nil
            let b = FrameReader.blockPresent(v, base - 2) && v.count > base + 7
            supported = b && (cfg == nil || cfg!.has(which, ServiceConfig.capability))
            let n = b ? FrameReader.u8(v, base + 1) : 0xFF
            var notify = -1
            if n != 0xFF && Reminder.field(cfg, which, ServiceConfig.notify) { notify = n >> 4 }
            let m = n & 0x0F
            var month = -1
            if b && m >= 1 && m <= 12 && Reminder.field(cfg, which, ServiceConfig.month) { month = m }
            let d = b ? FrameReader.u8(v, base + 2) & 0x3F : 0
            var day = -1
            if d >= 1 && d <= 31 && Reminder.field(cfg, which, ServiceConfig.day) { day = d }
            let y = b ? FrameReader.u8(v, base + 3) : 0xFF
            var year = -1
            if y != 0xFF && Reminder.field(cfg, which, ServiceConfig.year) { year = 2000 + (y & 0x7F) }
            var distanceKm = -1
            if b && FrameReader.u8(v, base + 5) != 0xFF && Reminder.field(cfg, which, ServiceConfig.distance) {
                distanceKm = (FrameReader.u8(v, base + 5) & 0x0F) << 16 | FrameReader.be16(v, base + 6)
            }
            self.notify = notify
            self.month = month
            self.day = day
            self.year = year
            self.distanceKm = distanceKm
        }

        private static func field(_ cfg: ServiceConfig?, _ which: Int, _ field: Int) -> Bool {
            cfg == nil || cfg!.has(which, field)
        }

        public func hasDate() -> Bool {
            year > 0 && month > 0 && day > 0
        }
    }

    public let reminders: [Reminder?]

    init(_ v: [UInt8], _ c: ServiceConfig?) {
        var r = [Reminder?](repeating: nil, count: 3)
        for i in 0..<3 { r[i] = Reminder(v, 7 + i * 10, c, i) }
        self.reminders = r
        super.init(v)
    }
}

// MARK: - decoder

/// Decodes the frames of one connection. Remembers the config frames since they decide which values are real.
public final class Decoder {
    public var info: InfoConfig?
    public var tuning: TuningConfig?
    public var service: ServiceConfig?
    public var caps: GeneralCaps?
    private var shortFrameLogged = false

    /// The decoded frame, or a plain Frame for types not decoded; nil for empty/short frames.
    public func decode(_ v: [UInt8]) -> Frame? {
        if v.isEmpty { return nil }
        let type = Int(v[0])
        if (type == BikeFrames.ridingLog || type == BikeFrames.ridingLogHigh) && v.count >= 2
            && v.count < Int(v[1]) + 3 {
            if !shortFrameLogged {
                shortFrameLogged = true
                print("Bike: dropping short " + BikeFrames.name(type) + " frames (" + v.count
                    + " of " + (Int(v[1]) + 3) + " bytes): the values were never sent")
            }
            return nil
        }
        switch type {
        case BikeFrames.ack: return Ack(v)
        case BikeFrames.status: return Status(v)
        case BikeFrames.modelInfo: return ModelInfo(v)
        case BikeFrames.generalCaps:
            let f = GeneralCaps(v); caps = f; return f
        case BikeFrames.generalSettings: return GeneralSettings(v, caps)
        case BikeFrames.infoConfig:
            let f = InfoConfig(v); info = f; return f
        case BikeFrames.tuningConfig:
            let f = TuningConfig(v); tuning = f; return f
        case BikeFrames.serviceConfig:
            let f = ServiceConfig(v); service = f; return f
        case BikeFrames.vehicleInfo: return VehicleInfo(v, info)
        case BikeFrames.ridingLogExt: return LogExt(v, info)
        case BikeFrames.ridingLog: return Telemetry(v, info)
        case BikeFrames.ridingLogHigh: return ImuSusp(v)
        case BikeFrames.vehicleSettings: return VehicleSettings(v, tuning)
        case BikeFrames.serviceIndicator: return ServiceIndicator(v, service)
        default: return Frame(v)
        }
    }
}
