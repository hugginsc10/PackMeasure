import SwiftUI

/// Shared visual language. Presentation only; measurement and capture policies live elsewhere.
enum MeasureStyle {
    static let background = Color(red: 0.035, green: 0.047, blue: 0.067)
    static let panel = Color(red: 0.075, green: 0.094, blue: 0.12)
    static let accent = Color(red: 0.27, green: 0.9, blue: 0.96)
    static let violet = Color(red: 0.63, green: 0.64, blue: 1)
    static let line = Color.white.opacity(0.10)
}

struct MeasurePanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MeasureStyle.panel, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(MeasureStyle.line, lineWidth: 1))
    }
}

extension View {
    func measurePanel() -> some View { modifier(MeasurePanel()) }
    func measureScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(MeasureStyle.background)
            .toolbarBackground(MeasureStyle.background, for: .navigationBar)
    }
}

struct MeasurePrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(MeasureStyle.background)
            .background(MeasureStyle.accent.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MeasureEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(.caption, design: .monospaced).weight(.semibold))
            .tracking(2).foregroundStyle(MeasureStyle.accent)
    }
}

struct MeasureMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BlueprintArtwork: View {
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: 24) {
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat(0), through: size.height, by: 24) {
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(MeasureStyle.accent.opacity(0.07)), lineWidth: 0.5)
            let points: [CGPoint] = [CGPoint(x: 0.17, y: 0.23), CGPoint(x: 0.77, y: 0.23),
                                    CGPoint(x: 0.77, y: 0.50), CGPoint(x: 0.62, y: 0.50),
                                    CGPoint(x: 0.62, y: 0.8), CGPoint(x: 0.17, y: 0.8)]
                .map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            var outline = Path(); outline.addLines(points); outline.closeSubpath()
            context.fill(outline, with: .color(MeasureStyle.accent.opacity(0.05)))
            context.stroke(outline, with: .color(MeasureStyle.accent.opacity(0.8)), lineWidth: 1.5)
            for p in points {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(MeasureStyle.accent))
            }
        }.accessibilityHidden(true)
    }
}

struct MeasureActionLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(MeasureStyle.accent)
                .frame(width: 52, height: 52)
                .background(MeasureStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.subheadline).foregroundStyle(MeasureStyle.accent)
        }.measurePanel()
    }
}
