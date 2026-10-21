import AppKit
import GuardShared
import OSLog
import SwiftUI

private let log = Logger(subsystem: GuardIDs.appBundleID, category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var guardian: GuardController!
    private let kiosk = KioskController()
    private var server: ControlServer?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var housekeepingTimer: Timer?
    private var devTools: DevToolsHost!
    private let settingsNav = SettingsNavigation()
    private var viewMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: GuardIDs.supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guardian = GuardController()
        buildMainMenu()
        guardian.onPhaseChange = { [weak self] phase in self?.phaseChanged(phase) }
        guardian.onNeedsSetup = { [weak self] in self?.openSettings(.overview) }
        devTools = DevToolsHost { [weak self] in self?.guardian.readinessForScreen() ?? ([], []) }
        // The real guard needs the camera; the Developer section hands it back first.
        guardian.onWillArm = { [weak self] in self?.leaveDeveloperSection() }

        let server = ControlServer { [weak self] request in
            MainActor.assumeIsolated {
                self?.guardian.handle(request) ?? ControlResponse(ok: false, error: "shutting down")
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            guardian.events.add("error", "Control socket unavailable: \(error)")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eyes", accessibilityDescription: "Torie-chan")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Housekeeping: drop old alarm photos now and every few hours.
        SnapshotRetention.prune()
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in SnapshotRetention.prune() }
        RunLoop.main.add(t, forMode: .common)
        housekeepingTimer = t

        guardian.sleepGuard.checkHelperVersion { [weak self] message in
            self?.guardian.events.add("helper", message)
        }

        if needsMoveToApplications {
            promptMoveToApplications()
        }

        if guardian.armedMarker.exists {
            // We were killed mid-guard (the helper relaunches us). Come back up screaming.
            guardian.resumeAfterTamper()
        } else if let dir = Self.argument(after: "--snapshot-settings") {
            snapshotSettings(to: URL(fileURLWithPath: dir))
        } else if CommandLine.arguments.contains("--devtools") {
            openSettings(.developer)
        } else if !guardian.passcode.isSet || !guardian.acknowledgedResponsibility {
            showSettings()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guardian.phase.isGuarding ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log.info("reopen (visible windows: \(flag))")
        if !guardian.phase.isGuarding { showSettings() }
        return true
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === viewMenu {
            rebuildViewMenu(menu)
            return
        }
        menu.removeAllItems()
        let armed = guardian.phase.isGuarding
        let arm = NSMenuItem(title: "Arm Guard (10s countdown)", action: #selector(armFromMenu), keyEquivalent: "")
        arm.isEnabled = !armed
        menu.addItem(arm)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        let dev = NSMenuItem(title: "Developer Tools…", action: #selector(showDevTools), keyEquivalent: "i")
        dev.keyEquivalentModifierMask = [.command, .option]
        dev.isEnabled = !armed
        menu.addItem(dev)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Torie-chan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isEnabled = !armed
        menu.addItem(quit)
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
    }

    @objc private func showDevTools() {
        guard !guardian.phase.isGuarding else { return }
        guardian.stopMotionTest()
        openSettings(.developer)
    }

    @objc private func armFromMenu() {
        guardian.arm()
    }

    @objc func showSettings() {
        openSettings(nil)
    }

    func openSettings(_ section: SettingsSection?) {
        if let section {
            if section == .developer { settingsNav.showDeveloper = true }
            settingsNav.section = section
        }
        // While a window is open we're a regular app: Dock icon, menu bar, ⌘W/⌘V/⌘M all work.
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Torie-chan Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 860, height: 560)
            window.contentView = NSHostingView(rootView: SettingsView(guardian: guardian, nav: settingsNav, devTools: devTools))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TorieChanSettings")
            settingsWindow = window
        }
        // A menu-bar (accessory) app isn't allowed to steal focus on macOS 14+, so the old
        // activate(ignoringOtherApps:) is silently ignored. Order the window in regardless,
        // then ask politely for activation.
        settingsWindow?.orderFrontRegardless()
        settingsWindow?.makeKey()
        NSApp.activate()
        log.info("settings shown (on screen: \(self.settingsWindow?.isVisible ?? false))")
    }

    /// Running from the disk image or a quarantined download (App Translocation)? Then the
    /// lid-close helper can't register, and permissions won't stick. Ask to be moved first.
    private var needsMoveToApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    private func promptMoveToApplications() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Torie-chan to your Applications folder"
        alert.informativeText = "Torie-chan is running from the disk image or Downloads. Drag it into Applications and open it from there, so lid-close protection and permissions work."
        alert.addButton(withTitle: "Show Applications Folder")
        alert.addButton(withTitle: "Continue Anyway")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            NSApp.terminate(nil)
        }
    }

    private static func argument(after flag: String) -> String? {
        #if DEBUG
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
        #else
        return nil
        #endif
    }

    /// Debug builds only: render every Settings section of the real window to PNGs, then quit.
    /// (Drawing our own view hierarchy needs no screen-recording permission.)
    private func snapshotSettings(to dir: URL) {
        if let appearance = Self.argument(after: "--appearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        openSettings(.overview)
        // Each step sets something up, waits, then captures the window.
        var steps: [(name: String, delay: Double, setup: () -> Void)] = SettingsSection.allCases.map { section in
            (section.rawValue, section == .developer ? 4 : 1.2, { [weak self] in self?.settingsNav.section = section })
        }
        for mode in [DevMode.arming, .suspicious, .alarm] {
            steps.append(("guard-\(mode.rawValue)", 1.5, { [weak self] in
                self?.devTools.model?.fullGuardScreen = true
                self?.devTools.model?.mode = mode
            }))
        }
        func next() {
            guard !steps.isEmpty else {
                leaveDeveloperSection()
                NSApp.terminate(nil)
                return
            }
            let step = steps.removeFirst()
            step.setup()
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                if let view = self?.settingsWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(step.name).png"))
                }
                next()
            }
        }
        next()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        leaveDeveloperSection()
        guardian.stopMotionTest()
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    /// Single owner of the Dock icon: shown while Settings or the guard screen is up.
    private func updateActivationPolicy() {
        let needsRegular = settingsWindow?.isVisible == true || kiosk.isShowing
        NSApp.setActivationPolicy(needsRegular ? .regular : .accessory)
    }

    // MARK: - Main menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Torie-chan", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Torie-chan", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Torie-chan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.delegate = self // rebuilt on open so the Developer item reflects the setting
        viewItem.submenu = view
        viewMenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func rebuildViewMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, section) in settingsNav.visibleSections.enumerated() {
            let item = NSMenuItem(title: section.title, action: #selector(selectSection(_:)), keyEquivalent: "\(index + 1)")
            item.target = self
            item.representedObject = section.rawValue
            item.state = settingsNav.section == section ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let dev = NSMenuItem(title: "Show Developer Section", action: #selector(toggleDeveloperSection), keyEquivalent: "")
        dev.target = self
        dev.state = settingsNav.showDeveloper ? .on : .off
        menu.addItem(dev)
    }

    @objc private func selectSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = SettingsSection(rawValue: raw) else { return }
        openSettings(section)
    }

    @objc private func toggleDeveloperSection() {
        settingsNav.showDeveloper.toggle()
        if !settingsNav.showDeveloper { leaveDeveloperSection() }
    }

    /// Release the Developer section's camera. Hidden windows don't reliably tell SwiftUI their
    /// views disappeared, so switch sections explicitly as well.
    private func leaveDeveloperSection() {
        if settingsNav.section == .developer { settingsNav.section = .overview }
        devTools.stop()
    }

    private func phaseChanged(_ phase: GuardPhase) {
        if phase == .disarmed {
            kiosk.hide()
            updateActivationPolicy()
        } else {
            settingsWindow?.orderOut(nil)
            kiosk.show(guardian)
        }
        statusItem.button?.image = NSImage(systemSymbolName: phase == .disarmed ? "eyes" : "eyes.inverse",
                                           accessibilityDescription: "Torie-chan")
    }
}
