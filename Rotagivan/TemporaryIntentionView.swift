import SwiftUI

/// The same native editor is used in Voice settings and the HUD popover.
/// Its store is deliberately separate from persisted/synced settings.
struct TemporaryIntentionEditor: View {
    @ObservedObject var store: TemporaryIntentionStore
    @StateObject private var speech: NoteDictationSession
    var admission: VoiceMicrophoneAdmission
    @State private var entryID = UUID()
    @State private var draft = ""
    @State private var error: String?

    init(store: TemporaryIntentionStore, speech: NoteDictationSession? = nil,
         admission: VoiceMicrophoneAdmission? = nil) {
        let admission = admission ?? .shared
        self.store = store; self.admission = admission
        _speech = StateObject(wrappedValue: speech ?? NoteDictationSession(admission: admission))
    }

    private var activeText: String? { store.snapshot().text }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temporary note").font(.headline)
            TextField("For example, the marketing campaign", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Temporary intention")
                .accessibilityIdentifier("temporary-intention-input")
            HStack {
                Button("Dictate note") { speech.start() }
                    .disabled(speech.phase == .preparing || speech.phase == .listening || speech.phase == .stopping)
                    .accessibilityIdentifier("temporary-intention-dictate")
                if speech.phase == .listening {
                    Button("Stop") { speech.stop() }.accessibilityIdentifier("temporary-intention-dictation-stop")
                }
                if speech.phase == .preparing || speech.phase == .listening || speech.phase == .stopping {
                    Button("Cancel") { speech.cancel() }.accessibilityIdentifier("temporary-intention-dictation-cancel")
                }
            }
            if !speech.message.isEmpty {
                Text(speech.phase == .idle || speech.phase == .cancelled
                     ? "Dictate a short note, then review and save it." : speech.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("temporary-intention-dictation-status")
            }
            HStack {
                Text("\(trimmed.count)/500 characters").foregroundStyle(trimmed.count > 500 ? Color.red : Color.secondary)
                Spacer()
                Text("30 minutes").foregroundStyle(.secondary)
            }.font(.caption)
            HStack {
                Button(activeText == nil ? "Save note" : "Replace note") {
                    speech.cancel()
                    do { try store.set(text: draft); error = nil; draft = store.snapshot().text ?? "" }
                    catch { self.error = error.localizedDescription }
                }.disabled(trimmed.isEmpty || trimmed.count > TemporaryIntentionStore.maximumCharacters)
                    .accessibilityIdentifier("temporary-intention-set")
                Button("Clear note") {
                    speech.cancel()
                    store.clear(); draft = ""; error = nil
                }.disabled(activeText == nil).accessibilityIdentifier("temporary-intention-clear")
            }
            if let error = error ?? (trimmed.count > TemporaryIntentionStore.maximumCharacters ? TemporaryIntentionError.tooLong.errorDescription : nil) {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("temporary-intention-error")
            }
            Divider()
            if let activeText {
                Text(activeText).lineLimit(3).help(activeText)
                    .accessibilityIdentifier("temporary-intention-active")
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(expiryText).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("temporary-intention-expiry")
                }
            } else {
                Text("No active note").foregroundStyle(.secondary)
                    .accessibilityIdentifier("temporary-intention-empty")
            }
            Text("Dictation sends audio to OpenRouter/xAI for transcription only. The note stays in memory on this Mac for 30 minutes, then expires. It is not synced, sent to Jev, or used to choose apps or actions.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("temporary-intention-privacy")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { admission.beginPrivateEntry(entryID); store.refreshExpiry(); draft = store.snapshot().text ?? "" }
        .onDisappear { speech.cancel(); admission.endPrivateEntry(entryID) }
        .onChange(of: speech.transcript) { _, text in
            if speech.phase == .listening || speech.phase == .stopping || speech.phase == .finished { draft = text }
        }
        .onChange(of: store.context.revision) { _, _ in
            speech.cancel(); draft = store.snapshot().text ?? ""; error = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("temporary-intention-editor")
    }

    private var expiryText: String {
        guard let seconds = store.remainingSeconds, seconds > 0 else { return "Expired" }
        return "Expires in \(max(1, (seconds + 59) / 60)) min"
    }
}

/// Compact status opens the full editor without changing the HUD wheel layout.
struct TemporaryIntentionControl: View {
    @ObservedObject var store: TemporaryIntentionStore = .shared
    var compact = false
    @StateObject private var speech: NoteDictationSession
    var admission: VoiceMicrophoneAdmission = .shared
    @State private var showingEditor = false
    @State private var entryID = UUID()
    var onPresent: () -> Void
    var onDismiss: () -> Void

    init(store: TemporaryIntentionStore? = nil, compact: Bool = false,
         speech: NoteDictationSession? = nil, admission: VoiceMicrophoneAdmission? = nil,
         onPresent: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}) {
        let admission = admission ?? .shared
        self.store = store ?? .shared; self.compact = compact; self.admission = admission
        self.onPresent = onPresent; self.onDismiss = onDismiss
        _speech = StateObject(wrappedValue: speech ?? NoteDictationSession(admission: admission))
    }

    var body: some View {
        let text = store.snapshot().text
        Button {
            admission.beginPrivateEntry(entryID)
            onPresent()
            showingEditor = true
        } label: {
            Label(text.map { "Note: " + $0 } ?? "Add note", systemImage: "note.text")
                .lineLimit(1).truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: compact ? 160 : .infinity, alignment: .leading)
        .help(text ?? "Save a temporary note for 30 minutes")
        .accessibilityLabel(text.map { "Temporary note: " + $0 } ?? "Add temporary note")
        .accessibilityIdentifier("temporary-intention-control")
        .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
            TemporaryIntentionEditor(store: store, speech: speech, admission: admission)
                .padding(16).frame(width: 320)
                .onDisappear { speech.cancel(); admission.endPrivateEntry(entryID); onDismiss() }
        }
        .onDisappear { speech.cancel(); admission.endPrivateEntry(entryID) }
    }
}
