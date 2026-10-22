import AppKit
import SwiftUI

// MARK: - Design tokens

/// Shared spacing, radius, sizing and colour tokens for every Rota
/// settings surface. Components below read only from these values so the
/// whole app can be retuned in one place.
enum RotaTokens {
    /// The soft light blue behind a selected HUD tile, the timer glow and other HUD accents.
    static let glassBlue = Color(red: 0.58, green: 0.80, blue: 1.0)
    /// Settings panes beside the HUD canvas: a flat tint instead of a material,
    /// which costs a backdrop blur on every redraw for no visible gain over an opaque window.
    static let paneFill = Color(nsColor: .underPageBackgroundColor).opacity(0.35)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 22
    }
    enum Radius {
        static let s: CGFloat = 5
        static let m: CGFloat = 7
        static let l: CGFloat = 12
    }
    static func controlHeight(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 18
        case .small: return 22
        case .large, .extraLarge: return 32
        default: return 26
        }
    }
    static func fontSize(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 10
        case .small: return 11
        case .large, .extraLarge: return 13
        default: return 12
        }
    }
    /// The brand accent used for selection, focus and primary actions.
    static let accent = Color(nsColor: NSColor(name: "RotaAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.20, green: 0.70, blue: 0.75, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.53, blue: 0.58, alpha: 1)
    })
    static let fieldFill = Color(nsColor: .controlBackgroundColor)
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.13)
    static let subtleFill = Color.primary.opacity(0.06)
    static let hoverFill = Color.primary.opacity(0.09)
    static let pressedFill = Color.primary.opacity(0.14)
}

// MARK: - Shared control chrome

/// Bezel shared by fields, select triggers and menu buttons.
struct RotaControlChrome: View {
    var hovered = false
    var pressed = false
    var active = false
    var enabled = true
    var body: some View {
        RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
            .fill(pressed ? AnyShapeStyle(RotaTokens.pressedFill) : AnyShapeStyle(RotaTokens.fieldFill))
            .overlay {
                RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .fill(hovered && !pressed && enabled ? RotaTokens.subtleFill : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .strokeBorder(active ? RotaTokens.accent.opacity(0.85) : RotaTokens.hairline, lineWidth: active ? 1.5 : 1)
            }
            // A half-point shadow needs an offscreen blur per button; the same
            // hairline below the edge reads identically.
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .strokeBorder(Color.black.opacity(enabled ? 0.06 : 0), lineWidth: 0.5)
                    .offset(y: 0.5)
            }
    }
}

// MARK: - Buttons

/// Primary, secondary, destructive, ghost, icon and link buttons.
struct RotaButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, ghost, icon, link }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        RotaButtonBody(kind: configuration.role == .destructive && kind == .secondary ? .destructive : kind,
                       configuration: configuration)
    }
}

private struct RotaButtonBody: View {
    let kind: RotaButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovered = false

    var body: some View {
        styled
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    @ViewBuilder private var styled: some View {
        let height = RotaTokens.controlHeight(controlSize)
        let font = Font.system(size: RotaTokens.fontSize(controlSize), weight: kind == .primary ? .semibold : .medium)
        switch kind {
        case .link:
            configuration.label
                .foregroundStyle(RotaTokens.accent.opacity(configuration.isPressed ? 0.6 : 1))
                .underline(hovered && enabled)
                .contentShape(Rectangle())
        case .icon:
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: RotaTokens.fontSize(controlSize) + 1, weight: .medium))
                .foregroundStyle(hovered ? Color.primary : Color.secondary)
                .frame(minWidth: height, minHeight: height)
                .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .fill(configuration.isPressed ? RotaTokens.pressedFill : hovered && enabled ? RotaTokens.hoverFill : .clear))
                .contentShape(RoundedRectangle(cornerRadius: RotaTokens.Radius.m))
        case .ghost:
            configuration.label
                .font(font)
                .lineLimit(1)
                .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
                .padding(.horizontal, RotaTokens.Space.m)
                .frame(minHeight: height)
                .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .fill(configuration.isPressed ? RotaTokens.pressedFill : hovered && enabled ? RotaTokens.hoverFill : .clear))
                .contentShape(RoundedRectangle(cornerRadius: RotaTokens.Radius.m))
        case .primary:
            configuration.label
                .font(font)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, RotaTokens.Space.l)
                .frame(minHeight: height)
                .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .fill(RotaTokens.accent.opacity(configuration.isPressed ? 0.75 : hovered ? 0.92 : 1)))
                .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18)))
                .shadow(color: RotaTokens.accent.opacity(enabled ? 0.25 : 0), radius: 2, y: 1)
                .contentShape(RoundedRectangle(cornerRadius: RotaTokens.Radius.m))
        case .secondary, .destructive:
            configuration.label
                .font(font)
                .lineLimit(1)
                .foregroundStyle(kind == .destructive ? Color.red : Color.primary)
                .padding(.horizontal, RotaTokens.Space.l - 2)
                .frame(minHeight: height)
                .background(RotaControlChrome(hovered: hovered, pressed: configuration.isPressed, enabled: enabled))
                .contentShape(RoundedRectangle(cornerRadius: RotaTokens.Radius.m))
        }
    }
}

