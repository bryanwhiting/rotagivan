import SwiftUI

struct LayerActionAssignmentsEditor: View {
    @Binding var gestures: ProfileGestures
    @Binding var globalBindings: [ActionBinding]
    var resolveGestures: (ProfileGestures) -> ProfileGestures
    @State private var showingAddAction = false
    @State private var editingGlobalBinding: ActionBinding?

    init(gestures: Binding<ProfileGestures>, globalBindings: Binding<[ActionBinding]> = .constant([]),
         resolveGestures: @escaping (ProfileGestures) -> ProfileGestures = { $0 }) {
        _gestures = gestures
        _globalBindings = globalBindings
        self.resolveGestures = resolveGestures
    }

    private var effectiveGestures: ProfileGestures {
        resolveGestures(gestures)
    }

    private func globalBinding(for trigger: AppGestureTrigger) -> ActionBinding? {
        globalBindings.first { $0.trigger.gesture == trigger }
    }

    private var assignments: [AppGestureBinding] {
        (AppGestureTrigger.layerActionTriggers +
            [AppGestureTrigger.twoFingerLeft, .twoFingerRight, .twoFingerUp, .twoFingerDown].filter { globalBinding(for: $0) != nil }).compactMap { trigger in
            let assignment = trigger.assignment(in: effectiveGestures).binding
            return assignment.action == .none ? nil : assignment
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap action assignments")
                        .font(.system(size: 13, weight: .semibold))
                    Text("A gesture on the left runs the action on the right.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingAddAction = true
                } label: {
                    Label("Add tap action", systemImage: "plus")
                }
                .accessibilityIdentifier("add-layer-action")
            }

            VStack(spacing: 0) {
                if assignments.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                        Text("No tap actions assigned")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                } else {
                    ForEach(Array(assignments.enumerated()), id: \.element.id) { index, assignment in
                        LayerActionAssignmentRow(
                            trigger: assignment.trigger,
                            action: actionBinding(for: assignment.trigger),
                            shortcut: shortcutBinding(for: assignment.trigger),
                            globalBinding: globalBinding(for: assignment.trigger),
                            onEditGlobal: { if let binding = globalBinding(for: assignment.trigger) { editingGlobalBinding = binding } },
                            onRemove: { remove(assignment.trigger) }
                        )
                        if index < assignments.count - 1 {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            if assignments.contains(where: { globalBinding(for: $0.trigger) != nil }) {
                Text("Global assignments stay active across layers and devices, even when this layer’s tap actions are off. Edit them here or in Hotkeys.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Label("Gesture timing, movement thresholds, and swipe recognition are in Calibration.",
                  systemImage: "dial.low")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingAddAction) {
            AddLayerActionSheet(existing: Set(assignments.map(\.trigger))) { trigger, action, shortcut in
                let bindingAction: BindingAction = action == .shortcut && shortcut != nil
                    ? .from(shortcut: shortcut!) : .tap(action)
                if [.twoFingerLeft, .twoFingerRight, .twoFingerUp, .twoFingerDown].contains(trigger) {
                    if let existing = globalBinding(for: trigger) {
                        var updated = existing
                        updated.action = bindingAction
                        saveGlobalDraft(updated)
                    } else {
                        globalBindings.append(ActionBinding(trigger: BindingTrigger(gesture: trigger), action: bindingAction))
                    }
                    showingAddAction = false
                    return
                }
                if let existing = globalBinding(for: trigger) {
                    var updated = existing
                    updated.action = bindingAction
                    saveGlobalDraft(updated)
                    showingAddAction = false
                    return
                }
                var updated = gestures
                _ = updated.setLayerAction(action, shortcut: shortcut, for: trigger)
                gestures = updated
                showingAddAction = false
            } onCancel: {
                showingAddAction = false
            }
        }
        .sheet(item: $editingGlobalBinding) { candidate in
            BindingEditor(binding: candidate, existing: globalBindings, global: true,
                title: "Global tap or swipe action", onSave: { updated in
                    saveGlobalDraft(updated)
                    editingGlobalBinding = nil
                }, onCancel: { editingGlobalBinding = nil })
        }
    }

    private func actionBinding(for trigger: AppGestureTrigger) -> Binding<TapAction> {
        Binding(get: {
            trigger.assignment(in: effectiveGestures).binding.action
        }, set: { action in
            let current = trigger.assignment(in: gestures).binding
            var updated = gestures
            _ = updated.setLayerAction(action, shortcut: current.shortcut, for: trigger)
            gestures = updated
        })
    }

    private func shortcutBinding(for trigger: AppGestureTrigger) -> Binding<RecordedShortcut?> {
        Binding(get: {
            trigger.assignment(in: effectiveGestures).binding.shortcut
        }, set: { shortcut in
            var updated = gestures
            _ = updated.setLayerAction(shortcut == nil ? .none : .shortcut, shortcut: shortcut, for: trigger)
            gestures = updated
        })
    }

    private func remove(_ trigger: AppGestureTrigger) {
        if let global = globalBinding(for: trigger) {
            removeGlobalBinding(id: global.id)
            return
        }
        var updated = gestures
        _ = updated.setLayerAction(.none, shortcut: nil, for: trigger)
        gestures = updated
    }

    /// Uses the same owner-writing path as the global row's editor.
    func saveGlobalDraft(_ updated: ActionBinding) {
        guard let index = globalBindings.firstIndex(where: { $0.id == updated.id }) else { return }
        globalBindings[index] = updated
    }

    func removeGlobalBinding(id: UUID) {
        globalBindings.removeAll { $0.id == id }
    }
}

private struct LayerActionAssignmentRow: View {
    @Environment(\.hotkeyDictionary) private var dictionary
    let trigger: AppGestureTrigger
    @Binding var action: TapAction
    @Binding var shortcut: RecordedShortcut?
    let globalBinding: ActionBinding?
    let onEditGlobal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: trigger.direction == nil ? "hand.tap" : "hand.draw")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(trigger.direction == nil ? Color.accentColor : Color.cyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.baseTapTrigger?.title ?? trigger.title)
                    .lineLimit(1)
                if let direction = trigger.direction {
                    Label(direction.title, systemImage: direction.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 138, maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            if let globalBinding {
                HStack(spacing: 5) {
                    Text(dictionary.title(for: globalBinding.action)).lineLimit(1)
                    Text("Global").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Button("Edit", action: onEditGlobal).controlSize(.small)
                }.frame(width: 190, alignment: .leading)
            } else {
                UnifiedLayerActionPicker(
                    action: $action,
                    shortcut: $shortcut,
                    shortcutsOnly: trigger.direction != nil
                )
                .frame(width: 190)
            }

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(globalBinding == nil ? "Remove \(trigger.title)" :
                "Remove global assignment and reveal this layer’s action")
            .accessibilityLabel("Remove \(trigger.title)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layer-action-\(trigger.rawValue)")
    }
}

private struct LayerActionValueMenu: View {
    @Environment(\.hotkeyDictionary) private var dictionary
    @Environment(\.hudActionLayers) private var hudLayers
    @Binding var action: TapAction
    @Binding var shortcut: RecordedShortcut?
    var shortcutsOnly = false
    @State private var showingRecorder = false

    private var title: String {
        guard action == .shortcut else { return action.title }
        guard let shortcut else { return "Missing shortcut" }
        if let id = shortcut.hudLayerID {
            return hudLayers.first { $0.id == id }.map { "HUD · \($0.name)" } ?? "Missing HUD layer"
        }
        if let id = shortcut.macroID {
            return dictionary.first { $0.id == id }.map { $0.name } ?? "Missing keybinding"
        }
        return dictionary.label(for: shortcut) ?? shortcut.displayName
    }

    private var symbol: String {
        if action == .shortcut, shortcut?.hudLayerID != nil { return "square.stack.3d.up" }
        if action == .shortcut { return "keyboard" }
        switch action {
        case .leftClick, .doubleLeftClick, .tripleLeftClick, .rightClick: return "cursorarrow.click"
        case .appExplorer: return "circle.grid.3x3"
        case .windowManager: return "rectangle.3.group"
        case .enter, .optionF19: return "keyboard"
        case .none: return "minus.circle"
        case .shortcut: return "keyboard"
        }
    }

    var body: some View {
        Menu {
            Section("Keyboard") {
                Button("Record a shortcut…") { showingRecorder = true }
                if !dictionary.isEmpty {
                    Menu("Macros") {
                        ForEach(dictionary.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { entry in
                            Button("\(entry.name) · \(entry.summary)") {
                                shortcut = .macro(entry)
                                action = .shortcut
                            }
                        }
                    }
                }
                if !shortcutsOnly {
                    Button("Return") { choose(.enter) }
                    Button("Option + F19") { choose(.optionF19) }
                }
            }

            if !hudLayers.isEmpty {
                Section("HUD layers") {
                    ForEach(hudLayers) { layer in
                        Button(layer.name) {
                            shortcut = .hudLayer(layer)
                            action = .shortcut
                        }
                    }
                }
            }

            Section("Rotagivan") {
                Button("HUD") { choose(.appExplorer) }
                if !shortcutsOnly {
                    Button("Window Manager") { choose(.windowManager) }
                }
            }

            if !shortcutsOnly {
                Section("Pointer") {
                    Button("Left click") { choose(.leftClick) }
                    Button("Double left click") { choose(.doubleLeftClick) }
                    Button("Triple left click") { choose(.tripleLeftClick) }
                    Button("Right click") { choose(.rightClick) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.11), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Assigned action: \(title)")
        .accessibilityIdentifier("layer-action-value-menu")
        .popover(isPresented: $showingRecorder, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard shortcut")
                    .font(.headline)
                Text("Click the field, then type the hotkey to send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShortcutRecorder(title: "Click, then type a hotkey") { recorded in
                    shortcut = recorded
                    action = .shortcut
                    showingRecorder = false
                }
                .frame(width: 270, height: 28)
            }
            .padding(16)
        }
    }

    private func choose(_ value: TapAction) {
        shortcut = nil
        action = value
    }
}

struct AddLayerActionSheet: View {
    let existing: Set<AppGestureTrigger>
    let onSave: (AppGestureTrigger, TapAction, RecordedShortcut?) -> Void
    let onCancel: () -> Void
    @State private var tap = AppGestureTrigger.oneFingerTap
    @State private var swipeEnabled = false
    @State private var swipeFingers = 1
    @State private var direction = SwipeDirection.left
    @State private var action = TapAction.none
    @State private var shortcut: RecordedShortcut?

    private var standaloneSwipe: Bool {
        [.twoFingerLeft, .twoFingerRight, .twoFingerUp, .twoFingerDown].contains(tap)
    }
    private var trigger: AppGestureTrigger {
        guard swipeEnabled, canSwipe else { return tap }
        return AppGestureTrigger.combining(tap: tap, direction: direction,
            swipeFingers: tap == .oneFingerTap ? swipeFingers : 1) ?? tap
    }
    private var canSwipe: Bool { AppGestureTrigger.swipeCapableTapTriggers.contains(tap) }
    private var canSave: Bool {
        action != .none && (action != .shortcut || shortcut != nil) &&
            (!swipeEnabled || canSwipe) &&
            (!swipeEnabled || action == .shortcut || action == .appExplorer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add tap action")
                    .font(.title3.weight(.semibold))
                Text("Choose a tap. Optionally add a one- or two-finger swipe and its direction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                selectionRow(number: "1", title: "Gesture") {
                    Picker("Gesture", selection: $tap) {
                        Section("Tap") {
                            ForEach(AppGestureTrigger.baseTapTriggers) { trigger in
                                Text(trigger.title).tag(trigger)
                            }
                        }
                        Section("Two-finger swipe") {
                            Text(AppGestureTrigger.twoFingerLeft.title).tag(AppGestureTrigger.twoFingerLeft)
                            Text(AppGestureTrigger.twoFingerRight.title).tag(AppGestureTrigger.twoFingerRight)
                            Text(AppGestureTrigger.twoFingerUp.title).tag(AppGestureTrigger.twoFingerUp)
                            Text(AppGestureTrigger.twoFingerDown.title).tag(AppGestureTrigger.twoFingerDown)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: tap) { _, value in
                        if !AppGestureTrigger.swipeCapableTapTriggers.contains(value) {
                            swipeEnabled = false
                        }
                        if value != .oneFingerTap {
                            swipeFingers = 1
                        }
                    }
                }
                Divider().padding(.leading, 42)
                selectionRow(number: "2", title: "Swipe (optional)") {
                    Toggle("Add swipe", isOn: $swipeEnabled)
                        .toggleStyle(.checkbox)
                        .disabled(!canSwipe || standaloneSwipe)
                        .onChange(of: swipeEnabled) { _, enabled in
                            guard enabled, action != .none, action != .shortcut, action != .appExplorer else { return }
                            shortcut = .assigned(.tap(action))
                            action = .shortcut
                        }
                }
                if swipeEnabled && canSwipe {
                    if tap == .oneFingerTap {
                        HStack {
                            Text("Swipe with")
                            Spacer()
                            Picker("Swipe fingers", selection: $swipeFingers) {
                                Text("One finger").tag(1)
                                Text("Two fingers").tag(2)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    HStack {
                        Text("Direction")
                        Spacer()
                        Picker("Swipe direction", selection: $direction) {
                            ForEach(SwipeDirection.allCases, id: \.self) { direction in
                                Label(direction.title, systemImage: direction.symbolName).tag(direction)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                Divider().padding(.leading, 42)
                selectionRow(number: "3", title: "Action") {
                    UnifiedLayerActionPicker(
                        action: $action,
                        shortcut: $shortcut,
                        shortcutsOnly: swipeEnabled
                    )
                    .frame(width: 220)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            if existing.contains(trigger) {
                Label("This gesture is already assigned. Saving will replace its action.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !canSwipe && !standaloneSwipe {
                Text("Triple taps run on the tap itself; swipe directions are available for single and double taps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(trigger.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button(existing.contains(trigger) ? "Replace" : "Add") {
                    onSave(trigger, action, shortcut)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .accessibilityIdentifier("save-layer-action")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func selectionRow<Content: View>(number: String, title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text(title)
            Spacer()
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Projects legacy tap/swipe storage into the shared action catalog.
private struct UnifiedLayerActionPicker: View {
    @Binding var action: TapAction
    @Binding var shortcut: RecordedShortcut?
    var shortcutsOnly = false

    private var value: Binding<BindingAction> {
        Binding(get: {
            if action == .shortcut, let shortcut { return .from(shortcut: shortcut) }
            return .tap(action)
        }, set: { selected in
            if selected.kind == .tap {
                if shortcutsOnly, selected.tap != TapAction.none {
                    action = .shortcut
                    shortcut = .assigned(selected)
                } else {
                    action = selected.tap ?? .none
                    shortcut = nil
                }
            } else {
                action = .shortcut
                shortcut = selected.kind == .keystroke ? selected.shortcut : .assigned(selected)
            }
        })
    }

    var body: some View {
        BindingActionPicker(action: value)
            .accessibilityIdentifier("layer-action-value-menu")
    }
}

struct LayerSwipeRecognitionEditor: View {
    @Binding var gestures: ProfileGestures
    var distanceScale: TrackpadDistanceScale?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recognition settings are shared by every direction with the same tap pattern. A pattern turns on when its first assignment is added.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            family(
                "One-finger tap + swipe",
                settings: setting(\.singleTapSwipe, fallback: .singleTapDefaults),
                showTiming: false,
                showQuickDuration: false
            )
            family(
                "One-finger tap + two-finger swipe",
                settings: setting(\.oneFingerTapTwoFingerSwipe, fallback: .singleTapDefaults),
                showTiming: true,
                showQuickDuration: true
            )
            family(
                "One-finger double-tap + swipe",
                settings: setting(\.doubleTapSwipe, fallback: DoubleTapSwipeSettings()),
                showTiming: false,
                showQuickDuration: false
            )
            family(
                "Two-finger tap + swipe",
                settings: setting(\.twoFingerSingleTapSwipe, fallback: .singleTapDefaults),
                showTiming: true,
                showQuickDuration: true
            )
            family(
                "Two-finger double-tap + swipe",
                settings: setting(\.twoFingerDoubleTapSwipe, fallback: DoubleTapSwipeSettings()),
                showTiming: true,
                showQuickDuration: false
            )
        }
    }

    private func setting(_ key: WritableKeyPath<ProfileGestures, DoubleTapSwipeSettings?>,
                         fallback: DoubleTapSwipeSettings) -> Binding<DoubleTapSwipeSettings> {
        Binding(get: {
            gestures[keyPath: key] ?? fallback
        }, set: { value in
            gestures[keyPath: key] = value
        })
    }

    @ViewBuilder
    private func family(_ title: String, settings: Binding<DoubleTapSwipeSettings>,
                        showTiming: Bool, showQuickDuration: Bool) -> some View {
        let count = SwipeDirection.allCases.filter { settings.wrappedValue.action(for: $0) != .none }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(count == 0 ? "Not assigned" : "\(count) direction\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
            }
            if showTiming {
                Stepper(value: Binding(get: {
                    settings.wrappedValue.resolvedWindow * 1_000
                }, set: { value in
                    settings.wrappedValue.swipeWindow = value / 1_000
                }), in: 100...800, step: 25) {
                    Text("Swipe window: \(Int(settings.wrappedValue.resolvedWindow * 1_000)) ms")
                        .monospacedDigit()
                }
            }
            TrackpadDistanceControl(
                title: "Swipe distance",
                units: settings.swipeDistance,
                scale: distanceScale,
                range: 20...240,
                explanation: "Minimum straight-line movement before the direction is recognized."
            )
            if showQuickDuration {
                Stepper(value: Binding(get: {
                    settings.wrappedValue.resolvedFastDuration * 1_000
                }, set: { value in
                    settings.wrappedValue.fastSwipeDuration = value / 1_000
                }), in: 60...300, step: 10) {
                    Text("Quick-swipe duration: \(Int((settings.wrappedValue.resolvedFastDuration * 1_000).rounded())) ms")
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

private extension SwipeDirection {
    var symbolName: String {
        switch self {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
}
