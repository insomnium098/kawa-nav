//
//  BikeRequests.swift
//
//  Requests to the meter, one at a time, the way Rideology sends them: a gap between requests, wait for
//  the answer (a frame of the same type or an ACK naming the request), retry after a timeout, give up
//  after a few tries. Requests the meter rejects (ACK result 01) are remembered as unsupported.
//
//  Ported from KawaNav (Darthbob/kawa-nav), BikeRequests.java. Time and scheduling come from `Io` so
//  this runs in unit tests without a real clock or Bluetooth.
//

import Foundation

public final class BikeRequests {

    /// What a request expects back.
    public enum Expect: Int {
        case dataOrAck = 0
        case ackOnly = 1
        case anyAck = 2
        case none = 3
    }

    /// Priorities: the rider's own action, the connect sequence, background polling.
    public enum Priority: Int, Comparable {
        case user = 0
        case startup = 1
        case poll = 2
        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    public static let gapMs: Int64 = 200
    public static let timeoutMs: Int64 = 3000
    public static let maxTries = 3

    /// Clock / scheduling / I/O, so the queue can run in tests.
    public protocol Io {
        /// Writes the frame to the meter; false if it could not be queued (not connected).
        func send(_ frame: [UInt8], _ label: String) -> Bool
        func now() -> Int64
        func schedule(_ r: ScheduledWork, _ delayMs: Int64)
        func cancel(_ r: ScheduledWork)
        func log(_ line: String)
    }

    /// A scheduled runnable that can be cancelled by identity. `schedule` clears the flag
    /// (a re-schedule revives the work); `cancel` sets it.
    public final class ScheduledWork {
        let run: () -> Void
        var cancelled = false
        public init(_ run: @escaping () -> Void) { self.run = run }
        public func perform() { if !cancelled { run() } }
    }

    /// Called when a request was answered or gave up.
    public protocol Done {
        func on(_ r: Request, ok: Bool, result: Int)
    }

    /// A `Done` backed by a closure, so callers can pass a simple `(Request, Bool, Int) -> Void`.
    public final class ClosureDone: Done {
        let run: (Request, Bool, Int) -> Void
        public init(_ run: @escaping (Request, Bool, Int) -> Void) { self.run = run }
        public func on(_ r: Request, ok: Bool, result: Int) { run(r, ok, result) }
    }

    public final class Request {
        public let frame: [UInt8]
        public let label: String
        public let expect: Expect
        public let priority: Priority
        let done: Done?
        var tries = 0

        public init(_ frame: [UInt8], _ label: String, _ expect: Expect, _ priority: Priority, _ done: Done?) {
            self.frame = frame
            self.label = label
            self.expect = expect
            self.priority = priority
            self.done = done
        }

        public func id() -> Int { Int(frame[0]) }

        /// This frame from the meter answers the request.
        func answeredBy(_ v: [UInt8]) -> Bool {
            guard !v.isEmpty else { return false }
            let type = Int(v[0])
            let isAck = type == BikeFrames.ack && v.count > 3
            let cmd = isAck ? Int(v[3]) : -1
            switch expect {
            case .dataOrAck: return type == id() || cmd == id()
            case .ackOnly: return cmd == id() || (id() == BikeFrames.meterInit && cmd == 0x13)
            case .anyAck: return isAck
            case .none: return false
            }
        }
    }

    private let io: Io
    private var queue: [Request] = []
    private var unsupported = Set<Int>()
    private var pending: Request?
    private var lastSentAt: Int64 = -BikeRequests.gapMs
    // Assigned in init (a property default value cannot capture `self`).
    private var pumpWork: ScheduledWork!
    private var timeoutWork: ScheduledWork!

    public init(_ io: Io) {
        self.io = io
        self.pumpWork = ScheduledWork { [weak self] in self?.pump() }
        self.timeoutWork = ScheduledWork { [weak self] in self?.onTimeout() }
    }

    /// Queues a request behind those of the same or a higher priority.
    public func submit(_ r: Request) {
        var i = 0
        while i < queue.count && queue[i].priority <= r.priority { i += 1 }
        queue.insert(r, at: i)
        pump()
    }

    /// Queues the request unless one of the same frame type is already waiting or running.
    @discardableResult
    public func submitIfIdle(_ r: Request) -> Bool {
        if let p = pending, p.id() == r.id() { return false }
        for q in queue where q.id() == r.id() { return false }
        submit(r)
        return true
    }

    /// The meter rejected this frame type (ACK result 01) since the last clear.
    public func unsupported(_ id: Int) -> Bool {
        unsupported.contains(id)
    }

    public func idle() -> Bool {
        pending == nil && queue.isEmpty
    }

    /// Drops everything, e.g. when the link is lost.
    public func clear() {
        io.cancel(pumpWork)
        io.cancel(timeoutWork)
        queue.removeAll()
        pending = nil
        unsupported.removeAll()
        lastSentAt = -BikeRequests.gapMs
    }

    /// A frame from the meter: completes the running request if it answers it.
    public func onFrame(_ v: [UInt8]) {
        guard let r = pending, r.answeredBy(v) else { return }
        let result = (Int(v[0]) == BikeFrames.ack && v.count > 4) ? Int(v[4]) : 0
        if result == 1 {
            unsupported.insert(r.id())
            io.log("Bike: " + r.label + " not supported (rejected)")
        }
        finish(r, ok: true, result: result)
    }

    private func pump() {
        if pending != nil || queue.isEmpty { return }
        let wait = lastSentAt + Self.gapMs - io.now()
        if wait > 0 {
            io.cancel(pumpWork)
            io.schedule(pumpWork, wait)
            return
        }
        let r = queue.removeFirst()
        r.tries += 1
        lastSentAt = io.now()
        if !io.send(r.frame, r.label) {
            finish(r, ok: false, result: -1)
            return
        }
        if r.expect == .none {
            finish(r, ok: true, result: 0)
            return
        }
        pending = r
        io.schedule(timeoutWork, Self.timeoutMs)
    }

    private func onTimeout() {
        guard let r = pending else { return }
        pending = nil
        if r.tries < Self.maxTries {
            queue.insert(r, at: 0)
            pump()
        } else {
            io.log("Bike: no answer to " + r.label + " after \(Self.maxTries) tries")
            finish(r, ok: false, result: -1)
        }
    }

    private func finish(_ r: Request, ok: Bool, result: Int) {
        if pending === r {
            pending = nil
            io.cancel(timeoutWork)
        }
        r.done?.on(r, ok: ok, result: result)
        pump()
    }
}
