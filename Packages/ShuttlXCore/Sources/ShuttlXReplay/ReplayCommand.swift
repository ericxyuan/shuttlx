import Foundation
import ShuttlXCore

/// No production data is seeded. Run with an explicitly supplied recorded dataset.
@main struct ReplayCommand {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 || arguments.count == 2 else {
            print("Usage: swift run shuttlx-replay recording.json [report.json]")
            return
        }
        let recording = try MotionRecording.decode(Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        let events = MotionReplay.process(samples: recording.samples)
        struct Report: Encodable {
            let name: String
            let synthetic: Bool
            let note: String
            let evaluation: ReplayEvaluation
            let events: [ShotEvent]
        }
        let report = Report(name: recording.name, synthetic: recording.isSynthetic,
            note: "Replay uses production defaults. Detection is candidate-swing counting; unknown shot types are retained. Synthetic regression traces do not validate real-world badminton accuracy.",
            evaluation: ReplayEvaluation.evaluate(events: events, labels: recording.labels), events: events)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if arguments.count == 2 { try data.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic) }
        else { print(String(decoding: data, as: UTF8.self)) }
    }
}
