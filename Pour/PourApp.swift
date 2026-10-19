import SwiftUI
import AppKit

@main
struct PourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: PourMenu.windowID) {
            ContentView()
                .environment(appDelegate.session)
                .environment(appDelegate.settings)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 620)

        // Taking the item out of the menu bar by hand puts Pour back in the
        // Dock, so there is always a way to open it.
        MenuBarExtra(isInserted: Binding(
            get: { !appDelegate.settings.showInDock },
            set: { appDelegate.settings.showInDock = !$0 }
        )) {
            PourMenu(settings: appDelegate.settings)
        } label: {
            Image(nsImage: PourMenu.icon)
        }
    }
}

/// The menu bar item, shown while Pour is kept out of the Dock.
struct PourMenu: View {
    static let windowID = "main"

    /// The glass alone, as a template so the menu bar tints it.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: PourGlassShape().path(in: rect).cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var settings: PourSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(hint)
        Button("Open Pour", action: open)
        Divider()
        Button("Quit Pour") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var hint: String {
        let keys = settings.hotKey.displayString
        switch settings.activation {
        case .hold:   return "Hold \(keys) to dictate"
        case .toggle: return "Press \(keys) to dictate"
        }
    }

    private func open() {
        // The bar's panels can't become main, so this finds the window.
        if let window = NSApp.windows.first(where: \.canBecomeMain) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: Self.windowID)
        }
        NSApp.activate()
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

    private let dockTargets = DockTargetsModel()
    private var targetsPanel: NSPanel?
    /// Where the pointer and the panel were when a drag began.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the window opens, so a Dock icon doesn't flash up first.
        applyDockPolicy()
    }

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
        settings.onBarDockChange = { [weak self] in self?.placeBar(animated: true) }
        settings.onShowInDockChange = { [weak self] _ in
            self?.applyDockPolicy()
            // Leaving the Dock deactivates the app; keep the window in front.
            NSApp.activate()
        }

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

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
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

    private func placeBar(animated: Bool = false) {
        guard let panel = barPanel, let screen = NSScreen.main else { return }
        let frame = barFrame(for: settings.barDock, on: screen)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: false)
        }
    }

    /// The panel for each dock on the display you're working on: bottom
    /// centre, or halfway up either side, just clear of the Dock.
    /// `visibleFrame` already excludes the Dock, wherever it is and however
    /// big, and reaches the screen edge when the Dock hides itself.
    private func barFrame(for dock: BarDock, on screen: NSScreen) -> NSRect {
        let size = BarLayout.panelSize
        let area = screen.visibleFrame
        let origin: NSPoint = switch dock {
        case .bottom: NSPoint(x: screen.frame.midX - size.width / 2,
                              y: area.minY + BarLayout.lift - BarLayout.inset)
        case .left:   NSPoint(x: area.minX + BarLayout.lift - BarLayout.inset,
                              y: area.midY - size.height / 2)
        case .right:  NSPoint(x: area.maxX - BarLayout.lift + BarLayout.inset - size.width,
                              y: area.midY - size.height / 2)
        }
        return NSRect(origin: origin, size: size)
    }

    // MARK: - Moving the bar

    /// The spots the bar can snap to, in screen coordinates, each centred on
    /// where the listening bar sits in that dock.
    private func dockZones(on screen: NSScreen) -> [BarDock: CGRect] {
        let area = screen.visibleFrame
        let near = BarLayout.lift + BarLayout.depth / 2
        let long: CGFloat = 180, short: CGFloat = 60
        func zone(_ center: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                   width: size.width, height: size.height)
        }
        return [
            .bottom: zone(CGPoint(x: screen.frame.midX, y: area.minY + near), CGSize(width: long, height: short)),
            .left:   zone(CGPoint(x: area.minX + near, y: area.midY), CGSize(width: short, height: long)),
            .right:  zone(CGPoint(x: area.maxX - near, y: area.midY), CGSize(width: short, height: long)),
        ]
    }

    private func nearestDock(to point: NSPoint, on screen: NSScreen) -> BarDock {
        let zones = dockZones(on: screen)
        return BarDock.allCases.min { a, b in
            distance(point, zones[a]!) < distance(point, zones[b]!)
        } ?? .bottom
    }

    private func distance(_ point: NSPoint, _ rect: CGRect) -> CGFloat {
        hypot(point.x - rect.midX, point.y - rect.midY)
    }

    /// The bar follows the pointer, the screen dims, and the spot it would
    /// snap to lights up.
    private func barDragChanged() {
        guard let panel = barPanel, let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, panel.frame.origin)
            pointer.isDragging = true
            showDockTargets(on: screen)
        }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
        dockTargets.target = nearestDock(to: mouse, on: screen)
    }

    /// Let go: snap to the nearest spot and remember it.
    private func barDragEnded() {
        guard dragStart != nil, let screen = NSScreen.main else { return }
        let dock = nearestDock(to: NSEvent.mouseLocation, on: screen)
        dragStart = nil
        pointer.isDragging = false
        hideDockTargets()
        if settings.barDock == dock {
            placeBar(animated: true)
        } else {
            settings.barDock = dock
        }
    }

    private func showDockTargets(on screen: NSScreen) {
        let panel = targetsPanel ?? makeTargetsPanel()
        targetsPanel = panel
        panel.setFrame(screen.frame, display: false)
        // The overlay draws top-down from the screen's top-left corner.
        dockTargets.zones = dockZones(on: screen).mapValues { rect in
            CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                   width: rect.width, height: rect.height)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hideDockTargets() {
        guard let panel = targetsPanel else { return }
        dockTargets.target = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new drag may have started during the fade.
                guard self?.dragStart == nil else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func makeTargetsPanel() -> NSPanel {
        let host = NSHostingView(rootView: DockTargetsView(model: dockTargets))
        host.safeAreaRegions = []
        let panel = PourFloatingPanel(contentRect: .zero,
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        // Just under the bar, so the bar is dragged over the dimmed screen.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        return panel
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
        // Mid-drag the panel moves with the pointer and already has the mouse.
        // SwiftUI doesn't report a cancelled drag, so a drag with the button
        // already up is finished here instead.
        if dragStart != nil {
            if NSEvent.pressedMouseButtons & 1 == 0 { barDragEnded() }
            return
        }
        guard let panel = barPanel, panel.isVisible else { return }
        let area = BarLayout.hitRect(dock: settings.barDock, drawn: pointer.barSize)
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let inside = area.contains(NSEvent.mouseLocation)
        if pointer.isHovering != inside { pointer.isHovering = inside }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    private func makeBarPanel() -> NSPanel {
        let size = BarLayout.panelSize
        let host = BarHostingView(rootView: BarHost(
            session: session, settings: settings, pointer: pointer,
            onDragChanged: { [weak self] in self?.barDragChanged() },
            onDragEnded: { [weak self] in self?.barDragEnded() }
        ))
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
    var onDragChanged: () -> Void
    var onDragEnded: () -> Void

    var body: some View {
        let dock = settings.barDock
        ZStack(alignment: alignment(for: dock)) {
            Color.clear
            PourBar(
                isActive: session.isExpanded,
                showsIdle: settings.showBarAlways,
                isHovering: pointer.isHovering && !pointer.isDragging && !session.isVisible,
                hint: hint,
                state: session.hudState,
                audioLevel: Double(session.recorder.audioLevel) * 14,
                spectrum: session.recorder.spectrum,
                outcome: session.outcome,
                errorMessage: session.phase == .error ? "Microphone unavailable" : nil,
                modelDownload: session.recorder.isDownloadingModel
                    ? session.recorder.downloadProgress : nil,
                heldText: session.heldText,
                dock: dock,
                onCopy: { Task { await session.copyHeld() } },
                onDismiss: { Task { await session.dismissHeld() } },
                onSize: { pointer.barSize = $0 }
            )
            .onTapGesture {
                // The card has its own buttons; a click on its text does nothing.
                guard session.heldText == nil else { return }
                Task { await session.toggle() }
            }
            // Drag to move it to another edge. A few points of slack keeps a
            // click a click.
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in onDragChanged() }
                    .onEnded { _ in onDragEnded() }
            )
            .padding(edge(for: dock), BarLayout.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: dock)
    }

    private func alignment(for dock: BarDock) -> Alignment {
        switch dock {
        case .bottom: .bottom
        case .left:   .leading
        case .right:  .trailing
        }
    }

    private func edge(for dock: BarDock) -> Edge.Set {
        switch dock {
        case .bottom: .bottom
        case .left:   .leading
        case .right:  .trailing
        }
    }

    private var hint: String {
        let keys = settings.hotKey.displayString
        switch settings.activation {
        case .hold:   return "Click, or hold \(keys) to dictate"
        case .toggle: return "Click, or press \(keys) to dictate"
        }
    }
}
