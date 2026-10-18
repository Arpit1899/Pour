import SwiftUI

enum PourState {
    case listening, transcribing, polishing, inserting, error
}

/// How a finished session actually ended. `copied` is its own case because a
/// missing Accessibility grant leaves the text on the clipboard and nowhere
/// else — reporting that as "Pasted" would be a lie.
enum PourOutcome {
    case pasted, copied, nothingHeard
}

/// Where the bar sits. Shared by the view, which draws inside the panel, and
/// `AppDelegate`, which places the panel and decides when it takes clicks.
enum BarLayout {
    /// Room around the bar for the glow, the widest message and the card,
    /// whichever edge the bar is docked to.
    static let panelSize = CGSize(width: 460, height: 260)
    /// From the panel's docked edge to the bar, so the glow isn't clipped.
    static let inset: CGFloat = 22
    /// From the Dock, or the screen edge, to the bar.
    static let lift: CGFloat = 10
    /// The bar's thickness while it listens.
    static let thickness: CGFloat = 34

    static let cardWidth: CGFloat = 360

    /// The area that reacts to the pointer, in the panel's own coordinates
    /// (origin bottom left): what is drawn right now, plus the resting bar so
    /// the hint can't flicker on and off at its edge, plus a margin.
    static func hitRect(dock: BarDock, drawn: CGSize) -> CGRect {
        let rest = dock.isVertical ? CGSize(width: 8, height: 40) : CGSize(width: 40, height: 8)
        let margin: CGFloat = 8
        return place(drawn, dock: dock).union(place(rest, dock: dock))
            .insetBy(dx: -margin, dy: -margin)
    }

    private static func place(_ size: CGSize, dock: BarDock) -> CGRect {
        let origin: CGPoint = switch dock {
        case .bottom: CGPoint(x: (panelSize.width - size.width) / 2, y: inset)
        case .left:   CGPoint(x: inset, y: (panelSize.height - size.height) / 2)
        case .right:  CGPoint(x: panelSize.width - inset - size.width,
                              y: (panelSize.height - size.height) / 2)
        }
        return CGRect(origin: origin, size: size)
    }
}

/// The pointer, as AppKit sees it, because the panel ignores the mouse
/// everywhere except over the bar; and the bar's drawn size, as SwiftUI
/// measures it, so only the bar takes clicks.
@Observable
final class BarPointer {
    var isHovering = false
    var isDragging = false
    var barSize = CGSize(width: 40, height: 8)
}

// MARK: - The bar

/// Pour's dictation bar, docked at the bottom of the screen or standing up on
/// either side. At rest it is a sliver; while you speak it opens into a warm
/// aurora and nothing else, because the words can't be changed mid-sentence
/// anyway — they arrive when you let go.
struct PourBar: View {
    /// A session is on screen. False while summoning and dismissing, so the
    /// bar grows out of, and settles back into, its resting shape.
    var isActive: Bool
    /// Keep the resting bar on screen between sessions.
    var showsIdle: Bool
    var isHovering: Bool
    /// What hovering the resting bar says, e.g. "Hold ⌃Space to dictate".
    var hint: String
    var state: PourState
    var audioLevel: Double
    var outcome: PourOutcome
    var errorMessage: String?
    /// Fraction complete while a speech model installs, `nil` otherwise. The
    /// first run in a new language downloads hundreds of megabytes.
    var modelDownload: Double?
    /// A transcript with nowhere to paste it, shown with a Copy button.
    var heldText: String?
    var dock: BarDock = .bottom
    var onCopy: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onSize: (CGSize) -> Void = { _ in }

    private enum Mode: Equatable {
        case hidden, rest, hint, wave, thinking
        case message(symbol: String?, text: String)
        case card(String)

        var isLive: Bool { self == .wave || self == .thinking }
    }

