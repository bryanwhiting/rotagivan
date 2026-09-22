import SwiftUI

struct LayerActionAssignmentsEditor: View {
    @Binding var gestures: ProfileGestures
    var distanceScale: TrackpadDistanceScale? = nil
    @State private var showingAddAction = false

    private var assignments: [AppGestureBinding] {
        AppGestureTrigger.layerActionTriggers.compactMap { trigger in
            let assignment = trigger.assignment(in: gestures).binding
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

            DisclosureGroup {
                LayerSwipeRecognitionEditor(gestures: $gestures, distanceScale: distanceScale)
                    .padding(.top, 10)
            } label: {
                Label("Swipe recognition", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 2)
        }
        .sheet(isPresented: $showingAddAction) {
            AddLayerActionSheet(existing: Set(assignments.map(\.trigger))) { trigger, action, shortcut in
                var updated = gestures
                _ = updated.setLayerAction(action, shortcut: shortcut, for: trigger)
                gestures = updated
                showingAddAction = false
            } onCancel: {
                showingAddAction = false
            }
        }
    }

    private func actionBinding(for trigger: AppGestureTrigger) -> Binding<TapAction> {
        Binding(get: {
            trigger.assignment(in: gestures).binding.action
        }, set: { action in
            let current = trigger.assignment(in: gestures).binding
            var updated = gestures
            _ = updated.setLayerAction(action, shortcut: current.shortcut, for: trigger)
            gestures = updated
        })
    }

    private func shortcutBinding(for trigger: AppGestureTrigger) -> Binding<RecordedShortcut?> {
        Binding(get: {
            trigger.assignment(in: gestures).binding.shortcut
        }, set: { shortcut in
            var updated = gestures
            _ = updated.setLayerAction(shortcut == nil ? .none : .shortcut, shortcut: shortcut, for: trigger)
            gestures = updated
        })
    }

    private func remove(_ trigger: AppGestureTrigger) {
        var updated = gestures
        _ = updated.setLayerAction(.none, shortcut: nil, for: trigger)
        gestures = updated
    }
}

private struct LayerActionAssignmentRow: View {
    let trigger: AppGestureTrigger
    @Binding var action: TapAction
    @Binding var shortcut: RecordedShortcut?
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

            LayerActionValueMenu(
                action: $action,
                shortcut: $shortcut,
                shortcutsOnly: trigger.direction != nil
            )
            .frame(width: 190)

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(trigger.title)")
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
                    Menu("Keybindings and macros") {
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
                        Button(layer.name + (layer.appName.map { " · \($0)" } ?? "")) {
                            shortcut = .hudLayer(layer)
                            action = .shortcut
                        }
                    }
                }
            }

            Section("Rotagivan") {
                Button("App Explorer") { choose(.appExplorer) }
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
    @State private var direction: SwipeDirection?
    @State private var action = TapAction.none
    @State private var shortcut: RecordedShortcut?

    private var trigger: AppGestureTrigger {
        direction.flatMap { AppGestureTrigger.combining(tap: tap, direction: $0) } ?? tap
    }
    private var canSwipe: Bool { AppGestureTrigger.swipeCapableTapTriggers.contains(tap) }
    private var canSave: Bool {
        action != .none && (action != .shortcut || shortcut != nil) &&
            (direction == nil || action == .shortcut || action == .appExplorer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add tap action")
                    .font(.title3.weight(.semibold))
                Text("Choose the tap first. Add a direction only when the action should run after a swipe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                selectionRow(number: "1", title: "Tap") {
                    Picker("Tap", selection: $tap) {
                        ForEach(AppGestureTrigger.baseTapTriggers) { trigger in
                            Text(trigger.title).tag(trigger)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: tap) { _, value in
                        if !AppGestureTrigger.swipeCapableTapTriggers.contains(value) { direction = nil }
                    }
                }
                Divider().padding(.leading, 42)
                selectionRow(number: "2", title: "Swipe (optional)") {
                    Picker("Swipe direction", selection: $direction) {
                        Text("No swipe").tag(nil as SwipeDirection?)
                        ForEach(SwipeDirection.allCases, id: \.self) { direction in
                            Label(direction.title, systemImage: direction.symbolName)
                                .tag(direction as SwipeDirection?)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(!canSwipe)
                    .onChange(of: direction) { _, value in
                        guard value != nil, action != .shortcut, action != .appExplorer else { return }
                        action = .none
                        shortcut = nil
                    }
                }
                Divider().padding(.leading, 42)
                selectionRow(number: "3", title: "Action") {
                    LayerActionValueMenu(
                        action: $action,
                        shortcut: $shortcut,
                        shortcutsOnly: direction != nil
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
            } else if !canSwipe {
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
        .frame(width: 470)
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

private struct LayerSwipeRecognitionEditor: View {
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
