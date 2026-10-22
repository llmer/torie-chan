import AVFoundation
import AppKit
import Combine
import GuardShared
import ServiceManagement
import SwiftUI

// MARK: - Navigation

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview, security, sensors, alerts, agents, data, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .security: "Security"
        case .sensors: "Sensors"
        case .alerts: "Phone Alerts"
        case .agents: "AI Agents"
        case .data: "Privacy & Data"
        case .developer: "Developer"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "Torie-chan at a glance: what's set up, what's protected, and what happened."
        case .security: "Who can disarm the guard, and how."
        case .sensors: "What Torie-chan can feel and see, and how jumpy it should be."
        case .alerts: "Get an iMessage on your iPhone when something happens."
        case .agents: "Let Claude Code or Codex arm the guard for you."
        case .data: "Everything stays on this Mac. Here's what's kept, and for how long."
        case .developer: "Live tracking, camera frames and every expression. Silent: no alarm, speech or logging."
        }
    }

    var symbol: String {
        switch self {
        case .overview: "eyes"
        case .security: "lock.fill"
        case .sensors: "sensor.fill"
        case .alerts: "bell.badge.fill"
        case .agents: "terminal.fill"
        case .data: "hand.raised.fill"
        case .developer: "hammer.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .indigo
        case .security: .red
        case .sensors: .orange
        case .alerts: .pink
        case .agents: .purple
        case .data: .green
        case .developer: .gray
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .overview
    /// View › Show Developer Section. On by default for now; regular users can hide it.
    @Published var showDeveloper: Bool = UserDefaults.standard.object(forKey: "showDeveloperSection") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showDeveloper, forKey: "showDeveloperSection")
            if !showDeveloper, section == .developer { section = .overview }
        }
    }

    var visibleSections: [SettingsSection] {
        showDeveloper ? SettingsSection.allCases : SettingsSection.allCases.filter { $0 != .developer }
    }
}

/// Owns the Developer section's tracker/sensors only while that section is on screen, and hands
/// the camera back the moment the real guard arms.
@MainActor
final class DevToolsHost: ObservableObject {
    @Published private(set) var model: DevToolsModel?
    private let readiness: () -> (protections: [String], gaps: [String])

    init(readiness: @escaping () -> (protections: [String], gaps: [String])) {
        self.readiness = readiness
    }

    func start() {
        guard model == nil else { return }
        let m = DevToolsModel(readiness: readiness)
        m.start()
        model = m
    }

    func stop() {
        model?.stop()
        model = nil
    }
}

/// Permission/helper states that change outside the app; polled while the window is open.
@MainActor
final class SystemStatus: ObservableObject {
    @Published var helper: SMAppService.Status = .notRegistered
    @Published var camera = AVCaptureDevice.authorizationStatus(for: .video)
    private var timer: AnyCancellable?

    func start(_ sleepGuard: SleepGuard) {
        refresh(sleepGuard)
        timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(sleepGuard) }
        }
    }

    func refresh(_ sleepGuard: SleepGuard) {
        helper = sleepGuard.helperStatus
        camera = AVCaptureDevice.authorizationStatus(for: .video)
    }
}