extension ButtonStyle where Self == RotaButtonStyle {
    static var rotaPrimary: RotaButtonStyle { RotaButtonStyle(kind: .primary) }
    static var rotaSecondary: RotaButtonStyle { RotaButtonStyle(kind: .secondary) }
    static var rotaDestructive: RotaButtonStyle { RotaButtonStyle(kind: .destructive) }
    static var rotaGhost: RotaButtonStyle { RotaButtonStyle(kind: .ghost) }
    static var rotaIcon: RotaButtonStyle { RotaButtonStyle(kind: .icon) }
    static var rotaLink: RotaButtonStyle { RotaButtonStyle(kind: .link) }
}

// MARK: - Options

/// One choice in a `RotaSelect` or `RotaSegmented`.
struct RotaOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String? = nil
    var section: String? = nil
    var id: Value { value }

    init(_ title: String, value: Value, systemImage: String? = nil, section: String? = nil) {
        self.title = title; self.value = value; self.systemImage = systemImage; self.section = section
    }
}

extension Array {
    /// Builds options from a value list, e.g. `ExplorerTheme.allCases.rotaOptions(\.title)`.
    func rotaOptions(_ title: (Element) -> String, systemImage: ((Element) -> String?)? = nil) -> [RotaOption<Element>] where Element: Hashable {
        map { RotaOption(title($0), value: $0, systemImage: systemImage?($0)) }
    }
}

// MARK: - Select (custom dropdown)

/// A custom-drawn single-choice dropdown. The trigger is a Rota field;
/// the list is a Rota popover with hover/keyboard highlight, type-to-select,
/// arrow keys, Return to choose and Escape to dismiss. VoiceOver sees a
/// button whose value is the current choice and can adjust it directly.
struct RotaSelect<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [RotaOption<Value>]
    var showsTitle: Bool
    var fill: Bool
    var placeholder: String

    @State private var open = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize

    init(_ title: String, selection: Binding<Value>, options: [RotaOption<Value>],
         showsTitle: Bool = true, fill: Bool = false, placeholder: String = "Choose…") {
        self.title = title; _selection = selection; self.options = options
        self.showsTitle = showsTitle; self.fill = fill; self.placeholder = placeholder
    }

    private var current: RotaOption<Value>? { options.first { $0.value == selection } }

    var body: some View {
        HStack(spacing: RotaTokens.Space.m) {
            if showsTitle { Text(title).lineLimit(1).fixedSize() }
            trigger
        }
        .accessibilityElement(children: .contain)
    }

    private var trigger: some View {
        Button { open.toggle() } label: {
            HStack(spacing: RotaTokens.Space.s) {
                if let symbol = current?.systemImage {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
                }
                ZStack(alignment: .leading) {
                    // Size to the widest choice so the trigger never jumps.
                    ForEach(options) { option in Text(option.title).lineLimit(1).hidden() }
                    Text(current?.title ?? placeholder).lineLimit(1)
                        .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                }
                .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(open ? RotaTokens.accent : Color.secondary)
            }
            .font(.system(size: RotaTokens.fontSize(controlSize)))
            .padding(.horizontal, RotaTokens.Space.m + 1)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: RotaTokens.controlHeight(controlSize))
            .background(RotaControlChrome(hovered: hovered, active: open, enabled: enabled))
            .contentShape(RoundedRectangle(cornerRadius: RotaTokens.Radius.m))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(current?.title ?? placeholder)
        .accessibilityHint("Shows choices")
        .accessibilityAdjustableAction { direction in
            guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
            switch direction {
            case .increment: if index + 1 < options.count { selection = options[index + 1].value }
            case .decrement: if index > 0 { selection = options[index - 1].value }
            @unknown default: break
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            RotaOptionList(options: options, selection: selection, onPick: { value in
                open = false
                if value != selection { selection = value }
            }, onCancel: { open = false })
        }
    }
}

