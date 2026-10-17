import AppKit
import SwiftUI

/// Measurements of the display's camera housing, plus the size Pour expands
/// to. Everything the notch HUD lays out is derived from these.
struct NotchGeometry: Equatable {
    /// Width of the physical camera housing.
    var notchWidth: CGFloat
    /// Height of the housing — also the menu bar height on notched Macs.
    var notchHeight: CGFloat
    var hasHardwareNotch: Bool
    /// How wide the shape opens to. Smaller for the in-app preview, which has
    /// a narrower column to live in than the whole display.
    var expandedWidth: CGFloat

    /// Displays without a notch (externals, older Macs) get a synthetic one so
    /// the expand/collapse choreography is identical everywhere.
    static let synthetic = NotchGeometry(notchWidth: 190,
                                         notchHeight: 32,
                                         hasHardwareNotch: false)

    init(notchWidth: CGFloat,
         notchHeight: CGFloat,
         hasHardwareNotch: Bool,
         expandedWidth: CGFloat = 520) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.hasHardwareNotch = hasHardwareNotch
        self.expandedWidth = expandedWidth
    }

    init(screen: NSScreen) {
        // The auxiliary areas are the strips of menu bar either side of the
        // housing; what they don't cover is the notch.
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            let height = max(left.height, right.height)
            if width > 1, height > 1 {
                self.init(notchWidth: width, notchHeight: height, hasHardwareNotch: true)
                return
            }
        }
        self = .synthetic
    }

    // MARK: - Expanded metrics

    /// The camera row, plus a band beneath it for the transcript.
    var expandedHeight: CGFloat { notchHeight + 54 }

    var collapsedWidth: CGFloat { notchWidth }
    var collapsedHeight: CGFloat { notchHeight }

    /// How far the concave shoulders flare out past the body at the top.
    var shoulder: CGFloat { 13 }

    /// Room around the shape for the drop shadow, so it never clips.
    var panelSize: CGSize {
        CGSize(width: expandedWidth + shoulder * 2 + 90,
               height: expandedHeight + 70)
    }
}

/// The Dynamic Island silhouette: flush against the top of the screen, square
/// where it meets the bezel, rounded at the bottom, and flared outward at the
/// top corners so it melts into the menu bar instead of ending on a hard edge.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The concave shoulders live inside `rect`, so the body is inset by
        // the shoulder radius on both sides.
        let shoulder = min(13, rect.height * 0.4)
        let bottom = min(20, rect.height * 0.45)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let top = rect.minY
        let base = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        // Outward flare into the left edge.
        path.addQuadCurve(to: CGPoint(x: left, y: top + shoulder),
                          control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: base - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: base),
                          control: CGPoint(x: left, y: base))
        path.addLine(to: CGPoint(x: right - bottom, y: base))
        path.addQuadCurve(to: CGPoint(x: right, y: base - bottom),
                          control: CGPoint(x: right, y: base))
        path.addLine(to: CGPoint(x: right, y: top + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top),
                          control: CGPoint(x: right, y: top))
        path.closeSubpath()
        return path
    }
}
