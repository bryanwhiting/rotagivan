import SwiftUI

struct ExplorerTileAnchors: PreferenceKey {
    static let defaultValue: [ExplorerSlot: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ExplorerSlot: Anchor<CGRect>], nextValue: () -> [ExplorerSlot: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Preview drag targets use exactly the same sector paths as the live renderer.
enum ExplorerPreviewGeometry {
    static func dropTarget(at point: CGPoint, from source: ExplorerSlot, theme: ExplorerTheme, count: Int, depth: Int) -> ExplorerSlot? {
        if theme.isRadial || count != 8 {
            return ExplorerSlot.slots(count).first {
                ExplorerStarburstSector(direction: $0, innerRadius: ExplorerStarburstLayout.innerRadius(depth: depth),
                    outerRadius: 143, tip: theme.isFloating ? 2 : 11, halfAngle: 180 / Double(count) - 2, roundedRim: theme.isFloating)
                    .path(in: CGRect(x: 0, y: 0, width: 418, height: 310)).contains(point)
            }
        }
        let rows: [[ExplorerSlot?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]
        for row in 0..<3 {
            for column in 0..<3 where rows[row][column] == source {
                let position = CGPoint(x: point.x + Double(column) * 138, y: point.y + Double(row) * 106)
                for targetRow in 0..<3 {
                    for targetColumn in 0..<3 {
                        if CGRect(x: targetColumn * 138, y: targetRow * 106, width: 130, height: 98).contains(position) {
                            return rows[targetRow][targetColumn]
                        }
                    }
                }
            }
        }
        return nil
    }
}

struct ExplorerPreviewDrag: ViewModifier {
    let enabled: Bool
    let source: ExplorerSlot
    let theme: ExplorerTheme
    let count: Int
    let depth: Int
    var onChanged: (ExplorerSlot, ExplorerSlot?) -> Void
    var onEnded: (ExplorerSlot, ExplorerSlot?) -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { value in onChanged(source, ExplorerPreviewGeometry.dropTarget(at: value.location, from: source, theme: theme, count: count, depth: depth)) }
                .onEnded { value in onEnded(source, ExplorerPreviewGeometry.dropTarget(at: value.location, from: source, theme: theme, count: count, depth: depth)) })
        } else { content } // Never install an editing gesture on the live HUD.
    }
}

enum ExplorerHUDMotion {
    static func enabled(theme: ExplorerTheme, preference: Bool, reduceMotion: Bool) -> Bool {
        theme.isHUD && preference && !reduceMotion
    }
    static func nearestAngle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return current + delta
    }
}

extension ExplorerTheme {
    var accent: Color {
        switch self {
        case .native: return .teal
        case .starburst: return Color(red: 0.73, green: 0.65, blue: 1)
        case .starburstAir: return RotaTokens.glassBlue
        }
    }
    var surface: Color {
        if self == .starburst { return Color(red: 0.055, green: 0.043, blue: 0.105) }
        if self == .starburstAir { return Color(red: 0.10, green: 0.10, blue: 0.11) }
        return Color(red: 0.025, green: 0.045, blue: 0.045)
    }
}

