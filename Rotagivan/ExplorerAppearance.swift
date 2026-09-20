import SwiftUI

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
        case .vector: return Color(red: 0.38, green: 0.94, blue: 0.91)
        case .ember: return Color(red: 1, green: 0.69, blue: 0.35)
        }
    }
    var surface: Color {
        self == .ember ? Color(red: 0.10, green: 0.075, blue: 0.065) : Color(red: 0.035, green: 0.075, blue: 0.105)
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
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(theme.surface)
                Canvas { context, size in
                    var grid = Path()
                    for x in stride(from: 18.0, to: size.width, by: 24) {
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: 18.0, to: size.height, by: 24) {
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(theme.accent.opacity(0.04)), lineWidth: 0.5)
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    for radius in [76.0, 167.0] {
                        let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                        context.stroke(ring, with: .color(theme.accent.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 22))
                RoundedRectangle(cornerRadius: 22).strokeBorder(theme.accent.opacity(0.27), lineWidth: 1)
                ExplorerCornerMarks().stroke(theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .square)).padding(9)
            }.accessibilityHidden(true).allowsHitTesting(false)
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
                            HStack(spacing: 5) {
                                ForEach(0..<3) { index in
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(option.accent.opacity(index == 1 ? 0.75 : 0.16))
                                        .frame(width: 22, height: index == 1 ? 30 : 24)
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
