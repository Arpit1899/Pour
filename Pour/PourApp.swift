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
        .windowResizability(.contentSize)
    }
}

/// Keeps the titlebar chrome out of the way while leaving the window itself
/// opaque, so content contrast doesn't depend on the user's wallpaper.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            // The window commits to the notch's palette, so the titlebar and
            // traffic lights have to come with it rather than follow the
            // system appearance into light mode.
            window.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = PourSessionModel()
    let settings = PourSettings.shared
    private var hudPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the panel up front so the first hotkey press doesn't pay for
        // constructing it.
        hudPanel = makeHUDPanel()

        session.presentHUD = { [weak self] in self?.showHUD() }
        session.dismissHUD = { [weak self] in self?.hideHUD() }

        GlobalHotKey.shared.onPressed = { [weak self] in
            guard let self else { return }
            Task { await self.session.begin() }
        }
        GlobalHotKey.shared.onReleased = { [weak self] in
            guard let self else { return }
            Task { await self.session.end() }
        }
        GlobalHotKey.shared.register(settings.hotKey)
        session.prewarm()

        // Rebind live, so a shortcut recorded in Settings works immediately
        // rather than after a relaunch.
        settings.onHotKeyChange = { combo in
            GlobalHotKey.shared.register(combo)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.shared.unregister()
    }

    /// Stay alive after the window closes so the hotkey keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - HUD panel

    private func showHUD() {
        if hudPanel == nil { hudPanel = makeHUDPanel() }
        guard let panel = hudPanel, let screen = NSScreen.main else { return }

        // Re-measure: the user may have moved to a display with a different
        // notch, or none at all.
        let geometry = NotchGeometry(screen: screen)
        session.notch = geometry

        // Pin the panel's top edge to the very top of the display — not
        // `visibleFrame`, which stops below the menu bar — so the shape starts
        // flush with the hardware notch.
        let size = geometry.panelSize
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: screen.frame.maxY - size.height,
                   width: size.width,
                   height: size.height),
            display: false
        )

        // No AppKit fade — the shape's own expansion is the entrance.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hideHUD() {
        guard let panel = hudPanel else { return }
        // By now the shape has already collapsed onto the hardware notch, so
        // there is nothing visible left to fade — just take the panel down.
        panel.orderOut(nil)
    }

    private func makeHUDPanel() -> NSPanel {
        let size = NotchGeometry.synthetic.panelSize
        let host = NSHostingView(rootView: HUDHost(session: session))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        // Without this the hosting view inherits the display's 32pt notch
        // safe area and pushes our shape *below* the notch it is meant to be.
        host.safeAreaRegions = []

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
        // Above the menu bar — otherwise the notch would be drawn *under* the
        // very chrome it is supposed to be part of.
        panel.level = .statusBar
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

    /// AppKit normally pushes windows down clear of the menu bar. Pour needs
    /// to sit *on* the notch, so the frame is used exactly as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private struct HUDHost: View {
    @Bindable var session: PourSessionModel

    var body: some View {
        VStack(spacing: 0) {
            if session.isVisible {
                PourNotchHUD(
                    geometry: session.notch,
                    state: session.hudState,
                    words: session.recorder.words,
                    audioLevel: Double(session.recorder.audioLevel) * 8,
                    elapsed: session.recorder.recordingDuration,
                    outcome: session.outcome,
                    errorMessage: session.phase == .error ? "Microphone unavailable" : nil,
                    modelDownload: session.recorder.isDownloadingModel
                        ? session.recorder.downloadProgress : nil,
                    expanded: session.isExpanded
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all)
    }
}