extension RotaSelect {
    /// Convenience for value lists: `RotaSelect("Theme", selection: $t, values: ExplorerTheme.allCases) { $0.title }`.
    init(_ title: String, selection: Binding<Value>, values: [Value], showsTitle: Bool = true, fill: Bool = false,
         titleFor: (Value) -> String) {
        self.init(title, selection: selection, options: values.rotaOptions(titleFor), showsTitle: showsTitle, fill: fill)
    }
}

private struct RotaOptionList<Value: Hashable>: View {
    let options: [RotaOption<Value>]
    let selection: Value
    let onPick: (Value) -> Void
    let onCancel: () -> Void
    @State private var highlighted: Value?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if options.count > 12 {
                    ScrollView { rows.padding(RotaTokens.Space.xs + 1) }.frame(height: 330)
                } else {
                    rows.padding(RotaTokens.Space.xs + 1)
                }
            }
            .frame(minWidth: 190, alignment: .leading)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.return) { if let highlighted { onPick(highlighted) }; return .handled }
            .onKeyPress(.space) { if let highlighted { onPick(highlighted) }; return .handled }
            .onKeyPress(.escape) { onCancel(); return .handled }
            .onKeyPress(characters: .alphanumerics, phases: .down) { press in
                let prefix = press.characters.lowercased()
                if let match = options.first(where: { $0.title.lowercased().hasPrefix(prefix) }) {
                    highlighted = match.value; proxy.scrollTo(match.value, anchor: .center)
                }
                return .handled
            }
            .onAppear {
                highlighted = selection
                focused = true
                DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if let section = option.section, index == 0 || options[index - 1].section != section {
                    if index > 0 { Divider().padding(.vertical, 3) }
                    Text(section.uppercased())
                        .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, RotaTokens.Space.m).padding(.top, 3).padding(.bottom, 1)
                }
                row(option).id(option.value)
            }
        }
    }

    private func row(_ option: RotaOption<Value>) -> some View {
        let lit = highlighted == option.value
        return Button { onPick(option.value) } label: {
            HStack(spacing: RotaTokens.Space.s) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(option.value == selection ? 1 : 0)
                    .frame(width: 12)
                if let symbol = option.systemImage {
                    Image(systemName: symbol).frame(width: 16)
                }
                Text(option.title).lineLimit(1)
                Spacer(minLength: RotaTokens.Space.l)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(lit ? Color.white : Color.primary)
            .padding(.horizontal, RotaTokens.Space.s)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.s, style: .continuous)
                .fill(lit ? RotaTokens.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = option.value } }
        .accessibilityAddTraits(option.value == selection ? .isSelected : [])
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.value == highlighted } ?? -1
        let next = min(max(index + delta, 0), options.count - 1)
        highlighted = options[next].value
        proxy.scrollTo(options[next].value)
    }
}

// MARK: - Menu button (custom trigger for command menus)

/// A custom-drawn trigger for command menus. Command menus keep a native
/// macOS menu body so nested submenus, keyboard navigation and VoiceOver
/// work exactly like the rest of the system; only the button is custom.
struct RotaMenuButton<Content: View>: View {
    enum Kind { case toolbar, field, icon }
    let title: String
    var systemImage: String?
    var kind: Kind
    var showsTitle: Bool
    var help: String?
    var accessibilityTitle: String?
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize

    init(_ title: String, systemImage: String? = nil, kind: Kind = .toolbar, showsTitle: Bool = true,
         help: String? = nil, accessibilityTitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.systemImage = systemImage; self.kind = kind
        self.showsTitle = showsTitle; self.help = help; self.accessibilityTitle = accessibilityTitle
        self.content = content
    }