/// Static geometry, not a continuously redrawn/animated canvas. The hardware
/// report loop only publishes sector changes; no animation owns an input timer.
struct ExplorerHUDBackdrop: View {
    let theme: ExplorerTheme
    var forceReduceTransparency = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var opaque: Bool { reduceTransparency || forceReduceTransparency }
    var body: some View {
        if theme == .native {
            RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.2)))
                .overlay { if opaque { RoundedRectangle(cornerRadius: 26).fill(Color(nsColor: .windowBackgroundColor)) } }
        } else if theme == .starburst {
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [theme.surface, Color(red: 0.09, green: 0.065, blue: 0.17)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(theme.accent.opacity(0.28)))
                .accessibilityHidden(true).allowsHitTesting(false)
        } else {
            // Air's material belongs to the wheel, not a rectangular window.
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// Carries the HUD's atmospheric color into its one canonical editor without
/// reducing contrast in light appearance.
struct ExplorerSettingsBackdrop: View {
    let theme: ExplorerTheme
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let base = Color(nsColor: .windowBackgroundColor)
        LinearGradient(colors: colorScheme == .dark
            ? [theme.surface.opacity(0.98), Color(red: 0.22, green: 0.08, blue: 0.23), theme.surface.opacity(0.92)]
            : [base, theme.accent.opacity(0.10), Color.purple.opacity(0.08), base],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// One static native material surface, shared by all wheel segments. No custom
/// blur filter, continuous animation, or rendering work in the input callback.
struct ExplorerAirGlass: View {
    var opaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if opaque || reduceTransparency {
                Circle().fill(ExplorerTheme.starburstAir.surface)
            } else {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(ExplorerTheme.starburstAir.surface.opacity(0.42))
            }
            // Liquid-glass look: a soft top highlight, a faint blue body and a
            // specular rim that is brightest where light would catch it.
            Circle().fill(RadialGradient(colors: [.white.opacity(0.10), .clear], center: UnitPoint(x: 0.35, y: 0.12),
                startRadius: 0, endRadius: 170))
            Circle().fill(RotaTokens.glassBlue.opacity(0.035))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06), .white.opacity(0.10), .white.opacity(0.30)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            Circle().strokeBorder(.white.opacity(0.06), lineWidth: 0.5).padding(3)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 7)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Keep keyboard navigation visible without AppKit's unrelated blue focus halo.
struct ExplorerSectorFocus: ViewModifier {
    let theme: ExplorerTheme
    let shape: ExplorerStarburstSector
    var airShape: ExplorerGlassLens? = nil
    @FocusState private var focused: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *), theme.isHUD {
            content
                .focusEffectDisabled()
                .focused($focused)
                .overlay {
                    if focused {
                        if let airShape {
                            airShape.stroke(theme.accent.opacity(0.9), lineWidth: 1.5)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        } else {
                            shape.stroke(theme.accent.opacity(0.9), lineWidth: 1.5)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }
        } else {
            content
        }
    }
}

struct ExplorerAirSectorChrome<S: Shape>: View {
    let shape: S
    let selected: Bool
    let available: Bool
    var opaque = false
    var body: some View {
        let accent = ExplorerTheme.starburstAir.accent
        ZStack {
            shape.fill(opaque ? ExplorerTheme.starburstAir.surface : Color.white.opacity(available ? 0.035 : 0.015))
            if selected && opaque {
                shape.fill(accent.opacity(0.35))
            }
            // The glass lens carries the selection; the sector itself only
            // lights up when transparency is reduced and there is no lens.
            shape.stroke(selected && opaque ? accent.opacity(0.85) : Color.white.opacity(available ? 0.10 : 0.05), lineWidth: selected && opaque ? 0.75 : 0.5)
                .shadow(color: accent.opacity(selected && opaque ? 0.7 : 0), radius: selected && opaque ? 5 : 0)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Voice and application wheels share sector surfaces and availability contrast.
struct ExplorerSectorChrome: View {
    let theme: ExplorerTheme
    let shape: ExplorerStarburstSector
    let selected: Bool
    let available: Bool
    var opaque = false
    /// The rounded wedge Air tiles are drawn with; the starburst sector stays the hit area.
    var airShape: ExplorerGlassLens? = nil
    var body: some View {
        if theme.isFloating {
            if let airShape {
                ExplorerAirSectorChrome(shape: airShape, selected: selected, available: available, opaque: opaque)
            } else {
                ExplorerAirSectorChrome(shape: shape, selected: selected, available: available, opaque: opaque)
            }
        } else {
            ZStack {
                shape.fill(LinearGradient(colors: [theme.accent.opacity(selected ? 0.38 : 0.08),
                    theme.accent.opacity(selected ? 0.18 : 0.025)], startPoint: .top, endPoint: .bottom))
                shape.stroke(theme.accent.opacity(selected ? 0.95 : available ? 0.35 : 0.12),
                    lineWidth: selected ? 1.5 : 0.75)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// Amplitude/transcript updates do not invalidate static wheel layout or glass.
struct ExplorerStableWheel<State: Equatable, Content: View>: View, Equatable {
    let state: State
    let content: Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }
    var body: some View { content }
}

struct ExplorerCornerMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let arm = min(15.0, rect.width / 5)
        for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                              (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x, y: y + sy * arm))
            p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + sx * arm, y: y))
        }
        return p
    }
}

struct ExplorerTileChrome: View {
    let theme: ExplorerTheme
    let selected: Bool
    let occupied: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.isHUD ? 9 : 15)
        ZStack {
            shape.fill(theme.isHUD ? theme.surface.opacity(0.96) : Color.primary.opacity(0.035))
            shape.fill(theme.accent.opacity(selected ? 0.19 : (theme.isHUD && occupied ? 0.035 : 0)))
            shape.strokeBorder(selected ? theme.accent : (theme.isHUD ? theme.accent.opacity(occupied ? 0.20 : 0.08) : .clear), lineWidth: selected ? 1.5 : 0.7)
            if theme.isHUD {
                ExplorerCornerMarks().stroke(theme.accent, lineWidth: 1.5).padding(4).opacity(selected ? 1 : 0)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ExplorerThemePicker: View {
    @Binding var theme: ExplorerTheme
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ExplorerTheme.allCases, id: \.self) { option in
                Button { theme = option } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack {
                            ExplorerHUDBackdrop(theme: option)
                            if option.isRadial {
                                ZStack {
                                    if option.isFloating { ExplorerAirGlass().frame(width: 54, height: 54) }
                                    ForEach(ExplorerSlot.allCases, id: \.self) { direction in
                                        ExplorerStarburstSector(direction: direction, innerRadius: 9, outerRadius: 24, tip: 3, roundedRim: option.isFloating)
                                            .fill(option.isFloating ? (direction == .topRight ? option.accent.opacity(0.6) : option.surface.opacity(0.55)) : option.accent.opacity(direction == .topRight ? 0.9 : 0.3))
                                            .overlay {
                                                if option.isFloating {
                                                    ExplorerStarburstSector(direction: direction, innerRadius: 9, outerRadius: 24, tip: 3, roundedRim: true)
                                                        .stroke(direction == .topRight ? option.accent : option.accent.opacity(0.65), lineWidth: 0.75)
                                                }
                                            }
                                    }
                                    Circle().stroke(option.accent.opacity(0.8), lineWidth: 1).frame(width: 12, height: 12)
                                }.frame(width: 58, height: 58)
                            } else {
                            HStack(spacing: 5) {
                                ForEach(0..<3) { index in
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(option.accent.opacity(index == 1 ? 0.75 : 0.16))
                                        .frame(width: 22, height: index == 1 ? 30 : 24)
                                }
                            }
                            }
                        }.frame(height: 60).clipShape(RoundedRectangle(cornerRadius: 9))
                        HStack(spacing: 4) {
                            Text(option.title).font(.system(size: 11, weight: .semibold))
                            Spacer(minLength: 0)
                            Image(systemName: theme == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(theme == option ? Color.accentColor : .secondary)
                        }
                        Text(option.subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(8).frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(theme == option ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(theme == option ? 0.3 : 0.08)))
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) theme")
                    .accessibilityAddTraits(theme == option ? .isSelected : [])
            }
        }
    }
}

/// Fixed direction geometry: labels and hit targets never rotate when drilling
/// into groups. Ancestors add inner rings; the current choices stay on the rim.
enum ExplorerStarburstLayout {
    static func angle(_ direction: ExplorerSlot) -> Double {
        direction.angle
    }
    static func point(_ direction: ExplorerSlot, radius: Double, center: CGPoint) -> CGPoint {
        let radians = angle(direction) * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }
    static func ringRadius(_ level: Int) -> Double { 35 + Double(max(0, min(4, level))) * 9 }
    static func innerRadius(depth: Int) -> Double { 48 + Double(max(0, min(5, depth))) * 9 }
    /// Air tiles and the selection lens share one rounded wedge, so a tile's
    /// border is exactly the highlight's border.
    static let airOuterRadius = 139.0
    static func airTile(angle: Double, depth: Int, slotCount: Int) -> ExplorerGlassLens {
        ExplorerGlassLens(angle: angle, innerRadius: innerRadius(depth: depth) + 26, outerRadius: airOuterRadius,
                          halfAngle: 180 / Double(slotCount) - 3.5)
    }
}

struct ExplorerStarburstSector: Shape {
    let direction: ExplorerSlot
    let innerRadius: Double
    let outerRadius: Double
    var tip: Double = 0
    var halfAngle: Double = 20.5
    var roundedRim = false
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let middle = ExplorerStarburstLayout.angle(direction)
        let start = Angle.degrees(middle - halfAngle), end = Angle.degrees(middle + halfAngle)
        func point(_ angle: Angle, _ radius: Double) -> CGPoint {
            CGPoint(x: center.x + cos(angle.radians) * radius, y: center.y + sin(angle.radians) * radius)
        }
        var path = Path()
        path.move(to: point(start, innerRadius))
        path.addLine(to: point(start, roundedRim ? outerRadius + tip : outerRadius))
        if roundedRim {
            path.addArc(center: center, radius: outerRadius + tip, startAngle: start, endAngle: end, clockwise: false)
        } else {
            path.addLine(to: point(.degrees(middle), outerRadius + tip))
            path.addLine(to: point(end, outerRadius))
        }
        path.addLine(to: point(end, innerRadius))
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Real destination geometry, shown before the window is moved.
struct ExplorerLayoutPreview: View {
    let direction: SwipeDirection?
    let layout: ExplorerWindowLayout
    let accent: Color
    var body: some View {
        let area = CGRect(x: 0, y: 0, width: 72, height: 46)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.04))
            RoundedRectangle(cornerRadius: 5).strokeBorder(accent.opacity(0.5))
            if let direction {
                let tile = WindowTile.frame(direction, in: area, layout: layout).insetBy(dx: 2, dy: 2)
                RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.75))
                    .frame(width: tile.width, height: tile.height).offset(x: tile.minX, y: tile.minY)
            }
        }.frame(width: 72, height: 46).accessibilityHidden(true)
    }
}

