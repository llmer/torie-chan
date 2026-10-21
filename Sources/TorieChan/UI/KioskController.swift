import AppKit
import SwiftUI

private final class KioskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen, can't-switch-away presentation while the guard is up.
///
/// macOS won't let us block everything (Spotlight, Siri, a newly plugged-in display), so instead
/// anything that takes focus away for more than a couple of seconds is reported to the guard,
/// which treats it as an escape attempt. New displays get covered immediately.
@MainActor
final class KioskController {
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var refocusTimer: Timer?
    private weak var guardian: GuardController?

    var isShowing: Bool { !windows.isEmpty }

    func show(_ guardian: GuardController) {
        self.guardian = guardian
        guard windows.isEmpty else { return }

        NSApp.setActivationPolicy(.regular)
        buildWindows()
        NSApp.activate()
        applyPresentationOptions()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.guardian?.noteUserInput()
            self?.handleKey(event)
            return nil
        }
        // Clicks, scrolls and pointer movement mean someone's hand is on the laptop: give the owner
        // leeway, and let the eyes follow the pointer.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            guard let self, let guardian = self.guardian else { return event }
            guardian.noteUserInput()
            if let window = event.window, let view = window.contentView, view.bounds.width > 0 {
                let p = event.locationInWindow
                guardian.eyes.lookAtCursor(CGPoint(x: (p.x / view.bounds.width - 0.5) * 2,
                                                   y: -(p.y / view.bounds.height - 0.56) * 2)) // AppKit y is bottom-up
            }
            return event
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.guardian?.kioskFocusChanged(false)
                NSApp.activate()
            }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.applyPresentationOptions() // presentation options only stick while we're active
                self?.guardian?.kioskFocusChanged(true)
            }
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isShowing else { return }
                self.buildWindows()
                self.guardian?.displaysChanged()
            }
        })
        guardian.kioskFocusChanged(NSApp.isActive)

        // macOS may refuse activation for a background-launched app; keep asking politely.
        // (Any click on the eyes activates us for sure.)
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !NSApp.isActive { NSApp.activate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refocusTimer = t
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        refocusTimer?.invalidate()
        refocusTimer = nil
        NSApp.presentationOptions = []
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guardian?.kioskFocusChanged(false)
        // The app delegate decides whether we still need a Dock icon (Settings may be open).
    }

    /// One borderless window per display; rebuilt whenever displays change.
    private func buildWindows() {
        guard let guardian else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        for screen in NSScreen.screens {
            let window = KioskWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.acceptsMouseMovedEvents = true
            window.contentView = NSHostingView(rootView: GuardScreen(guardian: guardian))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        (windows.first { $0.screen == NSScreen.main } ?? windows.first)?.makeKey()
    }

    private func applyPresentationOptions() {
        guard isShowing, NSApp.isActive else { return }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                     .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
    }

    private func handleKey(_ event: NSEvent) {
        guard let guardian else { return }
        if case .welcomeBack = guardian.phase {
            guardian.finishWelcomeBack()
            return
        }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            guardian.deleteDigit()
        case 36, 76: // return, keypad enter
            guardian.submitEntry()
        case 53: // escape: clear a half-typed code, then close the keypad
            if !guardian.entry.isEmpty {
                guardian.clearEntry()
            } else if guardian.keypadVisible {
                guardian.hideKeypad()
            } else {
                guardian.showKeypad()
            }
        default:
            if let c = event.charactersIgnoringModifiers?.first, c.isNumber, c.isASCII {
                guardian.typeDigit(c)
            } else {
                guardian.showKeypad()
            }
        }
    }
}