    private var mode: Mode {
        guard isActive else {
            if !showsIdle { return .hidden }
            return isHovering ? .hint : .rest
        }
        if let heldText { return .card(heldText) }
        if let progress = modelDownload {
            return .message(symbol: nil, text: "Preparing speech model… \(Int(progress * 100))%")
        }
        switch state {
        case .listening, .transcribing:
            return .wave
        case .polishing:
            return .thinking
        case .inserting:
            switch outcome {
            case .pasted:       return .message(symbol: "checkmark", text: "Pasted")
            case .copied:       return .message(symbol: "doc.on.clipboard", text: "Copied, press ⌘V to paste")
            case .nothingHeard: return .message(symbol: "mic.slash", text: "Nothing heard")
            }
        case .error:
            return .message(symbol: "exclamationmark.triangle.fill",
                            text: errorMessage ?? "Microphone unavailable")
        }
    }

    /// The resting sliver and the listening bar run along the docked edge;
    /// words always read across.
    private var size: (width: CGFloat?, height: CGFloat?) {
        let along: (CGFloat, CGFloat)? = switch mode {
        case .hidden, .rest:   (40, 8)
        case .wave, .thinking: (150, BarLayout.thickness)
        default:               nil
        }
        if let along {
            return dock.isVertical ? (along.1, along.0) : (along.0, along.1)
        }
        switch mode {
        case .hint: return (nil, 28)
        case .card: return (nil, nil)
        default:    return (nil, BarLayout.thickness)
        }
    }

    /// A capsule for every shape but the card, so the bar can round off into
    /// the card and back.
    private var shape: RoundedRectangle {
        if case .card = mode { return RoundedRectangle(cornerRadius: 20, style: .continuous) }
        let short = min(size.width ?? .infinity, size.height ?? BarLayout.thickness)
        return RoundedRectangle(cornerRadius: short / 2, style: .continuous)
    }

    /// Louder speech reads as a bigger change than the raw level suggests.
    private var level: Double { min(1, audioLevel).squareRoot() }

    private var anchor: UnitPoint {
        switch dock {
        case .bottom: .bottom
        case .left:   .leading
        case .right:  .trailing
        }
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .background { background }
            .clipShape(shape)
            .overlay { if mode.isLive { AuroraRim(level: mode == .wave ? level : 0.2, shape: shape) } }
            .contentShape(shape)
            .opacity(mode == .hidden ? 0 : 1)
            .scaleEffect(mode == .hidden ? 0.6 : 1, anchor: anchor)
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: mode)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: dock)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hidden, .rest:
            Color.clear
        case .hint:
            Text(hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
                .padding(.horizontal, 14)
                .transition(.opacity)
        case .wave, .thinking:
            PourAurora(level: level, thinking: mode == .thinking)
                .transition(.opacity)
        case .message(let symbol, let text):
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(text).font(.system(size: 13))
            }
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize()
            .padding(.horizontal, 16)
            .transition(.opacity)
        case .card(let text):
            HeldCard(text: text, onCopy: onCopy, onDismiss: onDismiss)
                .transition(.opacity)
        }
    }

    private var background: some View {
        let resting = mode == .rest || mode == .hidden
        return ZStack {
            shape.fill(.black.opacity(resting ? 0.4 : 0.9))
            shape.strokeBorder(.white.opacity(resting ? 0.3 : 0.1), lineWidth: 0.5)
        }
    }
}

/// The transcript, when there was no text field to paste it into: copy it,
/// or let it go. It goes by itself when the ring runs out.
private struct HeldCard: View {
    var text: String
    var onCopy: () -> Void
    var onDismiss: () -> Void

    @State private var shownAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("No text field selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button(action: onDismiss) {
                    CountdownRing(start: shownAt,
                                  seconds: Double(PourSessionModel.holdDuration.components.seconds))
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Copy", action: onCopy)
                    .buttonStyle(AmberPill())
            }
        }
        .padding(16)
        .frame(width: BarLayout.cardWidth)
    }
}

private struct CountdownRing: View {
    var start: Date
    var seconds: Double

