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

        // The forward chevron is never .disabled() (a real .disabled() toggle
        // in a List row is its own failure mode -- see DashboardView.swift),
        // so isEnabled is always true here and can't verify anything about the
        // current-month state. DashboardView also applies .accessibilityHidden
        // while on the current month so VoiceOver doesn't announce it as
        // active, but that isn't observable through XCUIElement -- confirmed
        // empirically that .exists still reports true regardless, since
        // XCUITest's element tree isn't identical to the tree VoiceOver reads.
        // That part of the fix needs a manual VoiceOver check, not this test.

        previousButton.tap()

        let afterPrevious = label.label
        XCTAssertNotEqual(afterPrevious, originalMonth, "Expected label to change after tapping previous.")

        nextButton.tap()

        let afterNext = label.label
        XCTAssertEqual(afterNext, originalMonth, "Expected forward navigation to return to the original month.")
    }
}
