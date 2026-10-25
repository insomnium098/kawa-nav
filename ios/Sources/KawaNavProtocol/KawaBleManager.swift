//
//  KawaBleManager.swift
//
//  Minimal GATT client for the Kawasaki BLE5 meter, on CoreBluetooth. Mirrors Rideology's connect
//  flow: connect (LE) -> MTU 300 -> discover -> enable the three notify characteristics -> ready.
//  CoreBluetooth allows one outstanding GATT operation, so everything goes through a queue. Frames
//  for the dash (arrow, status icons) go in an urgent lane that is served first; a newer frame of
//  the same type replaces one still waiting, so the dash never lags behind a backlog of requests.
//
//  Ported from KawaNav (Darthbob/kawa-nav), KawaBle.java. This file is iOS/macOS only (it needs
//  CoreBluetooth); the rest of the protocol package is platform-neutral.
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

#if canImport(CoreBluetooth)

public final class KawaBleManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Callbacks
    public final class Callbacks {
        public var onLog: ((String) -> Void)?
        public var onStateChanged: ((Bool) -> Void)?
        /// The link dropped or a connection attempt failed.
        public var onLinkLost: (() -> Void)?
        /// A frame from the meter on one of the notify characteristics.
        public var onNotify: ((UUID, [UInt8]) -> Void)?
        /// Debug: the meter's services and characteristics.
        public var onServicesDump: ((String) -> Void)?
        public init() {}
    }

    // MARK: - Constants
    private static let opTimeout: TimeInterval = 3.0
    private static let busyRetry: TimeInterval = 0.1
    private static let busyRetriesMax = 30
    private static let discoveryRetries = 2
    private static let reconnectMs: Int64 = 3000

    private let central: CBCentralManager
    private let callbacks: Callbacks
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var mtu = 23

    // Operation queue (one outstanding GATT op at a time)
    private var queue: [() -> Void] = []
    private var urgent: [[UInt8]] = []
    private var urgentLabels: [Int: String] = [:]
    private var busy = false
    private var busyCounter = 0
    private var opTimeoutWork: DispatchWorkItem?
    private var busyRetryWork: DispatchWorkItem?

    private let stateLock = NSLock()
    private var _ready = false
    private var ready: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _ready }
        set {
            stateLock.lock(); defer { stateLock.unlock() }
            if _ready == newValue { return }
            _ready = newValue
            stateLock.unlock()
            callbacks.onStateChanged?(newValue)
            stateLock.lock()
        }
    }

    private var missingStreak = 0
    private var discoveries = 0

    // MARK: - Init
    public init() {
        callbacks = Callbacks()
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        log("CBCentralManager state: " + centralStateName(central.state))
    }

    private func centralStateName(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized (enable Bluetooth / allow this app)"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Public

    public func isReady() -> Bool { ready }
    public func isConnecting() -> Bool { peripheral != nil && !ready }
    public func mtu() -> Int { mtu }

    /// How long to wait before reconnecting after a link loss (backoff when the device has no service).
    public func reconnectDelayMs() -> Int64 {
        missingStreak == 0 ? Self.reconnectMs : min(300_000, Self.reconnectMs << min(missingStreak, 7))
    }

    /// Scans for a bike advertising one of the Kawasaki scan-service UUIDs.
    public func scan(onFound: @escaping (CBPeripheral) -> Void) {
        guard central.state == .poweredOn else { log("Cannot scan: " + centralStateName(central.state)); return }
        let filterUUIDs: [String] = [
            "C5664E44-D60B-4342-8B7B-35BD6AE28E3F",
            "4FBB7609-F50A-40C6-89A9-9BE7EA880E95",
            "99EB13AC-42C9-4745-8B76-C30141401CE5",
        ]
        let services = filterUUIDs.map { CBUUID(string: $0) }
        log("Scanning for Kawasaki BLE5 meters…")
        central.scanForPeripherals(withServices: services, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
        // Store the continuation so a found peripheral routes here.
        scanContinuation = onFound
    }
    private var scanContinuation: ((CBPeripheral) -> Void)?

    /// Connects to a known peripheral (e.g. from a previous scan, remembered by name/MAC).
    public func connect(_ p: CBPeripheral, autoConnect: Bool) {
        disconnect()
        log("Connecting to " + (p.name ?? "unknown") + " (" + p.identifier.uuidString + ")"
            + (autoConnect ? ", waiting until in range" : ""))
        discoveries = 0
        mtu = 23
        peripheral = p
        p.delegate = self
        central.connect(p, options: [CBConnectPeripheralOptionAutoConnectKey: autoConnect])
    }

    public func disconnect() {
        opTimeoutWork?.cancel(); opTimeoutWork = nil
        busyRetryWork?.cancel(); busyRetryWork = nil
        queue.removeAll()
        urgent.removeAll()
        urgentLabels.removeAll()
        busy = false
        if let p = peripheral {
            p.cancelPeripheralConnection()
            p.delegate = nil
        }
        peripheral = nil
        writeChar = nil
        log("Disconnected")
        ready = false
    }

    /// Queues a write (with response) to the meter's write characteristic.
    @discardableResult
    public func write(_ data: [UInt8], _ label: String, urgent: Bool = false) -> Bool {
        if !ready || writeChar == nil {
            log("Not connected, dropped: " + label)
            return false
        }
        if !urgent {
            enqueue { [weak self] in self?.send(data, label, false) }
            return true
        }
        let type = Int(data[0])
        urgent.removeAll { Int($0[0]) == type }
        urgent.append(data)
        urgentLabels[type] = label
        if !busy { next() }
        return true
    }

    // MARK: - Queue plumbing

    private func enqueue(_ op: @escaping () -> Void) {
        queue.append(op)
        if !busy { next() }
    }

    private func next() {
        guard let p = peripheral else { busy = false; return }
        if let frame = urgent.first {
            urgent.removeFirst()
            busy = true
            send(frame, urgentLabels.removeValue(forKey: Int(frame[0])), true)
        } else if let op = queue.first {
            queue.removeFirst()
            busy = true
            scheduleOpTimeout()
            op()
        } else {
            busy = false
        }
    }

    private func scheduleOpTimeout() {
        let w = DispatchWorkItem { [weak self] in
            self?.log("GATT op timed out, continuing")
            self?.opDone()
        }
        opTimeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.opTimeout, execute: w)
    }

    private func opDone() {
        opTimeoutWork?.cancel(); opTimeoutWork = nil
        busy = false
        next()
    }

    private func send(_ data: [UInt8], _ label: String?, _ urgent: Bool) {
        guard let p = peripheral, let c = writeChar else { opDone(); return }
        c.writeType = .withResponse
        p.writeValue(Data(data), for: c)
        // CoreBluetooth reports the actual result in didWriteValueFor.
        if let l = label {
            log("TX " + l + ": " + KawaProtocol.hex(data))
        }
    }

    // MARK: - Connect flow

    private func onServicesDiscovered() {
        guard let p = peripheral else { return }
        let service = p.services?.first { $0.uuid == CBUUID(string: KawaProtocol.serviceUUID) }
        writeChar = service?.characteristics?.first {
            $0.uuid == CBUUID(string: KawaProtocol.writeCharUUID)
        }
        if writeChar == nil {
            if discoveries == 0 && missingStreak == 0 {
                if service == nil {
                    log("Kawasaki BLE5 service not found. Services on device:")
                    for s in (p.services ?? []) { log("  " + s.uuid.uuidString) }
                } else {
                    log("Write characteristic not found")
                }
            }
            if discoveries < Self.discoveryRetries {
                discoveries += 1
                log("Discovering services again")
                p.discoverServices(nil)
            } else {
                missingStreak += 1
                log("Kawasaki service still missing: reconnecting in " + (reconnectDelayMs() / 1000) + " s")
                disconnect()
                callbacks.onLinkLost?()
            }
            return
        }
        missingStreak = 0
        log("Found Kawasaki service + write characteristic; requesting MTU 300")
        requestMtu()
    }

    private func requestMtu() {
        guard let p = peripheral else { return }
        // requestMTU is async; it completes in peripheralDidUpdateMTU, then we enable notifies.
        if p.canUpdateMTU {
            p.requestMTU(300)
        } else {
            log("MTU update not supported, continuing with \(mtu)")
            enableNotifies()
        }
    }

    private func enableNotifies() {
        guard let p = peripheral else { return }
        let service = p.services?.first { $0.uuid == CBUUID(string: KawaProtocol.serviceUUID) }
        guard let service = service else { return }
        let chars = KawaProtocol.notifyCharUUIDs
            .compactMap { uuid in service.characteristics?.first { $0.uuid == CBUUID(string: uuid) } }
        if chars.count < KawaProtocol.notifyCharUUIDs.count {
            log("Some notify characteristics are missing: " +
                chars.map { $0.uuid.uuidString.prefix(8) + "…" }.joined(separator: ", "))
        }
        for c in chars {
            enqueue { [weak self] in
                guard let self = self, let p = self.peripheral else { return }
                p.setNotifyValue(true, for: c)
                // CoreBluetooth fires didUpdateNotificationState, then the op is done.
                DispatchQueue.main.async { self.opDone() }
            }
        }
        enqueue { [weak self] in
            self?.log("Ready")
            self?.ready = true
            self?.opDone()
        }
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: " + centralStateName(central.state))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any] = [:],
                               rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "unknown"
        log("Found: " + name + " (RSSI " + RSSI.stringValue + ")")
        let cont = scanContinuation
        if let cont = cont {
            central.stopScan()
            scanContinuation = nil
            cont(peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral) {
        log("Connected, requesting MTU 300")
        requestMtu()
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Connect failed: " + (error?.localizedDescription ?? "unknown"))
        disconnect()
        callbacks.onLinkLost?()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Link lost" + (error != nil ? " (" + error!.localizedDescription + ")" : ""))
        disconnect()
        callbacks.onLinkLost?()
    }

    // MARK: - CBPeripheralDelegate

    public func peripheralDidUpdateMTU(_ peripheral: CBPeripheral, error: Error?) {
        if let e = error {
            log("MTU update failed: " + e.localizedDescription)
        } else {
            mtu = Int(peripheral.maximumWriteValueLength(for: .withResponse))
            log("MTU \(mtu)")
        }
        // Android flow: connect -> MTU -> discover services -> (discover characteristics)
        // -> enable notifies -> ready. So after the MTU settles, discover services.
        peripheral.discoverServices(nil)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            log("Discover services failed: " + e.localizedDescription)
            return
        }
        guard let s = peripheral.services?.first(where: { $0.uuid == CBUUID(string: KawaProtocol.serviceUUID) }
        ) else {
            // Service not present yet (incomplete list): ask for the known services explicitly.
            let wanted = [CBUUID(string: KawaProtocol.serviceUUID)]
            peripheral.discoverServices(wanted)
            return
        }
        // Discover the characteristics of the Kawasaki service.
        s.discoverCharacteristics(nil)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        // Now that characteristics are known, run the connect flow once.
        onServicesDiscovered()
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let e = error {
            log("Write failed: " + e.localizedDescription)
        }
        opDone()
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let e = error {
            log("Notify enable failed on " + characteristic.uuid.uuidString.prefix(8) + "…: " + e.localizedDescription)
        } else {
            log("Notify on " + characteristic.uuid.uuidString.prefix(8) + "… enabled")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let value = characteristic.value else { return }
        let data = [UInt8](value)
        logRx(characteristic.uuid, data)
        callbacks.onNotify?(characteristic.uuid, data)
    }

    // MARK: - RX logging (change-only, streamed counted)

    private static let streamed: [Int] = [0x45, 0x4A, 0x4B]
    private var rxCount = [Int](repeating: 0, count: 256)
    private var rxCountLogged = [Int](repeating: 0, count: 256)
    private var lastRx = [[UInt8]?](repeating: nil, count: 256)

    private func logRx(_ id: CBUUID, _ v: [UInt8]) {
        guard !v.isEmpty else { return }
        let type = Int(v[0])
        rxCount[type] += 1
        let isStreamed = Self.streamed.contains(type)
        let last = lastRx[type]
        lastRx[type] = v
        let head = "RX " + id.uuidString.prefix(8) + "…: "
        if type == BikeFrames.modelInfo {
            // carries the VIN in plain text: never into the log (users share it)
            if last == nil { log(head + "03 model info (\(v.count) bytes, not logged: VIN)") }
        } else if (isStreamed ? rxCount[type] == 1 : (last == nil || !sameIgnoringCounter(last!, v))) {
            log(head + KawaProtocol.hex(v))
        }
    }

    private func sameIgnoringCounter(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count where i != 2 && a[i] != b[i] { return false }
        return true
    }

    private func log(_ s: String) {
        callbacks.onLog?(s)
    }
}

#endif
