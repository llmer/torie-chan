import CoreGraphics
import Foundation

/// Stitches per-frame face/body detections into people: each gets an ID, is confirmed after 3
/// sightings, coasts through brief misses, and is dropped after 1.5 s unseen. Also picks who the
/// eyes follow (sticky unless someone is clearly more prominent), and reports arrivals, departures,
/// approaches and lingering. Pure logic, so it can be tested without a camera.
struct PeopleTracker {
    struct Track {
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

    private(set) var tracks: [Track] = []
    private var nextTrackID = 1

    private(set) var lastTarget: CGPoint?

    mutating func reset() {
        tracks.removeAll()
        primaryID = nil
        lastTarget = nil
    }

    mutating func update(faces: [CGRect], bodies: [CGRect], now: TimeInterval) -> PersonTracker.Observation {
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
            guard let best = unmatched.max(by: { Self.score(predicted, detections[$0].rect) < Self.score(predicted, detections[$1].rect) }),
                  Self.score(predicted, detections[best].rect) > 0.15 else { continue }
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
            Self.updateAim(&tracks[t], d.rect, faceCenter: d.faceCenter, isBody: d.isBody)
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
            Self.updateAim(&tracks[tracks.count - 1], detections[i].rect, faceCenter: detections[i].faceCenter, isBody: detections[i].isBody)
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
        return PersonTracker.Observation(count: visible.count, lookAt: lookAt, isClose: visible.contains { $0.faceHeight > 0.3 },
                           arrived: arrived, departed: departed, lingerStarted: lingerStarted, approaching: approaching)
    }

    private static func updateAim(_ track: inout Track, _ rect: CGRect, faceCenter: CGPoint?, isBody: Bool) {
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

    private static func score(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
}
