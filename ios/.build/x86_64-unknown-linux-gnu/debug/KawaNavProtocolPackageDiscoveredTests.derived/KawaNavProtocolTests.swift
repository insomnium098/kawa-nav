import XCTest
@testable import KawaNavProtocolTests

fileprivate extension BikeRequestsTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__BikeRequestsTests = [
        ("testRejectedRequestRemembered", testRejectedRequestRemembered),
        ("testRequestAnsweredByAck", testRequestAnsweredByAck),
        ("testRequestAnsweredByData", testRequestAnsweredByData),
        ("testUnsupportedNotRequeued", testUnsupportedNotRequeued)
    ]
}

fileprivate extension DecoderTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__DecoderTests = [
        ("testAck", testAck),
        ("testGeneralCaps", testGeneralCaps),
        ("testGeneralSettingsClock", testGeneralSettingsClock),
        ("testImuSuspAbsentAllFF", testImuSuspAbsentAllFF),
        ("testInfoConfigGatesTelemetry", testInfoConfigGatesTelemetry),
        ("testLogExtInstantFuel", testLogExtInstantFuel),
        ("testModelInfoVin", testModelInfoVin),
        ("testShortRidingLogFrameDropped", testShortRidingLogFrameDropped),
        ("testTelemetryGear", testTelemetryGear),
        ("testTelemetryRpmMode0", testTelemetryRpmMode0),
        ("testTelemetrySpeedMode0", testTelemetrySpeedMode0),
        ("testVehicleInfoOdometer", testVehicleInfoOdometer),
        ("testVehicleSettingsKtrc", testVehicleSettingsKtrc)
    ]
}

fileprivate extension FrameReaderTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__FrameReaderTests = [
        ("testBe16Be24Be32", testBe16Be24Be32),
        ("testBits", testBits),
        ("testBlockPresentAndInPresentBlock", testBlockPresentAndInPresentBlock),
        ("testTextChunks", testTextChunks),
        ("testU8AndBounds", testU8AndBounds)
    ]
}

fileprivate extension KawaProtocolTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__KawaProtocolTests = [
        ("testBatteryLevel", testBatteryLevel),
        ("testClearFrame", testClearFrame),
        ("testHexRoundTrip", testHexRoundTrip),
        ("testMeterIndicationFrame", testMeterIndicationFrame),
        ("testNaviFrameLeftIn80m", testNaviFrameLeftIn80m),
        ("testNaviFrameRightIn250m", testNaviFrameRightIn250m),
        ("testNaviFrameRoundaboutExit2", testNaviFrameRoundaboutExit2),
        ("testPhoneNameFrame", testPhoneNameFrame),
        ("testStartupSequenceFull", testStartupSequenceFull),
        ("testStartupSequenceReadOnly", testStartupSequenceReadOnly)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __KawaNavProtocolTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(BikeRequestsTests.__allTests__BikeRequestsTests),
        testCase(DecoderTests.__allTests__DecoderTests),
        testCase(FrameReaderTests.__allTests__FrameReaderTests),
        testCase(KawaProtocolTests.__allTests__KawaProtocolTests)
    ]
}