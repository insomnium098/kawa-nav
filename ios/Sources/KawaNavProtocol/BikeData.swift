//
//  BikeData.swift
//
//  What KawaNav knows about the bike: the last frame of each kind the meter sent and when.
//  Filled by the bridge, read by the UI and the ride recorder.
//
//  Ported from KawaNav (Darthbob/kawa-nav), BikeData.java.
//

import Foundation

public struct Place {
    public let lat: Double
    public let lon: Double
    public let accuracyM: Double
    public let at: Int64
    public init(lat: Double, lon: Double, accuracyM: Double, at: Int64) {
        self.lat = lat
        self.lon = lon
        self.accuracyM = accuracyM
        self.at = at
    }
}

public final class BikeData {
    public var model: ModelInfo?
    public var caps: GeneralCaps?
    public var infoConfig: InfoConfig?
    public var tuning: TuningConfig?
    public var serviceConfig: ServiceConfig?
    public var info: VehicleInfo?
    public var ext: LogExt?
    public var live: Telemetry?
    public var imu: ImuSusp?
    public var general: GeneralSettings?
    public var settings: VehicleSettings?
    public var service: ServiceIndicator?

    public var infoAt: Int64 = 0
    public var extAt: Int64 = 0
    public var liveAt: Int64 = 0
    public var imuAt: Int64 = 0
    public var settingsAt: Int64 = 0
    public var serviceAt: Int64 = 0
    public var generalAt: Int64 = 0

    /// Where the phone was when the link to the bike was lost, or nil.
    public var parked: Place?

    // Debug: frames received per type since connecting, the last one and when.
    public var count = [Int](repeating: 0, count: 256)
    public var last: [[UInt8]?](repeating: nil, count: 256)
    public var lastAt = [Int64](repeating: 0, count: 256)
    public var since: Int64 = 0

    public init() {}

    public func apply(_ f: Frame, _ now: Int64) {
        let id = f.id
        if count[id] == 0 && since == 0 { since = now }
        count[id] += 1
        last[id] = f.raw
        lastAt[id] = now

        if let m = f as? ModelInfo { if let modelStr = m.model { model = m } }
        else if let g = f as? GeneralCaps { caps = g }
        else if let i = f as? InfoConfig { infoConfig = i }
        else if let t = f as? TuningConfig { tuning = t }
        else if let s = f as? ServiceConfig { serviceConfig = s }
        else if let vi = f as? VehicleInfo { info = vi; infoAt = now }
        else if let le = f as? LogExt { ext = le; extAt = now }
        else if let tl = f as? Telemetry { live = tl; liveAt = now }
        else if let im = f as? ImuSusp { imu = im; imuAt = now }
        else if let gs = f as? GeneralSettings { if gs.result >= 0 { general = gs; generalAt = now } }
        else if let vs = f as? VehicleSettings { settings = vs; settingsAt = now }
        else if let si = f as? ServiceIndicator { service = si; serviceAt = now }
    }

    /// A new connection: the per-connection counters start again; the last values stay.
    public func connected() {
        count = [Int](repeating: 0, count: 256)
        since = 0
    }

    /// The VIN with all but the last 6 characters hidden, for logs (users share them).
    public static func maskedVin(_ vin: String?) -> String {
        guard let vin = vin else { return "–" }
        return vin.count <= 6 ? vin : "…" + vin.suffix(6)
    }
}
