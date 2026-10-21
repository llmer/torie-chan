import AVFoundation
import GuardShared
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// Everything the guard screen shows, as plain data, so Developer Tools can preview any state
/// without a live (and possibly loud) GuardController behind it.
struct GuardDisplayState {
    var phase: GuardPhase
    var now: Date
    var note: String?
    var expectedBack: Date?
    var peopleSeen: Int
    var peopleInView: Int
    var kioskFocused: Bool
    var lidWarning: Bool
    var agentUpdate: String?
    var readiness: (protections: [String], gaps: [String])
    var ownerAlerted: Bool
}

extension GuardController {
    var displayState: GuardDisplayState {
        GuardDisplayState(
            phase: phase, now: now, note: note, expectedBack: expectedBack, peopleSeen: peopleSeen, peopleInView: peopleInView,
            kioskFocused: kioskFocused, lidWarning: lidProtection != .active && lidProtection != .inactive,
            agentUpdate: agentUpdate, readiness: phase.name == "arming" ? readinessForScreen() : ([], []),
            ownerAlerted: notifier.isConfigured)
    }
}

/// The full-screen kiosk view: guard visuals + camera mirror + the disarm keypad.
struct GuardScreen: View {
    @ObservedObject var guardian: GuardController

    var body: some View {
        ZStack {
            GuardScreenContent(state: guardian.displayState, eyes: guardian.eyes)

            if showMirror {
                CameraMirror(session: guardian.cameraSession)
                    .frame(width: 240, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .bottom) {
                        Label("You're on camera", systemImage: "video.fill")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.red, in: Capsule())
                            .padding(8)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 64)
                    .padding(.trailing, 40)
                    .transition(.scale.combined(with: .opacity))
            }

            if guardian.keypadVisible {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { guardian.hideKeypad() }
                KeypadView(guardian: guardian)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { guardian.showKeypad() }
        .animation(.easeOut(duration: 0.18), value: guardian.keypadVisible)
        .animation(.spring(duration: 0.35), value: showMirror)
        .preferredColorScheme(.dark)
    }

    private var showMirror: Bool {
        guard guardian.cameraState == .running else { return false }
        switch guardian.phase {
        case .suspicious, .alarm: return true
        default: return false
        }
    }
}

/// Guard visuals only: background, eyes, header, status and the bystander notice. No input, no sound.
struct GuardScreenContent: View {
    let state: GuardDisplayState
    @ObservedObject var eyes: EyesModel

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.33), value: eyes.angryFlash) // a soft red pulse, not a hard strobe
            EyesView(eyes: eyes)

            VStack(spacing: 0) {
                header
                Spacer()
                status
                Spacer().frame(height: 24)
                hints
                footer
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 22)
        }
        // The colored backgrounds don't reach VoiceOver; say what changed.
        .onChange(of: state.phase.name) { _, _ in
            AccessibilityNotification.Announcement("\(title). \(subtitle)").post()
        }
    }

    /// Notes for the owner (focus, lid sleep), stacked as calm capsules above the footer. The lid
    /// note is only shown during the countdown: once armed it would tell a thief the weakness.
    @ViewBuilder private var hints: some View {
        let focusHint = state.phase.isGuarding && !state.kioskFocused
        let lidHint = state.phase.name == "arming" && state.lidWarning
        if focusHint || lidHint {
            VStack(spacing: 8) {
                if focusHint {
                    hint("Click anywhere to lock the keyboard to this screen", "cursorarrow.click")
                }
                if lidHint {
                    hint("Heads up: closing the lid will put this Mac to sleep", "exclamationmark.triangle.fill")
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func hint(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.black.opacity(0.35), in: Capsule())
    }

    private var background: Color {
        switch state.phase {
        case .alarm: eyes.angryFlash ? Color(red: 0.898, green: 0.224, blue: 0.208) : Color(red: 0.69, green: 0, blue: 0.125) // #E53935 ⇄ #B00020
        case .suspicious: Color(red: 0.22, green: 0.13, blue: 0.0)
        case .welcomeBack: Color(red: 0.04, green: 0.14, blue: 0.1)
        default: Color(red: 0.07, green: 0.07, blue: 0.09)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Label("TORIE-CHAN", systemImage: "eyes")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2)
            Spacer()
            if let back = state.expectedBack, state.phase.isGuarding {
                let minutes = Int((back.timeIntervalSince(state.now) / 60).rounded(.up))
                Label(minutes > 0 ? "Back in about \(minutes) min" : "Running a little late", systemImage: "clock")
            }
            if state.peopleSeen > 0 {
                Label("\(state.peopleSeen) walked by", systemImage: "figure.walk")
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
    }

    @ViewBuilder private var status: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: state.phase.name == "alarm" ? 26 : 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            if let note = state.note {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.system(size: 16, design: .rounded).italic())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)
            }
            if case .arming = state.phase {
                ReadinessList(readiness: state.readiness)
                    .padding(.top, 10)
            }
            if case .welcomeBack(let box) = state.phase, !box.summary.agentUpdates.isEmpty {
                Text("Your agent: \(box.summary.agentUpdates.last!)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let update = state.agentUpdate, state.phase.isGuarding {
                Label(update, systemImage: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.white.opacity(0.08), in: Capsule())
                    .padding(.top, 6)
            }
            if state.phase.isGuarding {
                Text("Press any key to disarm")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 10)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// A standing notice for passers-by: what the camera does and doesn't do.
    private var footer: some View {
        Text("I'm Torie-chan, a laptop guard. Camera on: I notice people, I don't record. A photo is taken only if the alarm goes off.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
    }

    private var title: String {
        switch state.phase {
        case .disarmed: "Zzz"
        case .arming(let until): "Arming in \(max(0, Int(until.timeIntervalSince(state.now).rounded(.up))))"
        case .armed: state.peopleInView > 0 ? "I see you~" : "Watching~"
        case .suspicious: "Hey. Step away."
        case .alarm: "ALARM"
        case .welcomeBack: "Welcome back!"
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .disarmed: ""
        case .arming: "Go ahead, I've got this."
        case .armed: "I'm guarding this laptop. Please don't touch!"
        case .suspicious(let reason, _): "\(reason). Please put it down."
        case .alarm(let reason): "\(reason). " + (state.ownerAlerted ? "The owner has been alerted." : "Please put it back.")
        case .welcomeBack(let box): box.summary.headline
        }
    }
}

private struct ReadinessList: View {
    let readiness: (protections: [String], gaps: [String])

    /// Compact on purpose: it sits under the eyes during a short countdown.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Watching for: " + readiness.protections.map { $0.prefix(1).lowercased() + $0.dropFirst() }.joined(separator: ", "), systemImage: "checkmark.shield.fill")
                .foregroundStyle(Color(red: 0.55, green: 0.9, blue: 0.6))
                .lineLimit(2)
            ForEach(readiness.gaps.prefix(3), id: \.self) { gap in
                Label(gap, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct KeypadView: View {
    @ObservedObject var guardian: GuardController

    var body: some View {
        VStack(spacing: 18) {
            Text("Enter code")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            HStack(spacing: 12) {
                ForEach(0..<max(6, guardian.entry.count), id: \.self) { i in
                    Circle()
                        .fill(i < guardian.entry.count ? Color.white : Color.white.opacity(0.18))
                        .frame(width: 14, height: 14)
                }
            }
            .frame(height: 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Code")
            .accessibilityValue(guardian.entry.isEmpty ? "Empty" : "\(guardian.entry.count) digits entered")
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                .onChange(of: message) { _, text in
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        AccessibilityNotification.Announcement(text).post()
                    }
                }

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { d in key(d) { guardian.typeDigit(Character(d)) } }
                    }
                }
                GridRow {
                    key(symbol: "delete.left", style: .secondary) { guardian.deleteDigit() }
                        .accessibilityLabel("Delete")
                    key("0") { guardian.typeDigit("0") }
                    key(symbol: "checkmark", style: .accent) { guardian.submitEntry() }
                        .accessibilityLabel("Submit code")
                }
            }

            if let context = guardian.authContext {
                HStack(spacing: 10) {
                    TouchIDView(context: context)
                        .frame(width: 32, height: 32)
                    Text("or use Touch ID")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }

    private var message: String {
        if let seconds = guardian.lockoutRemaining, seconds > 0 { return "Locked. Try again in \(seconds)s" }
        return guardian.keypadMessage ?? " "
    }

    private enum KeyStyle { case primary, secondary, accent }

    private func key(_ label: String = "", symbol: String? = nil, style: KeyStyle = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(label) }
            }
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .frame(width: 72, height: 72)
                .background(
                    Circle().fill(style == .accent ? Color.green.opacity(0.75) : Color.white.opacity(style == .primary ? 0.14 : 0.06))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Embedded Touch ID prompt bound to the context, so authentication shows inside our kiosk window
/// instead of a system panel that the kiosk window would cover.
struct TouchIDView: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context ctx: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: .regular)
    }

    func updateNSView(_ view: LAAuthenticationView, context ctx: Context) {}
}

/// Live, mirrored camera preview shown while warning/alarming. Display only; nothing is recorded.
struct CameraMirror: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
