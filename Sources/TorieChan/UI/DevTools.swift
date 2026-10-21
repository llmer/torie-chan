import AppKit
import Combine
import GuardShared
import SwiftUI

/// Developer Tools: live googly eyes driven by the real camera and IMU, a sidecar with the raw
/// frames Vision analyzed (boxes, tracks, gaze target, timings), and a sidecar to preview every
/// guard mode.
///
/// Deliberately silent: it owns its own tracker, motion sensor and eyes, never touches Alarm,
/// the event log, notifications or the helper. It closes itself when the real guard arms.
enum DevMode: String, CaseIterable, Identifiable {
    case live, sleepy, arming, watching, close, skeptical, suspicious, alarm, welcomeBack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .sleepy: "Sleepy (disarmed)"
        case .arming: "Arming countdown"
        case .watching: "Watching"
        case .close: "Someone close"
        case .skeptical: "Skeptical (lingerer)"
        case .suspicious: "Suspicious"
        case .alarm: "Alarm"
        case .welcomeBack: "Welcome back"
        }
    }

    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .sleepy: "moon.zzz"
        case .arming: "timer"
        case .watching: "eyes"
        case .close: "person.fill.viewfinder"
        case .skeptical: "questionmark.circle"
        case .suspicious: "exclamationmark.triangle"
        case .alarm: "light.beacon.max"
        case .welcomeBack: "face.smiling"
        }
    }

    var detail: String {
        switch self {
        case .live: "Armed look, all social reactions, driven by the camera and IMU"
        case .sleepy: "Closed eyes, drifting z's"
        case .arming: "Countdown + readiness checklist (loops)"
        case .watching: "Calm, tracking people"
        case .close: "Bigger, sparkly and blushing"
        case .skeptical: "Side-eye and a raised brow"
        case .suspicious: "Angled lids, anger mark, amber screen"
        case .alarm: "Wide shocked eyes, red pulse (no sound)"
        case .welcomeBack: "Happy arcs, blush and the debrief"
        }
    }
}

@MainActor
final class DevToolsModel: ObservableObject {
    @Published var mode: DevMode = .live { didSet { applyMode() } }
    @Published var fullGuardScreen = false
    @Published var mirrorCamera = true
    @Published private(set) var frame: PersonTracker.DebugFrame?
    @Published private(set) var cameraState: PersonTracker.CameraState = .off
    @Published private(set) var now = Date()
    @Published private(set) var peopleSeen = 0
    @Published private(set) var peopleInView = 0
    @Published private(set) var agitation = 0.0
    @Published private(set) var jolt = 0.0
    @Published private(set) var noiseFloor = 0.0
    @Published private(set) var motionStatus = "starting…"
    @Published private(set) var reactions: [(Date, String)] = []
    @Published private(set) var hasSceneReference = false
    @Published private(set) var realLidAngle: Double?
    /// Developer override for the hinge angle, so lid animations can be scrubbed without closing the laptop.
    @Published var simulateLid = false {
        didSet { if !simulateLid { eyes.lidAngle = realLidAngle } else { eyes.lidAngle = simulatedLidAngle } }
    }
    @Published var simulatedLidAngle = 105.0 {
        didSet { if simulateLid { eyes.lidAngle = simulatedLidAngle } }
    }

    let eyes = EyesModel()
    private let tracker = PersonTracker()
    private let motion = MotionSensor()
    private let detector = MotionDetector()
    private let readiness: () -> (protections: [String], gaps: [String])
    private let lidFeed = LidAngleFeed()
    private var timer: Timer?
    private var armingUntil = Date()

    init(readiness: @escaping () -> (protections: [String], gaps: [String])) {
        self.readiness = readiness
        tracker.onObservation = { [weak self] obs in self?.handle(obs) }
        tracker.onDebug = { [weak self] frame in self?.frame = frame }
        motion.onAccel = { [weak self] a in
            guard let self else { return }
            _ = self.detector.ingestAccel(a)
            self.eyes.jolt = self.detector.jolt
            self.eyes.agitation = self.mode == .live ? self.detector.agitation : 0
        }
        motion.onGyro = { [weak self] g in self?.detector.ingestGyro(g) }
    }

