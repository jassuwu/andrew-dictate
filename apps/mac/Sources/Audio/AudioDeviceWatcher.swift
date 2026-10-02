import AppKit
import CoreAudio
import os

private let watcherLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "audio"
)

/// something underneath that decides which mic a press opens.
enum AudioDeviceChange: String, Equatable, Sendable {
    /// the capture's own engine reconfigured itself, and stopped.
    case engineReconfigured = "engine-reconfigured"
    case defaultInput = "default-input"
    case defaultOutput = "default-output"
    case deviceList = "device-list"
    case wake
    case screens

    /// the mic a live utterance is hearing may be gone, or no longer the
    /// mic, so the utterance ends and keeps what it had. the rest only make
    /// the capture stale for the next press: a monitor arriving
    /// mid-sentence is no reason to end the sentence.
    var endsLiveUtterance: Bool {
        switch self {
        case .engineReconfigured, .defaultInput:
            true
        case .defaultOutput, .deviceList, .wake, .screens:
            false
        }
    }
}

/// says when anything that decides which mic a press opens may have moved:
/// the default input or output, the list of devices, a wake, the displays.
/// the default input and the device list are watched straight from Core
/// Audio, on a private queue, because the engine's own configuration-change
/// notification does not always come — two device swaps have been seen to
/// post nothing at all. every change lands on the main actor.
///
/// not one audio call is made on the main thread, adding the listeners
/// included: the audio server can be the thing that is stuck.
final class AudioDeviceWatcher: @unchecked Sendable {
    /// a Core Audio listener and the property it listens to, kept so the
    /// same block can be removed again.
    private struct Listener: @unchecked Sendable {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleID).audio-devices",
        qos: .utility
    )
    private let listeners: [Listener]
    private let observers: [(NotificationCenter, NSObjectProtocol)]

    init(onChange: @escaping @MainActor @Sendable (AudioDeviceChange) -> Void) {
        let report: @Sendable (AudioDeviceChange) -> Void = { change in
            Task { @MainActor in
                onChange(change)
            }
        }

        let watched: [(AudioObjectPropertySelector, AudioDeviceChange)] = [
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInput),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutput),
            (kAudioHardwarePropertyDevices, .deviceList),
        ]
        listeners = watched.map { selector, change in
            Listener(
                address: AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                block: { _, _ in report(change) }
            )
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        observers = [
            (workspace, workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in report(.wake) }),
            (center, center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: nil
            ) { _ in report(.screens) }),
        ]

        let listeners = listeners
        let queue = queue
        queue.async {
            for var listener in listeners {
                let status = AudioObjectAddPropertyListenerBlock(
                    Self.system,
                    &listener.address,
                    queue,
                    listener.block
                )
                if status != noErr {
                    watcherLogger.error(
                        "couldn't watch the audio devices: \(status, privacy: .public)"
                    )
                }
            }
        }
    }

    deinit {
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        // queued behind the adding, on the queue the blocks were added
        // with, which is how Core Audio knows them again.
        let listeners = listeners
        let queue = queue
        queue.async {
            for var listener in listeners {
                AudioObjectRemovePropertyListenerBlock(
                    Self.system,
                    &listener.address,
                    queue,
                    listener.block
                )
            }
        }
    }
}
