import SwiftUI
import AppKit

@main
struct PourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.session)
                .environment(appDelegate.settings)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 620)
    }
}

/// Keeps the titlebar chrome out of the way so the sidebar runs to the top
/// edge with the traffic lights sitting on it. The window follows the system
/// appearance, light or dark.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = PourSessionModel()
    let settings = PourSettings.shared
    private let pointer = BarPointer()
    private var barPanel: NSPanel?
    private var pointerMonitors: [Any] = []
    private var pointerTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the panel up front so the first hotkey press doesn't pay for
        // constructing it.
        barPanel = makeBarPanel()

        session.presentHUD = { [weak self] in self?.showBar() }
        session.dismissHUD = { [weak self] in self?.hideBar() }

        GlobalHotKey.shared.onPressed = { [weak self] in
            guard let self else { return }
            Task { await self.session.shortcutPressed() }
        }
        GlobalHotKey.shared.onReleased = { [weak self] in
            guard let self else { return }
            Task { await self.session.shortcutReleased() }
        }
        GlobalHotKey.shared.register(settings.hotKey)
        session.prewarm()

        // Rebind live, so a shortcut recorded in Settings works immediately
        // rather than after a relaunch.
        settings.onHotKeyChange = { combo in
            GlobalHotKey.shared.register(combo)
        }
        settings.onShowBarChange = { [weak self] _ in self?.updateRestingBar() }

        // The Dock can grow, shrink or move, and displays come and go.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeBar() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointerIfNeeded() }
        }

        trackPointer()
        updateRestingBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.shared.unregister()
        pointerMonitors.forEach(NSEvent.removeMonitor)
    }

    /// Stay alive after the window closes so the hotkey keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - The bar

    private func showBar() {
        placeBar()
        barPanel?.orderFrontRegardless()
        pollPointerIfNeeded()
    }

    private func hideBar() {
        // The bar has already settled back to rest by now; whether the resting
        // bar stays is the user's call.
        guard !settings.showBarAlways else { return }
        barPanel?.orderOut(nil)
    }

    private func updateRestingBar() {
        if settings.showBarAlways || session.isVisible {
            showBar()
        } else {
            barPanel?.orderOut(nil)
        }
    }

    /// Bottom centre of the display you're working on, just clear of the Dock.
    /// `visibleFrame` already excludes the Dock, wherever it is and however
    /// big, and includes the whole bottom edge when the Dock hides itself.
    private func placeBar() {
        guard let panel = barPanel, let screen = NSScreen.main else { return }
        let size = BarLayout.panelSize
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: screen.visibleFrame.minY + BarLayout.lift - BarLayout.inset,
                   width: size.width,
                   height: size.height),
            display: false
        )
    }

    /// The panel lets clicks through everywhere except right over the bar, so
    /// the empty space around it never blocks the app underneath. A window
    /// that ignores the mouse never hears about the pointer, so it is tracked
    /// here instead.
    private func trackPointer() {
        let moved: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: moved) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { moved($0); return $0 }) {
            pointerMonitors.append(local)
        }
    }

    /// The monitors miss the pointer whenever Pour itself is the active app
    /// and the pointer is outside Pour's windows, which is exactly when you
    /// reach for the bar or the card's Copy button after using the window.
    /// So while a session is on screen, or Pour is active, the pointer is
    /// also checked on a timer, which stops itself once neither is true.
    private func pollPointerIfNeeded() {
        guard pointerTimer == nil, pointerPollingNeeded else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.pointerPollingNeeded else {
                    timer.invalidate()
                    self?.pointerTimer = nil
                    return
                }
                self.pointerMoved()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private var pointerPollingNeeded: Bool {
        barPanel?.isVisible == true && (session.isVisible || NSApp.isActive)
    }

    private func pointerMoved() {
        guard let panel = barPanel, panel.isVisible else { return }
        let area = BarLayout.hitRect(isActive: session.isVisible,
                                     isHovering: pointer.isHovering,
                                     cardHeight: session.heldText != nil ? pointer.cardHeight ?? 190 : nil)
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let inside = area.contains(NSEvent.mouseLocation)
        if pointer.isHovering != inside { pointer.isHovering = inside }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    private func makeBarPanel() -> NSPanel {
        let size = BarLayout.panelSize
        let host = BarHostingView(rootView: BarHost(session: session, settings: settings, pointer: pointer))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.safeAreaRegions = []
        host.onPointerMove = { [weak self] in self?.pointerMoved() }

        let panel = PourFloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        // Above ordinary and full-screen windows, one step below the Dock, so
        // a Dock that hides itself covers the bar when it slides up rather
        // than its middle icons landing under the bar. Set after
        // `isFloatingPanel`, which resets the level to floating.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        return panel
    }
}

/// Never steals focus — whatever the user was typing in stays first responder,
/// which is what makes the paste land in the right place.
final class PourFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click. The panel never becomes key, so without this a
/// click on the bar would only be spent bringing it forward.
private final class BarHostingView<Content: View>: NSHostingView<Content> {
    var onPointerMove: (() -> Void)?
    private var pointerArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Once the panel takes the mouse, moves over it belong to Pour and the
    /// global monitor stops hearing them. This keeps reporting them until
    /// the pointer leaves, so the panel lets go of the mouse on time.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerMove?()
    }
}

private struct BarHost: View {
    var session: PourSessionModel
    var settings: PourSettings
    var pointer: BarPointer

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            PourBar(
                isActive: session.isExpanded,
                showsIdle: settings.showBarAlways,
                isHovering: pointer.isHovering && !session.isVisible,
                hint: hint,
                state: session.hudState,
                audioLevel: Double(session.recorder.audioLevel) * 14,
                outcome: session.outcome,
                errorMessage: session.phase == .error ? "Microphone unavailable" : nil,
                modelDownload: session.recorder.isDownloadingModel
                    ? session.recorder.downloadProgress : nil,
                heldText: session.heldText,
                onCopy: { Task { await session.copyHeld() } },
                onDismiss: { Task { await session.dismissHeld() } },
                onCardHeight: { pointer.cardHeight = $0 }
            )
            .onTapGesture {
                // The card has its own buttons; a click on its text does nothing.
                guard session.heldText == nil else { return }
                Task { await session.toggle() }
            }
            .padding(.bottom, BarLayout.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
    }

    private var hint: String {
        let keys = settings.hotKey.displayString
        switch settings.activation {
        case .hold:   return "Click, or hold \(keys) to dictate"
        case .toggle: return "Click, or press \(keys) to dictate"
        }
    }
}
