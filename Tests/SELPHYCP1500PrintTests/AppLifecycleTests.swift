import AppKit
import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testClosingTheLastWindowQuitsTheApp() {
        XCTAssertTrue(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
