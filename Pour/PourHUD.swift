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
    /// The pill's thickness while it shows a message.
    static let thickness: CGFloat = 34
    /// The band along the docked edge that every state centres on, as deep
    /// as the listening ribbons, so they open out of the resting line in place.
    static let depth: CGFloat = 56

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
        let centring = max(0, (depth - (dock.isVertical ? size.width : size.height)) / 2)
        let origin: CGPoint = switch dock {
        case .bottom: CGPoint(x: (panelSize.width - size.width) / 2, y: inset + centring)
        case .left:   CGPoint(x: inset + centring, y: (panelSize.height - size.height) / 2)
        case .right:  CGPoint(x: panelSize.width - inset - centring - size.width,
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
/// either side. At rest it is a short line; while you speak it opens into
/// warm ribbons of light and nothing else, because the words can't be changed
/// mid-sentence anyway — they arrive when you let go. Only words get a pill.
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
    var spectrum: VoiceSpectrum = .silent
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

        /// Words sit on a pill; the line and the ribbons float free.
        var hasPill: Bool {
            switch self {
            case .hidden, .rest, .wave, .thinking: false
            case .hint, .message, .card: true
            }
        }
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
        case .wave, .thinking: (PourRibbons.length, BarLayout.depth)
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
            .background { if mode.hasPill { background } }
            .contentShape(shape)
            .opacity(mode == .hidden ? 0 : 1)
            .scaleEffect(mode == .hidden ? 0.6 : 1, anchor: anchor)
            .frame(minWidth: dock.isVertical ? BarLayout.depth : nil,
                   minHeight: dock.isVertical ? nil : BarLayout.depth)
            // Behind the pill, at a fixed size on the centre line, so the
            // ribbons grow out of the resting line instead of being swapped in.
            .background {
                PourRibbons(isOpen: mode == .wave || mode == .thinking,
                            level: audioLevel, spectrum: spectrum, thinking: mode == .thinking)
                    .frame(width: dock.isVertical ? BarLayout.depth : PourRibbons.length,
                           height: dock.isVertical ? PourRibbons.length : BarLayout.depth)
                    .opacity(mode == .hidden ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: mode)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: dock)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hidden, .rest, .wave, .thinking:
            // Drawn by the ribbons behind; this only sizes what takes clicks.
            Color.clear
        case .hint:
            Text(hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
                .padding(.horizontal, 14)
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
        ZStack {
            shape.fill(.black.opacity(0.9))
            shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
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

// MARK: - The ribbons

/// Carried between frames: the eased bands and the ribbons' own clocks. A
/// class so the canvas can update it while drawing without causing a view
/// update.
private final class RibbonMotion {
    var level: Double = 0
    var bands = SIMD4<Double>(repeating: 0)
    var phase: Double = 0
    var clock: Double = 0
    var lastTime: TimeInterval?
}

/// The resting line and, while you speak, translucent ribbons of ember, rose,
/// amber and honey mirrored about it, each swelling with its own part of your
/// voice: low vowels swell ember, the middle drives rose and amber, and "s",
/// "t" and "sh" flash honey. One drawing, so opening stretches the line out
/// from where it rests and the ribbons rise out of it. `thinking` keeps them
/// low and quick while the transcript is being tidied. Runs along the long
/// side, so it works standing up too.
struct PourRibbons: View {
    /// Listening or tidying. Closed, it is the resting line and stays still.
    var isOpen: Bool
    var level: Double
    var spectrum: VoiceSpectrum
    var thinking: Bool

    /// The canvas length, with room past the ribbons for their soft shade.
    static let length: CGFloat = 250

    @State private var motion = RibbonMotion()

    var body: some View {
        // Paused at rest, so the resting line costs nothing between dictations.
        TimelineView(.animation(paused: !isOpen)) { context in
            RibbonCanvas(openness: isOpen ? 1 : 0,
                         now: context.date.timeIntervalSinceReferenceDate,
                         level: level, spectrum: spectrum, thinking: thinking, motion: motion)
        }
        .animation(isOpen ? .easeOut(duration: 0.45) : .easeInOut(duration: 0.35), value: isOpen)
        // One layer, so the additive colour stays inside the ribbons.
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

/// Redrawn on every frame while open, and on every step of opening and
/// closing through `openness`, which SwiftUI animates.
private struct RibbonCanvas: View, Animatable {
    var openness: Double
    var now: TimeInterval
    var level: Double
    var spectrum: VoiceSpectrum
    var thinking: Bool
    var motion: RibbonMotion

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    /// A warm near-black under the line and ribbons. It sinks into a dark
    /// wallpaper and gives the colour an edge on a white window, without
    /// showing as a shape.
    private static let shade = Color(red: 0.10, green: 0.06, blue: 0.03)
    private static let resting: Double = 40
    private static let drawn: Double = 210
    /// Peak distance from the centre line at full voice.
    private static let reach: Double = 22

    /// Each ribbon is a few soft lumps drifting along the line.
    private struct Lump { var start, drift, speed, phase, width, weight: Double }
    private struct Ribbon { var color: Color; var band: Int; var lumps: [Lump] }

    private static let ribbons: [Ribbon] = [
        Ribbon(color: PourTheme.ember, band: 0, lumps: [
            Lump(start: -0.45, drift: 0.45, speed: 0.31, phase: 0, width: 0.55, weight: 1),
            Lump(start: 0.6, drift: 0.35, speed: 0.23, phase: 2, width: 0.42, weight: 0.65)]),
        Ribbon(color: PourTheme.rose, band: 1, lumps: [
            Lump(start: 0.2, drift: 0.5, speed: 0.27, phase: 1.1, width: 0.5, weight: 1),
            Lump(start: -0.85, drift: 0.3, speed: 0.19, phase: 3.3, width: 0.4, weight: 0.6)]),
        Ribbon(color: PourTheme.accent, band: 2, lumps: [
            Lump(start: -0.15, drift: 0.55, speed: 0.36, phase: 4, width: 0.42, weight: 0.95),
            Lump(start: 0.85, drift: 0.3, speed: 0.29, phase: 5.2, width: 0.36, weight: 0.6)]),
        Ribbon(color: PourTheme.honey, band: 3, lumps: [
            Lump(start: 0.35, drift: 0.6, speed: 0.43, phase: 2.7, width: 0.32, weight: 0.85),
            Lump(start: -0.55, drift: 0.4, speed: 0.5, phase: 0.6, width: 0.3, weight: 0.55)]),
    ]

    var body: some View {
        Canvas { ctx, size in
            let dt = motion.lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
            motion.lastTime = now
            step(dt: dt)
            draw(in: &ctx, size: size)
        }
    }

    private func step(dt: Double) {
        // Fully closed: start the next dictation from silence.
        guard openness > 0.01 else {
            motion.level = 0
            motion.bands = .zero
            return
        }
        let target = thinking ? 0.2 : min(1, level)
        motion.level += (target - motion.level) * (1 - exp(-dt * (target > motion.level ? 12 : 4.5)))
        for i in 0..<4 {
            let band = thinking ? 0.3 : Double(spectrum.bands[i])
            // Hiss is short, so honey rises fast; everything settles slowly.
            let rising = band > motion.bands[i]
            let rate = rising ? (i == 3 ? 22.0 : 12.0) : (i == 3 ? 6.0 : 4.5)
            motion.bands[i] += (band - motion.bands[i]) * (1 - exp(-dt * rate))
        }
        // Calm: the ribbons drift slowly in silence and only a little faster
        // when loud.
        let pace = thinking ? 3.0 : 1.0
        motion.phase += dt * pace * (1.6 + 3.4 * pow(motion.level, 1.4))
        motion.clock += dt * pace
    }

    /// Siri's taper: 1 in the middle, nearly 0 at x = ±2.
    private static func taper(_ x: Double) -> Double {
        pow(4 / (4 + pow(x, 4)), 4)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        var length = size.width, depth = size.height
        if size.height > size.width {
            // Standing up: draw the same thing turned a quarter.
            ctx.translateBy(x: size.width, y: 0)
            ctx.rotate(by: .degrees(90))
            swap(&length, &depth)
        }
        let open = openness
        let span = Self.resting + (Self.drawn - Self.resting) * open
        let x0 = (length - span) / 2, mid = depth / 2
        // The line reaches out first; the ribbons rise once it has.
        let rise = open * open
        let shapes = Self.ribbons.map { path(for: $0, x0: x0, span: span, mid: mid, rise: rise) }
        var line = Path()
        line.move(to: CGPoint(x: x0, y: mid))
        line.addLine(to: CGPoint(x: x0 + span, y: mid))
        let loud = min(1, motion.bands.max() * 1.2)

        ctx.drawLayer { shade in
            shade.addFilter(.blur(radius: 4))
            for shape in shapes { shade.fill(shape, with: .color(Self.shade.opacity(0.07 * rise))) }
            shade.stroke(line, with: fade(Self.shade, 0.2, x0: x0, span: span), lineWidth: 5)
        }
        // The amber line stays through opening, only thinning, so it never
        // fades out and snaps back; added light alone barely shows on a light
        // wallpaper.
        ctx.stroke(line, with: fade(PourTheme.accent, 0.85 - 0.2 * open, x0: x0, span: span),
                   style: StrokeStyle(lineWidth: 2 - 0.6 * open, lineCap: .round))
        ctx.blendMode = .plusLighter
        for (ribbon, shape) in zip(Self.ribbons, shapes) {
            let energy = min(1, motion.bands[ribbon.band] * 3)
            ctx.fill(shape, with: .color(ribbon.color.opacity(0.4 * rise)))
            ctx.stroke(shape, with: fade(ribbon.color, 0.4 * energy * rise, x0: x0, span: span),
                       lineWidth: 0.6)
        }
        ctx.stroke(line, with: fade(PourTheme.honey, (0.3 + 0.5 * loud) * open, x0: x0, span: span),
                   lineWidth: 1)
    }

    /// One ribbon, mirrored above and below the line.
    private func path(for ribbon: Ribbon, x0: Double, span: Double, mid: Double, rise: Double) -> Path {
        let steps = 90
        let energy = pow(max(0, motion.bands[ribbon.band]), 1.3) * rise
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for i in 0...steps {
            let u = Double(i) / Double(steps), x = -2 + 4 * u
            var height = 0.0
            for lump in ribbon.lumps {
                let centre = lump.start + lump.drift * sin(motion.clock * lump.speed + lump.phase)
                let q = (x - centre) / lump.width
                height += lump.weight / ((1 + q * q) * (1 + q * q))
            }
            height *= energy * Self.taper(x * 0.8)
                * (0.85 + 0.15 * sin(4 * x - motion.phase + Double(ribbon.band)))
            height = min(1, height) * Self.reach
            top.append(CGPoint(x: x0 + u * span, y: mid - height))
            bottom.append(CGPoint(x: x0 + u * span, y: mid + height))
        }
        var path = Path()
        path.addLines(top)
        for point in bottom.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// Fades both ends, so the overlapping strokes don't add up to bright tips.
    private func fade(_ color: Color, _ alpha: Double, x0: Double, span: Double,
                      edge: Double = 0.3) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [
            .init(color: color.opacity(0), location: 0),
            .init(color: color.opacity(0.1 * alpha), location: edge * 0.4),
            .init(color: color.opacity(0.5 * alpha), location: edge * 0.72),
            .init(color: color.opacity(alpha), location: edge),
            .init(color: color.opacity(alpha), location: 1 - edge),
            .init(color: color.opacity(0.5 * alpha), location: 1 - edge * 0.72),
            .init(color: color.opacity(0.1 * alpha), location: 1 - edge * 0.4),
            .init(color: color.opacity(0), location: 1),
        ]), startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x0 + span, y: 0))
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
