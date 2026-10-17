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

// MARK: - Live audio meter

/// Four rounded bars that ride the input level — the same visual language as
/// the system dictation indicator.
struct PourLevelMeter: View {
    var active: Bool
    var level: Double

    private let bars = 4
    private let barWidth: CGFloat = 3
    private let maxHeight: CGFloat = 16
    private let minHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(PourTheme.accent)
                        .frame(width: barWidth, height: height(bar: i, at: t))
                }
            }
            .frame(width: 21, height: maxHeight)
        }
        .frame(width: 21, height: maxHeight)
    }

    private func height(bar i: Int, at t: TimeInterval) -> CGFloat {
        guard active else { return minHeight }
        // Two detuned sines per bar so neighbours never march in lockstep.
        let phase = Double(i) * 1.9
        let wobble = 0.55 + 0.45 * sin(t * 7.5 + phase)
        let detail = 0.75 + 0.25 * sin(t * 13.1 + phase * 2.3)
        // Floor the amplitude so silence still breathes — four bars pinned at
        // their minimum read as an ellipsis, not a microphone.
        let amplitude = min(1, max(0.3, level)) * wobble * detail
        return minHeight + (maxHeight - minHeight) * amplitude
    }
}

// MARK: - Transcript ticker

/// The words as they land. The track shrinks to fit short transcripts and
/// caps at `maxWidth`, so a single word sits centred instead of stranded
/// against a fixed right edge.
private struct PourTranscript: View {
    var words: [String]
    var maxWidth: CGFloat

    /// Intrinsic width of the words, before the track clamps them.
    @State private var contentWidth: CGFloat = 0

    private static let visibleWindow = 16
    /// How far the leading fade reaches, in points rather than a fraction of
    /// the track — a fraction covers more text the wider the notch gets.
    private static let fadeLength: CGFloat = 26

    /// True only when there are words scrolled off the leading edge.
    private var isClipped: Bool { contentWidth > maxWidth + 0.5 }

    var body: some View {
        let start = max(0, words.count - Self.visibleWindow)
        let visible = (start..<words.count).map { (id: $0, text: words[$0]) }

        HStack(spacing: 6) {
            ForEach(visible, id: \.id) { word in
                Text(word.text)
                    .fixedSize()
                    .transition(.pourWord)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        // Measured here, where the view is still its full intrinsic width —
        // after the frame below it has already been clamped.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .frame(maxWidth: maxWidth, alignment: .trailing)
        // The outer `fixedSize` is what makes the track size to its content:
        // it proposes nil, so the flexible frame reports the text's own width
        // clamped to `maxWidth`, rather than greedily filling the row. Short
        // transcripts then sit centred; long ones fill and scroll leftward.
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .mask(leadingFade)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: words.count)
    }

    /// The fade exists to say "there is more text off to the left". When the
    /// transcript already fits there is nothing off to the left, and fading
    /// anyway just swallows the first letter — so it collapses to opaque.
    private var leadingFade: LinearGradient {
        let end = isClipped ? min(0.4, Self.fadeLength / max(maxWidth, 1)) : 0
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(isClipped ? 0 : 1), location: 0),
                .init(color: .black, location: end),
                .init(color: .black, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

private struct PourWordEffect: ViewModifier {
    var offsetY: CGFloat
    var opacity: Double
    func body(content: Content) -> some View {
        content.offset(y: offsetY).opacity(opacity)
    }
}

private extension AnyTransition {
    /// Opacity + a short rise. No blur: it cost a full-frame GPU pass per
    /// word and glitched during fast speech.
    static var pourWord: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PourWordEffect(offsetY: 5, opacity: 0),
                                 identity: PourWordEffect(offsetY: 0, opacity: 1)),
            removal: .modifier(active: PourWordEffect(offsetY: -4, opacity: 0),
                               identity: PourWordEffect(offsetY: 0, opacity: 1))
        )
    }
}

// MARK: - The notch

/// Pour lives in the camera housing. Collapsed, the shape sits exactly on the
/// hardware notch and is invisible; activating it springs the same black shape
/// wider and taller, so it reads as the notch itself opening up.
struct PourNotchHUD: View {
    var geometry: NotchGeometry
    var state: PourState
    var words: [String]
    var audioLevel: Double
    var elapsed: TimeInterval
    var outcome: PourOutcome
    var errorMessage: String?
    /// Fraction complete while a speech model installs, `nil` otherwise. The
    /// first run in a new language downloads hundreds of megabytes; without
    /// this the notch just sits on "Listening…" the whole time.
    var modelDownload: Double?
    /// False while summoning and while dismissing, so the shape starts and
    /// ends flush with the real notch.
    var expanded: Bool

    private var isLive: Bool { state == .listening || state == .transcribing }

    private var width: CGFloat {
        (expanded ? geometry.expandedWidth : geometry.collapsedWidth) + geometry.shoulder * 2
    }
    private var height: CGFloat {
        expanded ? geometry.expandedHeight : geometry.collapsedHeight
    }

    var body: some View {
        NotchShape()
            .fill(.black)
            .overlay { content.opacity(expanded ? 1 : 0) }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 22, y: 10)
            // One spring drives width, height and the shadow together, which
            // is what makes it feel like a single physical object.
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: expanded)
            // Short, so the cross-dissolve between two centred strings passes
            // too quickly to read as overlapping text.
            .animation(.easeOut(duration: 0.15), value: state)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Camera row: the housing occupies the middle, so the two shoulders
            // either side of it carry the level on the left and the clock on
            // the right.
            HStack(spacing: 0) {
                PourLevelMeter(active: isLive && modelDownload == nil,
                               level: audioLevel)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: geometry.notchWidth)

                Text(Self.clock(elapsed))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    // Faded rather than removed, so the shoulder keeps its
                    // width and nothing shifts when the clock appears.
                    .opacity(isLive && elapsed >= 1 ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: elapsed >= 1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: geometry.notchHeight)

            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, geometry.shoulder + 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var transcript: some View {
        if let progress = modelDownload {
            label("Preparing speech model… \(Int(progress * 100))%",
                  color: .white.opacity(0.55))
        } else {
            liveTranscript
        }
    }

    @ViewBuilder
    private var liveTranscript: some View {
        switch state {
        case .listening:
            label("Listening…", color: .white.opacity(0.55))
        case .transcribing, .polishing:
            if words.isEmpty {
                label("Listening…", color: .white.opacity(0.55))
            } else {
                PourTranscript(words: words,
                               maxWidth: geometry.expandedWidth - 32)
            }
        case .inserting:
            switch outcome {
            case .pasted:       row("checkmark", "Pasted")
            case .copied:       row("doc.on.clipboard", "Copied — press ⌘V to paste")
            case .nothingHeard: row("mic.slash", "Nothing heard")
            }
        case .error:
            row("exclamationmark.triangle.fill", errorMessage ?? "Microphone unavailable")
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            label(text, color: .white.opacity(0.8))
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private static func clock(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

#Preview {
    // A stand-in for the top of a display so the shoulders read.
    VStack {
        PourNotchHUD(
            geometry: .synthetic,
            state: .transcribing,
            words: "the notch opens up and the words land in it".split(separator: " ").map(String.init),
            audioLevel: 0.6,
            elapsed: 4,
            outcome: .nothingHeard,
            errorMessage: nil,
            modelDownload: nil,
            expanded: true
        )
        Spacer()
    }
    .frame(width: 900, height: 300)
    .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom))
}
