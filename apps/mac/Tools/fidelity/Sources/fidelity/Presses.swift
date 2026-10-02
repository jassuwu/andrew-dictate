import Foundation

/// the app's own numbers, from its press log: key-up → ⌘V and key-down →
/// first audio, p50 and p90, by word count. reads press lines on stdin from
/// wherever they came from — `log show`, `log stream`, or "copy
/// diagnostics" — and ignores every other line.
enum Presses {
    private struct Press {
        let words: Int
        let samples: Int
        let transport: String
        let firstBuffer: Int?
        let keyUp: Int
        let samplesReady: Int?
        let transcript: Int?
        let pastePosted: Int

        var keyUpToPaste: Int { pastePosted - keyUp }
        /// the samples are 16 kHz mono.
        var seconds: Double { Double(samples) / 16_000 }
    }

    static func run(_ arguments: [String]) throws {
        guard arguments.isEmpty else {
            throw FidelityError("presses reads press lines on stdin and takes no arguments")
        }
        var presses: [Press] = []
        var firstBuffers: [String: [Int]] = [:]
        while let line = readLine() {
            let fields = parse(line)
            // a press that heard the mic, delivered or not, says how fast it did.
            if let firstBuffer = fields["first_buffer_ms"].flatMap(Int.init) {
                firstBuffers[fields["transport"] ?? "unknown", default: []].append(firstBuffer)
            }
            guard fields["outcome"] == "delivered",
                  fields["retry"] == nil,
                  let words = fields["words"].flatMap(Int.init),
                  let samples = fields["samples"].flatMap(Int.init),
                  let keyUp = fields["key_up_ms"].flatMap(Int.init),
                  let pastePosted = fields["paste_posted_ms"].flatMap(Int.init) else {
                continue
            }
            presses.append(Press(
                words: words,
                samples: samples,
                transport: fields["transport"] ?? "unknown",
                firstBuffer: fields["first_buffer_ms"].flatMap(Int.init),
                keyUp: keyUp,
                samplesReady: fields["samples_ready_ms"].flatMap(Int.init),
                transcript: fields["transcript_ms"].flatMap(Int.init),
                pastePosted: pastePosted
            ))
        }
        guard !presses.isEmpty || !firstBuffers.isEmpty else {
            throw FidelityError("no press lines on stdin")
        }

        print("key-up → ⌘V, delivered presses")
        print("  words     n    p50      p90")
        for bucket in Bench.buckets {
            let runs = presses.filter { bucket.contains($0.words) }.map(\.keyUpToPaste)
            row("\(bucket.lowerBound)–\(bucket.upperBound)", runs)
        }
        row("> 150", presses.filter { $0.words > 150 }.map(\.keyUpToPaste))
        let short = presses.filter { $0.seconds < 15 }
        row("< 15 s", short.map(\.keyUpToPaste))

        // where the time went, for the takes the target is about.
        print("")
        print("  under 15 s, by stage (p50):")
        stage("    key-up → samples ready", short.compactMap { p in p.samplesReady.map { $0 - p.keyUp } })
        stage("    samples → transcript", short.compactMap { p in
            guard let s = p.samplesReady, let t = p.transcript else { return nil }
            return t - s
        })
        stage("    transcript → ⌘V", short.compactMap { p in p.transcript.map { p.pastePosted - $0 } })

        print("")
        print("key-down → first audio, every press that heard the mic")
        print("  mic         n    p50      p90")
        for transport in firstBuffers.keys.sorted() {
            row(transport, firstBuffers[transport] ?? [])
        }
    }

    private static func row(_ label: String, _ values: [Int]) {
        guard !values.isEmpty else { return }
        let doubles = values.map(Double.init)
        let p50 = "\(Int(Bench.percentile(doubles, 0.5))) ms".padding(toLength: 7, withPad: " ", startingAt: 0)
        print(
            "  \(label.padding(toLength: 11, withPad: " ", startingAt: 0))"
                + "\(String(values.count).padding(toLength: 5, withPad: " ", startingAt: 0))"
                + "\(p50)  \(Int(Bench.percentile(doubles, 0.9))) ms"
        )
    }

    private static func stage(_ label: String, _ values: [Int]) {
        guard !values.isEmpty else { return }
        print("\(label)  \(Int(Bench.percentile(values.map(Double.init), 0.5))) ms")
    }

    /// `key=value` pairs anywhere in the line; a quoted value (the mic's
    /// name) may hold spaces and escaped quotes.
    private static func parse(_ line: String) -> [String: String] {
        // a record starts at "at=": the start of a press-log line, or
        // after whatever prefix `log` puts in front of it.
        let start: String.Index
        if line.hasPrefix("at=") {
            start = line.startIndex
        } else if let at = line.range(of: " at=") {
            start = line.index(after: at.lowerBound)
        } else {
            return [:]
        }
        var fields: [String: String] = [:]
        var rest = line[start...]
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " }
            guard let equals = rest.firstIndex(of: "=") else { break }
            let key = String(rest[..<equals])
            rest = rest[rest.index(after: equals)...]
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                while let character = rest.first {
                    rest = rest.dropFirst()
                    if escaped {
                        value.append(character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        value.append(character)
                    }
                }
            } else {
                let end = rest.firstIndex(of: " ") ?? rest.endIndex
                value = String(rest[..<end])
                rest = rest[end...]
            }
            // the speech model was `engine=` in lines written before the
            // key was renamed; both read as `model`.
            fields[key == "engine" ? "model" : key] = value
        }
        return fields
    }
}
