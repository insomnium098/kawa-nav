//
//  ContentView.swift
//
//  The single screen: connect button, the bike's live values, and a debug log.
//  Values the bike does not send (or its 0x40 config marks absent) show "–".
//

import SwiftUI
import KawaNavProtocol

struct ContentView: View {
    @ObservedObject var bridge: BikeBridge

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    liveDataCard
                    InfoCard()
                    logCard
                }
                .padding()
            }
            .navigationTitle("KawaNav iOS")
            .tint(.orange)
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(bridge.ready ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(bridge.ready ? "Connected to bike" : (bridge.scanning ? "Scanning…" : "Not connected"))
                    .font(.headline)
                Spacer()
            }
            if let msg = bridge.connectionMessage {
                Text(msg).font(.footnote).foregroundStyle(.secondary)
            }
            if !bridge.ready {
                Button(action: { bridge.startScan() }) {
                    Label(bridge.scanning ? "Looking for your Z900…" : "Scan & connect",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(bridge.scanning)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - Live data

    private var liveDataCard: some View {
        let t = bridge.bike.live
        let info = bridge.bike.info
        let ext = bridge.bike.ext
        let age = timeSince(bridge.bike.liveAt)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bike data").font(.headline)
                Spacer()
                if t != nil {
                    Text(String(format: "%.0f s ago", age)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let t = t {
                row("Speed", fmt(t.speedKmh, " km/h"),
                    "RPM", fmtInt(t.rpm),
                    "Gear", fmtInt(t.gear))
                row("Throttle", fmt(t.throttlePct, " %"),
                    "Lean", fmt(t.leanDeg, "°"),
                    "Accel", fmt(t.accelG, " g"))
                row("Water", fmt(ext?.waterC, " °C"),
                    "Oil", fmt(ext?.oilC, " °C"),
                    "Intake", fmt(ext?.intakeC, " °C"))
            } else {
                Text("Waiting for live data…").font(.caption).foregroundStyle(.secondary)
            }
            if let info = info {
                Divider()
                row("Odometer", fmtInt(info.odometerKm, suffix: " km"),
                    "Trip A", fmt(info.tripAKm, " km"),
                    "Trip B", fmt(info.tripBKm, " km"))
                row("Range", fmtInt(info.rangeKm, suffix: " km"),
                    "Fuel", fmtInt(info.fuelBars),
                    "Battery", fmt(info.meterBatteryV, " V"))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(bridge.logText.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced)).lineLimit(3)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - Helpers

    private func row(_ l1: String, _ v1: String, _ l2: String, _ v2: String, _ l3: String, _ v3: String) -> some View {
        HStack(alignment: .top) {
            cell(l1, v1)
            cell(l2, v2)
            cell(l3, v3)
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fmt(_ v: Double?, _ unit: String) -> String {
        guard let v = v, v == v else { return "–" }
        return String(format: "%.1f%@", v, unit)
    }
    private func fmtInt(_ v: Int, suffix: String = "") -> String {
        v < 0 ? "–" : "\(v)\(suffix)"
    }
    private func timeSince(_ at: Int64) -> Double {
        at == 0 ? 0 : Date().timeIntervalSince1970 - Double(at) / 1000.0
    }
}

struct InfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About this port").font(.headline)
            Text("Open-source iOS port of KawaNav (GPL-3.0). It reads your Kawasaki BLE5 meter the same way Rideology does. Navigation on the dash is not available on iOS (no cross-app notification access) — see README.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}
