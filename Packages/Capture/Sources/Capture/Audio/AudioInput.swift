import AVFAudio
import Foundation

#if os(macOS)
import CoreAudio
#endif

/// Microphone permission and the current input device.
public enum AudioInput {
    /// Whether the app may record. Prompts on first use.
    public static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    public static var isPermissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    /// The system's current default input device, if any.
    public static func currentDevice() -> AudioDeviceInfo? {
        #if os(macOS)
        guard let deviceID = defaultInputDeviceID(),
              let name = stringProperty(kAudioObjectPropertyName, of: deviceID)
        else { return nil }
        return AudioDeviceInfo(name: name, uid: stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID))
        #else
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        return AudioDeviceInfo(name: port.portName, uid: port.uid)
        #endif
    }

    #if os(macOS)
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    #endif
}
