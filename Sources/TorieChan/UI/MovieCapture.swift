#if DEBUG
import AppKit
import GuardShared
import SwiftUI

/// Offline captures of the shipping views. Never constructs a controller, starts sensors,
/// accesses the camera, changes preferences, sounds an alarm, or sends an alert.
@MainActor
enum MovieCapture {
    static let fps = 24
    static let size = CGSize(width: 1440, height: 900)

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let epoch = Date(timeIntervalSince1970: 1_792_519_200)
        let clips: [(String, Double, EyesModel.Mood)] = [
            ("sleepy", 4, .sleepy), ("arming", 5, .calm), ("watching", 6, .calm),
            ("close", 4, .calm), ("skeptical", 4, .calm),
            ("warning", 4, .angry), ("alarm", 4, .alarm),
            ("welcome", 5, .happy), ("lid", 4, .calm),
        ]
        for (name, duration, mood) in clips {
            let output = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let eyes = EyesModel.preview(mood: mood, lookAt: .zero, close: name == "close")
            for index in 0..<Int(duration * Double(fps)) {
                try autoreleasepool {
                    let t = Double(index) / Double(fps)
                    let now = epoch.addingTimeInterval(t)
                    eyes.lookTarget = CGPoint(x: sin(t * 0.9) * 0.65, y: cos(t * 0.65) * 0.12)
                    if name == "skeptical" { eyes.raiseEyebrow(for: 60) }
                    if name == "lid" {
                        eyes.lidReferenceAngle = 105
                        eyes.lidAngle = t < 2 ? 105 - t * 44 : 17 + (t - 2) * 44
                    }
                    // The real alarm has a soft pulse; the capture holds its dark red phase.
                    eyes.angryFlash = false
                    eyes.settle(1.0 / Double(fps))
                    var summary = SessionSummary(startedAt: epoch.addingTimeInterval(-5 * 60))
                    summary.endedAt = epoch
                    summary.peopleWalkedBy = 7
                    summary.gotClose = 1
                    summary.warnings = ["Bumped"]
                    summary.alarms = ["Lifted"]
                    summary.photoTaken = true
                    summary.disarmedWith = "Touch ID"
                    summary.agentUpdates = ["all tests passing"]
                    let phase: GuardPhase
                    switch name {
                    case "sleepy": phase = .disarmed
                    case "arming": phase = .arming(until: epoch.addingTimeInterval(5))
                    case "warning": phase = .suspicious(reason: "Bumped", until: now.addingTimeInterval(5))
                    case "alarm": phase = .alarm(reason: "Lifted")
                    case "welcome": phase = .welcomeBack(SessionSummaryBox(summary: summary))
                    default: phase = .armed
                    }
                    let state = GuardDisplayState(
                        phase: phase, now: now, note: name == "arming" ? "Back in 5" : nil,
                        expectedBack: phase.isGuarding && name != "warning" && name != "alarm" ? epoch.addingTimeInterval(300) : nil,
                        peopleSeen: name == "arming" ? 0 : 7, peopleInView: name == "watching" ? 0 : 1,
                        kioskFocused: true, lidWarning: false,
                        agentUpdate: name == "watching" ? "tests passing, 3/5 tasks done" : nil,
                        readiness: (["Motion", "Camera", "Lid", "Charger"], []), ownerAlerted: true)
                    let view = GuardScreenContent(state: state, eyes: eyes, renderedEyes: eyes.currentFrame())
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, .dark)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 1
                    guard let cg = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "MovieCapture", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Unable to render \(name) frame \(index)"])
                    }
                    try png.write(to: output.appendingPathComponent(String(format: "%04d.png", index)))
                }
            }
            print("Captured \(name): \(Int(duration * Double(fps))) native frames")
        }
        let manifest: [String: Any] = [
            "renderer": "GuardScreenContent + EyesRenderer (SwiftUI)",
            "fps": fps, "width": Int(size.width), "height": Int(size.height),
            "scenario": "Fictional café demo: 5 min, 7 passers-by, 1 close, bumped then lifted; Touch ID return",
            "clips": clips.map { ["id": $0.0, "duration": $0.1] as [String: Any] },
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("capture.json"))
    }
}
#endif
