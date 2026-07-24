import XCTest

final class MonthNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNavigatingBackThenForwardReturnsToOriginalMonth() {
        let app = XCUIApplication()
        app.launch()

        let label = app.staticTexts["selectedMonthLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        let originalMonth = label.label

        let previousButton = app.buttons["previousMonthButton"]
        let nextButton = app.buttons["nextMonthButton"]
        XCTAssertTrue(previousButton.exists)
        XCTAssertTrue(nextButton.exists)

        previousButton.tap()

        let afterPrevious = label.label
        XCTAssertNotEqual(afterPrevious, originalMonth, "Expected label to change after tapping previous.")

        XCTAssertTrue(nextButton.isEnabled, "Next button should be enabled once we've moved off the current month.")
        nextButton.tap()

        let afterNext = label.label
        XCTAssertEqual(afterNext, originalMonth, "Expected forward navigation to return to the original month.")
    }
}
