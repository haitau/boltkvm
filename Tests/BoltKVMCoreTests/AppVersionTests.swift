import XCTest
@testable import BoltKVMCore

final class AppVersionTests: XCTestCase {
    func testDisplayIncludesShortVersionAndBuild() {
        XCTAssertEqual(AppVersion.display(short: "0.13", build: "230"), "0.13 (230)")
    }

    func testDisplayWithoutBuildIsStillUseful() {
        XCTAssertEqual(AppVersion.display(short: "0.13", build: nil), "0.13")
        XCTAssertEqual(AppVersion.display(short: "0.13", build: ""), "0.13")
    }

    func testDisplayFallsBackWhenBundleFieldsAreMissing() {
        XCTAssertEqual(AppVersion.display(short: nil, build: "230"), "dev (230)")
        XCTAssertEqual(AppVersion.display(short: " ", build: nil), "dev")
    }
}
