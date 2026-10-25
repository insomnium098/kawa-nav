import XCTest

@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
public func __allDiscoveredTests() -> [XCTestCaseEntry] {
    var tests = [XCTestCaseEntry]()

    tests += __KawaNavProtocolTests__allTests()

    return tests
}