    var body: some View {
        Menu {
            content()
                .toggleStyle(.automatic)
                .buttonStyle(.automatic)
        } label: {
            if kind == .icon || !showsTitle, let systemImage {
                Image(systemName: systemImage)
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .font(.system(size: RotaTokens.fontSize(controlSize), weight: .medium))
        .modifier(RotaMenuSizing(icon: kind == .icon, height: RotaTokens.controlHeight(controlSize)))
        .overlay(alignment: .trailing) {
            if kind != .icon {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, RotaTokens.Space.m + 1)
                    .allowsHitTesting(false)
            }
        }
        .background {
            if kind == .icon {
                RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .fill(hovered && enabled ? RotaTokens.hoverFill : .clear)
            } else {
                RotaControlChrome(hovered: hovered, enabled: enabled)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: RotaTokens.Radius.m))
        .onHover { hovered = $0 }
        .opacity(enabled ? 1 : 0.5)
        .help(help ?? title)
        .accessibilityLabel(accessibilityTitle ?? title)
    }
}

/// Text menus hug their title; icon menus fill a square-ish hit target so the
/// whole chip (not only the glyph) opens the menu.
private struct RotaMenuSizing: ViewModifier {
    let icon: Bool
    let height: CGFloat
    func body(content: Content) -> some View {
        if icon {
            content.frame(width: max(28, height + 4), height: height)
        } else {
            content.fixedSize()
                .padding(.leading, RotaTokens.Space.m + 1)
                .padding(.trailing, 23)
                .frame(minHeight: height)
        }
    }
}

// MARK: - Segmented control

/// A custom segmented control with a sliding selection thumb.
struct RotaSegmented<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [RotaOption<Value>]
    var fill = false
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize

    init(_ title: String, selection: Binding<Value>, options: [RotaOption<Value>], fill: Bool = false) {
        self.title = title; _selection = selection; self.options = options; self.fill = fill
    }

    var body: some View {
        HStack(spacing: RotaTokens.Space.xxs) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    if reduceMotion { selection = option.value }
                    else { withAnimation(.snappy(duration: 0.2)) { selection = option.value } }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.systemImage { Image(systemName: symbol) }
                        Text(option.title).lineLimit(1)
                    }
                    .font(.system(size: RotaTokens.fontSize(controlSize), weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, RotaTokens.Space.l - 1)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .frame(height: RotaTokens.controlHeight(controlSize) - 4)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: RotaTokens.Radius.s + 1, style: .continuous)
                                .fill(RotaTokens.fieldFill)
                                .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.s + 1, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5).offset(y: 0.5))
                                .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.s + 1, style: .continuous)
                                    .strokeBorder(RotaTokens.accent.opacity(0.35)))
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(RotaTokens.Space.xxs)
        .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m + 1, style: .continuous).fill(RotaTokens.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.m + 1, style: .continuous).strokeBorder(RotaTokens.hairline.opacity(0.6)))
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension RotaSegmented {
    init(_ title: String, selection: Binding<Value>, values: [Value], fill: Bool = false, titleFor: (Value) -> String) {
        self.init(title, selection: selection, options: values.rotaOptions(titleFor), fill: fill)
    }
}

// MARK: - Toggles

/// A custom switch. The accessibility representation is a native toggle so
/// VoiceOver and UI tests see an ordinary on/off control.
struct RotaSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RotaSwitchBody(configuration: configuration)
    }
}

private struct RotaSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height: CGFloat = controlSize == .mini ? 13 : controlSize == .small ? 16 : 19
        let width = height * 1.75
        HStack(spacing: RotaTokens.Space.m) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(RotaTokens.accent) : AnyShapeStyle(Color.primary.opacity(0.22)))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.06)))
                .frame(width: width, height: height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5).offset(y: 0.5))
                        .padding(1.5)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
        .opacity(enabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A custom checkbox: rounded box on the leading edge, label trailing.
struct RotaCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RotaCheckboxBody(configuration: configuration)
    }
}

