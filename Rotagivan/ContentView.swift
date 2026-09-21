import ServiceManagement
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @ObservedObject var sync: SettingsSync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = "Layers"
    @State private var actionDevice: GestureDevice = .navigator

    private let sections = [("Devices", "computermouse"), ("Layers", "square.3.layers.3d"),
        ("App Explorer", "safari"), ("App overrides", "app.badge"),
        ("Pointer & scrolling", "cursorarrow.motionlines"), ("General", "gearshape")]
    private var editingAppleActions: Bool { selection == "Layers" && actionDevice == .apple && !store.settings.resolvedDevices.shareTapActions }

    init(store: SettingsStore, hid: NavigatorHIDManager, sync: SettingsSync,
         initialSection: String = "Layers", initialDevice: GestureDevice = .navigator) {
        self.store = store; self.hid = hid; self.sync = sync
        _selection = State(initialValue: initialSection)
        _actionDevice = State(initialValue: initialDevice)
    }

    private enum ProfileSection {
        case motion, scrolling, tapping, dragging
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "safari").font(.system(size: 24, weight: .light)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ROTAGIVAN").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                    TextField("Profile name", text: Binding(get: { store.activeConfigurationName }, set: { store.renameConfiguration($0) }))
                        .font(.system(size: 19, weight: .semibold)).textFieldStyle(.plain)
                        .accessibilityLabel("Profile name")
                }
                Spacer()
                Picker("Profile", selection: Binding(get: { store.activeConfigurationID }, set: { switchProfile($0) })) {
                    ForEach(store.configurationProfiles) { profile in Text(profile.name).tag(profile.id) }
                }.frame(width: 215)
                Button { switchProfile(nil) } label: { Label("Add Profile", systemImage: "plus") }
                    .disabled(store.configurationProfiles.count >= 20)
                    .help("Copy this profile, including every layer and Explorer group")
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("THIS PROFILE").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.4).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 9)
                    ForEach(sections, id: \.0) { title, icon in
                        Button { selection = title } label: {
                            Label(title == "Layers" ? "Layer actions" : title, systemImage: icon)
                                .font(.system(size: 12, weight: selection == title ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                                .background(selection == title ? Color.teal.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(selection == title ? .isSelected : [])
                    }
                    Spacer()
                    Text("\(store.profiles.count) layers\n\(store.settings.resolvedDevices.shareTapActions ? "Shared actions" : "Device overrides")")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4).padding(10)
                }.padding(12).padding(.top, 10).frame(width: 180)
                    .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if selection != "Layers" && selection != "Pointer & scrolling" {
                            Text(selection).font(.system(size: 24, weight: .semibold))
                            Text(selection == "General" ? "Account, permissions and startup belong to this Mac. Configurations include every profile." : "Settings for \(store.activeConfigurationName)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        switch selection {
                        case "General": general
                        case "Devices": devices
                        case "App Explorer": AppExplorerSettingsView(store: store)
                        case "App overrides": AppOverridesView(store: store)
                        default: profiles
                        }
                    }
                    .frame(width: 708, alignment: .leading).padding(22)
                    .id(store.activeConfigurationID)
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("\(store.activeConfigurationName)  /  \(store.activeProfileName)")
                Spacer()
                Text(AppVersion.display)
                Text("Changes save automatically")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toggleStyle(.checkbox)
        .tint(.primary)
        .frame(width: 940, height: 740)
        .sheet(item: Binding(get: { hid.calibrationSession }, set: { value in
            if value == nil { hid.endCalibration() }
        })) { session in
            GestureCalibrationView(session: session,
                onApply: { hid.applyCalibration() }, onCancel: { hid.endCalibration() })
                .onDisappear { hid.endCalibration() }
        }
        .onDisappear { hid.endCalibration() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hid.endCalibration()
        }
        .onAppear {
            DispatchQueue.main.async {
                store.recenterSliderBaselines(revision: 6)
            }
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selection == "Layers" ? "Layer actions" : "Pointer & scrolling").font(.system(size: 24, weight: .semibold))
                    Text(selection == "Layers" ? "Choose what a gesture does. Each column is a layer." : "Navigator tuning, by layer. macOS keeps its native motion and scrolling.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let id = store.addProfile()
                    ShortcutSettings.shared.additional[id] = ProfileShortcut()
                    ShortcutSettings.shared.profileActions[id] = ShortcutSettings.shared.actions(for: store.defaultProfileID)
                } label: {
                    Label("Add layer", systemImage: "plus")
                }
            }
            if selection == "Layers" {
                Toggle("Share tap and swipe actions across devices", isOn: deviceBinding(\.shareTapActions))
                if !store.settings.resolvedDevices.shareTapActions {
                    Picker("Edit actions for", selection: $actionDevice) {
                        ForEach(GestureDevice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 340)
                } else {
                    Label("One set of actions for Navigator and Apple trackpads", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(selection == "Layers" ? [0, 3] : [0, 1, 2, 4], id: \.self) { section in
                    GridRow(alignment: .top) {
                        ForEach(store.profiles, id: \.id) { profile in
                            profileCell(profile.name, id: profile.id, section: section)
                                .frame(width: 322, alignment: .topLeading)
                        }
                    }
                }
            }
            .background {
                HStack(spacing: 12) {
                    ForEach(store.profiles, id: \.id) { profile in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(store.activeProfileID == profile.id ? Color.teal.opacity(0.65) : Color.primary.opacity(0.16), lineWidth: 1))
                            .frame(width: 322)
                    }
                }.allowsHitTesting(false)
            }
            .padding(.bottom, 8)
            }
            .onChange(of: store.profiles.count) { _, _ in
                if let id = store.profiles.last?.id { proxy.scrollTo(id, anchor: .trailing) }
            }
            }
            Divider()
            Text("New layers copy \(store.profiles[0].name). Hold temporarily overrides the selected layer; tap again to return to the previous layer.")
                .font(.caption).foregroundStyle(.secondary)
            ShortcutEditor(errorsOnly: true)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func profileCell(_ title: String, id: UInt32, section: Int) -> some View {
        switch section {
        case 0:
            profileHeader(title, id: id)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(store.activeProfileID == id ? Color.teal.opacity(0.09) : Color.primary.opacity(0.035))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
                .id(id)
        case 1:
            columnSection("Motion", icon: "cursorarrow.motionlines", profileID: id, copySection: .motion) {
                MotionCurveEditor(curve: Binding(get: { store.motion(for: id).resolvedCursorResponse }, set: { curve in
                    var motion = store.motion(for: id)
                    motion.cursorResponse = curve.sanitized
                    store.updateMotion(motion, for: id)
                }), telemetry: store.cursorTelemetry, profileID: id, isActive: store.activeProfileID == id)
            }
        case 2:
            columnSection("Scrolling", icon: "arrow.up.and.down", profileID: id, copySection: .scrolling) {
                ScrollCurveEditor(profile:motionBinding(id))
                Divider()
                Toggle("Invert horizontal", isOn: motionBinding(id).invertScrollX)
                Toggle("Invert vertical", isOn: motionBinding(id).invertScrollY)
                Toggle("After-scroll coasting", isOn: motionBinding(id).kineticScroll)
                columnSlider("Coast coefficient", value: motionBinding(id).kineticDecay, scale: centeredScale(id, minimum: 0, maximum: ProfileMaximum.coastCoefficient, keyPath: \.coastCoefficient))
                    .disabled(!store.motion(for: id).kineticScroll)
                Text("After lift-off, speed decays exponentially. 0 stops immediately; 100 keeps gliding until you touch again or turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case 3:
            columnSection("Tap & swipe actions", icon: "hand.tap", profileID: id, copySection: .tapping) { gestures(id) }
        default:
            columnSection("Dragging", icon: "hand.draw", profileID: id, copySection: .dragging) { dragging(id) }
        }
    }

    private func columnSection<Content: View>(_ title: String, icon: String, profileID: UInt32, copySection: ProfileSection, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if store.profiles.count > 1 {
                    Menu {
                        ForEach(store.profiles.filter { $0.id != profileID }, id: \.id) { source in
                            Button(source.name) { copy(copySection, from: source.id, to: profileID) }
                        }
                    } label: {
                        Label("Copy from", systemImage: "doc.on.doc")
                    }
                    .font(.caption)
                    .menuStyle(.borderlessButton)
                    .help("Copy this section from another layer")
                }
            }
            content()
        }
        .padding(.horizontal, 16).padding(.bottom, 18)
    }

    private func columnSlider(_ title: String, value: Binding<Double>, scale: SettingsScale) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            profileSlider(title, name: "", value: value, scale: scale)
        }
    }

    private func centeredScale(_ id: UInt32, minimum: Double, maximum: Double, keyPath: KeyPath<ProfileSliderBaseline, Double>) -> SettingsScale {
        .centered(minimum: minimum, maximum: maximum, baseline: store.settings.sliderBaseline(for: id)[keyPath: keyPath])
    }

    private func profileHeader(_ title: String, id: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ShortcutEditor(profile: title, showError: false, profileID: id, editableName: Binding(get: {
                store.settings.profileNames?[id] ?? title
            }, set: { name in
                var names = store.settings.profileNames ?? [:]
                names[id] = name
                store.settings.profileNames = names
            }), isDefaultProfile: id == store.defaultProfileID)
            HStack {
            Text(id == store.defaultProfileID ? (store.activeProfileID == id ? "Default · Active layer" : "Default layer") : (store.activeProfileID == id ? "Active layer" : " "))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if id != store.defaultProfileID {
                Button("Make default") { makeDefault(id) }.buttonStyle(.link).font(.caption)
            }
            }
        }
        .frame(width: 270, alignment: .leading)
        .frame(minHeight: 120, alignment: .topLeading)
    }

    private func makeDefault(_ id: UInt32) {
        let shortcuts = ShortcutSettings.shared
        let effective = HotKeyManager.resolvedActions(for: id, defaults: shortcuts.actions, saved: shortcuts.profileActions, customTapProfiles: store.settings.customTapProfiles ?? [], defaultID: store.defaultProfileID)
        shortcuts.profileActions[id] = effective
        shortcuts.disableActivation(for: store.defaultProfileID)
        shortcuts.disableActivation(for: id)
        store.makeDefault(id)
    }

    private func profileSlider(_ title: String, name: String, value: Binding<Double>, scale: SettingsScale) -> some View {
        let percentage = Binding(get: { scale.percentage(for: value.wrappedValue) }, set: {
            value.wrappedValue = scale.value(for: $0.rounded())
        })
        return HStack(spacing: 10) {
            Slider(value: percentage, in: 0...100)
                .accessibilityLabel("\(name) \(title)")
            TextField(title, value: percentage, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 52)
                .accessibilityLabel("\(name) \(title) value")
        }.frame(width: 270)
    }

    private func motionBinding(_ id: UInt32) -> Binding<MotionProfile> {
        Binding(get: { store.motion(for: id) }, set: { store.updateMotion($0, for: id) })
    }

    private func scrollAccelerationBinding(_ id: UInt32) -> Binding<Double> {
        Binding(get: { store.motion(for: id).resolvedScrollAcceleration }, set: { value in
            var motion = store.motion(for: id)
            motion.scrollAcceleration = min(ProfileMaximum.scrollAcceleration, max(1, value))
            store.updateMotion(motion, for: id)
        })
    }

    private func copy(_ section: ProfileSection, from sourceID: UInt32, to targetID: UInt32) {
        switch section {
        case .motion:
            let source = store.motion(for: sourceID)
            var target = store.motion(for: targetID)
            target.copyCursorSettings(from: source)
            store.updateMotion(target, for: targetID)
        case .scrolling:
            let source = store.motion(for: sourceID)
            var target = store.motion(for: targetID)
            target.copyScrollSettings(from:source)
            store.updateMotion(target, for: targetID)
        case .tapping:
            if editingAppleActions {
                store.updateAppleGestures(store.gestures(for: sourceID, device: .apple), for: targetID)
                return
            }
            let source = store.settings.effectiveGestures(for: sourceID)
            var target = store.settings.gestures(for: targetID)
            target.oneFingerTap = source.oneFingerTap
            target.twoFingerTap = source.twoFingerTap
            target.oneFingerShortcut = source.oneFingerShortcut
            target.twoFingerShortcut = source.twoFingerShortcut
            target.oneFingerDoubleTap = source.oneFingerDoubleTap
            target.twoFingerDoubleTap = source.twoFingerDoubleTap
            target.oneFingerDoubleShortcut = source.oneFingerDoubleShortcut
            target.twoFingerDoubleShortcut = source.twoFingerDoubleShortcut
            target.doubleTapSwipe = source.doubleTapSwipe
            target.singleTapSwipe = source.singleTapSwipe
            target.twoFingerSingleTapSwipe = source.twoFingerSingleTapSwipe
            target.twoFingerDoubleTapSwipe = source.twoFingerDoubleTapSwipe
            target.twoFingerSwipe = source.twoFingerSwipe
            target.oneFingerTripleTap = source.oneFingerTripleTap
            target.twoFingerTripleTap = source.twoFingerTripleTap
            target.oneFingerTripleShortcut = source.oneFingerTripleShortcut
            target.twoFingerTripleShortcut = source.twoFingerTripleShortcut
            target.gestures.tapToClick = source.gestures.tapToClick
            target.gestures.tapMaxDuration = source.gestures.tapMaxDuration
            target.gestures.tapMaxMovement = source.gestures.tapMaxMovement
            target.gestures.keepCursorStillForTaps = source.gestures.keepCursorStillForTaps
            target.gestures.doubleTapInterval = source.gestures.doubleTapInterval
            target.gestures.tripleTapFirstInterval = source.gestures.tripleTapFirstInterval
            target.gestures.tripleTapSecondInterval = source.gestures.tripleTapSecondInterval
            store.updateGestures(target, for: targetID)
            if targetID != store.defaultProfileID {
                var customProfiles = store.settings.customTapProfiles ?? []
                customProfiles.insert(targetID)
                store.settings.customTapProfiles = customProfiles
            }
            copyShortcutActions([0, 1], from: sourceID, to: targetID)
        case .dragging:
            let source = store.settings.gestures(for: sourceID).gestures
            var target = store.settings.gestures(for: targetID)
            target.gestures.touchAndHoldDrag = source.touchAndHoldDrag
            target.gestures.dragRegrip = source.dragRegrip
            target.gestures.dragRegripWindow = source.dragRegripWindow
            target.gestures.secondFingerGracePeriod = source.secondFingerGracePeriod
            store.updateGestures(target, for: targetID)
            copyShortcutActions([2], from: sourceID, to: targetID)
        }
    }

    private func copyShortcutActions(_ indexes: [Int], from sourceID: UInt32, to targetID: UInt32) {
        let shortcuts = ShortcutSettings.shared
        let source = shortcuts.actions(for: sourceID)
        var target = shortcuts.actions(for: targetID)
        for index in indexes where source.indices.contains(index) && target.indices.contains(index) {
            target[index] = source[index]
        }
        shortcuts.profileActions[targetID] = target
    }

    private func gestures(_ id: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if editingAppleActions {
                Toggle("Customize Apple actions", isOn: Binding(get: {
                    store.settings.devices?.appleLayerGestures?[id] != nil
                }, set: { enabled in
                    store.updateAppleGestures(enabled ? store.settings.effectiveGestures(for: id) : nil, for: id)
                }))
                if store.settings.devices?.appleLayerGestures?[id] == nil {
                    Text("Uses this layer’s shared actions. Enable customization to override them on Apple trackpads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if id != store.defaultProfileID {
                Toggle("Set Custom Tap settings", isOn: Binding(get: {
                    (store.settings.customTapProfiles ?? []).contains(id)
                }, set: { enabled in
                    var ids = store.settings.customTapProfiles ?? []
                    if enabled { ids.insert(id) } else { ids.remove(id) }
                    store.settings.customTapProfiles = ids
                }))
            }
            if editingAppleActions ? store.settings.devices?.appleLayerGestures?[id] != nil : (id == store.defaultProfileID || (store.settings.customTapProfiles ?? []).contains(id)) {
            Toggle("Enable tap actions", isOn: gesture(id, \.tapToClick))
            if editableGestures(id).gestures.tapToClick {
                tapRecorder("One-finger tap", action: gestureBinding(id).oneFingerTap, shortcut: gestureBinding(id).oneFingerShortcut)
                tapRecorder("One-finger double tap", action: doubleTapActionBinding(id, twoFingers: false), shortcut: doubleTapShortcutBinding(id, twoFingers: false))
                tapRecorder("One-finger triple tap", action: tripleTapActionBinding(id, twoFingers: false), shortcut: gestureBinding(id).oneFingerTripleShortcut)
                tapRecorder("Two-finger tap", action: gestureBinding(id).twoFingerTap, shortcut: gestureBinding(id).twoFingerShortcut)
                tapRecorder("Two-finger double tap", action: doubleTapActionBinding(id, twoFingers: true), shortcut: doubleTapShortcutBinding(id, twoFingers: true))
                tapRecorder("Two-finger triple tap", action: tripleTapActionBinding(id, twoFingers: true), shortcut: gestureBinding(id).twoFingerTripleShortcut)
                Text("Double and triple taps replace shorter tap actions. Triple taps use the double-tap delay between taps; enabling them delays double-tap actions while waiting for a third tap.")
                    .font(.caption).foregroundStyle(.secondary)
                doubleTapDelaySlider(id)
                calibrationButton("Calibrate double tap…", profileID: id, mode: .doubleTap)
                calibrationButton("Calibrate triple tap…", profileID: id, mode: .tripleTap)
                if let first = editableGestures(id).gestures.tripleTapFirstInterval,
                   let second = editableGestures(id).gestures.tripleTapSecondInterval {
                    Text("Triple tap: \(Int(first * 1000)) + \(Int(second * 1000)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                }
                tapImpactSpeedSlider(id)
                Toggle("Keep cursor still while tapping", isOn: Binding(get: {
                    editableGestures(id).gestures.resolvedKeepCursorStillForTaps
                }, set: { enabled in
                    var taps = editableGestures(id)
                    taps.gestures.keepCursorStillForTaps = enabled
                    updateEditableGestures(taps, for: id)
                }))
                TrackpadDistanceControl(title: "Tap movement radius", units: gesture(id, \.tapMaxMovement),
                    scale: hid.distanceScale, range: 0...ProfileMaximum.tapMovement,
                    explanation: "How far one finger may move from its landing point and still count as a tap. Two-finger taps use accumulated movement. This does not limit the distance between separate taps.")
                if editableGestures(id).gestures.resolvedKeepCursorStillForTaps {
                    Text("Tap wobble within this radius won't move the cursor. Move beyond it or hold past Tap impact speed to start tracking. Lower the radius for quicker fine movement. Tap-and-hold dragging still works.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                DoubleTapSwipeEditor(settings: Binding(get: {
                    editableGestures(id).singleTapSwipe ?? .singleTapDefaults
                }, set: { value in
                    var taps = editableGestures(id)
                    taps.singleTapSwipe = value
                    updateEditableGestures(taps, for: id)
                }), singleTap: true, onCalibrate: {
                    hid.beginCalibration(profileID: id, mode: .singleTapSwipe, device: editingAppleActions ? .apple : .navigator)
                }, canCalibrate: hid.canCalibrate, distanceScale: hid.distanceScale)
                Divider()
                DoubleTapSwipeEditor(settings: Binding(get: {
                    editableGestures(id).doubleTapSwipe ?? DoubleTapSwipeSettings()
                }, set: { value in
                    var taps = editableGestures(id)
                    taps.doubleTapSwipe = value
                    updateEditableGestures(taps, for: id)
                }), onCalibrate: {
                    hid.beginCalibration(profileID: id, mode: .doubleTapSwipe, device: editingAppleActions ? .apple : .navigator)
                }, canCalibrate: hid.canCalibrate, distanceScale: hid.distanceScale)
                Divider()
                twoFingerSwipeEditor(id, singleTap: true)
                Divider()
                twoFingerSwipeEditor(id, singleTap: false)
            }
            if !editingAppleActions {
            Divider()
            ShortcutEditor(showBehavior: false, actionIndex: 0, showError: false, profileID: id)
            ShortcutEditor(showBehavior: false, actionIndex: 1, showError: false, profileID: id)
            Text("These are separate keyboard shortcuts that click at the cursor; they do not change what a trackpad tap does.")
                .font(.caption).foregroundStyle(.secondary)
            }
            } else if !editingAppleActions {
                Text("Inherit from default")
                    .foregroundStyle(.secondary)
                Text("Uses tapping settings from \(store.profiles[0].name). Enable custom settings to override them while this layer is active.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }

    private func twoFingerSwipeEditor(_ id: UInt32, singleTap: Bool) -> some View {
        let key: WritableKeyPath<ProfileGestures, DoubleTapSwipeSettings?> = singleTap ? \.twoFingerSingleTapSwipe : \.twoFingerDoubleTapSwipe
        return DoubleTapSwipeEditor(settings: Binding(get: {
            editableGestures(id)[keyPath: key] ?? (singleTap ? .singleTapDefaults : DoubleTapSwipeSettings())
        }, set: { value in
            var taps = editableGestures(id)
            taps[keyPath: key] = value
            updateEditableGestures(taps, for: id)
        }), singleTap: singleTap, twoFingers: true, distanceScale: hid.distanceScale)
    }

    private func tapRecorder(_ title: String, action: Binding<TapAction>, shortcut: Binding<RecordedShortcut?>) -> some View {
        TapActionEditor(title: title, action: action, shortcut: shortcut)
    }

    private func calibrationButton(_ title: String, profileID: UInt32, mode: GestureCalibrationMode) -> some View {
        Button { hid.beginCalibration(profileID: profileID, mode: mode, device: editingAppleActions ? .apple : .navigator) } label: {
            Label(title, systemImage: "stopwatch")
        }
        .disabled(!hid.canCalibrate)
        .help(hid.canCalibrate ? "Time 10 tries using your trackpad and apply the median." : "Enable and connect your trackpad to calibrate.")
    }

    private func doubleTapDelaySlider(_ id: UInt32) -> some View {
        let milliseconds = Binding<Double>(get: {
            editableGestures(id).gestures.resolvedDoubleTapInterval * 1_000
        }, set: { value in
            var profileGestures = editableGestures(id)
            profileGestures.gestures.doubleTapInterval = min(600, max(50, value.rounded())) / 1_000
            updateEditableGestures(profileGestures, for: id)
        })
        return VStack(alignment: .leading, spacing: 4) {
            Text("Double-tap recognition delay").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Slider(value: milliseconds, in: 50...max(60, store.settings.sliderBaseline(for: id).doubleTapDelay * 2_000 - 50), step: 10)
                    .accessibilityLabel("Double-tap recognition delay in milliseconds")
                TextField("Milliseconds", value: milliseconds, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                    .accessibilityLabel("Double-tap recognition delay in milliseconds")
            }
            Text("Single taps wait this long only when that finger count has a double-tap action.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 270)
    }

    private func tapImpactSpeedSlider(_ id: UInt32) -> some View {
        let milliseconds = Binding<Double>(get: {
            editableGestures(id).gestures.tapMaxDuration * 1_000
        }, set: { value in
            var profileGestures = editableGestures(id)
            profileGestures.gestures.tapMaxDuration = min(1_000, max(0, value.rounded())) / 1_000
            updateEditableGestures(profileGestures, for: id)
        })
        return VStack(alignment: .leading, spacing: 4) {
            Text("Tap impact speed").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Slider(value: milliseconds, in: 0...min(1_000, max(10, store.settings.sliderBaseline(for: id).tapImpactSpeed * 2_000)), step: 10)
                    .accessibilityLabel("Tap impact speed in milliseconds")
                TextField("Milliseconds", value: milliseconds, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                    .accessibilityLabel("Tap impact speed in milliseconds")
            }
            Text("Maximum finger-down time for a tap. Lower milliseconds require a quicker tap.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 270)
    }

    private func dragging(_ id: UInt32) -> some View {
        let primaryTap = store.settings.effectiveGestures(for: id).oneFingerTap
        let canTapAndHoldDrag = store.settings.effectiveGestures(for: id).gestures.tapToClick && primaryTap.supportsTapAndHoldDrag
        return VStack(alignment: .leading, spacing: 12) {
            ShortcutEditor(showBehavior: false, actionIndex: 2, showError: false, profileID: id)
            Text("Hold the shortcut and move the cursor to drag. Release the key to drop. You can lift and reposition your finger while holding the shortcut.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Tap, then touch and hold to drag", isOn: gesture(id, \.touchAndHoldDrag))
                .disabled(!canTapAndHoldDrag)
            if canTapAndHoldDrag {
                Text("The second touch can land anywhere on the trackpad. You have at least 400 ms to touch again, then hold or move to drag. Lift to drop.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !canTapAndHoldDrag {
                Text("Tap-and-hold drag needs One-finger tap to be set to Left click. Your current action is \(primaryTap.title).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Allow re-grip while dragging", isOn: gesture(id, \.dragRegrip))
            columnSlider("Re-grip window", value: gesture(id, \.dragRegripWindow), scale: centeredScale(id, minimum: 0, maximum: ProfileMaximum.regripWindow, keyPath: \.regripWindow))
        }
        .font(.system(size: 12))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            Section("Status") {
                LabeledContent("Navigator") { Text(statusText) }
                Button("Reconnect") { hid.stop(); if store.settings.enabled { hid.start() } }
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Button("Open Input Monitoring Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                Toggle("Enable Rotagivan", isOn: enabledBinding)
            }
            Divider()
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }
            Divider()
            ConfigurationSettingsView(store: store, hid: hid)
            Divider()
            SyncSettingsView(sync: sync)
            Divider()
            Section {
                Text("Rotagivan is an independent, editable implementation. Quit ZSA Navigator before using Rotagivan’s Navigator driver. Apple trackpad actions are independent of that driver.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }

    private func gestureBinding(_ id: UInt32) -> Binding<ProfileGestures> {
        Binding(get: { editableGestures(id) }, set: { updateEditableGestures($0, for: id) })
    }

    private func editableGestures(_ id: UInt32) -> ProfileGestures {
        editingAppleActions ? store.gestures(for: id, device: .apple) : store.settings.gestures(for: id)
    }

    private func updateEditableGestures(_ value: ProfileGestures, for id: UInt32) {
        if editingAppleActions { store.updateAppleGestures(value, for: id) }
        else { store.updateGestures(value, for: id) }
    }

    private func switchProfile(_ id: String?) {
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
        hid.stop()
        if let id { store.selectConfiguration(id) } else { store.addConfiguration() }
        actionDevice = .navigator
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
            if store.settings.enabled { hid.start() }
        }
    }

    private func deviceBinding(_ key: WritableKeyPath<ProfileDevices, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings.resolvedDevices[keyPath: key] }, set: { enabled in
            hid.stop()
            var devices = store.settings.resolvedDevices
            devices[keyPath: key] = enabled
            store.settings.devices = devices
            if store.settings.enabled { hid.start() }
        })
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use ZSA Navigator", isOn: deviceBinding(\.navigatorEnabled))
                    Text("Cursor, scrolling, tap actions, layers and Explorer. When off, Rotagivan releases the Navigator driver.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use Apple trackpad actions", isOn: deviceBinding(\.appleEnabled))
                    Text("Built-in and Magic Trackpads. Native pointer and scrolling remain controlled by macOS; Rotagivan adds gesture actions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow Apple input on this Mac", isOn: Binding(get: { hid.appleTrackpadEnabled }, set: { hid.setAppleTrackpadEnabled($0) }))
                    Text(hid.appleTrackpadStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Experimental private macOS touch interface. Clicks take priority over touch actions. The pointer pauses only while an Apple-controlled HUD is active.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Share tap and swipe actions across devices", isOn: deviceBinding(\.shareTapActions))
            Text("Shared actions follow the active layer. Turn sharing off to customize Apple actions in Layer actions. Existing overrides are preserved when sharing is turned back on.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func gesture<Value>(_ id: UInt32, _ keyPath: WritableKeyPath<GestureSettings, Value>) -> Binding<Value> {
        gestureBinding(id).gestures[dynamicMember: keyPath]
    }

    private func tripleTapActionBinding(_ id: UInt32, twoFingers: Bool) -> Binding<TapAction> {
        Binding(get: {
            let taps = editableGestures(id)
            return (twoFingers ? taps.twoFingerTripleTap : taps.oneFingerTripleTap) ?? .none
        }, set: { action in
            var taps = editableGestures(id)
            if twoFingers { taps.twoFingerTripleTap = action } else { taps.oneFingerTripleTap = action }
            updateEditableGestures(taps, for: id)
        })
    }

    private func doubleTapActionBinding(_ id: UInt32, twoFingers: Bool) -> Binding<TapAction> {
        Binding(get: {
            let gestures = editableGestures(id)
            return twoFingers ? (gestures.twoFingerDoubleTap ?? .none) : (gestures.oneFingerDoubleTap ?? .none)
        }, set: { action in
            var gestures = editableGestures(id)
            if twoFingers { gestures.twoFingerDoubleTap = action } else { gestures.oneFingerDoubleTap = action }
            updateEditableGestures(gestures, for: id)
        })
    }

    private func doubleTapShortcutBinding(_ id: UInt32, twoFingers: Bool) -> Binding<RecordedShortcut?> {
        Binding(get: {
            let gestures = editableGestures(id)
            return twoFingers ? gestures.twoFingerDoubleShortcut : gestures.oneFingerDoubleShortcut
        }, set: { shortcut in
            var gestures = editableGestures(id)
            if twoFingers { gestures.twoFingerDoubleShortcut = shortcut } else { gestures.oneFingerDoubleShortcut = shortcut }
            updateEditableGestures(gestures, for: id)
        })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { store.settings.enabled }, set: { enabled in
            store.settings.enabled = enabled
            enabled ? hid.start() : hid.stop()
        })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { store.settings.launchAtLogin }, set: { enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                store.settings.launchAtLogin = enabled
            } catch {
                store.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        })
    }

    private var statusText: String {
        switch hid.state {
        case .stopped: return "Stopped"
        case .looking: return "Looking for ZSA trackpad…"
        case .connected(let name): return "Connected to \(name)"
        case .error(let message): return message
        }
    }
}

struct ShortcutEditor: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    var profile: String? = nil
    var showBehavior = true
    var errorsOnly = false
    var actionIndex: Int? = nil
    var showError = true
    var profileID: UInt32? = nil
    var editableName: Binding<String>? = nil
    var isDefaultProfile = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let index = actionIndex {
                shortcutRow(["Click at cursor", "Double-click at cursor", "Keyboard drag"][index], value: Binding(get: {
                    shortcuts.actions(for: profileID ?? 1)[index]
                }, set: { value in
                    var actions = shortcuts.actions(for: profileID ?? 1)
                    actions[index] = value
                    shortcuts.profileActions[profileID ?? 1] = actions
                }))
            } else if !errorsOnly {
                if isDefaultProfile { defaultProfileHeader }
                else if let id = profileID {
                    if id == 1 { shortcutRow(profile ?? "Normal", value: $shortcuts.normal) }
                    else if id == 2 { shortcutRow(profile ?? "Precision", value: $shortcuts.precision) }
                    else {
                        shortcutRow(profile ?? "Layer", value: Binding(get: { shortcuts.additional[id] ?? ProfileShortcut() }, set: { shortcuts.additional[id] = $0 }))
                    }
                } else {
                    if profile == nil || profile == "Normal" { shortcutRow("Normal", value: $shortcuts.normal) }
                    if profile == nil || profile == "Precision" { shortcutRow("Precision", value: $shortcuts.precision) }
                }
            }
            if showError, let error = shortcuts.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var defaultProfileHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let editableName {
                TextField("Layer name", text: editableName)
                    .textFieldStyle(.roundedBorder).fontWeight(.semibold)
                    .accessibilityLabel("Layer name")
            } else { Text(profile ?? "Default").fontWeight(.semibold) }
            Text("Used automatically when no other layer is active.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }

    private func shortcutRow(_ title: String, value: Binding<ProfileShortcut>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let editableName {
                    TextField("Layer name", text: editableName)
                        .textFieldStyle(.roundedBorder)
                        .fontWeight(.semibold)
                        .accessibilityLabel("Layer name")
                        .help("Rename this layer")
                } else {
                    Text(title).fontWeight(.semibold)
                }
                Spacer()
                Toggle("Hotkey", isOn: value.enabled).toggleStyle(.switch).controlSize(.small)
            }
            if actionIndex == nil {
                ShortcutRecorder(title: value.wrappedValue.enabled ? value.wrappedValue.displayName : "Record shortcut…") { recorded in
                    var updated = value.wrappedValue
                    updated.assign(recorded)
                    value.wrappedValue = updated
                }
                .frame(maxWidth: .infinity).frame(height: 26)
            } else {
            HStack(spacing: 6) {
                Picker("Key", selection: value.keyCode) {
                    ForEach(ShortcutSettings.keys, id: \.1) { name, code in Text(name).tag(code) }
                }.frame(width: 120)
                ForEach([( "⌃", UInt32(4096)), ("⌥", UInt32(2048)), ("⇧", UInt32(512)), ("⌘", UInt32(256))], id: \.1) { label, flag in
                    Toggle(label, isOn: Binding(get: { value.wrappedValue.modifiers & flag != 0 }, set: { on in
                        if on { value.wrappedValue.modifiers |= flag }
                        else { value.wrappedValue.modifiers &= ~flag }
                    }))
                    .toggleStyle(.button)
                    .help(flag == 4096 ? "Control" : flag == 2048 ? "Option" : flag == 512 ? "Shift" : "Command")
                }
            }.disabled(!value.wrappedValue.enabled)
            }
            if showBehavior && actionIndex == nil {
                Picker("Activation", selection: Binding(get: { value.wrappedValue.holdToActivate ?? true }, set: { value.wrappedValue.holdToActivate = $0 })) {
                    Text("Hold to activate").tag(true)
                    Text("Tap to toggle").tag(false)
                }
                .accessibilityLabel("\(title) activation")
                .disabled(!value.wrappedValue.enabled)
            }
        }.padding(.vertical, 4)
    }
}
