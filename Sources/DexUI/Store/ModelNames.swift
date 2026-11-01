import DexCore
import Foundation
import Observation

/// What the CLI calls each row of the model picker, read one subprocess per row.
@MainActor
@Observable
final class ModelNames {
    private(set) var names: [SessionModel: String] = [:]
    private var isReading = false

    /// Asked at launch, so the names are in before the composer first opens,
    /// and again each time it opens for any row still missing: each row costs
    /// a subprocess that reaches the network. They go together rather than in
    /// turn — four in a row is four seconds of a menu filling itself in while
    /// you read it.
    func read(keeping picked: SessionModel, executable: @escaping @MainActor () async -> String) {
        guard !isReading else { return }
        // Only what is still missing, so a row the CLI won't answer for costs
        // one subprocess the next time rather than four, and a row that failed
        // on a hiccup gets asked again.
        let missing = SessionModel.offered(keeping: picked)
            .filter { names[$0] == nil }
        guard !missing.isEmpty else { return }
        isReading = true

        Task {
            let executable = await executable()
            let named = await withTaskGroup(of: (SessionModel, String?).self) { group in
                for row in missing {
                    group.addTask(priority: .utility) {
                        (row, ModelReadout.read(row, executable: executable))
                    }
                }
                var names: [SessionModel: String] = [:]
                for await (row, name) in group {
                    if let name { names[row] = name }
                }
                return names
            }
            self.names.merge(named) { _, latest in latest }
            self.isReading = false
        }
    }

    /// Every row's name, or none of them. Default's own name is in here and is
    /// the only thing that says which class it lands on — the picker no longer
    /// draws it as a row, so this is where that answer has to come from.
    func named(keeping picked: SessionModel) -> [SessionModel: String] {
        SessionModel.named(names, covering: SessionModel.offered(keeping: picked))
    }
}
