import SwiftUI

enum Theme {
    static let purple = Color(red: 0.37, green: 0.27, blue: 0.96)
    static let purpleSoft = Color(red: 0.37, green: 0.27, blue: 0.96).opacity(0.12)
    static let lavender = Color(red: 0.94, green: 0.93, blue: 1.0)
    static let background = Color(red: 0.975, green: 0.975, blue: 0.985)
    static let card = Color.white
    static let border = Color.black.opacity(0.08)
    static let text = Color(red: 0.11, green: 0.11, blue: 0.16)
    static let secondary = Color(red: 0.45, green: 0.45, blue: 0.52)
    static let record = Color(red: 0.95, green: 0.16, blue: 0.18)
}

enum Layout {
    static let sidebarWidth: CGFloat = 250
    static let rulerHeight: CGFloat = 64
    static let rowHeight: CGFloat = 112          // one track: card on the left, lane on the right
    static let masterWidth: CGFloat = 132
}

extension View {
    /// White rounded card with a hairline border; purple border when selected.
    func card(selected: Bool = false, radius: CGFloat = 14) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Theme.card)
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: radius)
            .strokeBorder(selected ? Theme.purple : Theme.border, lineWidth: selected ? 1.5 : 1))
    }
}

/// Small square toggle chip (M, S, FX).
struct Chip: View {
    let label: String
    var on: Bool
    var onColor: Color = Theme.purple
    var size: CGFloat = 28
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size * 0.46, weight: .semibold))
                .frame(minWidth: size, minHeight: size)
                .padding(.horizontal, label.count > 1 ? 4 : 0)
                .foregroundStyle(on ? .white : Theme.text)
                .background(RoundedRectangle(cornerRadius: size * 0.28).fill(on ? onColor : Color.white))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(on ? .clear : Theme.border))
        }
        .buttonStyle(.plain)
    }
}

/// Round transport button.
struct RoundButton<Label: View>: View {
    var size: CGFloat = 46
    var fill: Color = .white
    let action: () -> Void
    @ViewBuilder let label: Label
    var body: some View {
        Button(action: action) {
            label
                .frame(width: size, height: size)
                .background(Circle().fill(fill).shadow(color: .black.opacity(fill == .white ? 0.12 : 0.25), radius: 5, y: 2))
                .overlay(Circle().strokeBorder(fill == .white ? Theme.border : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Volume slider positions are squared so most of the travel is the useful range;
/// the right end is +6 dB and unity sits at about 70 %.
enum Gain {
    static let max: Float = 2
    static func position(_ gain: Float) -> Double { Double(sqrt(Swift.max(0, gain) / max)) }
    static func gain(_ position: Double) -> Float { Float(position * position) * max }
    static func dbText(_ g: Float) -> String { g < 0.0001 ? "-∞ dB" : String(format: "%.1f dB", 20 * log10(g)) }
    static func binding(_ gain: Binding<Float>) -> Binding<Double> {
        Binding(get: { position(gain.wrappedValue) }, set: { gain.wrappedValue = Gain.gain($0) })
    }
}

/// Level meter on a -60…0 dB scale.
struct LevelMeter: View {
    var level: Float
    var vertical = true
    var body: some View {
        GeometryReader { geo in
            let db = 20 * log10(max(Double(level), 1e-6))
            let frac = max(0, min(1, (db + 60) / 60))
            let gradient = LinearGradient(colors: [Color(red: 0.2, green: 0.8, blue: 0.35), Color(red: 0.2, green: 0.8, blue: 0.35),
                                                   Color(red: 0.98, green: 0.85, blue: 0.1), Theme.record],
                                          startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing)
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(Color.black.opacity(0.07))
                Capsule().fill(gradient)
                    .mask(alignment: vertical ? .bottom : .leading) {
                        Rectangle().frame(width: vertical ? nil : geo.size.width * frac,
                                          height: vertical ? geo.size.height * frac : nil)
                    }
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowPills: SwiftUI.Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, point) in zip(subviews, arrange(width: bounds.width, subviews).points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + row))
    }
}
