import SwiftUI

/// Synthetic storage failures in the simulator-only QA target.
@MainActor
@Observable
private final class InventoryRecoveryFixtureModel {
    let appModel: AppModel
    let store: FixtureInventoryStore
    let offersRepair: Bool
    let saved = MeasuredItem(name: "Saved fixture box", lengthMeters: 0.6,
                             widthMeters: 0.4, heightMeters: 0.3, confidence: .medium)

    init(failWrites: Bool) {
        let url = URL.temporaryDirectory.appending(path: "inventory-recovery-\(UUID().uuidString).json")
        store = FixtureInventoryStore(backing: InventoryStore(storageURL: url))
        offersRepair = !failWrites
        if failWrites {
            try! store.save([saved])
            store.failWrites = true
        } else {
            try! Data("unreadable fixture inventory".utf8).write(to: url)
        }
        appModel = AppModel(store: store)
    }

    func repair() { try! store.save([saved]) }
}

private final class FixtureInventoryStore: InventoryStoring {
    let backing: InventoryStore
    var failWrites = false
    init(backing: InventoryStore) { self.backing = backing }
    func load() throws -> [MeasuredItem] { try backing.load() }
    func save(_ items: [MeasuredItem]) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try backing.save(items)
    }
}

struct InventoryRecoveryFixture: View {
    @State private var fixture: InventoryRecoveryFixtureModel
    init(failWrites: Bool) { _fixture = State(initialValue: InventoryRecoveryFixtureModel(failWrites: failWrites)) }

    var body: some View {
        VStack(spacing: 0) {
            HomeView().environment(fixture.appModel).task { fixture.appModel.loadIfNeeded() }
            if fixture.offersRepair {
                Button("Make test inventory readable") { fixture.repair() }
                    .accessibilityIdentifier("fixture-repair-inventory")
            }
        }
    }
}