    var body: some View {
        TimelineView(.animation) { context in
            let left = max(0, 1 - context.date.timeIntervalSince(start) / seconds)
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: left)
                    .stroke(PourTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(.circle)
    }
}

/// The light running round the rim while the bar listens: the glow colors
/// turning slowly, a soft halo outside and a fine line on the edge, both
/// brighter when you speak louder.
private struct AuroraRim: View {
    var level: Double
    var shape: RoundedRectangle

    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate * 52
            let ring = AngularGradient(colors: PourTheme.glow, center: .center,
                                       angle: .degrees(angle.truncatingRemainder(dividingBy: 360)))
            ZStack {
                shape.stroke(ring, lineWidth: 4)
                    .blur(radius: 5)
                    .opacity(0.3 + 0.5 * level)
                shape.strokeBorder(ring, lineWidth: 1.2)
                    .opacity(0.55 + 0.4 * level)
            }
            .blendMode(.plusLighter)
        }
        .animation(.easeOut(duration: 0.18), value: level)
        .allowsHitTesting(false)
    }
}

// MARK: - The aurora

/// Carried between frames: the eased level and the aurora's own clock. A
/// class so the canvas can update it while drawing without causing a view
/// update.
private final class AuroraMotion {
    var level: Double = 0
    var clock: Double = 0
    var lastTime: TimeInterval?
}

/// Soft fields of warm color drifting along the bar, brighter and taller as
/// you speak. `thinking` keeps them dim and quick while the transcript is
/// being tidied. Runs along the long side, so it works standing up too.
struct PourAurora: View {
    var level: Double
    var thinking: Bool

    @State private var motion = AuroraMotion()

    private struct Field {
        var color: Color
        var speed: Double
        var phase: Double
    }

    private static let fields: [Field] = [
        Field(color: PourTheme.ember,  speed: 0.33, phase: 0),
        Field(color: PourTheme.rose,   speed: 0.27, phase: 2.1),
        Field(color: PourTheme.honey,  speed: 0.41, phase: 4.2),
        Field(color: PourTheme.accent, speed: 0.22, phase: 1),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let dt = motion.lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
                motion.lastTime = now
                // Silence still glows faintly; a dark bar reads as "not listening".
                let target = thinking ? 0.2 : max(0.12, level)
                motion.level += (target - motion.level) * (1 - exp(-dt * 10))
                motion.clock += dt * (thinking ? 3 : 1)
                draw(in: &ctx, size: size, level: motion.level, clock: motion.clock)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, level: Double, clock: Double) {
        var length = size.width, depth = size.height
        if size.height > size.width {
            // Standing up: draw the same thing turned a quarter.
            ctx.translateBy(x: size.width, y: 0)
            ctx.rotate(by: .degrees(90))
            swap(&length, &depth)
        }
        ctx.blendMode = .plusLighter
        ctx.addFilter(.blur(radius: 6.5))
        for field in Self.fields {
            let cx = length * (0.5 + 0.48 * sin(clock * field.speed + field.phase))
            let cy = depth * (0.5 + 0.25 * sin(clock * field.speed * 1.7 + field.phase))
            let rx = length * 0.32
            let ry = depth * (0.55 + 0.35 * level)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)),
                     with: .color(field.color.opacity(0.25 + 0.6 * level)))
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        PourBar(isActive: false, showsIdle: true, isHovering: true, hint: "Hold ⌃Space to dictate",
                state: .listening, audioLevel: 0, outcome: .pasted, errorMessage: nil, modelDownload: nil)
        PourBar(isActive: true, showsIdle: true, isHovering: false, hint: "",
                state: .transcribing, audioLevel: 0.4, outcome: .pasted, errorMessage: nil, modelDownload: nil)
        PourBar(isActive: true, showsIdle: true, isHovering: false, hint: "",
                state: .transcribing, audioLevel: 0.4, outcome: .pasted, errorMessage: nil, modelDownload: nil,
                dock: .left)
    }
    .padding(60)
    .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom))
}
