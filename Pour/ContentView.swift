import SwiftUI
import AppKit
import AVFoundation

/// The pages in the sidebar.
enum Page: String, CaseIterable, Identifiable {
    case home, dictionary, style, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home:       "Home"
        case .dictionary: "Dictionary"
        case .style:      "Style"
        case .settings:   "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home:       "house"
        case .dictionary: "character.book.closed"
        case .style:      "textformat"
        case .settings:   "gearshape"
        }
    }
}

/// A sidebar on the window's own background, and the current page on a
/// lighter panel inset beside it. Light or dark follows the system.
struct ContentView: View {
    @State private var page: Page = .home
    @State private var permissions = PermissionStatus()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page, permissions: permissions)
                .frame(width: 208)

            Group {
                switch page {
                case .home:       HomePage()
                case .dictionary: DictionaryPage()
                case .style:      StylePage()
                case .settings:   SettingsPage(permissions: permissions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PourTheme.canvas, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(PourTheme.hairline, lineWidth: 0.5)
            }
            .padding([.top, .trailing, .bottom], 8)
        }
        .background(PourTheme.sidebar)
        // The sidebar runs up under the hidden titlebar, traffic lights and all.
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 540)
        // Permissions are granted in System Settings, outside the app, so
        // re-read them whenever Pour comes back to the foreground.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var page: Page
    var permissions: PermissionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                PourMark(size: 22)
                PourWordmark(size: 17, weight: .medium)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)

            ForEach(Page.allCases) { item in
                SidebarItem(page: item, isSelected: page == item) { page = item }
            }

            Spacer(minLength: 16)

            if !permissions.allGranted {
                SetupCard(permissions: permissions) { page = .settings }
            }
        }
        .padding(.horizontal, 10)
        // Clears the traffic lights.
        .padding(.top, 50)
        .padding(.bottom, 12)
    }
}

private struct SidebarItem: View {
    var page: Page
    var isSelected: Bool
    var select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                Color.primary.opacity(isSelected ? 0.07 : (hovering ? 0.04 : 0)),
                in: .rect(cornerRadius: 8, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Shown until both permissions are in place, the way a setup checklist
/// would be: what's done, what isn't, and one click to the fix.
private struct SetupCard: View {
    var permissions: PermissionStatus
    var open: () -> Void

    private var done: Int {
        (permissions.microphone == .authorized ? 1 : 0) + (permissions.accessibility ? 1 : 0)
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Finish setup")
                    .font(.system(size: 12, weight: .medium))
                ProgressView(value: Double(done), total: 2)
                    .progressViewStyle(.linear)
                    .tint(PourTheme.accent)
                    .controlSize(.small)
                step("Microphone", isDone: permissions.microphone == .authorized)
                step("Accessibility", isDone: permissions.accessibility)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PourTheme.canvas, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PourTheme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func step(_ title: String, isDone: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? PourTheme.accent : .secondary)
            Text(title)
                .foregroundStyle(isDone ? .secondary : .primary)
        }
        .font(.system(size: 12))
    }
}

// MARK: - Building blocks

/// A page: a serif title, an optional line under it, and the content in a
/// single readable column.
struct PageScaffold<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 28, design: .serif))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A label over a card of rows.
struct CardSection<Content: View>: View {
    var title: String
    var action: (label: String, run: () -> Void)?
    @ViewBuilder var content: Content

    init(_ title: String,
         action: (label: String, run: () -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let action {
                    Button(action.label, action: action.run)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Card { content }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Between rows in a card.
struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(PourTheme.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }
}

/// Title and explanation on the left, the control on the right.
struct SettingRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var subtitleColor: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct ToggleRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        SettingRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(PourTheme.accent)
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
    }
}

/// Quiet once granted, amber while it still wants a decision.
struct PermissionRow: View {
    var title: String
    var subtitle: String
    var isGranted: Bool
    var grant: () -> Void

    var body: some View {
        SettingRow(title: title, subtitle: subtitle) {
            if isGranted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Allowed")
            } else {
                Button("Allow", action: grant)
                    .buttonStyle(AmberPill())
            }
        }
    }
}

struct AmberPill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(PourTheme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: .capsule)
    }
}

/// The window is draggable by its background, which otherwise swallows a
/// press-and-hold on any control that isn't a real AppKit control — you end up
/// moving the window instead of dictating. This opts a region out.
private struct NotWindowDraggable: NSViewRepresentable {
    final class Blocker: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { Blocker() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keycaps stay physical — they stand for real keys, so the shape carries
/// meaning. Press them and they do what the real keys do, in either mode.
struct HoldableKeys: View {
    var caps: [String]
    var isRecording: Bool
    var onPress: () -> Void
    var onRelease: () -> Void
    var onHoverChange: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(caps, id: \.self) { cap($0) }
        }
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .animation(.easeOut(duration: 0.18), value: isRecording)
        .background(NotWindowDraggable())
        .contentShape(.rect)
        .onHover(perform: onHoverChange)
        // Push-to-talk needs press *and* release callbacks, which `Button`
        // doesn't give us — a zero-distance drag gesture does.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    onPress()
                }
                .onEnded { _ in
                    isPressed = false
                    onRelease()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("\(caps.joined(separator: " ")), press to dictate")
    }

    private func cap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isRecording ? PourTheme.accent : .primary)
            .padding(.horizontal, 13)
            .frame(minWidth: 42, minHeight: 36)
            .background(
                isRecording ? AnyShapeStyle(PourTheme.accent.opacity(0.16)) : AnyShapeStyle(PourTheme.control),
                in: .rect(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isRecording ? PourTheme.accent.opacity(0.5) : PourTheme.hairline,
                                  lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(isRecording ? 0 : 0.06), radius: 0, y: 1)
    }
}

#Preview {
    ContentView()
        .environment(PourSessionModel())
        .environment(PourSettings.shared)
}
