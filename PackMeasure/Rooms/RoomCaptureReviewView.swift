import SwiftUI

/// Keep each candidate intact. Picking an outline explicitly starts its own
/// wall selection; no live/processed segments or identifiers are combined.
struct RoomCaptureReviewView: View {
    let comparison: RoomCaptureComparison
    let store: RoomScanStore
    let diagnostics: String
    let onSaved: () -> Void
    let onScanAgain: () -> Void
    @State private var chosen: MeasuredRoom?
    @State private var preview: MeasuredRoom?

    init(comparison: RoomCaptureComparison, store: RoomScanStore, diagnostics: String,
         onSaved: @escaping () -> Void, onScanAgain: @escaping () -> Void) {
        self.comparison = comparison
        self.store = store
        self.diagnostics = diagnostics
        self.onSaved = onSaved
        self.onScanAgain = onScanAgain
        _chosen = State(initialValue: comparison.needsChoice ? nil : comparison.processed)
    }

    private var report: String { diagnostics + "\n" + comparison.diagnosticSummary }

    var body: some View {
        Group {
            if let chosen {
                VStack(spacing: 0) {
                    if comparison.live != nil {
                        Button { self.chosen = nil } label: {
                            Label("Compare outlines", systemImage: "square.on.square")
                        }.padding(.top, 8).accessibilityIdentifier("compare-outlines")
                    }
                    RoomScanReviewView(room: chosen, store: store,
                                       diagnostics: report + "\nreview_source=\(chosen.captureSource?.rawValue ?? "processed")",
                                       onSaved: onSaved, onScanAgain: onScanAgain)
                        .id(chosen.id)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(comparison.title).font(.title2.bold())
                        Text(comparison.message).font(.subheadline).foregroundStyle(.secondary)
                        if let live = comparison.live {
                            candidate(live, title: "Live outline", subtitle: "Unprocessed · captured before Finish", action: "Review live outline")
                        }
                        if let processed = comparison.processed {
                            candidate(processed, title: "Finished outline", subtitle: "After room processing", action: "Review finished outline")
                        }
                        Text("Choosing another outline starts a new wall selection. Neither outline verifies the ceiling height.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Scan again", action: onScanAgain).buttonStyle(.bordered)
                        ShareLink("Diagnostics", item: report)
                    }.padding(20)
                }.navigationTitle("Compare outlines")
            }
        }
        .fullScreenCover(item: $preview) { RoomFloorplanView(room: $0) }
    }

    private func candidate(_ room: MeasuredRoom, title: String, subtitle: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(room.walls.count) \(room.walls.count == 1 ? "wall" : "walls")").font(.subheadline)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Button { preview = room } label: {
                RoomFloorplanPreview(walls: room.walls).frame(height: 115)
                    .frame(maxWidth: .infinity)
                    .background(MeasureStyle.background, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel("Preview \(title.lowercased()) in 2D or 3D")
            Button(action) { chosen = room }.buttonStyle(MeasurePrimaryButton())
        }.measurePanel()
    }
}
