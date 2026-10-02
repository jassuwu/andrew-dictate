import Foundation

/// the three subcommands, and nothing else. each one is a plain function in
/// its own file; this file only reads the command line and reports failure.
@main
struct Fidelity {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            print(usage)
            exit(2)
        }
        let command = arguments.removeFirst()

        do {
            switch command {
            case "passages":
                try Passages.run(arguments)
            case "record":
                try await Record.run(arguments)
            case "compare":
                let allEqual = try await Compare.run(arguments)
                exit(allEqual ? 0 : 1)
            case "help", "--help", "-h":
                print(usage)
            default:
                throw FidelityError("unknown command '\(command)'\n\n\(usage)")
            }
        } catch {
            FileHandle.standardError.write(Data("fidelity: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    static let usage = """
    usage: fidelity <command>

      passages [--count N] [--force]
          pick reading prompts from your dictation history.
      record <n>
          show prompt n, record the mic until Enter, save passage-NN.wav.
      compare [--files a.wav b.wav ...] [--chunk S] [--left S] [--right S] [--buffer-ms MS]
          batch against streaming on each recording. exits 1 if any differ.

    recordings live in \(Folders.recordings.path)
    """
}

/// a failure with a message fit to print, nothing more.
struct FidelityError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
