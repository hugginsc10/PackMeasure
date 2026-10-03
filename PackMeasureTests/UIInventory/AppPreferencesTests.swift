import Foundation
import Testing
@testable import PackMeasure

@Suite("Persistent app preferences")
struct AppPreferencesTests {
    @Test @MainActor func defaultsAndChoicesSurviveARecreatedModel() {
        let suite = "preferences-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = AppPreferences(defaults: defaults)
        #expect(original.appearance == .system)
        #expect(original.units == .inches)
        original.appearance = .dark
        original.units = .both
        original.roomGuidance = .tightCloset
        original.floorplanLabels = .wallIDs
        let recreated = AppPreferences(defaults: defaults)
        #expect(recreated.appearance == .dark)
        #expect(recreated.units == .both)
        #expect(recreated.roomGuidance == .tightCloset)
        #expect(recreated.floorplanLabels == .wallIDs)
    }

    @Test @MainActor func migratesAnExistingInteriorMetricChoiceAndIgnoresInvalidValues() {
        let suite = "preferences-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("millimeters", forKey: InteriorUnit.storageKey)
        defaults.set("future-unknown", forKey: AppPreferences.Keys.appearance)
        let migrated = AppPreferences(defaults: defaults)
        #expect(migrated.units == .centimeters)
        #expect(migrated.appearance == .system)
        migrated.units = .inches
        #expect(AppPreferences(defaults: defaults).units == .inches)
    }

    @Test func exactInputConversionRoundTripsWithoutChangingGeometry() {
        #expect(abs(MeasurementInputUnit.centimeters.meters(from: 25.4) - 0.254) < 1e-12)
        #expect(abs(MeasurementInputUnit.inches.converted(value: 10, to: .centimeters) - 25.4) < 1e-12)
        for meters in [0.0001, 0.254, 1.2192, 5.0] {
            for unit in MeasurementInputUnit.allCases {
                #expect(abs(unit.meters(from: unit.value(fromMeters: meters)) - meters) < 1e-12)
            }
        }
    }

    @Test func lengthsAndPlanningVolumesUseTheRequestedUnits() {
        #expect(MeasurementUnits.inches.length(meters: 5) == "16 ft 5 in")
        #expect(MeasurementUnits.centimeters.length(meters: 5) == "500.0 cm")
        #expect(MeasurementUnits.both.preciseLength(millimeters: 254) == "10.00 in · 25.40 cm")
        #expect(MeasurementUnits.centimeters.preciseLength(millimeters: 0.5) == "0.05 cm")
        #expect(MeasurementUnits.centimeters.areaFromSquareFeet(10.7639) == "1.00 m²")
        #expect(MeasurementUnits.centimeters.volumeFromCubicFeet(35.3147) == "1.00 m³")
    }

    @Test func smallItemPreviewsKeepUsefulVolumePrecision() {
        let sideInFeet: Double = 8.0 / 12.0
        let cubeEightInches = sideInFeet * sideInFeet * sideInFeet
        #expect(MeasurementUnits.inches.volumeFromCubicFeet(cubeEightInches, imperialDecimalPlaces: 1, metricDecimalPlaces: 3) == "0.3 cu ft")
        #expect(MeasurementUnits.centimeters.volume(cubicMeters: 0.001, imperialDecimalPlaces: 1, metricDecimalPlaces: 3) == "0.001 m³")
        #expect(MeasurementUnits.both.volumeFromCubicFeet(0.75, imperialDecimalPlaces: 1, metricDecimalPlaces: 3) == "0.8 cu ft · 0.021 m³")
    }
}
