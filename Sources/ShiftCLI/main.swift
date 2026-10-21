import Foundation
import ShiftCore

// shift-cli suggest <files...>
// shift-cli <action-id> [--out <dir>] <files...>

func usage() -> Never {
    print("""
    Usage:
      shift-cli suggest <files...>
      shift-cli <action-id> [--out <dir>] <files...>

    Run `shift-cli suggest <file>` to see the action ids for a file.
    """)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

var outputDirectory = Processor.defaultOutputDirectory
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    outputDirectory = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
let files = args.map { URL(fileURLWithPath: $0).standardizedFileURL }
guard !files.isEmpty else { usage() }

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

if command == "suggest" {
    for group in Suggestions.groups(for: files) {
        print("\(group.files.count) \(group.kind.label(count: group.files.count))")
        for action in group.actions {
            print("  \(action.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(action.title) · \(action.subtitle)")
        }
    }
    exit(0)
}

guard let action = ShiftAction(id: command) else {
    print("Unknown action: \(command)")
    usage()
}

let report = await Processor.run(action, on: files, outputDirectory: outputDirectory)
for result in report.results {
    let delta = result.sourceBytes > 0 ? Int((Double(result.outputBytes) / Double(result.sourceBytes) - 1) * 100) : 0
    print("✓ \(result.output.path)  \(formatBytes(result.sourceBytes)) → \(formatBytes(result.outputBytes)) (\(delta > 0 ? "+" : "")\(delta)%)\(result.note.map { "  [\($0)]" } ?? "")")
}
for failure in report.failures {
    print("✗ \(failure.file.lastPathComponent): \(failure.message)")
}
exit(report.failures.isEmpty ? 0 : 2)
