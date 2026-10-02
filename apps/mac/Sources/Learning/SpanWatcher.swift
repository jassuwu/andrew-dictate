import AppKit
@preconcurrency import ApplicationServices

/// a minute of watching one delivered dictation's words, and only those.
///
/// the adapter between AX and `SpanWatch`: it hears the field change, asks
/// the watch to read, and hands over what our words read as once you have
/// paused. it ends after a minute, when focus leaves the field, when our
/// words are gone, or when the next dictation starts — whichever is first.
@MainActor
final class SpanWatcher {
    /// "~60 s" in the rule: long enough to read back what landed and fix a
    /// word, short enough that it's still about this dictation.
    static let lifetime: Duration = .seconds(60)
    /// typing pauses longer than this are a fix, not a word half-typed.
    static let quiet: Duration = .milliseconds(1500)
    /// the fallback for a field that never says it changed.
    static let pollInterval: Duration = .milliseconds(1500)
    /// the paste is a change: no notification by now means none are coming.
    static let notificationGrace: Duration = .seconds(1)
    /// a paste that hasn't shown up by now went somewhere we can't see.
    static let landingDeadline: Duration = .seconds(3)

    private let reader: AXSpanReader
    private var watch: SpanWatch
    private let onSettled: (String) -> Void
    private let onEnded: () -> Void

    private var observer: AXObserver?
    private var application: AXUIElement?
    private var retainedByObserver: Unmanaged<SpanWatcher>?
    private var activation: NSObjectProtocol?
    private var timers: [Task<Void, Never>] = []
    private var quietTimer: Task<Void, Never>?
    private var polling: Task<Void, Never>?

    private var hearsChanges = false
    private var landed = false
    private var lastRead: String?
    private var lastSettled: String?
    private var ended = false

    init(
        reader: AXSpanReader,
        inserted: String,
        onSettled: @escaping (String) -> Void,
        onEnded: @escaping () -> Void
    ) {
        self.reader = reader
        watch = SpanWatch(inserted: inserted)
        self.onSettled = onSettled
        self.onEnded = onEnded
    }

    func start() {
        observe()
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusMayHaveMoved()
            }
        }

        // the paste can land before the observer is in, and then there is
        // no change to hear: look once straight away.
        after(.milliseconds(150)) { $0.readSpan() }
        after(Self.notificationGrace) { watcher in
            if !watcher.hearsChanges {
                watcher.poll()
            }
        }
        after(Self.landingDeadline) { watcher in
            if !watcher.landed {
                watcher.end(flushing: false)
            }
        }
        after(Self.lifetime) { $0.end(flushing: true) }
    }

    /// the next dictation: whatever you were still typing isn't a finished
    /// fix, and a pill about it would land on the take.
    func stop() {
        end(flushing: false)
    }

    // MARK: - hearing the field

    private func observe() {
        var created: AXObserver?
        guard AXObserverCreate(
            reader.processIdentifier,
            spanWatcherCallback,
            &created
        ) == .success, let observer = created else {
            poll()
            return
        }
        // the observer holds the watcher until `end` lets go, so a callback
        // can never reach a watcher that is gone.
        let retained = Unmanaged.passRetained(self)
        retainedByObserver = retained
        let refcon = retained.toOpaque()
        let application = AXUIElementCreateApplication(reader.processIdentifier)
        _ = AXObserverAddNotification(
            observer,
            reader.element,
            kAXValueChangedNotification as CFString,
            refcon
        )
        _ = AXObserverAddNotification(
            observer,
            reader.element,
            kAXUIElementDestroyedNotification as CFString,
            refcon
        )
        _ = AXObserverAddNotification(
            observer,
            application,
            kAXFocusedUIElementChangedNotification as CFString,
            refcon
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        self.observer = observer
        self.application = application
    }

    fileprivate func notified(_ notification: String) {
        switch notification {
        case kAXValueChangedNotification:
            // the field does say when it changes: no need to keep asking.
            hearsChanges = true
            polling?.cancel()
            polling = nil
            readSpan()
        case kAXUIElementDestroyedNotification:
            end(flushing: true)
        default:
            focusMayHaveMoved()
        }
    }

    /// a slow look every second and a half, for a field that never says it
    /// changed — and the same look at where focus is.
    private func poll() {
        guard polling == nil, !ended else {
            return
        }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, !self.ended else {
                    return
                }
                self.focusMayHaveMoved()
                self.readSpan()
            }
        }
    }

    private func focusMayHaveMoved() {
        guard !ended, !reader.isStillFocused() else {
            return
        }
        end(flushing: true)
    }

    // MARK: - reading

    private func readSpan() {
        guard !ended else {
            return
        }
        switch watch.read(reader) {
        case .notLanded:
            return
        case let .reads(text):
            guard landed else {
                landed = true
                lastRead = text
                lastSettled = text
                return
            }
            guard text != lastRead else {
                return
            }
            lastRead = text
            quietTimer?.cancel()
            quietTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.quiet)
                guard !Task.isCancelled else {
                    return
                }
                self?.settle()
            }
        case .gone:
            // sent, cleared or deleted: what you left our words as before
            // they went is still what you made of them.
            end(flushing: landed)
        }
    }

    private func settle() {
        guard let lastRead, lastRead != lastSettled else {
            return
        }
        lastSettled = lastRead
        onSettled(lastRead)
    }

    private func end(flushing: Bool) {
        guard !ended else {
            return
        }
        ended = true
        timers.forEach { $0.cancel() }
        timers = []
        quietTimer?.cancel()
        polling?.cancel()
        if let activation {
            NSWorkspace.shared.notificationCenter.removeObserver(activation)
        }
        if let observer {
            AXObserverRemoveNotification(
                observer,
                reader.element,
                kAXValueChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                reader.element,
                kAXUIElementDestroyedNotification as CFString
            )
            if let application {
                AXObserverRemoveNotification(
                    observer,
                    application,
                    kAXFocusedUIElementChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        if flushing {
            settle()
        }
        // nothing is kept: what our words read as goes with the watch.
        lastRead = nil
        lastSettled = nil
        onEnded()
        // last, and nothing after it: this may be the final reference.
        let retained = retainedByObserver
        retainedByObserver = nil
        retained?.release()
    }

    private func after(
        _ delay: Duration,
        _ action: @escaping @MainActor (SpanWatcher) -> Void
    ) {
        timers.append(Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.ended else {
                return
            }
            action(self)
        })
    }
}

/// AX calls back on the run loop the source was added to — the main one.
private func spanWatcherCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }
    let watcher = Unmanaged<SpanWatcher>.fromOpaque(refcon)
        .takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        watcher.notified(name)
    }
}