/// The glass lens that slides between Air sectors as the selection moves.
/// Its angle animates, so the highlight glides around the ring instead of
/// jumping from tile to tile.
struct ExplorerGlassLens: Shape {
    var angle: Double
    let innerRadius: Double
    let outerRadius: Double
    let halfAngle: Double
    var cornerRadius = 10.0
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    /// An annular wedge whose four corners are rounded, so the highlight reads
    /// as one soft pill rather than a cut-out of the ring.
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(0, min(cornerRadius, (outerRadius - innerRadius) / 2 - 0.5))
        let lead = Angle.degrees(angle - halfAngle), trail = Angle.degrees(angle + halfAngle)
        // Corner-arc centres sit `radius` inside both edges they join.
        let outerInset = Angle.radians(asin(min(1, radius / max(1, outerRadius - radius))))
        let innerInset = Angle.radians(asin(min(1, radius / max(1, innerRadius + radius))))
        func point(_ value: Angle, _ distance: Double) -> CGPoint {
            CGPoint(x: center.x + cos(value.radians) * distance, y: center.y + sin(value.radians) * distance)
        }
        var path = Path()
        path.move(to: point(lead + outerInset, outerRadius))
        path.addArc(center: center, radius: outerRadius, startAngle: lead + outerInset, endAngle: trail - outerInset, clockwise: false)
        path.addArc(center: point(trail - outerInset, outerRadius - radius), radius: radius,
                    startAngle: trail - outerInset, endAngle: trail + .degrees(90), clockwise: false)
        path.addArc(center: point(trail - innerInset, innerRadius + radius), radius: radius,
                    startAngle: trail + .degrees(90), endAngle: trail - innerInset + .degrees(180), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: trail - innerInset, endAngle: lead + innerInset, clockwise: true)
        path.addArc(center: point(lead + innerInset, innerRadius + radius), radius: radius,
                    startAngle: lead + innerInset + .degrees(180), endAngle: lead + .degrees(270), clockwise: false)
        path.addArc(center: point(lead + outerInset, outerRadius - radius), radius: radius,
                    startAngle: lead + .degrees(270), endAngle: lead + outerInset + .degrees(360), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct ExplorerGlassLensView: View {
    let angle: Double
    let innerRadius: Double
    let outerRadius: Double
    let halfAngle: Double
    var body: some View {
        let lens = ExplorerGlassLens(angle: angle, innerRadius: innerRadius, outerRadius: outerRadius, halfAngle: halfAngle)
        let blue = RotaTokens.glassBlue
        ZStack {
            // Soft light-blue hue behind the selected tile.
            lens.fill(RadialGradient(colors: [blue.opacity(0.55), blue.opacity(0.18)], center: .center,
                startRadius: innerRadius, endRadius: outerRadius)).blur(radius: 9)
            // The glass itself: a faint body with one soft specular edge.
            lens.fill(LinearGradient(colors: [.white.opacity(0.16), blue.opacity(0.10), .white.opacity(0.04)],
                startPoint: .top, endPoint: .bottom))
            lens.stroke(LinearGradient(colors: [.white.opacity(0.55), blue.opacity(0.35), .white.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
