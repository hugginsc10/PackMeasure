import Testing
@testable import PackMeasure

@Suite("Independent measurement input")
struct InteriorVerificationLengthDraftTests {
    @Test func unitChangesRetainExactStoredMillimetersWithoutReparsingDisplay() {
        // This value cannot be represented by the existing two-decimal inch display.
        let exactMM = 270.612345678901
        var draft = InteriorVerificationLengthDraft(millimeters: exactMM)
        for _ in 0..<100 {
            let inches = draft.changeUnit(to: .inches)
            let centimeters = draft.changeUnit(to: .centimeters)
            let millimeters = draft.changeUnit(to: .millimeters)
            #expect(inches && centimeters && millimeters)
        }
        #expect(draft.millimeters == exactMM)
        #expect(draft.text == String(exactMM))
    }

    @Test func editingUsesTheSelectedUnitAndAcceptsCommaDecimal() throws {
        var draft = InteriorVerificationLengthDraft()
        draft.setText(" 270,6123 ")
        #expect(draft.isValid)
        #expect(try #require(draft.millimeters) == 270.6123)
        let changedToInches = draft.changeUnit(to: .inches)
        #expect(changedToInches)
        draft.setText("3,5")
        #expect(abs(try #require(draft.millimeters) - 88.9) < 0.0000001)
        let changedToCentimeters = draft.changeUnit(to: .centimeters)
        #expect(changedToCentimeters)
        draft.setText("8,89123")
        let editedMM = try #require(draft.millimeters)
        #expect(abs(editedMM - 88.9123) < 0.0000001)
        for _ in 0..<100 {
            let millimeters = draft.changeUnit(to: .millimeters)
            let inches = draft.changeUnit(to: .inches)
            let centimeters = draft.changeUnit(to: .centimeters)
            #expect(millimeters && inches && centimeters)
        }
        #expect(draft.millimeters == editedMM)
    }

    @Test func blankClearsOnlyTheOptionalDraftValue() {
        var draft = InteriorVerificationLengthDraft(millimeters: 400)
        draft.setText(" \n ")
        #expect(draft.isValid)
        #expect(draft.millimeters == nil)
        let changed = draft.changeUnit(to: .inches)
        #expect(changed)
        #expect(draft.text.isEmpty)
        #expect(draft.millimeters == nil)
    }

    @Test func invalidNonemptyInputCannotBecomeValidThroughUnitSwitching() {
        for text in ["0", "-1", "nan", "inf", "1e309", ".", "8..9", "1,2,3"] {
            var draft = InteriorVerificationLengthDraft(millimeters: 400)
            draft.setText(text)
            #expect(!draft.isValid)
            #expect(draft.millimeters == nil)
            let changed = draft.changeUnit(to: .centimeters)
            #expect(!changed)
            #expect(draft.unit == .millimeters)
            #expect(draft.text == text)
        }
        var overflow = InteriorVerificationLengthDraft(unit: .inches)
        overflow.setText("1e308")
        #expect(!overflow.isValid)
        #expect(overflow.millimeters == nil)
    }
}