    func start() {
        tracker.setDebug(true)
        tracker.start { [weak self] state in self?.cameraState = state }
        if motion.start() {
            detector.reset()
            detector.beginCalibration()
            motionStatus = "calibrating"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.motion.isRunning else { return }
                self.detector.finishCalibration()
                self.motionStatus = "ok"
            }
        } else {
            motionStatus = motion.lastError ?? "unavailable"
        }
        eyes.start()
        if let angle = LidAngleSensor.shared.angle() {
            eyes.lidReferenceAngle = Double(angle)
            simulatedLidAngle = Double(angle)
        }
        lidFeed.start { [weak self] angle in
            guard let self else { return }
            self.realLidAngle = angle
            if !self.simulateLid { self.eyes.lidAngle = angle }
        }
        applyMode()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lidFeed.stop()
        tracker.setDebug(false)
        tracker.stop(wait: true) // hand the camera back before the real guard takes it
        motion.stop()
        detector.reset()
        eyes.stop()
        cameraState = .off
    }

    func setSceneReference() {
        tracker.captureSceneReference()
        hasSceneReference = true
        log("Scene reference set")
    }

    /// Treat the current (real or simulated) angle as "fully open".
    func setLidReference() {
        eyes.lidReferenceAngle = simulateLid ? simulatedLidAngle : realLidAngle
    }

    func resetCounts() {
        peopleSeen = 0
        reactions.removeAll()
    }

    // MARK: - Preview state

    var displayState: GuardDisplayState {
        GuardDisplayState(phase: previewPhase, now: now, note: mode == .arming ? "Back in 5" : nil,
                          expectedBack: mode == .live || mode == .watching ? now.addingTimeInterval(300) : nil,
                          peopleSeen: peopleSeen, peopleInView: peopleInView, kioskFocused: true, lidWarning: false,
                          agentUpdate: mode == .watching ? "tests passing, 3/5 tasks done" : nil,
                          readiness: mode == .arming ? readiness() : ([], []), ownerAlerted: true)
    }

    private var previewPhase: GuardPhase {
        switch mode {
        case .sleepy: return .disarmed
        case .arming: return .arming(until: armingUntil)
        case .live, .watching, .close, .skeptical: return .armed
        case .suspicious: return .suspicious(reason: "Bumped", until: .distantFuture)
        case .alarm: return .alarm(reason: "Lifted")
        case .welcomeBack:
            var summary = SessionSummary(startedAt: now.addingTimeInterval(-7 * 60))
            summary.endedAt = now
            summary.peopleWalkedBy = max(peopleSeen, 14)
            summary.gotClose = 2
            summary.agentUpdates = ["all tests passing"]
            return .welcomeBack(SessionSummaryBox(summary: summary))
        }
    }

    private func applyMode() {
        switch mode {
        case .sleepy: eyes.mood = .sleepy
        case .suspicious: eyes.mood = .angry
        case .alarm: eyes.mood = .alarm
        case .welcomeBack: eyes.mood = .happy
        default: eyes.mood = .calm
        }
        if mode == .arming { armingUntil = Date().addingTimeInterval(10) }
        eyes.boing(0.8)
    }

    private func tick() {
        now = Date()
        agitation = detector.agitation
        jolt = (detector.jolt * detector.jolt).sum().squareRoot()
        noiseFloor = detector.noiseFloor
        if mode == .arming, now >= armingUntil { armingUntil = now.addingTimeInterval(10) }
        if mode == .skeptical { eyes.raiseEyebrow(for: 0.3) }
        let reduceFlashing = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        eyes.angryFlash = mode == .alarm && !reduceFlashing && Int(now.timeIntervalSince1970 * 3) % 2 == 0
        if mode == .close, eyes.lookTarget == nil { eyes.lookTarget = .zero }
    }

    private func handle(_ obs: PersonTracker.Observation) {
        eyes.react(to: obs, playful: mode == .live || mode == .watching)
        switch mode {
        case .sleepy: eyes.lookTarget = nil
        case .close:
            eyes.someoneClose = true
            if eyes.lookTarget == nil { eyes.lookTarget = .zero }
        default: break
        }
        peopleInView = obs.count
        if obs.arrived > 0 {
            peopleSeen += obs.arrived
            log("+\(obs.arrived) arrived (\(peopleSeen) total)")
        }
        if obs.departed > 0 { log("\(obs.departed) left" + (obs.count == 0 ? ", view empty → wink" : "")) }
        if obs.approaching { log("someone approaching → boing") }
        if obs.lingerStarted { log("someone lingering 6s+ → eyebrow") }
    }

    private func log(_ message: String) {
        reactions.insert((Date(), message), at: 0)
        if reactions.count > 30 { reactions.removeLast() }
    }
}

