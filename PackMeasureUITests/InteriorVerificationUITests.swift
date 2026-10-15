import XCTest

final class InteriorVerificationUITests: XCTestCase {
    @MainActor func testLegacyMeasurementReferencesPersistWithoutReplacingGeometry() throws {
        let app = launch(["light"])
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        replace(app.textFields["verification-along-value"], with: "398.5", in: app)
        replace(app.textFields["verification-across-value"], with: "299", in: app)
        replace(app.textFields["verification-height-value"], with: "98", in: app)
        replace(app.textFields["verification-insert-height-value"], with: "80", in: app)
        replace(app.textFields["verification-source"], with: "Steel ruler", in: app)
        applyAnnotations(app)
        XCTAssertTrue(app.buttons["interior-review-back"].exists)
        app.buttons["interior-review-back"].tap()
        XCTAssertTrue(app.buttons["save-and-leave-interior-review"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["discard-interior-review-changes"].firstMatch.exists)
        app.buttons["keep-editing-interior-review"].firstMatch.tap()
        reveal(element("verification-original-summary", in: app), in: app)
        XCTAssertTrue(element("verification-original-summary", in: app).exists)
        capture(app, "verification-legacy-light")
        let persisted = try saveAndRead(app)
        try assertOriginalGeometry(persisted)
        let values = try verification(persisted)
        assertNumber(values, "alongFirstEdgeMM", 398.5)
        assertNumber(values, "acrossFirstEdgeMM", 299)
        assertNumber(values, "usableHeightMM", 98)
        assertNumber(values, "intendedInsertHeightMM", 80)
        XCTAssertEqual(values["source"] as? String, "Steel ruler")
        XCTAssertNotNil(values["measuredAt"] as? NSNumber)
        XCTAssertEqual(persisted["_qaCurrentFitStatus"] as? String, "notTested")

        app.terminate()
        app.launchArguments = ["interior-verification", "verification-preserve", "centimeters"]
        app.launch()
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        assertField("verification-along-value", equals: 398.5, in: app)
        assertField("verification-across-value", equals: 299, in: app)
        assertField("verification-height-value", equals: 98, in: app)
        assertField("verification-insert-height-value", equals: 80, in: app)
        XCTAssertEqual(app.textFields["verification-source"].value as? String, "Steel ruler")
        app.buttons["cancel-interior-verification"].tap()
    }

    @MainActor func testConversionRepeatedCancelAndDismissPreserveMillimeters() throws {
        let app = launch(["dark"])
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        replace(app.textFields["verification-along-value"], with: "254", in: app)
        chooseUnit("Inches", in: app, finishEditing: false)
        assertField("verification-along-value", equals: 10, in: app)
        chooseUnit("Millimeters", in: app)
        replace(app.textFields["verification-across-value"], with: "127", in: app)
        replace(app.textFields["verification-height-value"], with: "50.8", in: app)
        replace(app.textFields["verification-insert-height-value"], with: "25.4", in: app)
        for _ in 0..<3 {
            chooseUnit("Inches", in: app)
            assertField("verification-along-value", equals: 10, in: app)
            assertField("verification-height-value", equals: 2, in: app)
            chooseUnit("Centimeters", in: app)
            assertField("verification-along-value", equals: 25.4, in: app)
            assertField("verification-height-value", equals: 5.08, in: app)
            chooseUnit("Millimeters", in: app)
            assertField("verification-along-value", equals: 254, in: app)
            assertField("verification-height-value", equals: 50.8, in: app)
        }
        applyAnnotations(app)
        for _ in 0..<2 {
            openAnnotations(app)
            chooseUnit("Millimeters", in: app)
            replace(app.textFields["verification-along-value"], with: "999", in: app)
            app.buttons["cancel-interior-verification"].tap()
            openAnnotations(app)
            chooseUnit("Millimeters", in: app)
            assertField("verification-along-value", equals: 254, in: app)
            app.buttons["cancel-interior-verification"].tap()
        }
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        replace(app.textFields["verification-along-value"], with: "888", in: app)
        finishKeyboard(app)
        // Dismissing the draft sheet must be equivalent to Cancel.
        app.navigationBars["Measured dimensions"].swipeDown()
        XCTAssertTrue(app.buttons["edit-interior-verification"].waitForExistence(timeout: 4))
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        assertField("verification-along-value", equals: 254, in: app)
        app.buttons["cancel-interior-verification"].tap()
        reveal(element("verification-original-summary", in: app), in: app)
        capture(app, "verification-annotations-dark")
        let persisted = try saveAndRead(app)
        try assertOriginalGeometry(persisted)
        let values = try verification(persisted)
        assertNumber(values, "alongFirstEdgeMM", 254)
        assertNumber(values, "acrossFirstEdgeMM", 127)
        assertNumber(values, "usableHeightMM", 50.8)
        assertNumber(values, "intendedInsertHeightMM", 25.4)
    }

    @MainActor func testFitPersistsAcrossDisplayUnitsAndBecomesStaleAtNewIntendedHeight() throws {
        let app = launch(["light"])
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        replace(app.textFields["verification-insert-height-value"], with: "80", in: app)
        applyAnnotations(app)
        recordFit(app, status: "Fits", note: "Synthetic coupon result")
        var persisted = try saveAndRead(app)
        XCTAssertEqual(persisted["_qaCurrentFitStatus"] as? String, "fits")
        XCTAssertEqual(persisted["_qaFitIsStale"] as? Bool, false)
        let oldFit = try fit(persisted)
        XCTAssertEqual(oldFit["status"] as? String, "fits")
        XCTAssertEqual(oldFit["note"] as? String, "Synthetic coupon result")
        XCTAssertNotNil(oldFit["testedAt"] as? NSNumber)

        app.terminate()
        app.launchArguments = ["interior-verification", "verification-preserve", "centimeters", "dark"]
        app.launch()
        reveal(element("verification-fit-state", in: app), in: app)
        XCTAssertTrue(element("verification-fit-state", in: app).label.contains("Fits"))
        recordFit(app, status: "Fits", note: "Edited synthetic coupon note")
        persisted = try saveAndRead(app)
        XCTAssertEqual(persisted["_qaFitIsStale"] as? Bool, false)
        XCTAssertEqual(try fit(persisted)["testedAt"] as? NSNumber, oldFit["testedAt"] as? NSNumber)
        reopen(app)
        let fitButton = app.buttons["record-interior-fit"]
        reveal(fitButton, in: app)
        fitButton.tap()
        app.buttons["verification-fit-status"].tap()
        app.buttons["Too tight"].tap()
        replace(element("verification-fit-note", in: app), with: "Discarded fit draft", in: app)
        app.buttons["cancel-interior-fit"].tap()
        persisted = try saveAndRead(app)
        XCTAssertEqual(try fit(persisted)["status"] as? String, "fits")
        XCTAssertEqual(try fit(persisted)["note"] as? String, "Edited synthetic coupon note")
        XCTAssertEqual(try fit(persisted)["testedAt"] as? NSNumber, oldFit["testedAt"] as? NSNumber)
        reopen(app)
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        replace(app.textFields["verification-insert-height-value"], with: "90", in: app)
        applyAnnotations(app)
        assertStaleLabel(app)
        persisted = try saveAndRead(app)
        XCTAssertEqual(persisted["_qaFitIsStale"] as? Bool, true)
        XCTAssertEqual(persisted["_qaCurrentFitStatus"] as? String, "notTested")
        XCTAssertEqual(try fit(persisted)["status"] as? String, "fits")
        let bound = try XCTUnwrap(try fit(persisted)["snapshot"] as? [String: Any])
        assertNumber(bound, "intendedInsertHeightMM", 80)
        assertNumber(try verification(persisted), "intendedInsertHeightMM", 90)
    }

    @MainActor func testCoordinateHeightAndClearanceCorrectionsStaleHistoricalFit() throws {
        let app = launch(["light"])
        recordFit(app, status: "Fits", note: "Synthetic original fit")
        _ = try saveAndRead(app)
        reopen(app)
        enableMillimeterCorrections(app)
        let perimeter = app.buttons["Inside perimeter"]
        reveal(perimeter, in: app)
        perimeter.tap()
        assertField("interior-point-0-1-x", equals: 400, in: app)
        capture(app, "verification-coordinate-millimeters")
        replace(app.textFields["interior-point-0-1-x"], with: "398", in: app)
        // Save while editing: the bound field must not lose its final typed value.
        var persisted = try saveAndRead(app)
        var contours = try XCTUnwrap(persisted["contours"] as? [[[String: Double]]])
        XCTAssertEqual(contours[0][1]["x"] ?? 0, 398, accuracy: 0.000001)
        XCTAssertEqual(persisted["_qaFitIsStale"] as? Bool, true)
        let original = try XCTUnwrap(persisted["originalGeometry"] as? [String: Any])
        let originalValues = try XCTUnwrap(original["geometry"] as? [String: Any])
        let originalContours = try XCTUnwrap(originalValues["contours"] as? [[[String: Double]]])
        XCTAssertEqual(originalContours[0][1]["x"], 400)

        reopen(app)
        recordFit(app, status: "Fits", note: "Synthetic corrected fit")
        enableMillimeterCorrections(app)
        assertField("interior-usable-height", equals: 100, in: app)
        replace(app.textFields["interior-usable-height"], with: "95", in: app)
        persisted = try saveAndRead(app)
        assertNumber(persisted, "heightMM", 95)
        XCTAssertEqual(persisted["_qaFitIsStale"] as? Bool, true)

        reopen(app)
        recordFit(app, status: "Fits", note: "Synthetic new height fit")
        incrementClearance("interior-side-clearance", in: app)
        incrementClearance("interior-top-clearance", in: app)
        assertStaleLabel(app)
        persisted = try saveAndRead(app)
        assertNumber(persisted, "sideClearanceMM", 2.5)
        assertNumber(persisted, "topClearanceMM", 2.5)
        XCTAssertEqual(persisted["_qaFitIsStale"] as? Bool, true)
        contours = try XCTUnwrap(persisted["contours"] as? [[[String: Double]]])
        XCTAssertEqual(contours[0][1]["x"], 398)
    }

    @MainActor func testVerificationAndFitControlsAtLargestTextSize() {
        let app = launch(["light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openAnnotations(app)
        chooseUnit("Millimeters", in: app)
        replace(app.textFields["verification-along-value"], with: "400", in: app)
        replace(app.textFields["verification-insert-height-value"], with: "80", in: app)
        applyAnnotations(app)
        reveal(element("verification-original-summary", in: app), in: app)
        capture(app, "verification-accessibility-light")
        let fitButton = app.buttons["record-interior-fit"]
        reveal(fitButton, in: app)
        XCTAssertTrue(fitButton.isHittable)
        fitButton.tap()
        XCTAssertTrue(app.navigationBars["Physical fit"].waitForExistence(timeout: 4))
        reveal(element("verification-fit-note", in: app), in: app)
        XCTAssertTrue(element("verification-fit-note", in: app).isHittable)
        capture(app, "verification-fit-accessibility-light")
        XCTAssertTrue(app.buttons["cancel-interior-fit"].isHittable)
        app.buttons["cancel-interior-fit"].tap()
    }

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["interior-verification"] + extra
        app.launch()
        XCTAssertFalse(app.staticTexts["verification-fixture-error"].exists)
        XCTAssertTrue(app.navigationBars["Review interior"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func openAnnotations(_ app: XCUIApplication) {
        let button = app.buttons["edit-interior-verification"]
        reveal(button, in: app)
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.navigationBars["Measured dimensions"].waitForExistence(timeout: 4))
    }

    @MainActor private func chooseUnit(_ title: String, in app: XCUIApplication, finishEditing: Bool = true) {
        if finishEditing { finishKeyboard(app) }
        let picker = app.segmentedControls["verification-unit-picker"]
        let option = picker.buttons[title]
        reveal(option, in: app, searchDownFirst: true)
        XCTAssertTrue(option.isHittable)
        option.tap()
    }

    @MainActor private func applyAnnotations(_ app: XCUIApplication) {
        app.buttons["apply-interior-verification"].tap()
        XCTAssertTrue(app.navigationBars["Review interior"].waitForExistence(timeout: 4))
    }

    @MainActor private func recordFit(_ app: XCUIApplication, status: String, note: String) {
        let button = app.buttons["record-interior-fit"]
        reveal(button, in: app)
        button.tap()
        XCTAssertTrue(app.navigationBars["Physical fit"].waitForExistence(timeout: 4))
        let picker = app.buttons["verification-fit-status"]
        reveal(picker, in: app)
        picker.tap()
        XCTAssertTrue(app.buttons[status].waitForExistence(timeout: 3))
        app.buttons[status].tap()
        replace(element("verification-fit-note", in: app), with: note, in: app)
        app.buttons["apply-interior-fit"].tap()
        XCTAssertTrue(app.navigationBars["Review interior"].waitForExistence(timeout: 4))
    }

    @MainActor private func saveAndRead(_ app: XCUIApplication) throws -> [String: Any] {
        app.buttons["save-interior-review"].tap()
        let snapshot = app.staticTexts["verification-persisted-json"]
        XCTAssertTrue(snapshot.waitForExistence(timeout: 4))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.label.utf8)) as? [String: Any])
    }

    @MainActor private func reopen(_ app: XCUIApplication) {
        let button = app.buttons["verification-fixture-reopen"]
        reveal(button, in: app)
        button.tap()
        XCTAssertTrue(app.navigationBars["Review interior"].waitForExistence(timeout: 4))
    }

    @MainActor private func replace(_ field: XCUIElement, with value: String, in app: XCUIApplication) {
        // Reveal the next field with the previous keyboard dismissed. Leave this
        // field focused after typing for the active-unit and active-Save checks.
        finishKeyboard(app)
        reveal(field, in: app)
        XCTAssertTrue(field.isHittable)
        field.tap()
        let old = field.value as? String ?? ""
        if !old.isEmpty && old != field.placeholderValue {
            // Caret placement varies with alignment and horizontal scrolling.
            // Replace a selection instead of guessing where an end tap lands.
            field.press(forDuration: 1.1)
            let selectAll = editMenuAction("Select All", in: app)
            if !selectAll.waitForExistence(timeout: 2) {
                let select = editMenuAction("Select", in: app)
                if select.exists && select.isHittable { select.tap() }
            }
            guard selectAll.waitForExistence(timeout: 2), selectAll.isHittable else {
                XCTFail("The edit menu did not expose Select All for \(field.identifier)")
                return
            }
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            let emptied = field.value as? String ?? ""
            XCTAssertTrue(emptied.isEmpty || emptied == field.placeholderValue,
                          "Replacement must clear the old value, found \(emptied)")
        }
        field.typeText(value)
        let displayed = (field.value as? String ?? "").replacingOccurrences(of: ",", with: "")
        if let requestedNumber = Double(value) {
            XCTAssertEqual(Double(displayed) ?? .nan, requestedNumber, accuracy: 0.000001)
        } else {
            XCTAssertEqual(displayed, value)
        }
    }

    @MainActor private func editMenuAction(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor private func finishKeyboard(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
    }

    @MainActor private func enableMillimeterCorrections(_ app: XCUIApplication) {
        let control = app.switches["interior-correction-millimeters"]
        reveal(control, in: app)
        // SwiftUI exposes the label and trailing native switch as one wide row.
        // Its center lands on the label; target the visible switch itself.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(control.value as? String, "1")
    }

    @MainActor private func incrementClearance(_ identifier: String, in app: XCUIApplication) {
        let control = app.steppers[identifier]
        reveal(control, in: app)
        // The native +/- control is visible but iOS 27 does not expose an
        // "Increment" child. Target its trailing + and verify saved millimeters.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    }

    @MainActor private func assertField(_ identifier: String, equals expected: Double, in app: XCUIApplication) {
        let field = app.textFields[identifier]
        reveal(field, in: app)
        let displayed = (field.value as? String ?? "").replacingOccurrences(of: ",", with: "")
        XCTAssertEqual(Double(displayed) ?? .nan, expected, accuracy: 0.000001)
    }

    @MainActor private func assertStaleLabel(_ app: XCUIApplication) {
        let status = element("verification-fit-state", in: app)
        reveal(status, in: app)
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("needs recheck"), status.label)
    }

    private func verification(_ snapshot: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(snapshot["verification"] as? [String: Any])
    }

    private func fit(_ snapshot: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(try verification(snapshot)["fit"] as? [String: Any])
    }

    private func assertNumber(_ values: [String: Any], _ key: String, _ expected: Double) {
        XCTAssertEqual((values[key] as? NSNumber)?.doubleValue ?? .nan, expected, accuracy: 0.000001)
    }

    private func assertOriginalGeometry(_ snapshot: [String: Any]) throws {
        XCTAssertEqual(snapshot["id"] as? String, "11111111-1111-1111-1111-111111111111")
        assertNumber(snapshot, "heightMM", 100)
        assertNumber(snapshot, "sideClearanceMM", 2)
        assertNumber(snapshot, "topClearanceMM", 2)
        let contours = try XCTUnwrap(snapshot["contours"] as? [[[String: Double]]])
        XCTAssertEqual(contours.count, 1)
        XCTAssertEqual(contours[0], [["x": 0, "y": 0], ["x": 400, "y": 0], ["x": 400, "y": 300], ["x": 0, "y": 300]])
        let original = try XCTUnwrap(snapshot["originalGeometry"] as? [String: Any])
        XCTAssertEqual(original["source"] as? String, "savedGeometry")
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func reveal(_ item: XCUIElement, in app: XCUIApplication, searchDownFirst: Bool = false) {
        let surfaces = [app.collectionViews.firstMatch, app.tables.firstMatch, app.scrollViews.firstMatch]
        let surface = surfaces.first(where: { $0.exists && $0.isHittable }) ?? app
        for down in [searchDownFirst, !searchDownFirst] {
            for _ in 0..<12 {
                if item.exists && item.isHittable { return }
                if down { surface.swipeDown() } else { surface.swipeUp() }
            }
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
