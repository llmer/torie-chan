import SwiftUI

/// Torie-chan's eyes, redrawn every display refresh while the model is running.
struct EyesView: View {
    @ObservedObject var eyes: EyesModel

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !eyes.isRunning)) { context in
            let frame = eyes.frame(at: context.date.timeIntervalSinceReferenceDate)
            Canvas { gc, size in EyesRenderer.draw(frame, in: &gc, size: size) }
        }
        .accessibilityHidden(true) // decorative; state changes are announced as text
    }
}

/// A single pose, for offscreen renders (share card, contact sheets).
struct StaticEyesView: View {
    let frame: EyesModel.Frame

    var body: some View {
        Canvas { gc, size in EyesRenderer.draw(frame, in: &gc, size: size) }
            .accessibilityHidden(true)
    }
}

/// Flat kawaii drawing: no outlines, gloss, shadows or filters, so it stays cheap at 120 Hz
/// full screen. Highlights are fixed to the eye while the iris slides underneath them.
enum EyesRenderer {
    static let cream = Color(red: 1, green: 0.973, blue: 0.941)          // #FFF8F0
    static let irisTop = Color(red: 0.169, green: 0.137, blue: 0.314)    // #2B2350
    static let irisBottom = Color(red: 0.478, green: 0.416, blue: 0.941) // #7A6AF0
    static let pupil = Color(red: 0.071, green: 0.055, blue: 0.141)      // #120E24
    static let blush = Color(red: 1, green: 0.561, blue: 0.694)          // #FF8FB1

