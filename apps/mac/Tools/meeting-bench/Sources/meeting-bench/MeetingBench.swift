import Foundation

/// the subcommands, and nothing else. each is a plain function in its own file;
/// this file only reads the command line and reports failure.
@main
struct MeetingBench {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            print(usage)
            exit(2)
        }
        let command = arguments.removeFirst()

        do {
            switch command {
            case "vad-check":
                try await VadCheck.run(arguments)
            case "decode":
                try await Decode.run(arguments)
            case "simulate":
                try Simulate.run(arguments)
            case "live":
                try await Live.run(arguments)
            case "spool":
                try Spool.build(arguments)
            case "tail":
                try Spool.tail(arguments)
            case "ending":
                try await Ending.run(arguments)
            case "help", "--help", "-h":
                print(usage)
            default:
                throw BenchError("unknown command '\(command)'\n\n\(usage)")
            }
        } catch {
            FileHandle.standardError.write(Data("meeting-bench: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    static let usage = """
    usage: meeting-bench <command>

    measurement A, do two sides of a model keep up live?
      vad-check --you f.wav --them f.wav --truth truth.json [--cap S] [--threshold P] [--min-silence S]
          where the VAD cuts, against the turns that were synthesized.
      decode --engine E --you f.wav --them f.wav --out run.json [--seconds N] [--cap S] [--min-silence S] [--threshold P]
          cut each side, decode every stretch once, one after another. E is whisper-large-v3,
          parakeet-v3, parakeet-v2 or whisper-turbo (turbo is never downloaded).
      simulate run.json ...
          the shared queue, from the decode times a run measured.
      live --engine E --you f.wav --them f.wav --seconds N --out run.json [--compare offline.json]
          the same, with the audio fed at wall-clock speed.

    measurement B, how long does the end of a meeting take?
      spool --you f.wav --them f.wav --hours H --out spool.caf
          a two-channel spool in the app's format, the two files looped to H hours.
      tail --from f.wav [--start S] [--seconds 20] --out tail.wav
          20 seconds of a file, from S or ending at its last audible sample, for the stop-time decode.
      ending --spool spool.caf --tail tail.wav [--no-whisper]
          the end of a meeting, step by step. wrap in /usr/bin/time -l for peak memory.
          --no-whisper skips the model and the tail decode (steps 1 and 2 only).
    """
}