/// The one thing standing between the user and arming, if anything.
@MainActor
private func nextRequiredStep(_ guardian: GuardController) -> (title: String, section: SettingsSection)? {
    if guardian.passcode.loadState == .needsUnlock { return ("Unlock your disarm code", .security) }
    if !guardian.acknowledgedResponsibility { return ("Confirm responsible use", .security) }
    if !guardian.passcode.isSet { return ("Set a disarm code", .security) }
    return nil
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var guardian: GuardController
    @ObservedObject var nav: SettingsNavigation
    let devTools: DevToolsHost
    @ObservedObject var updater: Updater
    @StateObject private var status = SystemStatus()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(guardian: guardian, nav: nav)
                .frame(width: 236)
            Divider().ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .onAppear { status.start(guardian.sleepGuard) }
    }

    @ViewBuilder private var detail: some View {
        switch nav.section {
        case .developer:
            DeveloperPage(host: devTools, guarding: guardian.phase.isGuarding)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeader(section: nav.section)
                    page
                }
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity) // centered column on wide windows
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch nav.section {
        case .overview: OverviewPage(guardian: guardian, nav: nav, status: status, updater: updater)
        case .security: SecurityPage(guardian: guardian)
        case .sensors: SensorsPage(guardian: guardian, status: status)
        case .alerts: AlertsPage(guardian: guardian)
        case .agents: AgentsPage()
        case .data: DataPage(guardian: guardian)
        case .developer: EmptyView()
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var guardian: GuardController
    @ObservedObject var nav: SettingsNavigation

    private static let miniEyes = EyesModel.preview(mood: .calm, lookAt: CGPoint(x: 0.4, y: -0.2)).currentFrame()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StaticEyesView(frame: Self.miniEyes)
                    .frame(width: 36, height: 36)
                    .background(Color(red: 0.07, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Torie-chan").font(.headline)
                    StatusPill(phaseLabel, tone: phaseTone)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 40)
            .padding(.bottom, 10)

            // A real sidebar list: arrow keys, type-select, focus and VoiceOver selection for free.
            List(selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) {
                Section {
                    ForEach(nav.visibleSections.filter { $0 != .developer }) { row($0) }
                }
                if nav.showDeveloper {
                    Section { row(.developer) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            armFooter
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    private func row(_ section: SettingsSection) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if needsAttention(section) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                }
            }
        } icon: {
            IconTile(symbol: section.symbol, tint: section.tint, size: 22)
        }
        .tag(section)
    }

    @ViewBuilder private var armFooter: some View {
        VStack(spacing: 6) {
            if let next = nextRequiredStep(guardian) {
                Button {} label: { Label("Arm Guard", systemImage: "shield.lefthalf.filled").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(true)
                Button("\(next.title) to arm") { nav.section = next.section }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            } else {
                Button { guardian.arm() } label: { Label("Arm Guard", systemImage: "shield.lefthalf.filled").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(guardian.phase.isGuarding)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Text("10-second countdown, then it's watching.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(16)
    }

    private var phaseLabel: String {
        switch guardian.phase {
        case .disarmed, .welcomeBack: "Disarmed"
        case .arming: "Arming"
        case .armed: "Watching"
        case .suspicious: "Warning"
        case .alarm: "Alarm"
        }
    }

    private var phaseTone: StatusPill.Tone {
        switch guardian.phase {
        case .disarmed, .welcomeBack: .neutral
        case .arming, .armed: .good
        case .suspicious: .warning
        case .alarm: .bad
        }
    }

    /// Only things that block arming get a badge; recommended extras live in Overview's checklist.
    private func needsAttention(_ section: SettingsSection) -> Bool {
        section == .security && nextRequiredStep(guardian) != nil
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    @ObservedObject var guardian: GuardController
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var status: SystemStatus
    @ObservedObject var updater: Updater
    @StateObject private var heroEyes = EyesModel()
    @State private var shareCardURL: URL?

    private enum Tier: String { case required = "Required", recommended = "Recommended", optional = "Optional" }

    private struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String
        let done: Bool
        let tier: Tier
        let section: SettingsSection
    }

    private var steps: [Step] {
        let p = guardian.passcode
        let codeStep: Step = switch p.loadState {
        case .needsUnlock:
            Step(id: "code", title: "Unlock your disarm code", detail: "macOS needs your permission to read it from the keychain.",
                 done: false, tier: .required, section: .security)
        case .notSet:
            Step(id: "code", title: "Set a disarm code", detail: "\(Passcode.minLength)–12 digits. Touch ID and Apple Watch work too.",
                 done: false, tier: .required, section: .security)
        case .loaded:
            Step(id: "code", title: "Set a disarm code",
                 detail: p.isShort ? "Works, but \(Passcode.minLength)+ digits is safer." : "Touch ID and Apple Watch work too.",
                 done: true, tier: .required, section: .security)
        }
        return [
            Step(id: "ack", title: "Confirm responsible use", detail: "Only use it where filming is allowed.",
                 done: guardian.acknowledgedResponsibility, tier: .required, section: .security),
            codeStep,
            Step(id: "helper", title: "Install lid-close protection", detail: "Keeps the Mac awake if the lid is shut.",
                 done: status.helper == .enabled, tier: .recommended, section: .sensors),
            Step(id: "camera", title: "Allow the camera", detail: "People tracking and the alarm photo.",
                 done: status.camera == .authorized, tier: .recommended, section: .sensors),
            Step(id: "alerts", title: "Turn on iMessage alerts", detail: "So your phone buzzes in the bathroom.",
                 done: guardian.notifier.isConfigured, tier: .optional, section: .alerts),
        ]
    }

    var body: some View {
        let detail = guardian.readinessDetail()
        VStack(alignment: .leading, spacing: 24) {
            hero
            if steps.contains(where: { !$0.done }) { setupCard }
            Card(title: "What sets it off") {
                ForEach(Array(detail.protections.enumerated()), id: \.element) { index, item in
                    if index > 0 { RowDivider() }
                    CardRow(symbol: "checkmark.shield.fill", tint: .green, plainIcon: true, title: item)
                }
            }
            if !detail.gaps.isEmpty {
                Card(title: "Not covered yet") {
                    ForEach(Array(detail.gaps.enumerated()), id: \.element.text) { index, gap in
                        if index > 0 { RowDivider() }
                        CardRow(symbol: "exclamationmark.triangle.fill", tint: .orange, plainIcon: true, title: gap.text) {
                            if let section = fixSection(gap.fix) {
                                Button("Fix") { nav.section = section }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            if let last = guardian.lastSession { lastSessionCard(last) }
            activityCard
            if Updater.isAvailable { updatesCard }
        }
        .onAppear {
            heroEyes.mood = .calm
            heroEyes.start()
        }
        .onDisappear { heroEyes.stop() }
    }

    private func fixSection(_ fix: GuardController.Gap.Fix) -> SettingsSection? {
        switch fix {
        case .lidHelper, .camera: .sensors
        case .alerts: .alerts
        case .focus, .none: nil
        }
    }

    private var hero: some View {
        let next = nextRequiredStep(guardian)
        return HStack(spacing: 24) {
            GeometryReader { geo in
                EyesView(eyes: heroEyes)
                    .onContinuousHover { phase in
                        if case .active(let p) = phase {
                            heroEyes.lookAtCursor(CGPoint(x: (p.x / geo.size.width - 0.5) * 2, y: (p.y / geo.size.height - 0.46) * 2))
                        }
                    }
            }
            .frame(width: 240, height: 160)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(next == nil ? "Ready when you are." : "Almost ready.")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(next == nil
                     ? "Press Arm Guard in the sidebar, or tell your AI agent \u{201C}watch my laptop.\u{201D}"
                     : "One more thing before Torie-chan can keep an eye on your laptop.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let next {
                    Button(next.title) { nav.section = next.section }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var setupCard: some View {
        let required = steps.filter { $0.tier == .required }
        return Card(title: "Setup", trailing: AnyView(
            Text("\(required.filter(\.done).count) of \(required.count) required done")
                .font(.system(size: 11)).foregroundStyle(.secondary))) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { RowDivider() }
                Button { nav.section = step.section } label: {
                    CardRow(symbol: step.done ? "checkmark.circle.fill" : "circle", tint: step.done ? .green : .secondary, plainIcon: true,
                            title: step.title, subtitle: step.detail) {
                        HStack(spacing: 8) {
                            if step.done {
                                StatusPill("Done", tone: .good)
                            } else {
                                Text(step.tier.rawValue).font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(step.done ? "Done" : "\(step.tier.rawValue). Opens \(step.section.title).")
            }
        }
    }

    private func lastSessionCard(_ last: SessionSummary) -> some View {
        Card(title: "Last session") {
            CardRow(symbol: last.alarms.isEmpty ? "face.smiling" : "light.beacon.max.fill", tint: last.alarms.isEmpty ? .green : .red,
                    title: last.headline,
                    subtitle: last.endedAt.map { "Ended \($0.formatted(.relative(presentation: .named)))" + (last.disarmedWith.map { ", disarmed with \($0)" } ?? "") }) {
                if let shareCardURL {
                    ShareLink(item: shareCardURL) { Label("Share", systemImage: "square.and.arrow.up") }
                        .controlSize(.small)
                }
            }
        }
        .task(id: last.startedAt) { shareCardURL = ShareCard.render(last) }
    }

    private var updatesCard: some View {
        Card(title: "Updates") {
            if let version = updater.availableVersion {
                CardRow(symbol: "arrow.down.circle.fill", tint: .blue, title: "Torie-chan \(version) is available",
                        subtitle: "You have \(updater.currentVersion).") {
                    Button("Install…") { updater.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!updater.canCheck)
                }
            } else {
                CardRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "Torie-chan \(updater.currentVersion)",
                        subtitle: "Updates are signed and checked before they install. Never while guarding.") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!updater.canCheck)
                }
            }
            RowDivider()
            CardRow(symbol: "clock.arrow.circlepath", tint: .teal, title: "Check automatically",
                    subtitle: "Once a day, while Torie-chan isn't guarding.") {
                Toggle("Check automatically", isOn: Binding(get: { updater.checksAutomatically },
                                                            set: { updater.checksAutomatically = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            RowDivider()
            CardRow(symbol: "arrow.down.app.fill", tint: .indigo, title: "Install automatically",
                    subtitle: "Downloads in the background and installs the next time you quit.") {
                Toggle("Install automatically", isOn: Binding(get: { updater.installsAutomatically },
                                                              set: { updater.installsAutomatically = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!updater.checksAutomatically)
            }
        }
    }

    private var activityCard: some View {
        let recent = Array(guardian.events.events.suffix(5).reversed())
        return Card(title: "Recent activity",
                    trailing: AnyView(Button("Open Event Log") { nav.section = .data }.buttonStyle(.link).font(.system(size: 11)))) {
            if recent.isEmpty {
                CardRow(symbol: "moon.zzz.fill", tint: .indigo, title: "Nothing yet", subtitle: "Arm the guard and events show up here.")
            }
            ForEach(Array(recent.enumerated()), id: \.element.rowID) { index, event in
                if index > 0 { RowDivider() }
                EventRow(event: event)
            }
        }
    }
}

// MARK: - Security

private struct SecurityPage: View {
    @ObservedObject var guardian: GuardController
    @State private var currentCode = ""
    @State private var newCode = ""
    @State private var confirmCode = ""
    @State private var message: (text: String, isError: Bool)?
    @FocusState private var focus: Field?

    private enum Field { case current, new, confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Card(title: "Responsible use") {
                Toggle(isOn: $guardian.acknowledgedResponsibility) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("I'll only use this where filming is allowed, and I'm responsible for it")
                            .font(.system(size: 13, weight: .medium))
                        Text("The camera notices people walking by (nothing is recorded) and saves one photo if the alarm goes off. Some cafés don't allow cameras; never use it in restrooms or changing areas.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
                .toggleStyle(.checkbox)
                .padding(16)
            }

            Card(title: "Disarm code", trailing: AnyView(codeStatus)) {
                if guardian.passcode.loadState == .needsUnlock {
                    CardRow(symbol: "key.fill", tint: .orange, title: "Unlock your disarm code",
                            subtitle: "macOS needs your permission to read it from the keychain.") {
                        Button("Unlock") {
                            guardian.passcode.load(interactive: true)
                            guardian.objectWillChange.send()
                        }
                    }
                } else {
                    if guardian.passcode.isShort {
                        CardRow(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Your code is short",
                                subtitle: "It works, but \(Passcode.minLength)+ digits is much harder to guess.")
                        RowDivider(inset: 0)
                    }
                    codeForm
                        .disabled(guardian.phase.isGuarding)
                }
            }

            Card(title: "How disarming works") {
                CardRow(symbol: "touchid", tint: .pink, title: "Touch ID", subtitle: "Shown right on the guard screen; no system pop-up.")
                RowDivider()
                CardRow(symbol: "applewatch", tint: .orange, title: "Apple Watch",
                        subtitle: "Double-click the side button to approve. Only works with your unlocked Watch right next to the Mac. Turn it on in System Settings > Touch ID & Password.")
                RowDivider()
                CardRow(symbol: "number", tint: .blue, title: "Code",
                        subtitle: "\(Passcode.freeAttempts) free tries, then lockouts of 10 s, 20 s, 40 s and up that survive a relaunch. Guessing sets off the alarm.")
                RowDivider()
                CardRow(symbol: "terminal.fill", tint: .purple, title: "AI agents can't disarm",
                        subtitle: "There's deliberately no disarm tool. It's always you, in person.")
            }
        }
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                if guardian.passcode.isSet {
                    GridRow {
                        Text("Current code").foregroundStyle(.secondary)
                        SecureField("Current code", text: $currentCode)
                            .labelsHidden()
                            .focused($focus, equals: .current)
                            .onSubmit { focus = .new }
                    }
                }
                GridRow {
                    Text(guardian.passcode.isSet ? "New code" : "Code").foregroundStyle(.secondary)
                    SecureField(guardian.passcode.isSet ? "New code" : "Code", text: $newCode, prompt: Text("\(Passcode.minLength)–12 digits"))
                        .labelsHidden()
                        .focused($focus, equals: .new)
                        .onSubmit { focus = .confirm }
                }
                GridRow {
                    Text("Confirm").foregroundStyle(.secondary)
                    SecureField("Confirm code", text: $confirmCode)
                        .labelsHidden()
                        .focused($focus, equals: .confirm)
                        .onSubmit(save)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button(guardian.passcode.isSet ? "Change Code" : "Set Code", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCode.isEmpty)
                if guardian.phase.isGuarding {
                    Text("Disarm first to change the code.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let message {
                    Label(message.text, systemImage: message.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.isError ? .red : .green)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(16)
    }

    private var codeStatus: some View {
        switch guardian.passcode.loadState {
        case .loaded: StatusPill(guardian.passcode.isShort ? "Short" : "Set", tone: guardian.passcode.isShort ? .warning : .good)
        case .notSet: StatusPill("Not set", tone: .warning)
        case .needsUnlock: StatusPill("Locked", tone: .warning)
        }
    }

    private func save() {
        guard !newCode.isEmpty else { return }
        guard newCode == confirmCode else {
            message = ("Codes don't match.", true)
            focus = .confirm
            return
        }
        do {
            try guardian.passcode.set(newCode, current: guardian.passcode.isSet ? currentCode : nil)
            message = ("Code saved.", false)
            currentCode = ""
            newCode = ""
            confirmCode = ""
            focus = nil
            guardian.objectWillChange.send()
        } catch {
            message = (error.localizedDescription, true)
        }
    }
}

// MARK: - Sensors

private struct SensorsPage: View {
    @ObservedObject var guardian: GuardController
    @ObservedObject var status: SystemStatus
    @State private var helperError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Card(title: "Hardware") {
                CardRow(symbol: "laptopcomputer", tint: .blue, title: "Lid-close protection", subtitle: helperError ?? helperSubtitle) {
                    HStack(spacing: 8) {
                        StatusPill(helperLabel, tone: status.helper == .enabled ? .good : .warning)
                        helperButton
                    }
                }
                RowDivider()
                CardRow(symbol: "camera.fill", tint: .gray, title: "Camera", subtitle: cameraSubtitle) {
                    HStack(spacing: 8) {
                        StatusPill(cameraLabel, tone: status.camera == .authorized ? .good : .warning)
                        cameraButton
                    }
                }
                RowDivider()
                CardRow(symbol: "gyroscope", tint: .orange, title: "Motion sensor",
                        subtitle: MotionSensor.isAvailable ? "Built-in accelerometer and gyroscope."
                            : "Needs an Apple Silicon MacBook. Lid, charger and screen-lock triggers still work.") {
                    StatusPill(MotionSensor.isAvailable ? "Found" : "Not found", tone: MotionSensor.isAvailable ? .good : .warning)
                }
                RowDivider()
                CardRow(symbol: "laptopcomputer.and.arrow.down", tint: .teal, title: "Lid angle sensor",
                        subtitle: "Notices the screen being lowered before it shuts.") {
                    Text(LidAngleSensor.shared.angle().map { "\($0)°" } ?? "Not available")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "Sensitivity") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Sensitivity", selection: $guardian.sensitivity) {
                        ForEach(Sensitivity.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Text(sensitivityDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                RowDivider(inset: 0)
                CardRow(symbol: "waveform.path.ecg", tint: .red, title: "Test motion",
                        subtitle: guardian.motionTestNote ?? "Tap the table, type, nudge it: see what would set it off, without arming.") {
                    Button(guardian.motionTestActive ? "Stop" : "Start") {
                        guardian.motionTestActive ? guardian.stopMotionTest() : guardian.startMotionTest()
                    }
                    .controlSize(.small)
                    .disabled(guardian.phase.isGuarding)
                }
                if guardian.motionTestActive {
                    AgitationMeter(value: guardian.agitationMeter, peak: guardian.agitationPeak)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                }
            }
        }
        .onDisappear { guardian.stopMotionTest() }
    }

    private var sensitivityDetail: String {
        switch guardian.sensitivity {
        case .low: "For busy tables and wobbly counters. Needs a firm grab or lift."
        case .medium: "Recommended. One bump just gets a look, repeated bumping gets a warning, and handling it sounds the alarm."
        case .high: "For quiet places. Small nudges and slow slides count sooner."
        }
    }

    private var helperSubtitle: String {
        switch status.helper {
        case .requiresApproval: "Turn on Torie-chan in System Settings > General > Login Items, then come back here."
        default: "Keeps the Mac awake with the lid shut, only while armed. Needs a one-time admin approval."
        }
    }

    private var helperLabel: String {
        switch status.helper {
        case .enabled: "Installed"
        case .requiresApproval: "Needs approval"
        default: "Not installed" // .notFound also just means "never registered"
        }
    }

    @ViewBuilder private var helperButton: some View {
        switch status.helper {
        case .enabled:
            Button("Remove") { run { try guardian.sleepGuard.uninstallHelper() } }.controlSize(.small)
        case .requiresApproval:
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
        default:
            Button("Install") { run { try guardian.sleepGuard.installHelper() } }.controlSize(.small)
        }
    }

    private var cameraSubtitle: String {
        switch status.camera {
        case .denied, .restricted: "Turn it on in System Settings > Privacy & Security > Camera."
        default: "People tracking and the alarm photo. Processed on this Mac."
        }
    }

    private var cameraLabel: String {
        switch status.camera {
        case .authorized: "Allowed"
        case .denied, .restricted: "Off"
        default: "Not allowed yet"
        }
    }

    @ViewBuilder private var cameraButton: some View {
        if status.camera == .notDetermined {
            Button("Allow") {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { status.refresh(guardian.sleepGuard) }
                }
            }
            .controlSize(.small)
        } else if status.camera != .authorized {
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            .controlSize(.small)
        }
    }

    private func run(_ work: () throws -> Void) {
        do {
            try work()
            helperError = nil
        } catch {
            helperError = error.localizedDescription
        }
        status.refresh(guardian.sleepGuard)
    }
}

// MARK: - Alerts

private struct AlertsPage: View {
    @ObservedObject var guardian: GuardController
    @State private var enabled = false
    @State private var handle = ""
    @State private var includePhoto = false
    @State private var sending = false
    @State private var testResult: (text: String, isError: Bool)?
    @FocusState private var handleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Card(title: "iMessage alerts") {
                CardRow(symbol: "message.fill", tint: .green, title: "Text me when something happens",
                        subtitle: "Warnings, alarms, and a nudge if you're away longer than you said.") {
                    Toggle("Text me when something happens", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: enabled) { _, on in
                            guardian.notifier.isEnabled = on
                            guardian.objectWillChange.send()
                        }
                }
                if enabled {
                    RowDivider()
                    CardRow(symbol: "iphone", tint: .blue, title: "Send to",
                            subtitle: handleHint) {
                        TextField("Send to", text: $handle, prompt: Text("+1 555 123 4567 or you@icloud.com"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .focused($handleFocused)
                            .onSubmit(saveHandle)
                            .onChange(of: handleFocused) { _, focused in if !focused { saveHandle() } }
                    }
                    RowDivider()
                    CardRow(symbol: "photo.fill", tint: .orange, title: "Include the alarm photo",
                            subtitle: "Off by default: it's a picture of whoever was at your laptop. iMessage is end-to-end encrypted.") {
                        Toggle("Include the alarm photo", isOn: $includePhoto)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: includePhoto) { _, on in guardian.notifier.includePhoto = on }
                    }
                    RowDivider()
                    CardRow(symbol: "paperplane.fill", tint: .indigo, title: "Send a test message",
                            subtitle: testResult?.text ?? "Then check that your iPhone actually buzzes.") {
                        Button(sending ? "Sending…" : "Send Test Message", action: sendTest)
                            .controlSize(.small)
                            .disabled(sending || !Notifier.looksLikeHandle(handle))
                    }
                }
            }

            Card(title: "How it works") {
                CardRow(symbol: "message.fill", tint: .green, title: "Uses Messages on this Mac",
                        subtitle: "Messages needs to be signed in to iMessage. The first time, macOS asks to let Torie-chan control Messages.") {
                    Button("Open Messages") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
                    }
                    .controlSize(.small)
                }
                RowDivider()
                CardRow(symbol: "bell.slash.fill", tint: .gray, title: "If your iPhone doesn't buzz",
                        subtitle: "Messages you send to yourself can arrive silently. Use another number or email of yours, or someone you trust.")
                if testResult?.isError == true, testResult?.text.contains("Automation") == true {
                    RowDivider()
                    CardRow(symbol: "hand.raised.fill", tint: .red, title: "Messages access is blocked",
                            subtitle: "Turn on Messages under Torie-chan in Automation settings.") {
                        Button("Open Automation Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                        .controlSize(.small)
                    }
                }
            }
            Footnote("Nothing goes through a third-party service. If someone forces the Mac off, nothing can be sent after that, which is why the alarm (and its message) fires the moment the power button is pressed.")
        }
        .onAppear {
            enabled = guardian.notifier.isEnabled
            handle = guardian.notifier.handle
            includePhoto = guardian.notifier.includePhoto
        }
        .onDisappear(perform: saveHandle)
    }

    private var handleHint: String {
        if handle.isEmpty { return "Your iPhone number or Apple ID email." }
        return Notifier.looksLikeHandle(handle) ? "Your iPhone number or Apple ID email." : "That doesn't look like a phone number or email yet."
    }

    private func saveHandle() {
        guardian.notifier.handle = handle
        guardian.objectWillChange.send()
    }

    private func sendTest() {
        saveHandle()
        sending = true
        testResult = nil
        guardian.notifier.send("Test", "If your iPhone buzzed, alerts work. You can delete this.", force: true) { error in
            sending = false
            testResult = error.map { ($0, true) } ?? ("Sent. Did your iPhone buzz? If not, see below.", false)
        }
    }
}

// MARK: - Agents

private struct AgentsPage: View {
    private var mcpPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bg-mcp").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Card(title: "Connect") {
                agent("Claude Code", "claude mcp add torie-chan -- \(shellQuoted(mcpPath))")
                RowDivider(inset: 0)
                agent("Codex", "codex mcp add torie-chan -- \(shellQuoted(mcpPath))")
            }
            Footnote("Run one of these in Terminal, then just say \u{201C}watch my laptop, back in 5.\u{201D}")

            Card(title: "What agents can do") {
                CardRow(symbol: "shield.lefthalf.filled", tint: .indigo, title: "Arm the guard",
                        subtitle: "With a countdown, an expected-back time and a short note. They're told what's protected.")
                RowDivider()
                CardRow(symbol: "text.bubble.fill", tint: .blue, title: "Post progress",
                        subtitle: "Show a short line like \u{201C}tests passing\u{201D} on the guard screen while you're away.")
                RowDivider()
                CardRow(symbol: "list.bullet.rectangle.fill", tint: .green, title: "Read what happened",
                        subtitle: "Status, the event log and a debrief when you're back. Never the photos.")
                RowDivider()
                CardRow(symbol: "lock.fill", tint: .red, title: "Never disarm",
                        subtitle: "By design. Only you can disarm, in person, with your code or Touch ID.")
            }
        }
    }

    private func agent(_ name: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 13, weight: .semibold))
            CodeBlock(text: command, copyable: true)
        }
        .padding(16)
    }

    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Data

private struct DataPage: View {
    @ObservedObject var guardian: GuardController
    @State private var retention = SnapshotRetention.current
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Card(title: "Retention") {
                CardRow(symbol: "photo.fill", tint: .orange, title: "Keep alarm photos for",
                        subtitle: "One photo per alarm, of whoever is in front of the camera.") {
                    Picker("Keep alarm photos for", selection: $retention) {
                        ForEach(SnapshotRetention.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: retention) { _, value in
                        SnapshotRetention.current = value
                        SnapshotRetention.prune()
                    }
                }
                RowDivider()
                CardRow(symbol: "list.bullet.rectangle.fill", tint: .blue, title: "Event log",
                        subtitle: "Kept for \(EventLog.maxAgeDays) days. AI agents can read it, but never the photos.") {
                    Button("Show in Finder") {
                        let log = GuardIDs.eventLogURL
                        if FileManager.default.fileExists(atPath: log.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([log])
                        } else {
                            NSWorkspace.shared.open(GuardIDs.supportDirectory)
                        }
                    }
                    .controlSize(.small)
                }
                RowDivider()
                CardRow(symbol: "trash.fill", tint: .red, title: "Delete all data",
                        subtitle: "Event log, alarm photos and session history.") {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .controlSize(.small)
                        .disabled(guardian.phase.isGuarding)
                }
            }
            .confirmationDialog("Delete the event log, alarm photos and session history?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { guardian.deleteAllData() }
            } message: {
                Text("This can't be undone.")
            }

            let events = Array(guardian.events.events.suffix(40).reversed())
            Card(title: "Event log") {
                if events.isEmpty {
                    CardRow(symbol: "moon.zzz.fill", tint: .indigo, title: "Nothing yet")
                }
                ForEach(Array(events.enumerated()), id: \.element.rowID) { index, event in
                    if index > 0 { RowDivider() }
                    EventRow(event: event)
                }
            }
        }
    }
}

// MARK: - Developer

private struct DeveloperPage: View {
    @ObservedObject var host: DevToolsHost
    let guarding: Bool

    var body: some View {
        Group {
            if guarding {
                VStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Unavailable while the guard is armed.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let model = host.model {
                DeveloperContent(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if !guarding { host.start() } }
        .onDisappear { host.stop() }
    }
}

private struct DeveloperContent: View {
    @ObservedObject var model: DevToolsModel
    @State private var showCamera = true
    @State private var showModes = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                PageHeader(section: .developer)
                Spacer(minLength: 20)
                HStack(spacing: 6) {
                    Toggle(isOn: $model.fullGuardScreen) { Label("Guard Screen", systemImage: "rectangle.inset.filled") }
                    Toggle(isOn: $showCamera.animation()) { Label("Camera", systemImage: "camera.viewfinder") }
                    Toggle(isOn: $showModes.animation()) { Label("Modes", systemImage: "theatermasks") }
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 14)
            Divider()
            DevToolsPanes(model: model, showCamera: showCamera, showModes: showModes)
        }
    }
}

// MARK: - Building blocks

private struct PageHeader: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: section.symbol, tint: section.tint, size: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.system(size: 24, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(section.subtitle).foregroundStyle(.secondary).font(.system(size: 13))
            }
        }
    }
}

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Small uppercase label used above cards (and in the Developer panes).
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct Card<Content: View>: View {
    let title: String?
    var trailing: AnyView?
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { SectionLabel(title) }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(border))
        }
    }

    /// Dark mode: raised above the window (controlBackground is darker there and reads as a hole).
    private var fill: Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color(nsColor: .controlBackgroundColor)
    }

    private var border: Color {
        if contrast == .increased { return .primary.opacity(0.45) }
        return scheme == .dark ? Color.white.opacity(0.08) : Color(nsColor: .separatorColor).opacity(0.5)
    }
}

private struct CardRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    var plainIcon = false
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(symbol: String, tint: Color, plainIcon: Bool = false, title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.symbol = symbol
        self.tint = tint
        self.plainIcon = plainIcon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if plainIcon {
                    Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint).frame(width: 28)
                } else {
                    IconTile(symbol: symbol, tint: tint)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            trailing()
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// Inset dividers line up with row text; use inset 0 around non-row blocks.
private struct RowDivider: View {
    var inset: CGFloat = 56
    var body: some View { Divider().padding(.leading, inset) }
}

struct StatusPill: View {
    enum Tone { case good, warning, bad, neutral }
    let text: String
    let tone: Tone
    @Environment(\.colorScheme) private var scheme

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(textColor)
            .background(fillColor.opacity(scheme == .dark ? 0.2 : 0.14), in: Capsule())
            .fixedSize()
    }

    private var fillColor: Color {
        switch tone {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }

    /// Darker text in light mode so pills pass contrast on their tinted fill.
    private var textColor: Color {
        switch (tone, scheme) {
        case (.good, .light): Color(red: 0.118, green: 0.498, blue: 0.227)    // #1E7F3A
        case (.warning, .light): Color(red: 0.706, green: 0.325, blue: 0.035) // #B45309
        case (.warning, _): Color(red: 1, green: 0.702, blue: 0.251)          // #FFB340
        case (.bad, .light): Color(red: 0.75, green: 0.1, blue: 0.1)
        default: fillColor
        }
    }
}

private struct CodeBlock: View {
    let text: String
    var copyable = false
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
                    .textSelection(.enabled)
            }
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(scheme == .dark ? 0.09 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension GuardEvent {
    /// Stable identity for lists (events have no id of their own).
    var rowID: String { "\(date.timeIntervalSince1970)|\(kind)|\(message)" }
}

private struct EventRow: View {
    let event: GuardEvent

    var body: some View {
        CardRow(symbol: symbol, tint: tint, plainIcon: true, title: event.message,
                subtitle: event.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())) {
            if let path = event.snapshotPath {
                Button("Photo") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.controlSize(.small)
            }
        }
        .help(event.message)
    }

    private var symbol: String {
        switch event.kind {
        case "alarm", "tamper": "light.beacon.max.fill"
        case "suspicious": "exclamationmark.triangle.fill"
        case "armed", "arming": "shield.lefthalf.filled"
        case "disarmed": "checkmark.shield.fill"
        case "person", "close": "figure.walk"
        case "wrong_code": "xmark.octagon.fill"
        case "agent_update": "text.bubble.fill"
        default: "info.circle"
        }
    }

    private var tint: Color {
        switch event.kind {
        case "alarm", "tamper", "wrong_code": .red
        case "suspicious": .orange
        case "armed", "arming", "disarmed": .green
        case "person", "close": .blue
        case "agent_update": .purple
        default: .secondary
        }
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, -14)
    }
}

/// Native translucent sidebar material (honors Reduce Transparency automatically).
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct AgitationMeter: View {
    let value: Double
    let peak: Double

    private let maxValue = MotionDetector.alarmLevel * 1.4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color(for: value)).frame(width: max(6, position(value, w)))
                    Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 2).offset(x: position(peak, w) - 1)
                    marker("warn", at: position(MotionDetector.warnLevel, w))
                    marker("alarm", at: position(MotionDetector.alarmLevel, w))
                }
            }
            .frame(height: 14)
            .animation(.linear(duration: 0.08), value: value)
            Text(peakLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Motion level")
        .accessibilityValue(peakLabel)
    }

    private func position(_ v: Double, _ width: CGFloat) -> CGFloat {
        width * CGFloat(min(v, maxValue) / maxValue)
    }

    private var peakLabel: String {
        let verdict = peak >= MotionDetector.alarmLevel ? "would sound the alarm"
            : peak >= MotionDetector.warnLevel ? "would give a warning" : "would be ignored"
        return String(format: "Peak %.2f: %@", peak, verdict)
    }

    private func color(for v: Double) -> Color {
        v >= MotionDetector.alarmLevel ? .red : v >= MotionDetector.warnLevel ? .orange : .green
    }

    private func marker(_ label: String, at x: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.8)).frame(width: 2, height: 22)
            .overlay(alignment: .top) {
                Text(label).font(.system(size: 9, weight: .semibold)).fixedSize().offset(y: 22)
            }
            .offset(x: x - 1)
    }
}
