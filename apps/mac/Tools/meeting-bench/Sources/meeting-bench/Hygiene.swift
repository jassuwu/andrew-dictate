import Darwin
import Foundation

/// the machine is shared, so every timed run says how quiet it was. a build
/// running beside a decode moves the numbers more than anything else does.
enum Hygiene {
    static let builders: Set<String> = ["xcodebuild", "swift-frontend", "swiftc"]

    static func loadAverage() -> Double {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return load[0]
    }

    /// names of the build processes running right now, none when quiet.
    static func busyBuilders() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0).split(separator: "/").last.map(String.init) ?? "" }
        return Array(Set(names.filter(builders.contains))).sorted()
    }

    static var machine: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let name = String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(name), \(memory) GiB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    struct Start: Codable {
        var loadAverageAtStart: Double
        var quietAtStart: Bool
        var waitedSeconds: Double
    }

    struct During: Codable {
        var maxLoadAverage: Double
        var samples: Int
        var busySamples: Int
        var busyNames: [String]
    }

    /// waits for no build process, up to `maxMinutes`, then notes the load.
    static func begin(maxMinutes: Double = 20) async -> Start {
        let began = ContinuousClock.now
        var quiet = busyBuilders().isEmpty
        while !quiet, ContinuousClock.now - began < .seconds(maxMinutes * 60) {
            print("waiting for a quiet machine, running: \(busyBuilders().joined(separator: ", "))")
            try? await Task.sleep(for: .seconds(10))
            quiet = busyBuilders().isEmpty
        }
        let waited = (ContinuousClock.now - began).seconds
        let start = Start(loadAverageAtStart: loadAverage(), quietAtStart: quiet, waitedSeconds: waited)
        print("machine: \(machine)")
        print("1-minute load average at start: \(String(format: "%.2f", start.loadAverageAtStart))"
            + (quiet ? "" : "  NOT QUIET: a build was still running after \(Int(waited)) s")
            + (waited > 1 ? "  (waited \(Int(waited)) s for it)" : ""))
        return start
    }

    /// samples the load and the build processes every 15 s until stopped.
    final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var during = During(maxLoadAverage: 0, samples: 0, busySamples: 0, busyNames: [])
        private var task: Task<Void, Never>?

        init() {
            task = Task.detached { [self] in
                while !Task.isCancelled {
                    sample()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }

        private func sample() {
            let load = Hygiene.loadAverage()
            let busy = Hygiene.busyBuilders()
            lock.lock()
            during.samples += 1
            during.maxLoadAverage = max(during.maxLoadAverage, load)
            if !busy.isEmpty {
                during.busySamples += 1
                during.busyNames = Array(Set(during.busyNames + busy)).sorted()
            }
            lock.unlock()
        }

        func stop() -> During {
            task?.cancel()
            sample()
            lock.lock()
            defer { lock.unlock() }
            let result = during
            let load = String(format: "%.2f", result.maxLoadAverage)
            let builds = result.busySamples == 0
                ? "no build process seen"
                : "\(result.busySamples) samples with a build running (\(result.busyNames.joined(separator: ", ")))"
            print("during the run: \(result.samples) samples, highest 1-minute load \(load), \(builds)")
            return result
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// peak resident set so far, in bytes (what `/usr/bin/time -l` calls maximum resident set size).
func peakResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

/// resident set right now, in bytes.
func currentResidentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

func gigabytes(_ bytes: Int) -> String {
    String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
}
