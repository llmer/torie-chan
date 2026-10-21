import AVFoundation
import CoreImage
import Foundation
import Vision

/// Watches the built-in camera with Vision (runs on the Neural Engine).
///
/// - People: face + body rectangles, stitched into tracks so each person is counted once, with
///   approach / linger detection. No face landmarks or templates are ever computed.
/// - Scene: once a second, compares the background against a reference frame taken when armed.
///   If the whole view has shifted, the laptop moved (catches level lifts and slow slides the
///   IMU can miss). A near-black frame means the camera was covered.
///
/// Frames are processed in memory and dropped; the only thing ever written to disk is an alarm snapshot.
final class PersonTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Observation {
        /// Confirmed people currently in view.
        var count: Int
        /// Where the eyes should look, in -1...1 screen space (x right, y down), already mirrored.
        var lookAt: CGPoint?
        /// Someone's face fills a big chunk of the frame: they're right at the laptop.
        var isClose: Bool
        /// People confirmed for the first time this frame (for "walked by" counts).
        var arrived: Int
        /// Confirmed people who left this frame.
        var departed: Int
        /// Someone has stayed close for a while (reported once per person).
        var lingerStarted: Bool
        /// Someone is closing in fast.
        var approaching: Bool
    }

    struct Scene {
        /// Fraction of frame width the background has shifted since the reference.
        var shift: Double
        var covered: Bool
    }

    enum CameraState: String {
        case off, running, denied, unavailable, notAsked
    }

    /// Developer Tools: the exact frame Vision analyzed, plus everything it found.
    struct DebugFrame {
        struct Track {
            var id: Int
            var rect: CGRect
            var confirmed: Bool
            var hits: Int
            var faceHeight: CGFloat
            var closeFor: TimeInterval?
            var lingering: Bool
        }

        var image: CGImage
        /// All rects are Vision-normalized: 0...1, origin bottom-left, unmirrored.
        var faces: [CGRect]
        var bodies: [(rect: CGRect, confidence: Float)]
        var tracks: [Track]
        var target: CGPoint?
        var processingMs: Double
        var visionFPS: Double
        var sceneShift: Double?
        var luma: Double?
    }

    var onObservation: ((Observation) -> Void)?
    var onScene: ((Scene) -> Void)?
    var onDebug: ((DebugFrame) -> Void)?
    private(set) var state: CameraState = .off
    /// Exposed for the on-screen "you're on camera" mirror. Display only.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "toriechan.camera")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var configured = false
    private var lastProcessed = CMTime.zero
    private var lastSceneCheck = CMTime.zero
    private var lowPower = false
    private var debugEnabled = false
    private var lastTarget: CGPoint?
    private var lastShift: Double?
    private var lastLuma: Double?
    private var processedTimes: [TimeInterval] = []

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let bodyRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false
        return r
    }()

    private let latestLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var sceneReference: CGImage?
    private var wantsSceneReference = false

    // Tracking (camera queue only)
    private struct Track {
        let id: Int
        var rect: CGRect
        var velocity: CGVector
        var lastSeen: TimeInterval
        var hits: Int
        var confirmed: Bool
        var faceHeight: CGFloat
        var closeSince: TimeInterval?
        var lingerReported: Bool
        var areaHistory: [(TimeInterval, CGFloat)]
        /// Smoothed point the eyes aim at (Vision coords).
        var aim: CGPoint?
        /// Where the face sits relative to the body box's head estimate, learned while both are
        /// visible, so the aim doesn't jump when face detection drops out for a frame.
        var faceOffset: CGVector?
    }

    /// The person the eyes are following; kept unless someone else is clearly more prominent.
    private var primaryID: Int?

    private var tracks: [Track] = []
    private var nextTrackID = 1

    /// Only starts if permission was already granted in Settings, so a system prompt can never
    /// appear underneath the kiosk window.
    func start(completion: @escaping (CameraState) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            state = .notAsked
            return completion(.notAsked)
        default:
            state = .denied
            return completion(.denied)
        }
        queue.async {
            if !self.configured { self.configured = self.configure() }
            let ok = self.configured
            if ok, !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.state = ok ? .running : .unavailable
                completion(self.state)
            }
        }
    }

    /// `wait`: block until the camera is released (so another tracker can take it right after).
    func stop(wait: Bool = false) {
        let work = {
            if self.session.isRunning { self.session.stopRunning() }
            self.latestLock.withLock { self.latestBuffer = nil }
            self.tracks.removeAll()
            self.sceneReference = nil
            self.wantsSceneReference = false
            self.lastShift = nil
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
        state = .off
    }

    /// Developer Tools mode: steady 10 fps and a DebugFrame per analyzed frame.
    func setDebug(_ on: Bool) {
        queue.async { self.debugEnabled = on }
    }

    /// Pause capture without forgetting the scene reference (lid closed: the camera sees black anyway).
    func pause() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func resume() {
        queue.async { if self.configured, !self.session.isRunning { self.session.startRunning() } }
    }

    func setLowPower(_ on: Bool) {
        queue.async { self.lowPower = on }
    }

    /// Take the next frame as "where the laptop was left".
    func captureSceneReference() {
        queue.async {
            self.sceneReference = nil
            self.wantsSceneReference = true
        }
    }

    /// JPEG of the most recent frame, for "who grabbed my laptop" evidence.
    func snapshotJPEG() -> Data? {
        guard let buffer = latestLock.withLock({ latestBuffer }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.jpegRepresentation(of: image, colorSpace: space,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
    }

    private func configure() -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .low
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        session.commitConfiguration()

        limitFrameRate(device, to: 10)
        return true
    }

    /// Cap capture at `fps` to save power, but only with a rate the active format supports:
    /// setting an unsupported duration throws an Objective-C exception (an instant crash).
    /// Must run after the session configuration is committed, once the format is final.
    private func limitFrameRate(_ device: AVCaptureDevice, to fps: Double) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let duration: CMTime
        if ranges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) {
            duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        } else if let slowest = ranges.min(by: { $0.minFrameRate < $1.minFrameRate }) {
            duration = slowest.maxFrameDuration
        } else {
            return
        }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = duration
        device.unlockForConfiguration()
    }


    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Vision rate: 3 fps when nobody's around, 8 fps while tracking someone, 2 fps when hot.
        let fps: Int32 = debugEnabled ? 10 : lowPower ? 2 : (tracks.isEmpty ? 3 : 8)
        guard CMTimeSubtract(time, lastProcessed) >= CMTime(value: 1, timescale: fps),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = time
        latestLock.withLock { latestBuffer = buffer }

        let started = CFAbsoluteTimeGetCurrent()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([faceRequest, bodyRequest])
        let faces = (faceRequest.results ?? []).map(\.boundingBox)
        let bodyObservations = (bodyRequest.results ?? []).filter { $0.confidence > 0.5 }
        let bodies = bodyObservations.map(\.boundingBox)
        let observation = updateTracks(faces: faces, bodies: bodies, now: time.seconds)
        DispatchQueue.main.async { self.onObservation?(observation) }

        if wantsSceneReference || ((sceneReference != nil || debugEnabled) && CMTimeSubtract(time, lastSceneCheck).seconds >= 1) {
            lastSceneCheck = time
            checkScene(buffer)
        }

        if debugEnabled {
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            processedTimes.append(time.seconds)
            processedTimes.removeAll { time.seconds - $0 > 2 }
            let fpsNow = processedTimes.count > 1 ? Double(processedTimes.count - 1) / (processedTimes.last! - processedTimes.first!) : 0
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = ciContext.createCGImage(image, from: image.extent) {
                let now = time.seconds
                let frame = DebugFrame(
                    image: cg, faces: faces,
                    bodies: bodyObservations.map { ($0.boundingBox, $0.confidence) },
                    tracks: tracks.map { t in
                        DebugFrame.Track(id: t.id, rect: t.rect, confirmed: t.confirmed, hits: t.hits, faceHeight: t.faceHeight,
                                         closeFor: t.closeSince.map { now - $0 }, lingering: t.lingerReported)
                    },
                    target: lastTarget, processingMs: elapsed, visionFPS: fpsNow, sceneShift: lastShift, luma: lastLuma)
                DispatchQueue.main.async { self.onDebug?(frame) }
            }
        }
    }

    // MARK: - Tracking

    private func updateTracks(faces: [CGRect], bodies: [CGRect], now: TimeInterval) -> Observation {
        // One detection per person: bodies, plus faces that aren't inside a detected body.
        var detections: [(rect: CGRect, face: CGFloat, faceCenter: CGPoint?, isBody: Bool)] = bodies.map { body in
            let face = faces.first { body.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            return (body, face?.height ?? 0, face.map { CGPoint(x: $0.midX, y: $0.midY) }, true)
        }
        for face in faces where !bodies.contains(where: { $0.contains(CGPoint(x: face.midX, y: face.midY)) }) {
            detections.append((face, face.height, CGPoint(x: face.midX, y: face.midY), false))
        }

        var unmatched = Array(detections.indices)
        var arrived = 0
        var lingerStarted = false
        var approaching = false
        for t in tracks.indices {
            let dt = now - tracks[t].lastSeen
            let predicted = tracks[t].rect.offsetBy(dx: tracks[t].velocity.dx * dt, dy: tracks[t].velocity.dy * dt)
            guard let best = unmatched.max(by: { score(predicted, detections[$0].rect) < score(predicted, detections[$1].rect) }),
                  score(predicted, detections[best].rect) > 0.15 else { continue }
            unmatched.removeAll { $0 == best }
            let d = detections[best]
            if dt > 0 {
                tracks[t].velocity = CGVector(dx: (d.rect.midX - tracks[t].rect.midX) / dt * 0.5 + tracks[t].velocity.dx * 0.5,
                                              dy: (d.rect.midY - tracks[t].rect.midY) / dt * 0.5 + tracks[t].velocity.dy * 0.5)
            }
            tracks[t].rect = d.rect
            tracks[t].lastSeen = now
            tracks[t].hits += 1
            tracks[t].faceHeight = d.face
            updateAim(&tracks[t], d.rect, faceCenter: d.faceCenter, isBody: d.isBody)
            if !tracks[t].confirmed, tracks[t].hits >= 3 {
                tracks[t].confirmed = true
                arrived += 1
            }

            // Linger: face reasonably big (within ~1.5m) for 6s+.
            if d.face > 0.2 {
                if tracks[t].closeSince == nil { tracks[t].closeSince = now }
                if !tracks[t].lingerReported, now - tracks[t].closeSince! > 6 {
                    tracks[t].lingerReported = true
                    lingerStarted = true
                }
            } else {
                tracks[t].closeSince = nil
            }

            // Approach: box area growing >30%/s over the last second.
            let area = d.rect.width * d.rect.height
            tracks[t].areaHistory.append((now, area))
            tracks[t].areaHistory.removeAll { now - $0.0 > 1.2 }
            if let first = tracks[t].areaHistory.first, now - first.0 > 0.5, first.1 > 0,
               (area / first.1 - 1) / CGFloat(now - first.0) > 0.3, tracks[t].confirmed {
                approaching = true
            }
        }
        for i in unmatched {
            tracks.append(Track(id: nextTrackID, rect: detections[i].rect, velocity: .zero, lastSeen: now, hits: 1,
                                confirmed: false, faceHeight: detections[i].face, closeSince: nil, lingerReported: false,
                                areaHistory: [(now, detections[i].rect.width * detections[i].rect.height)], aim: nil, faceOffset: nil))
            updateAim(&tracks[tracks.count - 1], detections[i].rect, faceCenter: detections[i].faceCenter, isBody: detections[i].isBody)
            nextTrackID += 1
        }
        let departed = tracks.filter { $0.confirmed && now - $0.lastSeen > 1.5 }.count
        tracks.removeAll { now - $0.lastSeen > 1.5 }

        let visible = tracks.filter { $0.confirmed && $0.lastSeen == now }
        // Gaze target: coast on people seen in the last half second (a single missed detection
        // shouldn't make the eyes look away), and stick with the current person unless someone
        // else is clearly more prominent.
        let recent = tracks.filter { $0.confirmed && now - $0.lastSeen < 0.5 }
        func area(_ t: Track) -> CGFloat { t.rect.width * t.rect.height }
        let biggest = recent.max { area($0) < area($1) }
        if let current = recent.first(where: { $0.id == primaryID }), let biggest, area(biggest) < area(current) * 1.5 {
            // keep following the current person
        } else {
            primaryID = biggest?.id
        }
        let target = recent.first { $0.id == primaryID }?.aim
        lastTarget = target
        // Vision coords: origin bottom-left in the (unmirrored) camera image.
        // Mirror x so the eyes look toward the person, flip y for screen space.
        let lookAt = target.map { CGPoint(x: -($0.x - 0.5) * 2, y: -($0.y - 0.5) * 2) }
        return Observation(count: visible.count, lookAt: lookAt, isClose: visible.contains { $0.faceHeight > 0.3 },
                           arrived: arrived, departed: departed, lingerStarted: lingerStarted, approaching: approaching)
    }

    private func updateAim(_ track: inout Track, _ rect: CGRect, faceCenter: CGPoint?, isBody: Bool) {
        // Roughly where a head is on a body box.
        let head = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.85)
        let point: CGPoint
        if let face = faceCenter {
            if isBody {
                let offset = CGVector(dx: face.x - head.x, dy: face.y - head.y)
                track.faceOffset = track.faceOffset.map { CGVector(dx: $0.dx * 0.7 + offset.dx * 0.3, dy: $0.dy * 0.7 + offset.dy * 0.3) } ?? offset
            }
            point = face
        } else if isBody {
            let o = track.faceOffset ?? .zero
            point = CGPoint(x: head.x + o.dx, y: head.y + o.dy)
        } else {
            point = CGPoint(x: rect.midX, y: rect.midY)
        }
        // Light per-track smoothing; the eyes smooth further on their side.
        track.aim = track.aim.map { CGPoint(x: $0.x + (point.x - $0.x) * 0.5, y: $0.y + (point.y - $0.y) * 0.5) } ?? point
    }

    private func score(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    // MARK: - Scene

    private func checkScene(_ buffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 160 / max(image.extent.width, 1)
        let small = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let cg = ciContext.createCGImage(small, from: small.extent) else { return }

        let luma = averageLuma(small)
        lastLuma = luma
        let covered = luma < 0.05
        if wantsSceneReference {
            wantsSceneReference = false
            if !covered { sceneReference = cg }
            return
        }
        guard let reference = sceneReference else {
            lastShift = nil
            return
        }

        var shift = 0.0
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: cg)
        if (try? VNImageRequestHandler(cgImage: reference).perform([request])) != nil,
           let alignment = request.results?.first {
            let t = alignment.alignmentTransform
            shift = Double(hypot(t.tx, t.ty)) / Double(small.extent.width)
        }
        lastShift = shift
        let scene = Scene(shift: shift, covered: covered)
        DispatchQueue.main.async { self.onScene?(scene) }
    }

    private func averageLuma(_ image: CIImage) -> Double {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Double(pixel[0]) / 255
    }
}
