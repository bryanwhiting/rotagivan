import AVFoundation
import Foundation

@main struct VoiceInputDeviceTests {
    @MainActor static func main() {
        preferenceRoundTrip()
        missingDeviceFallback()
        resolutionAgainstRealDevices()
        print("VoiceInputDevice passed preference round trip, missing-device fallback and real-device UID resolution.")
    }

    static func preferenceRoundTrip() {
        let suite = "local.rota.tests.voice-input-device.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(VoiceInputDevices.preferredUID(defaults) == nil, "Unset preference means system default")
        VoiceInputDevices.setPreferredUID("AppleUSBAudioEngine:Example:1", defaults)
        precondition(VoiceInputDevices.preferredUID(defaults) == "AppleUSBAudioEngine:Example:1")
        precondition(defaults.string(forKey: VoiceInputDevices.preferenceKey) == "AppleUSBAudioEngine:Example:1")
        precondition(VoiceInputDevices.preferenceKey == "voice.inputDeviceUID", "Device-local key, never a synced setting")
        VoiceInputDevices.setPreferredUID(VoiceInputDevices.systemDefault, defaults)
        precondition(VoiceInputDevices.preferredUID(defaults) == nil, "Empty string (RotaSelect's System default) reads as nil")
        precondition(defaults.object(forKey: VoiceInputDevices.preferenceKey) == nil)
        VoiceInputDevices.setPreferredUID("x", defaults)
        VoiceInputDevices.setPreferredUID(nil, defaults)
        precondition(VoiceInputDevices.preferredUID(defaults) == nil)
        // The settings page writes "" through @AppStorage; that still reads as system default.
        defaults.set("", forKey: VoiceInputDevices.preferenceKey)
        precondition(VoiceInputDevices.preferredUID(defaults) == nil)
    }

    static func missingDeviceFallback() {
        var lookups: [String] = []
        let none = VoiceInputDevices.resolve(preferredUID: nil) { lookups.append($0); return 7 }
        precondition(none == VoiceInputDevices.Resolution(deviceID: nil, notice: nil), "System default: no device, no notice")
        precondition(lookups.isEmpty, "System default never consults the device list")

        let found = VoiceInputDevices.resolve(preferredUID: "present") { _ in 42 }
        precondition(found == VoiceInputDevices.Resolution(deviceID: 42, notice: nil))

        let missing = VoiceInputDevices.resolve(preferredUID: "unplugged") { _ in nil }
        precondition(missing.deviceID == nil, "A missing device falls back to the system default")
        precondition(missing.notice == VoiceInputDevices.missingNotice)
        precondition(!missing.notice!.contains("\n") && missing.notice!.count < 90, "Notice is one short line")

        // Applying a missing preference leaves the engine on the default and reports it once.
        let engine = AVAudioEngine()
        precondition(VoiceInputDevices.apply(to: engine, preferredUID: "rota-test-missing-device") == VoiceInputDevices.missingNotice)
        precondition(VoiceInputDevices.apply(to: engine, preferredUID: nil) == nil, "System default applies silently")
    }

    @MainActor static func resolutionAgainstRealDevices() {
        let devices = VoiceInputDevices.list()
        precondition(Set(devices.map(\.uid)).count == devices.count, "UIDs are unique")
        precondition(devices.filter(\.isDefault).count <= 1, "At most one device is the current default")
        for device in devices {
            precondition(!device.uid.isEmpty && !device.name.isEmpty)
            precondition(VoiceInputDevices.deviceID(forUID: device.uid) != nil, "Every listed UID resolves to an AudioDeviceID: \(device.uid)")
        }
        precondition(VoiceInputDevices.deviceID(forUID: "rota-test-missing-device") == nil)
        if let defaultID = VoiceInputDevices.defaultInputDeviceID(),
           let current = devices.first(where: \.isDefault) {
            precondition(VoiceInputDevices.deviceID(forUID: current.uid) == defaultID, "isDefault matches kAudioHardwarePropertyDefaultInputDevice")
        }
        if let device = devices.first {
            let engine = AVAudioEngine()
            precondition(VoiceInputDevices.apply(to: engine, preferredUID: device.uid) == nil, "A connected device applies without a notice")
            var applied = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(engine.inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &applied, &size)
            precondition(status == noErr && applied == VoiceInputDevices.deviceID(forUID: device.uid), "The engine's input unit now targets the chosen device")
            precondition(VoiceInputDevices.list() == devices,
                "The hidden CADefaultDeviceAggregate that AVAudioEngine creates never appears in the picker")
        }
        let monitor = VoiceInputDeviceMonitor()
        monitor.startObserving()
        precondition(monitor.devices == devices, "The monitor publishes the same list the settings page shows")
        monitor.startObserving()
        precondition(monitor.devices == devices, "Observing twice does not duplicate listeners or change the list")
    }
}
