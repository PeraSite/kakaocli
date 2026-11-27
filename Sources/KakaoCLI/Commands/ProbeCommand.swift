import ArgumentParser
import KakaoCore

/// Development aid: look at the KakaoTalk UI without activating it. See `FastSender.probe`.
struct ProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui-probe", abstract: "Dump parts of the KakaoTalk UI (development)", shouldDisplay: false)
    @Option(name: .long) var depth: Int = 4
    @Argument var steps: [String] = ["main"]
    func run() { print(FastSender.probe(steps, depth: depth)) }
}
