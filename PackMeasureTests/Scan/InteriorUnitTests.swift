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
    @Test func enteredInchesStoreExactMillimeters() {
        #expect(abs(InteriorUnit.inches.millimeters(from: 3.5) - 88.9) < 0.000001)
        for mm in [0.5, 2, 88.9, 270.6, 3000] {
            #expect(abs(InteriorUnit.inches.millimeters(from: InteriorUnit.inches.value(fromMillimeters: mm)) - mm) < 0.000001)
            #expect(InteriorUnit.millimeters.value(fromMillimeters: mm) == mm)
        }
    }
}
