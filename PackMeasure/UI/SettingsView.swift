import SwiftUI

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("settings-appearance")
            }

            Section {
                Picker("Show dimensions in", selection: $preferences.units) {
                    ForEach(MeasurementUnits.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("settings-units")
                LabeledContent("Example", value: preferences.units.preciseLength(millimeters: 254))
                    .accessibilityIdentifier("settings-unit-example")
            } header: {
                Text("Measurements")
            } footer: {
                Text("Room lengths use feet and inches or centimeters. Metric area and volume use square and cubic meters. Saved measurements keep their original precision. CAD exports stay in millimeters.")
            }

            Section {
                Picker("Room guidance", selection: $preferences.roomGuidance) {
                    ForEach(RoomCaptureGuidance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("settings-room-guidance")
                Picker("Floorplan labels", selection: $preferences.floorplanLabels) {
                    ForEach(FloorplanLabelMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("settings-floorplan-labels")
            } header: {
                Text("Scan defaults")
            } footer: {
                Text("Choose the guidance for your next room scan and the labels shown when you open a floorplan. You can also change these while measuring.")
            }

            Section("About") {
                LabeledContent("PackMeasure", value: version)
                Text("Rooms and inventory are saved on this iPhone. These preferences apply across the app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .pickerStyle(.menu)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}
