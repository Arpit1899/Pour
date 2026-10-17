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
    /// Room around the bar for the glow, the widest message and the card.
    static let panelSize = CGSize(width: 440, height: 240)
    /// From the panel's bottom edge to the bar's, so the glow isn't clipped.
    static let inset: CGFloat = 22
    /// From the top of the Dock (or the bottom of the screen) to the bar.
    static let lift: CGFloat = 10

    static let cardWidth: CGFloat = 360

    /// The area that reacts to the pointer, in the panel's own coordinates
    /// (origin bottom left): what is drawn, grown from the bar's bottom edge
    /// the way the bar grows, plus a margin so the resting bar is easy to hit.
    static func hitRect(isActive: Bool, isHovering: Bool, cardHeight: CGFloat?) -> CGRect {
        let drawn: CGSize = if let cardHeight { CGSize(width: cardWidth, height: cardHeight) }
            else if isActive { CGSize(width: 260, height: 34) }
            else if isHovering { CGSize(width: 250, height: 28) }
            else { CGSize(width: 40, height: 8) }
        let margin: CGFloat = 8
        return CGRect(x: (panelSize.width - drawn.width) / 2 - margin,
                      y: inset - margin,
                      width: drawn.width + margin * 2,
                      height: drawn.height + margin * 2)
    }
}

/// Whether the pointer is over the resting bar. AppKit tracks the pointer,
/// because the panel ignores the mouse everywhere except over the bar, and
/// SwiftUI reads it here.
@Observable
final class BarPointer {
    var isHovering = false
    /// The card's measured height while it is up, so only the card itself
    /// takes clicks.
    var cardHeight: CGFloat?
}

// MARK: - The bar

/// Pour's dictation bar, just above the Dock. At rest it is a sliver; while
/// you speak it opens into a warm glowing wave and nothing else, because the
/// words can't be changed mid-sentence anyway — they arrive when you let go.
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
    var onCopy: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onCardHeight: (CGFloat?) -> Void = { _ in }

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

    private var width: CGFloat? {
        switch mode {
        case .hidden, .rest:          40
        case .wave, .thinking:        150
        case .hint, .message, .card:  nil
        }
    }

    private var height: CGFloat? {
        switch mode {
        case .hidden, .rest: 8
        case .hint:          28
        case .card:          nil
        default:             34
        }
    }

    /// A capsule for every shape but the card, so the bar can round off into
    /// the card and back.
    private var shape: RoundedRectangle {
        if case .card = mode { return RoundedRectangle(cornerRadius: 20, style: .continuous) }
        return RoundedRectangle(cornerRadius: (height ?? 34) / 2, style: .continuous)
    }

    /// Louder speech reads as a bigger change than the raw level suggests.
    private var level: Double { min(1, audioLevel).squareRoot() }

    var body: some View {
        content
            .frame(width: width, height: height)
            .background { background }
            .clipShape(shape)
            .background { if mode.isLive { BarGlow(level: mode == .wave ? level : 0.2) } }
            .contentShape(shape)
            .opacity(mode == .hidden ? 0 : 1)
            .scaleEffect(mode == .hidden ? 0.6 : 1, anchor: .bottom)
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: mode)
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
            PourWave(level: level, thinking: mode == .thinking)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onCardHeight($0) }
                .onDisappear { onCardHeight(nil) }
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

/// The light around the bar while it listens: the glow colors slowly turning,
/// brighter when you speak louder.
private struct BarGlow: View {
    var level: Double

    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate * 50
            let ring = AngularGradient(colors: PourTheme.glow, center: .center,
                                       angle: .degrees(angle.truncatingRemainder(dividingBy: 360)))
            ZStack {
                Capsule()
                    .fill(ring)
                    .blur(radius: 12)
                    .opacity(0.35 + 0.45 * level)
                    .scaleEffect(x: 1.02 + 0.06 * level, y: 1.15 + 0.35 * level)
                Capsule()
                    .strokeBorder(ring, lineWidth: 1)
                    .opacity(0.55 + 0.4 * level)
            }
        }
        .animation(.easeOut(duration: 0.18), value: level)
        .allowsHitTesting(false)
    }
}

// MARK: - The wave

/// Carried between frames: the eased level and the wave's own clock. A class
/// so the canvas can update it while drawing without causing a view update.
private final class WaveMotion {
    var level: Double = 0
    var clock: Double = 0
    var lastTime: TimeInterval?
}

