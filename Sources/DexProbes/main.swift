import Foundation

/// The view probes, kept out of the app: each stages the real views offscreen
/// and reads what they did. `swift run DexProbes --<name>-probe [arguments]`.
let probes: [String: () -> Int32] = [
    "--preview-probe": PreviewProbe.run,
    "--preview-leak-probe": PreviewLeakProbe.run,
    "--ask-card-probe": AskCardProbe.run,
    "--selection-probe": SelectionProbe.run,
    "--scroll-probe": ScrollProbe.run,
    "--switch-probe": SwitchProbe.run,
    "--live-probe": LiveProbe.run,
    "--fold-probe": FoldProbe.run,
    "--native-parity-probe": NativeParityProbe.run,
    "--menu-label-probe": MenuLabelProbe.run,
]

guard let probe = CommandLine.arguments.dropFirst().first.flatMap({ probes[$0] }) else {
    let names = probes.keys.sorted().joined(separator: " | ")
    FileHandle.standardError.write(Data("usage: DexProbes <\(names)> [arguments]\n".utf8))
    exit(2)
}
exit(probe())
