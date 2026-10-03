import CoreAudio
import Foundation
import os

private let callLogger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "call")

/// Core Audio's process objects, read (ADR 0047): which processes have audio
/// open, and whether their input and their output are running. It needs no
/// permission and reads no window, tab or calendar.
///
/// Every call here waits on the audio server, which can be the thing that is
/// stuck, so the caller runs it on a queue of its own and never on the main
/// thread.
enum AudioProcessList {
    /// Every process with its input or its output running now. The HAL lists
    /// every process that has opened audio, running or not; an idle one costs
    /// two reads and is left out, and only a running one is asked who it is.
    /// Nil when the list cannot be read at all.
    static func running() -> [AudioProcess]? {
        guard let objects = processObjects() else { return nil }
        return objects.compactMap { object in
            let input = flag(kAudioProcessPropertyIsRunningInput, of: object)
            let output = flag(kAudioProcessPropertyIsRunningOutput, of: object)
            guard input || output, let pid = pid(of: object) else { return nil }
            return AudioProcess(
                pid: pid, bundleID: bundleID(of: object),
                isRunningInput: input, isRunningOutput: output)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return nil
        }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
            return nil
        }
        return objects
    }

    /// A process that went away between the list and this read answers with
    /// an error, which reads as not running.
    private static func flag(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> Bool {
        var address = address(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func pid(of object: AudioObjectID) -> Int32? {
        var address = address(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    /// Missing for some helpers and daemons: they belong to no call app.
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let id = value as String
        return id.isEmpty ? nil : id
    }
}

/// Whether anyone is using any mic, said once when asked and again every
/// time it changes. What tells the call reader there is anything to read.
protocol MicUseSignal: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func stop()
}

/// Listens to `DeviceIsRunningSomewhere` on every input device: the one bit
/// the HAL keeps for "someone, anyone, is using this device". Every one, not
/// the default: a call app set to a usb mic or airpods while the mac's
/// default is its own mic is a call all the same. It cannot say who, and it
/// counts us, so it only starts the reader; the reader tells us apart by
/// pid. The device list is listened to as well, so a mic plugged in, or
/// airpods connecting, is listened to from the moment it is there.
///
/// A device that plays as well as it listens, a headset, runs for music
/// too, and the bit cannot say which: then the reader finds nobody else on
/// the mic, and reads rarely.
///
/// Every Core Audio call, the adding and removing of listeners included,
/// runs on its own queue; the listener blocks are delivered on it too, so
/// that queue is the only place its state is touched. The blocks hold it
/// weakly; `stop()` is how it lets go of the HAL. Listening costs nothing
/// until the HAL calls.
final class MicInUseListener: MicUseSignal, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleID).mic-in-use", qos: .utility)
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    // on `queue` only
    private var report: (@Sendable (Bool) -> Void)?
    private var listBlock: AudioObjectPropertyListenerBlock?
    /// Every input device listened to, with the block it was given.
    private var inputs: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var lastSaid: Bool?

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard report == nil else { return }
            report = onChange
            var address = Self.address(kAudioHardwarePropertyDevices)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.followTheInputs()
            }
            if AudioObjectAddPropertyListenerBlock(Self.system, &address, queue, block) == noErr {
                listBlock = block
            } else {
                callLogger.error("couldn't watch the device list")
            }
            followTheInputs()
        }
    }

    func stop() {
        queue.async { [self] in
            for input in Array(inputs.keys) {
                detach(from: input)
            }
            if let listBlock {
                var address = Self.address(kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, listBlock)
            }
            listBlock = nil
            report = nil
            lastSaid = nil
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// On the queue: off the inputs that went, onto the ones that came, and
    /// what they are doing said at once. A list that cannot be read leaves
    /// the listeners as they were.
    private func followTheInputs() {
        guard report != nil else { return }
        if let present = Self.inputDevices().map(Set.init) {
            for input in Array(inputs.keys) where !present.contains(input) {
                detach(from: input)
            }
            for input in present where inputs[input] == nil {
                attach(to: input)
            }
        }
        say()
    }

    private func attach(to input: AudioObjectID) {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.say()
        }
        if AudioObjectAddPropertyListenerBlock(input, &address, queue, block) == noErr {
            inputs[input] = block
        } else {
            callLogger.error("couldn't watch an input for use")
        }
    }

    private func detach(from input: AudioObjectID) {
        guard let block = inputs.removeValue(forKey: input) else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(input, &address, queue, block)
    }

    /// No input at all is a mic nobody is using.
    private func say() {
        let inUse = inputs.keys.contains(where: Self.isRunningSomewhere)
        guard inUse != lastSaid else { return }
        lastSaid = inUse
        report?(inUse)
    }

    /// Every device with an input stream, or nil when the list cannot be
    /// read.
    private static func inputDevices() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return nil
        }
        guard size > 0 else { return [] }
        var devices = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }
        return devices.filter(hasInput)
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
