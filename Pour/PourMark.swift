import SwiftUI

/// The glass silhouette: a body whose top edge dips into a meniscus curve,
/// with softly rounded bottom corners. Drawn as a real `Shape` so the dip is
/// genuine transparency — the previous version faked it by filling the curve
/// with a guessed background color, which broke over the blurred window.
struct PourGlassShape: Shape {
    /// Master geometry is authored in a 96×96 box, then scaled to `rect`.
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 96
        let dx = rect.minX + (rect.width - 96 * s) / 2
        let dy = rect.minY + (rect.height - 96 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: dx + x * s, y: dy + y * s)
        }

        let r: CGFloat = 7  // bottom corner radius, master units
        var path = Path()
        path.move(to: p(14, 22))
        // Meniscus: the liquid surface pulled down in the middle.
        path.addQuadCurve(to: p(82, 22), control: p(48, 34))
        path.addLine(to: p(82, 86 - r))
        path.addQuadCurve(to: p(82 - r, 86), control: p(82, 86))
        path.addLine(to: p(14 + r, 86))
        path.addQuadCurve(to: p(14, 86 - r), control: p(14, 86))
        path.closeSubpath()
        return path
    }
}

/// The Pour logomark — foam strip above a meniscus glass.
struct PourMark: View {
    var size: CGFloat = 96
    var color: Color = PourTheme.accent
    var foamColor: Color = PourTheme.foam

    /// Below ~22pt the 6-unit foam strip collapses into an illegible smudge,
    /// so small renderings drop it and show the glass alone.
    private var showsFoam: Bool { size >= 22 }

    var body: some View {
        ZStack(alignment: .top) {
            if showsFoam {
                // Flush with the rim and the full width of the glass: a gap
                // here reads as a detached handle rather than a head of foam.
                Capsule(style: .continuous)
                    .fill(foamColor)
                    .frame(width: size * 68 / 96, height: size * 6 / 96)
                    .offset(y: size * 15 / 96)
            }
            PourGlassShape().fill(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The wordmark: lowercase "pour" with an accented period.
struct PourWordmark: View {
    var size: CGFloat = 15
    var weight: Font.Weight = .regular
    var color: Color = .primary

    var body: some View {
        HStack(spacing: 0) {
            Text("pour").foregroundStyle(color)
            Text(".").foregroundStyle(PourTheme.accent)
        }
        .font(.system(size: size, weight: weight))
        .tracking(-0.2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pour")
    }
}
