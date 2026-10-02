import AVFoundation
import Foundation

/// the spool as the app writes it: one two-channel 16 kHz float caf, left = you, right = them.
/// `init` and `append` are `SpoolAudioFile`'s (Sources/Meetings/MeetingAudio.swift) minus the
/// actor; `read` below is its `read`, unchanged. if the app's format moves, move these.
final class SpoolWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat

    init(url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 2,
            interleaved: false
        ) else {
            throw CocoaError(.featureUnsupported)
        }
        self.format = format
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func append(you: ArraySlice<Float>, them: ArraySlice<Float>) throws {
        let frames = AVAudioFrameCount(min(you.count, them.count))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else {
            return
        }
        buffer.frameLength = frames
        you.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: Int(frames)) }
        them.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: Int(frames)) }
        try file.write(from: buffer)
    }
}

/// `SpoolAudioFile.read`, as it is in the app.
enum SpoolRead {
    static func read(_ url: URL) throws -> (you: [Float], them: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else {
            return ([], [])
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return ([], []) }
        let count = Int(buffer.frameLength)
        let you = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let them = file.processingFormat.channelCount > 1
            ? Array(UnsafeBufferPointer(start: channels[1], count: count))
            : []
        return (you, them)
    }
}

enum Spool {
    /// `spool`: the two files, looped, as a spool of exactly H hours.
    static func build(_ arguments: [String]) throws {
        let options = try Options(arguments)
        let sides = try Sides.load(you: options.require("you"), them: options.require("them"))
        let hours = try options.double("hours")
        let url = URL(fileURLWithPath: try options.require("out"))
        try? FileManager.default.removeItem(at: url)

        let target = Int(hours * 3600 * Double(sampleRate))
        let writer = try SpoolWriter(url: url)
        let chunk = sampleRate  // one second at a time
        var written = 0
        while written < target {
            let from = written % sides.you.count
            let n = min(chunk, target - written, sides.you.count - from)
            try writer.append(you: sides.you[from..<from + n], them: sides.them[from..<from + n])
            written += n
        }

        let check = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("\(url.path): \(check.processingFormat.channelCount) channels, \(Int(check.processingFormat.sampleRate)) Hz, "
            + "\(check.length) frames = \(String(format: "%.1f", Double(check.length) / Double(sampleRate))) s, "
            + "\(gigabytes(bytes)) on disk, "
            + "source \(String(format: "%.0f", sides.seconds)) s looped \(String(format: "%.2f", Double(target) / Double(sides.you.count)))x")
    }

    /// `tail`: `--seconds` of a file as its own wav, the stop-time decode's input. from `--start`
    /// seconds in, or ending where the file's last audible sample is.
    static func tail(_ arguments: [String]) throws {
        let options = try Options(arguments)
        let samples = try readMono(URL(fileURLWithPath: options.require("from")))
        let length = Int(try options.double("seconds", default: 20) * Double(sampleRate))
        let start: Int
        let end: Int
        if options.string("start") != nil {
            start = Int(try options.double("start") * Double(sampleRate))
            end = min(samples.count, start + length)
        } else {
            guard let last = samples.lastIndex(where: { abs($0) > 0.004 }) else { throw BenchError("that file is silent") }
            end = last + 1
            start = max(0, end - length)
        }
        let window = Array(samples[start..<end])
        try writeMono(window, to: URL(fileURLWithPath: try options.require("out")))
        let rms = (window.reduce(0) { $0 + $1 * $1 } / Float(window.count)).squareRoot()
        print(String(format: "tail: %.1f s to %.1f s of the file (%.1f s), rms %.3f", Double(start) / Double(sampleRate),
                     Double(end) / Double(sampleRate), Double(window.count) / Double(sampleRate), rms))
    }
}
