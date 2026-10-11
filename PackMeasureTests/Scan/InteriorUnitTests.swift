import Testing
@testable import PackMeasure

@Suite("Interior display units")
struct InteriorUnitTests {
    @Test func inchesShowHundredthsOfTheStoredMillimeters() {
        // Values from a device review of a 10.5 x 11.2 in cabinet compartment.
        #expect(InteriorUnit.inches.format(millimeters: 270.6) == "10.65 in")
        #expect(InteriorUnit.inches.format(millimeters: 278.2) == "10.95 in")
        #expect(InteriorUnit.inches.format(millimeters: 240) == "9.45 in")
    }
    @Test func millimetersShowTenths() {
        #expect(InteriorUnit.millimeters.format(millimeters: 270.6) == "270.6 mm")
    }
    @Test func centimetersShowHundredthsButInputRetainsExactMillimeters() {
        #expect(InteriorUnit.centimeters.format(millimeters: 270.6) == "27.06 cm")
        #expect(abs(InteriorUnit.centimeters.millimeters(from: 27.06) - 270.6) < 0.000001)
        for mm in [0.5, 2, 88.9, 270.6, 3000] {
            #expect(abs(InteriorUnit.centimeters.millimeters(from: InteriorUnit.centimeters.value(fromMillimeters: mm)) - mm) < 0.000001)
        }
    }
    @Test func enteredInchesStoreExactMillimeters() {
        #expect(abs(InteriorUnit.inches.millimeters(from: 3.5) - 88.9) < 0.000001)
        for mm in [0.5, 2, 88.9, 270.6, 3000] {
            #expect(abs(InteriorUnit.inches.millimeters(from: InteriorUnit.inches.value(fromMillimeters: mm)) - mm) < 0.000001)
            #expect(InteriorUnit.millimeters.value(fromMillimeters: mm) == mm)
        }
    }
    @Test func switchingHeightInputUnitsConvertsTheDraftWithoutDisplayRounding() throws {
        var draft = InteriorHeightDraft()
        draft.text = "3.5"
        let changedToCentimeters = draft.changeInputUnit(to: .centimeters)
        #expect(changedToCentimeters)
        #expect(abs(try #require(Double(draft.text)) - 8.89) < 0.000001)
        #expect(abs(try #require(draft.millimeters) - 88.9) < 0.000001)
        draft.text = "8.89123"
        for _ in 0..<10 {
            let changedToInches = draft.changeInputUnit(to: .inches)
            let changedBackToCentimeters = draft.changeInputUnit(to: .centimeters)
            #expect(changedToInches)
            #expect(changedBackToCentimeters)
        }
        #expect(abs(try #require(draft.millimeters) - 88.9123) < 0.000001)
        draft.text = "8,89"
        #expect(abs(try #require(draft.millimeters) - 88.9) < 0.000001)
    }
    @Test func invalidHeightTextCannotBeReinterpretedDuringAUnitChange() {
        for invalid in [".", "nan", "inf", "8..9"] {
            var draft = InteriorHeightDraft()
            draft.text = invalid
            let changed = draft.changeInputUnit(to: .centimeters)
            #expect(!changed)
            #expect(draft.inputUnit == .inches && draft.text == invalid)
            #expect(draft.millimeters == nil)
        }
    }
    @Test func centimeterInputKeepsInsertGeometryAndSVGInMillimeters() throws {
        var draft = InteriorHeightDraft()
        let changedToCentimeters = draft.changeInputUnit(to: .centimeters)
        #expect(changedToCentimeters)
        draft.text = "8.89"
        let width = InteriorUnit.centimeters.millimeters(from: 27.06)
        let depth = InteriorUnit.centimeters.millimeters(from: 27.82)
        let record = InteriorMeasurement(contours: [[.init(x: 0, y: 0), .init(x: width, y: 0),
                                                     .init(x: width, y: depth), .init(x: 0, y: depth)]],
                                         heightMM: try #require(draft.millimeters), heightSource: .entered)
        let inset = try record.insertContours()[0]
        #expect(abs(inset.map(\.x).max()! - inset.map(\.x).min()! - 266.6) < 0.000001)
        #expect(abs(inset.map(\.y).max()! - inset.map(\.y).min()! - 274.2) < 0.000001)
        let svg = try record.svg()
        #expect(svg.contains("width=\"266.600mm\" height=\"274.200mm\""))
        #expect(svg.contains("viewBox=\"0 0 266.600 274.200\""))
        #expect(svg.contains("Draft extrusion height: 86.900 mm"))
    }
}
