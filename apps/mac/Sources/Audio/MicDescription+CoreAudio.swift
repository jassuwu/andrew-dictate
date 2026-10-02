import CoreAudio

extension MicDescription {
    /// the input macOS would hand a new recording right now. what the press
    /// log's diagnostics header names, next to what each press actually got.
    static func systemDefaultInput() -> MicDescription? {
        defaultInputDevice().flatMap(MicDescription.init(device:))
    }

    /// the id of that input, nil when the mac has none. a call into the
    /// audio server, so never on the main thread while a press is waiting.
    static func defaultInputDevice() -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr,
              device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    /// a device's own name and how it is attached. nil for a device that
    /// will not say its name — gone, most likely, which a record shows as
    /// no mic at all.
    init?(device: AudioObjectID) {
        guard device != kAudioObjectUnknown else {
            return nil
        }

        var nameAddress = Self.propertyAddress(kAudioObjectPropertyName)
        var name: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0)
        }
        guard nameStatus == noErr, let name else {
            return nil
        }

        var transportAddress = Self.propertyAddress(
            kAudioDevicePropertyTransportType
        )
        var transport = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            device,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transport
        )

        self.init(
            name: name as String,
            transport: transportStatus == noErr
                ? Self.transport(transport)
                : .unknown
        )
    }

    private static func transport(_ type: UInt32) -> Transport {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn:
            .builtIn
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            .bluetooth
        case kAudioDeviceTransportTypeUSB:
            .usb
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            .continuity
        // an aggregate is software stitched over real devices, the same
        // kind of thing as a loopback driver as far as a failure goes.
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            .virtual
        default:
            .unknown
        }
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
