import AVFoundation
import Foundation

let sampleRate = 16_000

enum Side: String, Codable, Sendable {
    case you, them
}

struct BenchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// a 16 kHz mono wav, whole, as floats.
func readMono(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == Double(sampleRate) else {
        throw BenchError("\(url.lastPathComponent) is \(file.processingFormat.sampleRate) Hz, not \(sampleRate)")
    }
    let frames = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
        throw BenchError("could not allocate \(frames) frames")
    }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func writeMono(_ samples: [Float], to url: URL) throws {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { throw BenchError("could not make a buffer") }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

/// the two sides of one meeting, same length.
struct Sides: Sendable {
    let you: [Float]
    let them: [Float]

    var seconds: Double { Double(them.count) / Double(sampleRate) }

    func samples(_ side: Side) -> [Float] { side == .you ? you : them }

    /// only the first `seconds` of each, for a shorter run.
    func prefix(seconds: Double) -> Sides {
        let n = min(you.count, them.count, Int(seconds * Double(sampleRate)))
        return Sides(you: Array(you[..<n]), them: Array(them[..<n]))
    }

    static func load(you: String, them: String) throws -> Sides {
        let y = try readMono(URL(fileURLWithPath: you))
        let t = try readMono(URL(fileURLWithPath: them))
        let n = min(y.count, t.count)
        return Sides(you: Array(y[..<n]), them: Array(t[..<n]))
    }
}

/// `--name value` pairs and bare flags, in whatever order.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String], flags known: Set<String> = []) throws {
        var rest = arguments[...]
        while let key = rest.popFirst() {
            guard key.hasPrefix("--") else { throw BenchError("unexpected argument '\(key)'") }
            let name = String(key.dropFirst(2))
            if known.contains(name) {
                flags.insert(name)
            } else {
                guard let value = rest.popFirst() else { throw BenchError("--\(name) needs a value") }
                values[name] = value
            }
        }
    }

    func string(_ name: String) -> String? { values[name] }

    func require(_ name: String) throws -> String {
        guard let value = values[name] else { throw BenchError("--\(name) is required") }
        return value
    }

    func double(_ name: String, default fallback: Double? = nil) throws -> Double {
        if let text = values[name] {
            guard let value = Double(text) else { throw BenchError("--\(name) is not a number: \(text)") }
            return value
        }
        guard let fallback else { throw BenchError("--\(name) is required") }
        return fallback
    }

    func has(_ name: String) -> Bool { flags.contains(name) }
}