    static func draw(_ f: EyesModel.Frame, in gc: inout GraphicsContext, size: CGSize) {
        // Eye height: big enough to read across a café, but always fits the pane.
        let H = min(size.height * 0.40, size.width * 0.33)
        let eyeW = H * 0.66
        let dx = eyeW * 0.95

        // The closing lid is the underside of a bed coming down from the top. The eyes stay put
        // until its edge reaches them, then duck under it: the edge always covers the top of the
        // eyes a bit more the further it comes down, so they peer up and out from the gap.
        let edgeY = underEdge(f.hide, size)
        let eyeH = H * 0.92
        let covered = 0.1 + 0.2 * f.hide // never hide the pupils: they're doing the peering
        let restingY = size.height * 0.46
        let duckedY = edgeY - covered * eyeH + eyeH / 2
        let face = CGPoint(x: size.width / 2 + f.offset.x * H, y: max(restingY, duckedY) + f.offset.y * H)

        // Blush (behind everything), soft edge faked with two layers.
        if f.blush > 0.01 {
            for side in [-1.0, 1.0] {
                let c = CGPoint(x: face.x + side * (dx + eyeW * 0.15), y: face.y + H * 0.62)
                for (grow, alpha) in [(1.3, 0.45), (1.0, 1.0)] {
                    let w = eyeW * 0.55 * grow, h = eyeW * 0.16 * grow
                    gc.fill(Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)),
                            with: .color(blush.opacity(f.blush * alpha)))
                }
            }
        }

        for (isLeft, shape) in [(true, f.left), (false, f.right)] {
            var eye = gc
            eye.translateBy(x: face.x + (isLeft ? -dx : dx), y: face.y)
            drawEye(shape, isLeft: isLeft, flinch: f.flinch, in: &eye, w: eyeW, h: H)
        }

        drawMouth(f, in: &gc, at: CGPoint(x: face.x, y: face.y + H * 0.62), H: H)
        drawDecorations(f, in: &gc, face: face, dx: dx, eyeW: eyeW, H: H)
        drawUnderside(f.hide, edgeY: edgeY, in: &gc, size: size)
    }

    /// Where the bed's edge is: off the top of the screen when open, 62% down when nearly shut.
    private static func underEdge(_ hide: Double, _ size: CGSize) -> CGFloat {
        size.height * 0.62 * hide
    }

    /// The bed: a near-black underside with a rail along its edge and a soft shadow below it,
    /// drawn over the eyes so their tops disappear into the dark.
    private static func drawUnderside(_ hide: Double, edgeY: CGFloat, in gc: inout GraphicsContext, size: CGSize) {
        guard hide > 0.005 else { return }
        var c = gc
        c.opacity = smoothstep(0, 0.06, hide)
        let w = size.width
        let rail = size.height * 0.035
        c.fill(Path(CGRect(x: 0, y: 0, width: w, height: edgeY)), with: .color(Color(red: 0.02, green: 0.02, blue: 0.03)))
        c.fill(Path(CGRect(x: 0, y: edgeY - rail, width: w, height: rail)), with: .color(Color(red: 0.12, green: 0.11, blue: 0.15)))
        var rim = Path()
        rim.move(to: CGPoint(x: 0, y: edgeY - rail))
        rim.addLine(to: CGPoint(x: w, y: edgeY - rail))
        c.stroke(rim, with: .color(Color(red: 0.28, green: 0.27, blue: 0.34)), lineWidth: 1.5)
        let shadow = size.height * 0.09
        c.fill(Path(CGRect(x: 0, y: edgeY, width: w, height: shadow)),
               with: .linearGradient(Gradient(colors: [.black.opacity(0.6), .clear]),
                                     startPoint: CGPoint(x: 0, y: edgeY), endPoint: CGPoint(x: 0, y: edgeY + shadow)))
    }

    private static func drawEye(_ s: EyesModel.EyeShape, isLeft: Bool, flinch: Bool, in gc: inout GraphicsContext, w: CGFloat, h: CGFloat) {
        gc.scaleBy(x: s.scaleX, y: s.scaleY)

        if flinch {
            // > <
            let arm = h * 0.22, dir: CGFloat = isLeft ? 1 : -1
            var p = Path()
            p.move(to: CGPoint(x: -dir * arm * 0.6, y: -arm))
            p.addLine(to: CGPoint(x: dir * arm * 0.6, y: 0))
            p.addLine(to: CGPoint(x: -dir * arm * 0.6, y: arm))
            gc.stroke(p, with: .color(cream), style: StrokeStyle(lineWidth: h * 0.08, lineCap: .round, lineJoin: .round))
            return
        }

        let openAlpha = smoothstep(0.08, 0.2, s.open)
        if openAlpha < 0.999 {
            drawClosed(s.closedStyle, alpha: 1 - openAlpha, in: &gc, w: w, h: h)
        }
        guard openAlpha > 0.001 else { return }

        var e = gc
        e.opacity = openAlpha
        e.scaleBy(x: 1, y: max(0.02, s.open)) // blink: squash toward the center line
        let eyeRect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let eyePath = Path(ellipseIn: eyeRect)

        // Lids are clip masks (not filled shapes), so tinted backgrounds show through cleanly.
        if s.lidCut > 0.005 {
            let rise = tan(s.lidTilt * .pi / 180) * w / 2
            let line = -h / 2 + h * s.lidCut
            let inner = line + rise, outer = line - rise
            var keep = Path()
            keep.move(to: CGPoint(x: -w, y: isLeft ? outer : inner))
            keep.addLine(to: CGPoint(x: w, y: isLeft ? inner : outer))
            keep.addLine(to: CGPoint(x: w, y: h))
            keep.addLine(to: CGPoint(x: -w, y: h))
            keep.closeSubpath()
            e.clip(to: keep)
        }
        e.clip(to: eyePath)
        e.fill(eyePath, with: .color(cream))

        // Iris slides under fixed highlights; tanh keeps it off the rim.
        let iw = w * 0.80 * s.irisScale, ih = h * 0.80 * s.irisScale
        let ic = CGPoint(x: w * 0.14 * tanh(s.look.x), y: h * 0.10 * tanh(s.look.y))
        let iris = CGRect(x: ic.x - iw / 2, y: ic.y - ih / 2, width: iw, height: ih)
        e.fill(Path(ellipseIn: iris), with: .linearGradient(Gradient(colors: [irisTop, irisBottom]),
                                                             startPoint: CGPoint(x: ic.x, y: iris.minY),
                                                             endPoint: CGPoint(x: ic.x, y: iris.maxY)))
        let pw = iw * 0.42 * s.pupilScale, ph = ih * 0.50 * s.pupilScale
        e.fill(Path(ellipseIn: CGRect(x: ic.x - pw / 2, y: ic.y - ph / 2, width: pw, height: ph)), with: .color(pupil))

        let baseIW = w * 0.80
        func dot(_ cx: CGFloat, _ cy: CGFloat, _ d: CGFloat) {
            e.fill(Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)), with: .color(.white))
        }
        dot(-0.22 * baseIW, -0.26 * h * 0.80, 0.30 * baseIW)
        dot(0.20 * baseIW, 0.24 * h * 0.80, 0.12 * baseIW)
    }

    private static func drawClosed(_ style: EyesModel.ClosedStyle, alpha: Double, in gc: inout GraphicsContext, w: CGFloat, h: CGFloat) {
        let half = w * 0.45
        var p = Path()
        p.move(to: CGPoint(x: -half, y: 0))
        switch style {
        case .happy:  p.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: -h * 0.28)) // ^
        case .sleepy: p.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: h * 0.24))  // ‿
        case .lash:   p.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: h * 0.12))
        }
        let lineWidth = style == .happy ? h * 0.08 : h * 0.07
        gc.stroke(p, with: .color(cream.opacity(alpha * (style == .sleepy ? 0.75 : 1))),
                  style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private static func drawMouth(_ f: EyesModel.Frame, in gc: inout GraphicsContext, at c: CGPoint, H: CGFloat) {
        guard f.mouthAlpha > 0.01 else { return }
        let style = StrokeStyle(lineWidth: H * 0.035, lineCap: .round, lineJoin: .round)
        let color = Color(cream).opacity(min(1, f.mouthAlpha))
        let half = H * 0.10
        var p = Path()
        switch f.mood {
        case .happy: // ω
            p.move(to: CGPoint(x: c.x - half, y: c.y - H * 0.02))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - H * 0.02), control: CGPoint(x: c.x - half / 2, y: c.y + H * 0.07))
            p.addQuadCurve(to: CGPoint(x: c.x + half, y: c.y - H * 0.02), control: CGPoint(x: c.x + half / 2, y: c.y + H * 0.07))
        case .angry: // ︿
            p.move(to: CGPoint(x: c.x - half * 0.8, y: c.y + H * 0.03))
            p.addQuadCurve(to: CGPoint(x: c.x + half * 0.8, y: c.y + H * 0.03), control: CGPoint(x: c.x, y: c.y - H * 0.05))
        case .alarm: // O
            p.addEllipse(in: CGRect(x: c.x - H * 0.07, y: c.y - H * 0.09, width: H * 0.14, height: H * 0.18))
        default:
            return
        }
        gc.stroke(p, with: .color(color), style: style)
    }

    private static func drawDecorations(_ f: EyesModel.Frame, in gc: inout GraphicsContext, face: CGPoint, dx: CGFloat, eyeW: CGFloat, H: CGFloat) {
        let t = f.time
        let rightEye = CGPoint(x: face.x + dx, y: face.y)
        let leftEye = CGPoint(x: face.x - dx, y: face.y)

        // Anger mark (suspicious) and !! (alarm): manga marks that read instantly from across the room.
        if f.iconAlpha > 0.01 {
            if f.mood == .alarm {
                let pulse = 1 + 0.08 * sin(2 * .pi * 2 * t)
                let text = gc.resolve(Text("!!").font(.system(size: H * 0.26 * pulse, weight: .black, design: .rounded)).foregroundStyle(cream))
                var c = gc
                c.opacity = f.iconAlpha
                c.draw(text, at: CGPoint(x: face.x, y: face.y - H * 0.72), anchor: .center)
            } else if f.mood == .angry {
                let pulse = 1 + 0.06 * sin(2 * .pi * 1.5 * t)
                var c = gc
                c.opacity = f.iconAlpha
                c.stroke(angerMark(at: CGPoint(x: rightEye.x + eyeW * 0.66, y: rightEye.y - H * 0.5), size: H * 0.1 * pulse),
                         with: .color(Color(red: 1, green: 0.3, blue: 0.43)),
                         style: StrokeStyle(lineWidth: H * 0.03, lineCap: .round))
            }
        }

        // Drifting z's while asleep.
        if f.mood == .sleepy {
            for i in 0..<3 {
                let phase = (t / 2.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let alpha = sin(phase * .pi) * 0.7
                let text = gc.resolve(Text("z").font(.system(size: H * (0.1 + 0.08 * phase), weight: .heavy, design: .rounded))
                    .foregroundStyle(cream))
                var c = gc
                c.opacity = alpha
                c.draw(text, at: CGPoint(x: rightEye.x + eyeW * (0.5 + 0.3 * phase), y: rightEye.y - H * (0.25 + 0.45 * phase)), anchor: .center)
            }
        }

        // Sparkle when someone's close.
        if f.sparkle > 0.01 {
            let r = eyeW * 0.1 * (1 + 0.15 * sin(4 * t)) * f.sparkle
            let c = CGPoint(x: leftEye.x - eyeW * 0.62, y: leftEye.y + H * 0.38)
            gc.fill(star(at: c, radius: r), with: .color(cream.opacity(f.sparkle)))
        }

        // Sweat drop while the lid closes in, sliding down a little.
        if f.sweat > 0.01 {
            let slide = (t * 0.7).truncatingRemainder(dividingBy: 1)
            let c = CGPoint(x: rightEye.x + eyeW * 0.68, y: rightEye.y - H * 0.08 + H * 0.08 * slide)
            let r = H * 0.055
            var drop = Path()
            drop.move(to: CGPoint(x: c.x, y: c.y - r * 2.1))
            drop.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * 0.9, y: c.y - r * 1.2))
            drop.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            drop.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r * 2.1), control: CGPoint(x: c.x - r * 0.9, y: c.y - r * 1.2))
            gc.fill(drop, with: .color(Color(red: 0.56, green: 0.83, blue: 1).opacity(f.sweat * (1 - 0.5 * slide))))
        }

        // "Ta-da!" sparkle burst after peeking back out.
        if f.burst > 0 {
            let size = eyeW * 0.09 * sin(.pi * f.burst)
            let radius = H * (0.55 + 0.25 * f.burst)
            for eye in [leftEye, rightEye] {
                for k in 0..<4 {
                    let angle = CGFloat(k) * .pi / 2 + .pi / 4
                    let c = CGPoint(x: eye.x + radius * cos(angle) * 0.8, y: eye.y + radius * sin(angle))
                    gc.fill(star(at: c, radius: size), with: .color(cream))
                }
            }
        }

        // Skeptical brow dash over one eye.
        if f.browAlpha > 0.01 {
            var c = gc
            c.translateBy(x: rightEye.x, y: rightEye.y - H * 0.62)
            c.rotate(by: .degrees(-10))
            var p = Path()
            p.move(to: CGPoint(x: -eyeW * 0.175, y: 0))
            p.addLine(to: CGPoint(x: eyeW * 0.175, y: 0))
            c.stroke(p, with: .color(cream.opacity(f.browAlpha)), style: StrokeStyle(lineWidth: H * 0.04, lineCap: .round))
        }
    }

    /// Manga anger mark: four rounded corner pieces (like ╯╰ over ╮╭) whose arms run out along
    /// the axes and whose bends are pulled in toward the center, leaving a plus-shaped gap.
    private static func angerMark(at c: CGPoint, size L: CGFloat) -> Path {
        let g = L * 0.3 // half-width of the plus-shaped gap
        var p = Path()
        for (sx, sy) in [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] {
            p.move(to: CGPoint(x: c.x + sx * g, y: c.y + sy * L))
            p.addQuadCurve(to: CGPoint(x: c.x + sx * L, y: c.y + sy * g),
                           control: CGPoint(x: c.x + sx * g * 0.35, y: c.y + sy * g * 0.35))
        }
        return p
    }

    /// Four-point sparkle.
    private static func star(at c: CGPoint, radius r: CGFloat) -> Path {
        var p = Path()
        for k in 0..<8 {
            let angle = CGFloat(k) * .pi / 4 - .pi / 2
            let rr = k.isMultiple(of: 2) ? r : r * 0.32
            let point = CGPoint(x: c.x + rr * cos(angle), y: c.y + rr * sin(angle))
            if k == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
