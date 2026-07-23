import AppKit
import Carbon

@MainActor
final class PasteKeyCodeResolver: NSObject {
    private static let fallbackKeyCode: CGKeyCode = 9

    private var cachedKeyCode: CGKeyCode?

    override init() {
        super.init()

        guard let notification = kTISNotifySelectedKeyboardInputSourceChanged
        else {
            return
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: Notification.Name(notification as String),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func keyCodeForV() -> CGKeyCode {
        if let cachedKeyCode {
            return cachedKeyCode
        }

        let keyCode = Self.resolveKeyCodeForV() ?? Self.fallbackKeyCode
        cachedKeyCode = keyCode
        return keyCode
    }

    @objc
    private func inputSourceDidChange() {
        cachedKeyCode = nil
    }

    private static func resolveKeyCodeForV() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue(),
            let property = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
            ) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>
            .fromOpaque(property)
            .takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let layout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        for keyCode in 0...127 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = characters.withUnsafeMutableBufferPointer {
                UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    $0.count,
                    &length,
                    $0.baseAddress
                )
            }

            guard status == noErr, length > 0 else {
                continue
            }

            let translated = characters.withUnsafeBufferPointer {
                String(
                    utf16CodeUnits: $0.baseAddress!,
                    count: length
                )
            }
            if translated.lowercased() == "v" {
                return CGKeyCode(keyCode)
            }
        }

        return nil
    }
}
