// Renders Torie-chan's app icon with the app's own eye renderer.
//   scripts/build-icon-tool.sh
//   build/make-icon <out.png> [close|calm|happy]   (or just: make icon)
//   build/make-icon <out.png> dmg|dmg@2x            disk image window background
import AppKit
import SwiftUI

@MainActor
struct IconView: View {
    let frame: EyesModel.Frame
    let blush: Bool

    var body: some View {
        // macOS icon grid: 1024 canvas, 824 artwork squircle, soft drop shadow.
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.18, blue: 0.42), Color(red: 0.07, green: 0.06, blue: 0.16)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 3)
                )
                .overlay(
                    StaticEyesView(frame: frame)
                        .frame(width: 1000, height: 820)
                        .offset(y: 40)
                )
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 14)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Background for the disk image window (660 x 400 pt): app on the left at (170, 190), the
/// Applications shortcut on the right at (490, 190), an arrow between them.
@MainActor
struct DMGBackground: View {
    let eyes: EyesModel.Frame

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.32), Color(red: 0.06, green: 0.05, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
            StaticEyesView(frame: eyes)
                .frame(width: 160, height: 90)
                .position(x: 330, y: 62)
            Text("Drag Torie-chan into Applications")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 660)
                .position(x: 330, y: 318)
            Canvas { gc, _ in
                var arrow = Path()
                arrow.move(to: CGPoint(x: 262, y: 190))
                arrow.addLine(to: CGPoint(x: 392, y: 190))
                arrow.move(to: CGPoint(x: 376, y: 176))
                arrow.addLine(to: CGPoint(x: 394, y: 190))
                arrow.addLine(to: CGPoint(x: 376, y: 204))
                gc.stroke(arrow, with: .color(.white.opacity(0.35)),
                          style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 660, height: 400)
    }
}

@MainActor func render() {
    let args = CommandLine.arguments
    let out = URL(fileURLWithPath: args[1])
    let variant = args.count > 2 ? args[2] : "close"
    if variant.hasPrefix("dmg") {
        let renderer = ImageRenderer(content: DMGBackground(eyes: EyesModel.preview(mood: .calm, lookAt: CGPoint(x: -0.6, y: 0.3)).currentFrame()))
        renderer.scale = variant == "dmg@2x" ? 2 : 1
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
        try! png.write(to: out)
        return
    }
    let model: EyesModel = switch variant {
    case "close": EyesModel.preview(mood: .calm, lookAt: CGPoint(x: 0, y: -0.1), close: true)
    case "happy": EyesModel.preview(mood: .happy)
    default: EyesModel.preview(mood: .calm, lookAt: CGPoint(x: 0.35, y: -0.25))
    }
    let renderer = ImageRenderer(content: IconView(frame: model.currentFrame(), blush: variant == "close"))
    renderer.scale = 1
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        exit(1)
    }
    try! png.write(to: out)
}

MainActor.assumeIsolated { render() }
