//
//  BikeBridge.swift
//
//  The controller that ties the BLE link, the request queue and the decoder together and exposes
//  the bike's live data to the UI. This is the top layer of the iOS port: everything below it
//  (KawaBleManager, BikeRequests, BikeFrames, KawaProtocol) is platform-neutral and unit-testable.
//
//  Ported from KawaNav (Darthbob/kawa-nav), BridgeService.java + Hub.java (condensed for iOS).
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

#if canImport(CoreBluetooth)
public final class BikeBridge: ObservableObject {

    @Published public var logText: [String] = []
    @Published public var ready = false
    @Published public var scanning = false
    @Published public var foundPeripheral: CBPeripheral?
    @Published public var bike: BikeData = BikeData()
    @Published public var connectionMessage: String?

    private let ble: KawaBleManager
    private var requests: BikeRequests?
    private let decoder = Decoder()
    private var logLimit = 400

    public init() {
        ble = KawaBleManager()
        wireCallbacks()
    }

    private func wireCallbacks() {
        ble.callbacks.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.appendLog(line) }
        }
        ble.callbacks.onStateChanged = { [weak self] r in
            DispatchQueue.main.async {
                self?.ready = r
                if r {
                    self?.startRequests()
                } else {
                    self?.requests?.clear()
                    self?.connectionMessage = "Link lost — reconnecting…"
                }
            }
        }
        ble.callbacks.onLinkLost = { [weak self] in
            DispatchQueue.main.async {
                self?.ready = false
                self?.requests?.clear()
                self?.connectionMessage = "Link lost"
            }
        }
        ble.callbacks.onNotify = { [weak self] _, value in
            self?.handleFrame(value)
        }
    }

    private func appendLog(_ line: String) {
        logText.append(line)
        if logText.count > logLimit {
            logText.removeFirst(logText.count - logLimit)
        }
    }

    // MARK: - Scan & connect

    public func startScan() {
        scanning = true
        connectionMessage = "Scanning…"
        ble.scan { [weak self] p in
            DispatchQueue.main.async {
                self?.scanning = false
                self?.foundPeripheral = p
                self?.connectionMessage = "Found \(p.name ?? "bike") — connecting…"
                self?.ble.connect(p, autoConnect: true)
            }
        }
    }

    /// Connects to a peripheral the user picked (e.g. from a remembered list).
    public func connect(_ p: CBPeripheral) {
        ble.connect(p, autoConnect: true)
    }

    /// (Re)starts the request queue against the live link, then runs the connect sequence
    /// (the same one Rideology runs). Called every time the link becomes ready, so a
    /// reconnection with autoConnect recovers by itself.
    private func startRequests() {
        let io = BleIo(ble: ble)
        requests = BikeRequests(io: io)
        bike.connected()
        appendLog("Link ready — starting connect sequence")
        startupSequence()
    }

    /// A frame from the meter: completes the running request if it answers it, then decodes
    /// for the UI.
    fileprivate func handleFrame(_ value: [UInt8]) {
        requests?.onFrame(value)
        if let f = decoder.decode(value) {
            bike.apply(f, now: nowMs())
        }
    }

    /// Runs the connect sequence once the link is ready. Wired from the state change.
    public func startupSequence() {
        guard let requests = requests else { return }
        let model = phoneModelName()
        let frames = KawaProtocol.startup(level: KawaProtocol.initRead, phoneModel: model, askExt: true)
        for (i, frame) in frames.enumerated() {
            let label = "frame \(i): " + BikeFrames.name(Int(frame[0]))
            let req = BikeRequests.Request(frame, label, .dataOrAck, .startup,
                BikeRequests.ClosureDone { [weak self] r, ok, result in
                    self?.appendLog("Startup \(i) \(r.label): " + (ok ? "ok" : "no answer")
                        + (result == 1 ? " (rejected)" : ""))
                })
            requests.submit(req)
        }
    }

    private func phoneModelName() -> String {
        #if os(iOS)
        // The meter shows the phone's kind; we send a short device descriptor.
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion)." + String(v.minorVersion)
        #else
        return "macOS"
        #endif
    }

    // MARK: - Dash frames (send to the meter)

    /// Send a turn-by-turn frame to the dash.
    public func sendTurn(turn: Int, distance: Int, unit: Int = 1) {
        let name = (turn >= 0 && turn < KawaProtocol.turnNames.count) ? KawaProtocol.turnNames[turn] : "?"
        ble.write(KawaProtocol.naviFrame(flag: 0, turn: turn, unit: unit, distance: distance),
                  "turn \(name) \(distance)")
    }

    /// Tell the dash navigation has ended.
    public func sendClear() {
        ble.write(KawaProtocol.clearFrame(), "clear nav")
    }

    /// Send the status-icon frame (battery, voice, headset, riding log) every few seconds.
    public func sendIndication(batteryPct: Double, charging: Bool, headset: Bool, ridingLog: Bool) {
        let bat = KawaProtocol.batteryLevel(batteryPct, charging: charging)
        let frame = KawaProtocol.meterIndicationFrame(battery: bat, voice: 0,
            headset: headset ? 1 : 0, ridingLog: ridingLog ? 1 : 0)
        ble.write(frame, "status icons")
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// The `BikeRequests.Io` that routes sends to the real BLE link and schedules work on the main
/// queue. Each `ScheduledWork` maps to a fresh DispatchWorkItem; scheduling one revives it.
private final class BleIo: BikeRequests.Io {
    let ble: KawaBleManager
    private var items: [ObjectIdentifier: DispatchWorkItem] = [:]
    init(ble: KawaBleManager) { self.ble = ble }
    func send(_ frame: [UInt8], _ label: String) -> Bool {
        ble.write(frame, label)
    }
    func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func schedule(_ r: BikeRequests.ScheduledWork, _ delayMs: Int64) {
        let key = ObjectIdentifier(r)
        items[key]?.cancel()
        r.cancelled = false
        let w = DispatchWorkItem { r.perform() }
        items[key] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: w)
    }
    func cancel(_ r: BikeRequests.ScheduledWork) {
        let key = ObjectIdentifier(r)
        items[key]?.cancel()
        items[key] = nil
        r.cancelled = true
    }
    func log(_ line: String) {
        // (routed through the bridge's log by the caller)
    }
}
#endif
