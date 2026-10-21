// Renders Torie-chan's app icon with the app's own eye renderer.
//   swiftc -O -swift-version 5 Sources/TorieChan/UI/EyesView.swift Sources/TorieChan/UI/EyesModel.swift \
//     Sources/TorieChan/Sensors/PersonTracker.swift scripts/icon/main.swift -o build/make-icon
//   build/make-icon <out.png> [close|calm|happy]   (or just: make icon)
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

@MainActor func render() {
    let args = CommandLine.arguments
    let out = URL(fileURLWithPath: args[1])
    let variant = args.count > 2 ? args[2] : "close"
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
