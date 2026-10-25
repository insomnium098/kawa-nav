# KawaNav iOS

Open-source iOS port of [KawaNav](https://github.com/Darthbob/kawa-nav) — the Rideology
alternative for Kawasaki motorcycles. It talks to your Z900's TFT dash over the same
Bluetooth LE protocol that Rideology uses, and shows the bike's live data on your iPhone.

This is a **fork** of `Darthbob/kawa-nav` (GPL-3.0) converted from Android (Java) to
iOS (Swift). See [PROTOCOL.md](../docs/PROTOCOL.md) for the verified byte layouts.

## What actually works

- **Connect to your Z900** over BLE5 (scan → MTU 300 → enable notifies → connect
  sequence, exactly like Rideology).
- **Read the bike's live data**: speed, rpm, gear, throttle, lean angle, acceleration,
  fuel range, fuel gauge, odometer, trip A/B, battery voltage, water/oil/intake
  temperatures, KTRC/riding mode, maintenance reminders — everything the meter streams.
- **Send frames to the dash**: turn-by-turn arrows, status icons (phone battery,
  headset, riding-log), and the "clear navigation" frame.

## What it does NOT do (honest scope)

- **Google Maps turn-by-turn on the dash.** The Android app works by *reading Google
  Maps' notification* and forwarding the turn. **iOS does not allow one app to read
  another app's notifications** (the `NotificationListenerService` model does not exist
  on Apple's platform). So the phone cannot silently feed Maps' turns to your dash.
  The `sendTurn(turn:distance:)` function is there and correct — it just needs a
  navigation source you wire up (e.g. a Maps screen on the phone, or a custom app).
- **Ride recording + export, the diary (refuels, battery, maintenance), settings
  write-back** (riding mode / KTRC / shift lamp). The *decoding* of those frames is
  fully ported and unit-tested, but the recording/export UI and the settings-write
  flow are not implemented in this first iOS build. They are the next step.
- **Spoken curve warnings, offline OpenStreetMap curve detection, speed cameras** —
  Android features not ported yet.

The point of this port is the **protocol bridge** (the part that makes the bike
"work" with your phone), which is complete, unit-tested, and verified against the
real frame captures in PROTOCOL.md.

## Requirements

- Xcode 15+ on macOS
- iOS 15+
- (optional) [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project:
  `brew install xcodegen`

## Setup (3 ways)

### Option A — XcodeGen (recommended)
```
cd ios
xcodegen generate
open KawaNavIOS.xcodeproj
```
Select your iPhone as the run target, trust the developer certificate, and run.

### Option B — Manual Xcode project
1. Xcode → **File → New → Project → iOS App**. Name: `KawaNavIOS`, Interface: SwiftUI.
2. Delete the generated `ContentView.swift` and `<Name>App.swift`.
3. **File → Add Package Dependency → Add Local…**, point it at this `ios/` folder,
   and add the product **`KawaNavProtocol`**.
4. Drag in `App/KawaNavIOSApp.swift` and `App/KawaNavIOS/ContentView.swift`.
5. Replace the auto-generated `Info.plist` with `App/Info.plist` (it carries the
   required `NSBluetoothAlwaysUsageDescription`), or copy that key in.
6. Run on your iPhone.

### Option C — Use the protocol package only
The Swift package `KawaNavProtocol` is self-contained and platform-neutral. You can
`import KawaNavProtocol` into any of your own iOS apps and drive `KawaBleManager` +
`BikeBridge` directly.

## Running the unit tests

The protocol layer is platform-neutral (no CoreBluetooth required to build it), so
the tests run on macOS and even Linux:

```
cd ios
swift test          # builds KawaNavProtocol + KawaNavProtocolTests, runs the suite
```

The suite pins the port to the **real frame captures documented in PROTOCOL.md**:
the four turn-by-turn hex frames (right/left/roundabout/clear), the battery
thresholds, the phone-name frame, the connect sequence order, and the decoders for
speed, rpm, gear, odometer, instant fuel, the meter clock and KTRC. All of them pass
against the verified Z900 data.

## How to verify it works on your bike

1. Turn on the Z900 ignition (the BLE5 meter is only alive when the bike is on).
2. Make sure **Rideology is NOT connected** (only one phone can hold the link).
3. Open KawaNav, tap **Scan & connect**. You should see your bike's name appear.
4. Once connected, the live data card fills in: speed (0 when parked), rpm, gear,
   fuel, odometer. The log shows the connect sequence and the incoming frames.
5. To see the dash respond, the app can send the status-icon frame — check that the
   phone-battery icon appears on the dash.

## Known caveats

- **MTU**: the app requests MTU 300, like Rideology. If the meter answers with a
  smaller MTU, long frames (the 85-byte vehicle-info, the 0x4B) may be split across
  multiple ATT notifications; the decoder already drops short 0x4A/0x4B frames so
  values never come out wrong — but some values may simply not arrive. Watch the log.
- **The phone name**: we send "iOS <version>" in the 0x0B frame; the dash shows the
  phone's kind there. Rideology sends `Build.MODEL` ("iPhone16,2" etc.) — you can
  change `phoneModelName()` in `BikeBridge.swift` if you want the exact model string.
- **First connection**: the bike may need a moment to finish its own startup before
  it answers the connect sequence; the request queue already retries each request
  three times with a 3 s timeout.

## Files

```
ios/
  Package.swift                          # SPM package (KawaNavProtocol + tests)
  project.yml                            # XcodeGen definition
  README.md                              # this file
  Sources/KawaNavProtocol/
    FrameReader.swift                    # bounds-checked byte reads (pure)
    KawaProtocol.swift                   # UUIDs, frame builders, connect sequence (pure)
    BikeFrames.swift                     # all frame decoders (pure) — the heart
    BikeRequests.swift                   # request queue with retry/timeout (pure)
    BikeData.swift                       # shared bike state (pure)
    KawaBleManager.swift                 # CoreBluetooth GATT client (#if canImport)
    BikeBridge.swift                     # ObservableObject tying it all together (#if)
  Tests/KawaNavProtocolTests/
    KawaProtocolTests.swift              # unit tests vs. real PROTOCOL.md frames
  App/
    Info.plist                           # NSBluetoothAlwaysUsageDescription
    KawaNavIOSApp.swift                  # @main SwiftUI app
    KawaNavIOS/ContentView.swift         # the single screen
```

## License

GNU GPL v3 — same as the upstream project. Kawasaki, Rideology and the model names
are trademarks of Kawasaki Motors; this project is not affiliated with or endorsed
by Kawasaki.
