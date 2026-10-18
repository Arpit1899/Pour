import SwiftUI

/// The three places the bar can live.
enum BarDock: String, CaseIterable, Codable {
    case bottom, left, right

    /// On the sides the bar stands up.
    var isVertical: Bool { self != .bottom }
}

/// The spots shown while the bar is dragged, in the overlay's own top-left
/// coordinates, and the one it would snap to if let go now.
@Observable
final class DockTargetsModel {
    var zones: [BarDock: CGRect] = [:]
    var target: BarDock?
}

/// Dims the screen and marks where the bar can go. The spot under the
/// pointer lights up in amber.
struct DockTargetsView: View {
    var model: DockTargetsModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.32)
            ForEach(BarDock.allCases, id: \.self) { dock in
                if let rect = model.zones[dock] {
                    zone(rect, isTarget: model.target == dock)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.15), value: model.target)
    }

    private func zone(_ rect: CGRect, isTarget: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(rect.width, rect.height) / 2, style: .continuous)
        return shape
            .fill(isTarget ? PourTheme.accent.opacity(0.28) : Color.white.opacity(0.14))
            .overlay {
                shape.strokeBorder(isTarget ? PourTheme.accent.opacity(0.85) : Color.white.opacity(0.3),
                                   lineWidth: 1)
            }
            .shadow(color: isTarget ? PourTheme.accent.opacity(0.45) : .clear, radius: 14)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}
