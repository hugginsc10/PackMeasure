import SwiftUI

/// Simulator-only saved-data fixture. The initial JSON deliberately predates
/// verification fields, and every Save/reopen uses the application's real store.
struct InteriorVerificationFixture: View {
    @State private var record: InteriorMeasurement?
    @State private var saved = false
    @State private var failure: String?
    private let store = InteriorStore(
        url: URL.documentsDirectory.appending(path: "verification-fixture-interiors.json")
    )

    init() {
        var initial: InteriorMeasurement?
        var message: String?
        do {
            if !ProcessInfo.processInfo.arguments.contains("verification-preserve") {
                try Self.legacyJSON.write(to: store.url, options: .atomic)
            }
            initial = try store.load().first
            if initial == nil { message = "No saved fixture record" }
        } catch {
            message = error.localizedDescription
        }
        _record = State(initialValue: initial)
        _failure = State(initialValue: message)
    }

    var body: some View {
        Group {
            if let failure {
                Text(failure).accessibilityIdentifier("verification-fixture-error")
            } else if saved {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Saved practice drawer")
                                .accessibilityIdentifier("verification-fixture-saved")
                            Text("Persisted measurement snapshot")
                                .font(.caption2)
                                .accessibilityIdentifier("verification-persisted-json")
                                .accessibilityLabel(persistedJSON)
                            Button("Reopen practice drawer") {
                                do {
                                    record = try store.load().first
                                    saved = false
                                } catch {
                                    failure = error.localizedDescription
                                }
                            }
                            .accessibilityIdentifier("verification-fixture-reopen")
                        }.padding()
                    }
                    .navigationTitle("Synthetic saved record")
                }
            } else if let record {
                NavigationStack {
                    InteriorReviewView(record: record, onDiscard: {
                        saved = true
                    }, onSave: { updated in
                        try store.save([updated])
                        self.record = updated
                        saved = true
                    })
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Synthetic verification fixture · no physical fit evidence")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("verification-fixture-disclaimer")
        }
    }

    private var persistedJSON: String {
        do {
            guard let persisted = try store.load().first else { return "Missing saved record" }
            let encoded = try JSONEncoder().encode(persisted)
            var snapshot = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            snapshot["_qaFitIsStale"] = persisted.fitIsStale
            snapshot["_qaCurrentFitStatus"] = persisted.currentFitStatus.rawValue
            return String(decoding: try JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys), as: UTF8.self)
        } catch {
            return "Store read failed: \(error.localizedDescription)"
        }
    }

    private static let legacyJSON = Data("""
    [{"id":"11111111-1111-1111-1111-111111111111","name":"Legacy practice drawer",
    "capturedAt":0,"contours":[[{"x":0,"y":0},{"x":400,"y":0},{"x":400,"y":300},{"x":0,"y":300}]],
    "heightMM":100,"heightSource":"lidar","sideClearanceMM":2,"topClearanceMM":2}]
    """.utf8)
}
