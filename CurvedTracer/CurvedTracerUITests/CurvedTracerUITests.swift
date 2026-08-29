//
//  CurvedTracerUITests.swift
//  CurvedTracerUITests
//

import XCTest

final class CurvedTracerUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testPhotoModeToggleStartsAndStopsProgressiveRendering() throws {
        let app = XCUIApplication()
        app.launch()

        let toggle = app.buttons["photo-mode-toggle"]
        let maximumBounces = app.steppers["photo-max-bounces-control"]
        let guaranteedBounces = app.steppers[
            "photo-guaranteed-bounces-control"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(maximumBounces.exists)
        XCTAssertTrue(guaranteedBounces.exists)
        XCTAssertEqual(toggle.label, "Start Photo Mode")
        XCTAssertTrue(maximumBounces.isEnabled)
        XCTAssertTrue(guaranteedBounces.isEnabled)

        toggle.click()
        XCTAssertEqual(toggle.label, "Stop Photo Mode")
        XCTAssertFalse(maximumBounces.isEnabled)
        XCTAssertFalse(guaranteedBounces.isEnabled)

        toggle.click()
        XCTAssertEqual(toggle.label, "Start Photo Mode")
        XCTAssertTrue(maximumBounces.isEnabled)
        XCTAssertTrue(guaranteedBounces.isEnabled)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
