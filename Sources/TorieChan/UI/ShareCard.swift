import AppKit
import GuardShared
import SwiftUI

/// A shareable "shift report" image: googly eyes + session stats. Never contains camera images.
@MainActor
enum ShareCard {
    static func render(_ summary: SessionSummary) -> URL? {
        let pose = EyesModel.preview(mood: summary.alarms.isEmpty ? .happy : .alarm).currentFrame()
        let renderer = ImageRenderer(content: CardView(summary: summary, pose: pose))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Torie-chan \(formatter.string(from: summary.startedAt)).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private struct CardView: View {
        let summary: SessionSummary
        let pose: EyesModel.Frame

        var body: some View {
            VStack(spacing: 0) {
                StaticEyesView(frame: pose)
                    .frame(height: 330)
                Text(verdict)
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(stats)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 10)
                Text("TORIE-CHAN")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 26)
            }
            .padding(.vertical, 36)
            .frame(width: 1200, height: 630)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        }

        private var verdict: String {
            if !summary.alarms.isEmpty { return "Caught one!" }
            if !summary.warnings.isEmpty { return "Had to give someone a look." }
            return "Guarded my laptop for \(summary.minutes) min"
        }

        private var stats: String {
            var parts = ["\(summary.peopleWalkedBy) passers-by"]
            if summary.gotClose > 0 { parts.append("\(summary.gotClose) got too close") }
            parts.append(summary.alarms.isEmpty ? "0 thieves" : "\(summary.alarms.count) alarm\(summary.alarms.count == 1 ? "" : "s")")
            return parts.joined(separator: " · ")
        }
    }
}
