import AppKit
import SwiftUI

enum LeChatonTheme {
    static let canvas = adaptive(
        light: NSColor(red: 0.973, green: 0.957, blue: 0.918, alpha: 1),
        dark: NSColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)
    )
    static let elevated = adaptive(
        light: NSColor(red: 1.000, green: 0.992, blue: 0.969, alpha: 1),
        dark: NSColor(red: 0.094, green: 0.114, blue: 0.161, alpha: 1)
    )
    static let primaryText = adaptive(
        light: NSColor(red: 0.118, green: 0.102, blue: 0.086, alpha: 1),
        dark: NSColor(red: 0.965, green: 0.922, blue: 0.843, alpha: 1)
    )
    static let secondaryText = adaptive(
        light: NSColor(red: 0.382, green: 0.345, blue: 0.306, alpha: 1),
        dark: NSColor(red: 0.714, green: 0.690, blue: 0.651, alpha: 1)
    )
    static let hairline = adaptive(
        light: NSColor(red: 0.745, green: 0.690, blue: 0.620, alpha: 0.32),
        dark: NSColor(red: 0.169, green: 0.200, blue: 0.263, alpha: 1)
    )

    // Brand-derived accents, reserved for semantic emphasis rather than chrome.
    static let yellow = Color(red: 1.000, green: 0.847, blue: 0.000)
    static let amber = Color(red: 1.000, green: 0.510, blue: 0.020)
    static let orange = Color(red: 0.980, green: 0.314, blue: 0.059)
    static let coral = Color(red: 0.882, green: 0.020, blue: 0.000)
    static let onAccent = Color(red: 0.075, green: 0.059, blue: 0.047)
    static let success = Color(red: 0.28, green: 0.68, blue: 0.46)
    static let danger = Color(red: 0.94, green: 0.24, blue: 0.18)

    static let userBubble = adaptive(
        light: NSColor(red: 1.000, green: 0.882, blue: 0.804, alpha: 1),
        dark: NSColor(red: 0.286, green: 0.122, blue: 0.082, alpha: 1)
    )
    static let agentBubble = adaptive(
        light: NSColor(red: 1.000, green: 0.988, blue: 0.957, alpha: 1),
        dark: NSColor(red: 0.137, green: 0.118, blue: 0.102, alpha: 1)
    )
    static let utilitySurface = adaptive(
        light: NSColor(red: 0.933, green: 0.910, blue: 0.859, alpha: 1),
        dark: NSColor(red: 0.071, green: 0.086, blue: 0.118, alpha: 1)
    )
    static let reasoningSurface = adaptive(
        light: NSColor(red: 0.925, green: 0.914, blue: 0.965, alpha: 1),
        dark: NSColor(red: 0.110, green: 0.114, blue: 0.173, alpha: 1)
    )
    static let reasoningAccent = Color(red: 0.690, green: 0.635, blue: 0.965)

    static let accentGradient = LinearGradient(
        colors: [yellow, amber, orange, coral],
        startPoint: .leading,
        endPoint: .trailing
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct LeChatonBrandLockup: View {
    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 2) {
                ForEach(Array([LeChatonTheme.yellow, LeChatonTheme.amber, LeChatonTheme.orange, LeChatonTheme.coral].enumerated()), id: \.offset) { index, color in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(width: 5, height: CGFloat(6 + index * 3))
                }
            }
            .frame(height: 15, alignment: .bottom)
            .accessibilityHidden(true)

            Text("LECHATON")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(1.7)
                .foregroundStyle(LeChatonTheme.primaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("LeChaton")
    }
}

/// A deliberately abstract pixel field. It borrows the brand's grid language
/// without reproducing or recoloring any Mistral logo or emblem.
struct LeChatonPixelField: View {
    let opacity: Double

    init(opacity: Double = 0.22) {
        self.opacity = opacity
    }

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0 ..< 6, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< 10, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(pixelColor(row: row, column: column))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .opacity(opacity)
        .mask {
            LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
    }

    private func pixelColor(row: Int, column: Int) -> Color {
        guard (row * 7 + column * 3) % 11 < 3 else { return .clear }
        switch (row + column) % 4 {
        case 0: return LeChatonTheme.yellow
        case 1: return LeChatonTheme.amber
        case 2: return LeChatonTheme.orange
        default: return LeChatonTheme.coral
        }
    }
}

private struct LeChatonGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

extension View {
    func leChatonGlassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(LeChatonGlassCardModifier(cornerRadius: cornerRadius))
    }

    func leChatonDetailCanvas() -> some View {
        background(LeChatonTheme.canvas)
            .foregroundStyle(LeChatonTheme.primaryText)
    }
}
