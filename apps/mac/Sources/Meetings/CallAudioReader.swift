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

/// Whether anyone is using the default mic, said once when asked and again
/// every time it changes. What tells the call reader there is anything to
/// read.
protocol MicUseSignal: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func stop()
}

/// Listens to the default input's `DeviceIsRunningSomewhere`: the one bit
/// the HAL keeps for "someone, anyone, is recording from this mic". It
/// cannot say who, and it counts us, so it only starts the reader; the
/// reader tells us apart by pid. The listener moves with the default input.
///
/// Every Core Audio call, the adding and removing of listeners included,
/// runs on its own queue; the listener blocks are delivered on it too, so
/// that queue is the only place its state is touched. The blocks hold it
/// weakly; `stop()` is how it lets go of the HAL.
final class MicInUseListener: MicUseSignal, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleID).mic-in-use", qos: .utility)
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    // on `queue` only
    private var report: (@Sendable (Bool) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var defaultBlock: AudioObjectPropertyListenerBlock?
    private var lastSaid: Bool?

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard report == nil else { return }
            report = onChange
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.followTheDefaultInput()
            }
            if AudioObjectAddPropertyListenerBlock(Self.system, &address, queue, block) == noErr {
                defaultBlock = block
            } else {
                callLogger.error("couldn't watch the default input")
            }
            followTheDefaultInput()
        }
    }

    func stop() {
        queue.async { [self] in
            detachFromDevice()
            if let defaultBlock {
                var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
                AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, defaultBlock)
            }
            defaultBlock = nil
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

    /// On the queue: the listener off the old default input, onto the new
    /// one, and what the new one is doing said at once.
    private func followTheDefaultInput() {
        guard report != nil else { return }
        let next = Self.defaultInput()
        if next != device {
            detachFromDevice()
            device = next
            if next != kAudioObjectUnknown {
                var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.say()
                }
                if AudioObjectAddPropertyListenerBlock(next, &address, queue, block) == noErr {
                    deviceBlock = block
                } else {
                    callLogger.error("couldn't watch the default input for use")
                }
            }
        }
        say()
    }

    private func detachFromDevice() {
        if let deviceBlock, device != kAudioObjectUnknown {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, deviceBlock)
        }
        deviceBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    /// No default input is a mic nobody is using.
    private func say() {
        let inUse = device != kAudioObjectUnknown && Self.isRunningSomewhere(device)
        guard inUse != lastSaid else { return }
        lastSaid = inUse
        report?(inUse)
    }

    private static func defaultInput() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