// MARK: - Views

/// The Developer section's three panes: live eyes (or the full guard screen), the camera
/// sidecar and the modes sidecar.
struct DevToolsPanes: View {
    @ObservedObject var model: DevToolsModel
    let showCamera: Bool
    let showModes: Bool

    var body: some View {
        HStack(spacing: 0) {
            eyesPane
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            if showCamera {
                Divider()
                CameraSidecar(model: model)
                    .frame(width: 380)
            }
            if showModes {
                Divider()
                ModesSidecar(model: model)
                    .frame(width: 240)
            }
        }
    }

    @ViewBuilder private var eyesPane: some View {
        if model.fullGuardScreen {
            // Dark for this pane only: preferredColorScheme would flip the whole Settings window.
            GuardScreenContent(state: model.displayState, eyes: model.eyes)
                .environment(\.colorScheme, .dark)
        } else {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09)
                EyesView(eyes: model.eyes)
            }
        }
    }
}

private struct CameraSidecar: View {
    @ObservedObject var model: DevToolsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Camera · Vision")
                    Spacer()
                    Toggle("Mirror", isOn: $model.mirrorCamera)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                frameView
                legend
                stats
                HStack {
                    Button(model.hasSceneReference ? "Reset Scene Reference" : "Set Scene Reference") { model.setSceneReference() }
                    Button("Reset Counts") { model.resetCounts() }
                }
                .controlSize(.small)
                SectionLabel("Reactions").padding(.top, 4)
                if model.reactions.isEmpty {
                    Text("Walk in and out of view…").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(model.reactions.prefix(12).enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.0, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(entry.1).font(.caption)
                    }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder private var frameView: some View {
        if let frame = model.frame {
            let aspect = CGFloat(frame.image.width) / CGFloat(max(frame.image.height, 1))
            ZStack {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaleEffect(x: model.mirrorCamera ? -1 : 1, y: 1)
                DetectionOverlay(frame: frame, mirrored: model.mirrorCamera)
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    Text(cameraMessage).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
        }
    }

    private var cameraMessage: String {
        switch model.cameraState {
        case .notAsked: "The camera isn't allowed yet.\nAllow it in Sensors."
        case .denied: "Camera access is off.\nTurn it on from Sensors."
        case .unavailable: "No camera available."
        default: "Starting camera…"
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(.yellow, "face")
            swatch(.cyan, "body")
            swatch(.green, "track ok")
            swatch(.gray, "tentative")
            swatch(.pink, "gaze target")
        }
        .font(.caption2)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 2).frame(width: 12, height: 9)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        let f = model.frame
        let confirmed = f?.tracks.filter(\.confirmed).count ?? 0
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Vision rate", f.map { String(format: "%.1f fps", $0.visionFPS) } ?? "–")
            row("Processing", f.map { String(format: "%.1f ms / frame", $0.processingMs) } ?? "–")
            row("Detections", f.map { "\($0.faces.count) faces · \($0.bodies.count) bodies" } ?? "–")
            row("Tracks", f.map { "\(confirmed) confirmed · \($0.tracks.count - confirmed) tentative" } ?? "–")
            row("People", "\(model.peopleInView) in view · \(model.peopleSeen) walked by")
            row("Scene shift", f?.sceneShift.map { String(format: "%.1f%% (alarm cue > 4%%)", $0 * 100) }
                ?? (model.hasSceneReference ? "measuring…" : "set a reference"))
            row("Brightness", f?.luma.map { String(format: "%.0f%%%@", $0 * 100, $0 < 0.05 ? " · COVERED" : "") } ?? "–")
            row("Lid angle", model.realLidAngle.map { String(format: "%.0f° (reference %.0f°)", $0, model.eyes.lidReferenceAngle ?? 0) } ?? "no sensor")
            row("Motion", model.motionStatus == "ok"
                ? String(format: "agitation %.2f · jolt %.3fg · floor %.3fg", model.agitation, model.jolt, model.noiseFloor)
                : model.motionStatus)
        }
        .font(.caption.monospacedDigit())
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// Boxes drawn in image space. Vision rects are normalized with a bottom-left origin.
private struct DetectionOverlay: View {
    let frame: PersonTracker.DebugFrame
    let mirrored: Bool

    var body: some View {
        Canvas { context, size in
            func rect(_ r: CGRect) -> CGRect {
                let x = mirrored ? 1 - r.maxX : r.minX
                return CGRect(x: x * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
            }
            func label(_ text: String, at r: CGRect, color: Color) {
                let resolved = context.resolve(Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.black))
                let s = resolved.measure(in: size)
                let bg = CGRect(x: r.minX, y: max(0, r.minY - s.height - 2), width: s.width + 6, height: s.height + 2)
                context.fill(Path(roundedRect: bg, cornerRadius: 3), with: .color(color))
                context.draw(resolved, at: CGPoint(x: bg.minX + 3, y: bg.minY + 1), anchor: .topLeading)
            }

            for body in frame.bodies {
                let r = rect(body.rect)
                context.stroke(Path(r), with: .color(.cyan.opacity(0.8)), lineWidth: 1.5)
                label(String(format: "body %.0f%%", body.confidence * 100), at: CGRect(x: r.minX, y: r.maxY + 14, width: 0, height: 0), color: .cyan)
            }
            for face in frame.faces {
                let r = rect(face)
                context.stroke(Path(r), with: .color(.yellow), lineWidth: 1.5)
                label(String(format: "face h=%.2f", face.height), at: CGRect(x: r.minX, y: r.maxY + 14, width: 0, height: 0), color: .yellow)
            }
            for track in frame.tracks {
                let r = rect(track.rect).insetBy(dx: -4, dy: -4)
                let color: Color = track.confirmed ? (track.lingering ? .orange : .green) : .gray
                context.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(color),
                               style: StrokeStyle(lineWidth: track.confirmed ? 3 : 2, dash: track.confirmed ? [] : [6, 4]))
                var text = "#\(track.id) " + (track.confirmed ? "ok" : "\(track.hits)/3")
                if let close = track.closeFor { text += String(format: " close %.0fs", close) }
                if track.lingering { text += " LINGER" }
                label(text, at: r, color: color)
            }
            if let t = frame.target {
                let p = CGPoint(x: (mirrored ? 1 - t.x : t.x) * size.width, y: (1 - t.y) * size.height)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 12, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 12, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 12)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 12))
                context.stroke(cross, with: .color(.pink), lineWidth: 2.5)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(.pink), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ModesSidecar: View {
    @ObservedObject var model: DevToolsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Modes").padding(.bottom, 4)
                ForEach(DevMode.allCases) { mode in
                    Button { model.mode = mode } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: mode.symbol)
                                .frame(width: 20)
                                .foregroundStyle(model.mode == mode ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title).font(.callout.weight(model.mode == mode ? .semibold : .regular))
                                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(model.mode == mode ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                SectionLabel("Reactions").padding(.top, 14)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Button { model.eyes.boing(1.5) } label: { Text("Boing").frame(maxWidth: .infinity) }
                        Button { model.eyes.shake() } label: { Text("Shake").frame(maxWidth: .infinity) }
                    }
                    GridRow {
                        Button { model.eyes.blink() } label: { Text("Blink").frame(maxWidth: .infinity) }
                        Button { model.eyes.wink() } label: { Text("Wink").frame(maxWidth: .infinity) }
                    }
                    GridRow {
                        Button { model.eyes.raiseEyebrow(for: 3) } label: { Text("Eyebrow").frame(maxWidth: .infinity) }
                        Button { model.eyes.boing(2.5) } label: { Text("Big Boing").frame(maxWidth: .infinity) }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                SectionLabel("Lid").padding(.top, 14)
                Toggle("Simulate lid angle", isOn: $model.simulateLid)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                HStack {
                    Slider(value: $model.simulatedLidAngle, in: 0...130)
                        .disabled(!model.simulateLid)
                    Text(String(format: "%.0f°", model.simulateLid ? model.simulatedLidAngle : (model.realLidAngle ?? 0)))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
                HStack {
                    Button { model.eyes.wakeFromLidClose() } label: { Text("Peekaboo").frame(maxWidth: .infinity) }
                    Button { model.setLidReference() } label: { Text("Set as Open").frame(maxWidth: .infinity) }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                Text("Closing: Torie-chan ducks under the bed and peers out. Opening: creeps back out and pops up with sparkles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Previews only. Modes never sound the alarm, speak, notify your phone or write to the event log. Live mode reacts to the real camera and motion sensor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }
            .padding(14)
        }
    }
}
