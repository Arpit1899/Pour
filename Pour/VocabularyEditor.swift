import SwiftUI

/// Left-to-right wrapping. Vocabulary terms are short and vary wildly in
/// width, so a row each would waste most of the window; pills that wrap fit
/// far more in the same space.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y),
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Add and remove the terms the recogniser should lean toward.
struct VocabularyEditor: View {
    var terms: [String]
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private let hairline = Color.white.opacity(0.07)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .frame(width: 20)

                TextField("Add a name, acronym or term", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit(commit)

                if !draft.isEmpty {
                    Button("Add", action: commit)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PourTheme.accent)
                }
            }
            .padding(.vertical, 12)

            if terms.isEmpty {
                Text("Names and jargon a general model would otherwise guess at — people you message, products you work on, acronyms.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(terms, id: \.self) { term in
                        TermPill(term: term) { onRemove(term) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func commit() {
        onAdd(draft)
        draft = ""
        fieldFocused = true
    }
}

private struct TermPill: View {
    var term: String
    var onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(term)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? .white : Color.white.opacity(0.35))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(hovering ? 0.13 : 0.07), in: .capsule)
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .contentShape(.capsule)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onRemove)
        .help("Remove “\(term)”")
        .accessibilityLabel("Remove \(term)")
    }
}
