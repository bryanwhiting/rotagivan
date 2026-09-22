import SwiftUI

/// Preview drag targets use exactly the same sector paths as the live renderer.
enum ExplorerPreviewGeometry {
    static func dropTarget(at point: CGPoint, from source: ExplorerSlot, theme: ExplorerTheme, count: Int, depth: Int) -> ExplorerSlot? {
        if theme.isRadial || count != 8 {
            return ExplorerSlot.slots(count).first {
                ExplorerStarburstSector(direction: $0, innerRadius: ExplorerStarburstLayout.innerRadius(depth: depth),
                    outerRadius: 143, tip: theme.isFloating ? 2 : 11, halfAngle: 180 / Double(count) - 2)
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
        case .starburstAir: return Color(red: 0.76, green: 0.96, blue: 0.87)
        }
    }
    var surface: Color {
        if self == .starburst { return Color(red: 0.055, green: 0.043, blue: 0.105) }
        return Color(red: 0.025, green: 0.045, blue: 0.045)
    }
}

/// Static geometry, not a continuously redrawn/animated canvas. The hardware
/// report loop only publishes sector changes; no animation owns an input timer.
struct ExplorerHUDBackdrop: View {
    let theme: ExplorerTheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if theme == .native {
            RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.2)))
                .overlay { if reduceTransparency { RoundedRectangle(cornerRadius: 26).fill(Color(nsColor: .windowBackgroundColor)) } }
        } else if theme == .starburst {
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [theme.surface, Color(red: 0.09, green: 0.065, blue: 0.17)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(theme.accent.opacity(0.28)))
                .accessibilityHidden(true).allowsHitTesting(false)
        } else {
            // Air leaves the desktop visible between every HUD element.
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
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
                                    ForEach(ExplorerSlot.allCases, id: \.self) { direction in
                                        ExplorerStarburstSector(direction: direction, innerRadius: 9, outerRadius: 24, tip: 3)
                                            .fill(option.isFloating ? option.surface.opacity(0.75) : option.accent.opacity(direction == .topRight ? 0.9 : 0.3))
                                            .overlay {
                                                if option.isFloating {
                                                    ExplorerStarburstSector(direction: direction, innerRadius: 9, outerRadius: 24, tip: 3)
                                                        .stroke(direction == .topRight ? option.accent : option.accent.opacity(0.3), lineWidth: 0.75)
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
}

struct ExplorerStarburstSector: Shape {
    let direction: ExplorerSlot
    let innerRadius: Double
    let outerRadius: Double
    var tip: Double = 0
    var halfAngle: Double = 20.5
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let middle = ExplorerStarburstLayout.angle(direction)
        let start = Angle.degrees(middle - halfAngle), end = Angle.degrees(middle + halfAngle)
        func point(_ angle: Angle, _ radius: Double) -> CGPoint {
            CGPoint(x: center.x + cos(angle.radians) * radius, y: center.y + sin(angle.radians) * radius)
        }
        var path = Path()
        path.move(to: point(start, innerRadius))
        path.addLine(to: point(start, outerRadius))
        path.addLine(to: point(.degrees(middle), outerRadius + tip))
        path.addLine(to: point(end, outerRadius))
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
