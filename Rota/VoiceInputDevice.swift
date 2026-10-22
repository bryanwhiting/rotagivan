import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation
import SwiftUI

/// One CoreAudio device that has at least one input stream.
struct VoiceInputDevice: Equatable, Identifiable, Sendable {
    let uid: String
    let name: String
    let isDefault: Bool
    var id: String { uid }
}

/// Lists microphones and applies the chosen one to every AVAudioEngine before
/// it starts. The choice is local to this Mac (UserDefaults, never synced):
/// device UIDs are meaningless on another machine.
enum VoiceInputDevices {
    /// Device-local preference. Missing or empty means the system default input.
    static let preferenceKey = "voice.inputDeviceUID"
    /// `RotaSelect` value that stands for the system default input.
    static let systemDefault = ""
    static let missingNotice = "Selected microphone is not connected; using the system default."
    static let unavailableNotice = "Could not switch to the selected microphone; using the system default."

    struct Resolution: Equatable {
        var deviceID: AudioDeviceID?
        var notice: String?
    }

    // MARK: Preference

    static func preferredUID(_ defaults: UserDefaults = .standard) -> String? {
        guard let uid = defaults.string(forKey: preferenceKey), !uid.isEmpty else { return nil }
        return uid
    }

    static func setPreferredUID(_ uid: String?, _ defaults: UserDefaults = .standard) {
        if let uid, !uid.isEmpty { defaults.set(uid, forKey: preferenceKey) }
        else { defaults.removeObject(forKey: preferenceKey) }
    }

    // MARK: Resolution

    /// Pure: `nil` UID keeps the engine on the system default without a notice;
    /// an unknown UID also keeps the default but reports it in one line.
    static func resolve(preferredUID: String?, lookup: (String) -> AudioDeviceID?) -> Resolution {
        guard let uid = preferredUID else { return Resolution(deviceID: nil, notice: nil) }
        if let id = lookup(uid) { return Resolution(deviceID: id, notice: nil) }
        return Resolution(deviceID: nil, notice: missingNotice)
    }

    /// Points the engine's input unit at the preferred device. Call before
    /// reading the input format or starting the engine. Returns a one-line
    /// notice when the preference could not be honored, otherwise `nil`.
    @discardableResult
    static func apply(to engine: AVAudioEngine, preferredUID: String? = VoiceInputDevices.preferredUID()) -> String? {
        let resolution = resolve(preferredUID: preferredUID, lookup: deviceID(forUID:))
        guard var deviceID = resolution.deviceID else { return resolution.notice }
        guard let unit = engine.inputNode.audioUnit else { return unavailableNotice }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr ? nil : unavailableNotice
    }

    // MARK: CoreAudio discovery

    static func list() -> [VoiceInputDevice] {
        let defaultID = defaultInputDeviceID()
        return allDeviceIDs().compactMap { id in
            guard isSelectable(id), let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            let name = string(id, kAudioObjectPropertyName).flatMap { $0.isEmpty ? nil : $0 } ?? uid
            return VoiceInputDevice(uid: uid, name: name, isDefault: id == defaultID)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { isSelectable($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Has input streams and is not a private aggregate. AVAudioEngine creates
    /// a hidden "CADefaultDeviceAggregate" while any voice session runs; it must
    /// never appear in the picker.
    private static func isSelectable(_ id: AudioDeviceID) -> Bool {
        hasInputStreams(id) && !isPrivateAggregate(id)
    }

    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = globalAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAggregate else { return false }
        if string(id, kAudioDevicePropertyDeviceUID)?.hasPrefix("CADefaultDeviceAggregate") == true { return true }
        var composition = globalAddress(kAudioAggregateDevicePropertyComposition)
        var dictionary: Unmanaged<CFDictionary>?
        var dictionarySize = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &dictionary) { pointer in
            AudioObjectGetPropertyData(id, &composition, 0, nil, &dictionarySize, pointer)
        }
        guard status == noErr, let dictionary else { return false }
        let values = dictionary.takeRetainedValue() as NSDictionary
        return (values[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Publishes the input device list and refreshes it when CoreAudio reports a
/// device or default-input change.
@MainActor final class VoiceInputDeviceMonitor: ObservableObject {
    static let shared = VoiceInputDeviceMonitor()
    @Published private(set) var devices: [VoiceInputDevice] = []
    private var observing = false
    private var listener: AudioObjectPropertyListenerBlock?

    func refresh() { devices = VoiceInputDevices.list() }

    func startObserving() {
        refresh()
        guard !observing else { return }
        observing = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = VoiceInputDevices.globalAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
}

/// The single place to choose the voice microphone (Settings → Voice mode).
struct VoiceInputDeviceSelect: View {
    @AppStorage(VoiceInputDevices.preferenceKey) private var selectedUID = VoiceInputDevices.systemDefault
    @ObservedObject private var monitor = VoiceInputDeviceMonitor.shared

    private var missing: Bool {
        selectedUID != VoiceInputDevices.systemDefault && !monitor.devices.contains { $0.uid == selectedUID }
    }

    private var options: [RotaOption<String>] {
        var options = [RotaOption("System default", value: VoiceInputDevices.systemDefault, systemImage: "mic")]
        options += monitor.devices.map {
            RotaOption($0.isDefault ? "\($0.name) · current default" : $0.name, value: $0.uid)
        }
        if missing { options.append(RotaOption("Not connected", value: selectedUID, systemImage: "mic.slash")) }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RotaSelect("Microphone", selection: $selectedUID, options: options)
                .accessibilityIdentifier("voice-input-device")
            if missing {
                Label(VoiceInputDevices.missingNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("voice-input-device-missing")
            }
            Text("Used by every voice feature on this Mac: action voice, OpenAI Realtime, note dictation and private intention dictation. Not synced.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { monitor.startObserving() }
    }
}
