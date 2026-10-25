//
//  KawaNavIOSApp.swift
//
//  The iOS app entry point. A minimal, honest port of KawaNav (Darthbob/kawa-nav): it talks to
//  the Kawasaki BLE5 meter over CoreBluetooth and shows the bike's live data on a phone.
//
//  What it does:
//    - Scans for your Z900 (it advertises a known Kawasaki service UUID).
//    - Connects, requests MTU 300, enables the notify characteristics and runs the connect
//      sequence (the same one Rideology runs) so the meter starts streaming its data.
//    - Decodes the frames (speed, rpm, gear, throttle, lean, fuel, range, temperatures, odometer…)
//      and shows them on screen, with a live log for debugging.
//
//  What it does NOT do (honest scope, see the README):
//    - Google Maps turn-by-turn on the dash: impossible on iOS — an app cannot read another app's
//      notifications the way the Android version does. The dash frame sender is there (sendTurn)
//      so it can be driven from any navigation source you wire up.
//    - Ride recording / export, the diary, settings write: not ported yet (marked in the README).
//

import SwiftUI
import KawaNavProtocol

@main
struct KawaNavIOSApp: App {
    @StateObject private var bridge = BikeBridge()

    var body: some Scene {
        WindowGroup {
            ContentView(bridge: bridge)
                .preferredColorScheme(.dark)
        }
    }
}