/// Overlapping warm lobes that swell with your voice — the Siri idea, drawn
/// in Pour's colors. `thinking` keeps them low and quick while the transcript
/// is being tidied.
struct PourWave: View {
    var level: Double
    var thinking: Bool

    @State private var motion = WaveMotion()

    private struct Layer {
        var color: Color
        var frequency: Double
        var speed: Double
        var phase: Double
        var weight: Double
    }

    private static let layers: [Layer] = [
        Layer(color: PourTheme.ember,  frequency: 1.5, speed: 2.2,  phase: 0.0, weight: 1.0),
        Layer(color: PourTheme.rose,   frequency: 2.2, speed: -1.8, phase: 1.3, weight: 0.8),
        Layer(color: PourTheme.accent, frequency: 1.1, speed: 1.4,  phase: 2.4, weight: 0.95),
        Layer(color: PourTheme.honey,  frequency: 2.8, speed: 2.7,  phase: 3.7, weight: 0.6),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let dt = motion.lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
                motion.lastTime = now
                // Silence still breathes; a flat line reads as "not listening".
                let target = thinking ? 0.16 : max(0.14, level)
                motion.level += (target - motion.level) * (1 - exp(-dt * 10))
                motion.clock += dt * (thinking ? 2.4 : 1)
                draw(in: &ctx, size: size, level: motion.level, clock: motion.clock)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, level: Double, clock: Double) {
        let mid = size.height / 2
        let lobes = Self.layers.map { lobe(for: $0, size: size, level: level, clock: clock) }

        ctx.blendMode = .plusLighter
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 5))
            glow.opacity = 0.8
            for (layer, path) in zip(Self.layers, lobes) {
                glow.fill(path, with: .color(layer.color.opacity(0.7)))
            }
        }
        for (layer, path) in zip(Self.layers, lobes) {
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [layer.color.opacity(0), layer.color.opacity(0.85), layer.color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: mid),
                endPoint: CGPoint(x: size.width, y: mid)))
        }

        var core = Path()
        core.move(to: CGPoint(x: size.width * 0.08, y: mid))
        core.addLine(to: CGPoint(x: size.width * 0.92, y: mid))
        ctx.stroke(core, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)]),
            startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: size.width, y: mid)),
                   lineWidth: 0.75)
    }

    /// The region between a sine wave and its mirror image, tapered to nothing
    /// at both ends.
    private func lobe(for layer: Layer, size: CGSize, level: Double, clock: Double) -> Path {
        let steps = 48
        let mid = size.height / 2
        let swell = 0.7 + 0.3 * sin(clock * abs(layer.speed) * 0.6 + layer.phase)
        let amplitude = (size.height / 2 - 1) * level * layer.weight * swell

        func offset(_ i: Int) -> CGPoint {
            let u = Double(i) / Double(steps)
            let taper = pow(sin(.pi * u), 2)
            let y = amplitude * taper * sin(u * .pi * 2 * layer.frequency + clock * layer.speed + layer.phase)
            return CGPoint(x: u * size.width, y: y)
        }

        var path = Path()
        for i in 0...steps {
            let p = offset(i)
            let point = CGPoint(x: p.x, y: mid - p.y)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let p = offset(i)
            path.addLine(to: CGPoint(x: p.x, y: mid + p.y))
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    VStack(spacing: 40) {
        PourBar(isActive: false, showsIdle: true, isHovering: false, hint: "Hold ⌃Space to dictate",
                state: .listening, audioLevel: 0, outcome: .pasted, errorMessage: nil, modelDownload: nil)
        PourBar(isActive: false, showsIdle: true, isHovering: true, hint: "Hold ⌃Space to dictate",
                state: .listening, audioLevel: 0, outcome: .pasted, errorMessage: nil, modelDownload: nil)
        PourBar(isActive: true, showsIdle: true, isHovering: false, hint: "",
                state: .transcribing, audioLevel: 0.4, outcome: .pasted, errorMessage: nil, modelDownload: nil)
        PourBar(isActive: true, showsIdle: true, isHovering: false, hint: "",
                state: .inserting, audioLevel: 0, outcome: .pasted, errorMessage: nil, modelDownload: nil)
    }
    .padding(60)
    .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom))
}