private struct RotaCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: RotaTokens.Space.s + 1) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? AnyShapeStyle(RotaTokens.accent) : AnyShapeStyle(RotaTokens.fieldFill))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.clear : Color.primary.opacity(hovered ? 0.4 : 0.28)))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                configuration.label.foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .opacity(enabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A pill that is filled while on — used for modifier keys and filters.
struct RotaChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
                .frame(minWidth: 26, minHeight: 24)
                .padding(.horizontal, RotaTokens.Space.xs)
                .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .fill(configuration.isOn ? AnyShapeStyle(RotaTokens.accent) : AnyShapeStyle(RotaTokens.fieldFill)))
                .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                    .strokeBorder(configuration.isOn ? Color.clear : RotaTokens.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == RotaSwitchToggleStyle {
    static var rotaSwitch: RotaSwitchToggleStyle { RotaSwitchToggleStyle() }
}
extension ToggleStyle where Self == RotaCheckboxToggleStyle {
    static var rotaCheckbox: RotaCheckboxToggleStyle { RotaCheckboxToggleStyle() }
}
extension ToggleStyle where Self == RotaChipToggleStyle {
    static var rotaChip: RotaChipToggleStyle { RotaChipToggleStyle() }
}

// MARK: - Stepper

/// A compact − value + stepper.
struct RotaStepper<Label: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @ViewBuilder let label: () -> Label

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, @ViewBuilder label: @escaping () -> Label) {
        _value = value; self.range = range; self.step = step; self.label = label
    }

    var body: some View {
        HStack(spacing: RotaTokens.Space.m) {
            label()
            HStack(spacing: 0) {
                stepButton("minus", delta: -step).disabled(value <= range.lowerBound)
                Rectangle().fill(RotaTokens.hairline).frame(width: 1, height: 14)
                stepButton("plus", delta: step).disabled(value >= range.upperBound)
            }
            .background(RotaControlChrome())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(step)
            case .decrement: change(-step)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button { change(delta) } label: {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Decrease" : "Increase")
    }

    private func change(_ delta: Double) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
    }
}

extension RotaStepper {
    init(value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, @ViewBuilder label: @escaping () -> Label) {
        self.init(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                  in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step), label: label)
    }
}

// MARK: - Cards, headers and disclosure

/// A titled content card that replaces GroupBox and ad-hoc rounded panels.
struct RotaCard<Content: View, Accessory: View>: View {
    let title: String?
    var systemImage: String?
    var subtitle: String?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, systemImage: String? = nil, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.systemImage = systemImage; self.subtitle = subtitle
        self.accessory = accessory; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.l) {
            if title != nil || subtitle != nil {
                HStack(alignment: .top) {
                    RotaSectionHeader(title ?? "", systemImage: systemImage, subtitle: subtitle)
                    Spacer(minLength: RotaTokens.Space.m)
                    accessory()
                }
            }
            content()
        }
        .padding(RotaTokens.Space.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.l, style: .continuous).fill(RotaTokens.cardFill))
        .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.l, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        // A container boundary, like GroupBox: identifiers applied around a
        // card never overwrite the identifiers of the controls inside it.
        .accessibilityElement(children: .contain)
    }
}

extension RotaCard where Accessory == EmptyView {
    init(_ title: String? = nil, systemImage: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, systemImage: systemImage, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// Section title with optional icon and supporting line.
struct RotaSectionHeader: View {
    let title: String
    var systemImage: String?
    var subtitle: String?

    init(_ title: String, systemImage: String? = nil, subtitle: String? = nil) {
        self.title = title; self.systemImage = systemImage; self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                HStack(spacing: RotaTokens.Space.s) {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(RotaTokens.accent).font(.system(size: 12, weight: .semibold))
                    }
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A custom disclosure section with an animated chevron.
struct RotaDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
        _isExpanded = isExpanded; self.label = label; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion { isExpanded.toggle() } else { withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() } }
            } label: {
                HStack(spacing: RotaTokens.Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hovered ? Color.primary : Color.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    label()
                    Spacer(minLength: 0)
                }
                .padding(.vertical, RotaTokens.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content()
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }
}

/// Owns its expansion state when the caller does not need to.
struct RotaDisclosureSection<Label: View, Content: View>: View {
    @State private var expanded: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    init(initiallyExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
        _expanded = State(initialValue: initiallyExpanded); self.label = label; self.content = content
    }

    var body: some View { RotaDisclosure(isExpanded: $expanded, content: content, label: label) }
}

extension RotaDisclosureSection where Label == Text {
    init(_ title: String, initiallyExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(initiallyExpanded: initiallyExpanded, content: content, label: { Text(title) })
    }
}

extension RotaDisclosure where Label == Text {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(isExpanded: isExpanded, content: content, label: { Text(title) })
    }
}
