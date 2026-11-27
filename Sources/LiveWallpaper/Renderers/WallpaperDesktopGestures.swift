import Foundation

/// Keeps down, drag and up in their original order while a renderer checks
/// the point of the press. A second click can arrive before the first reply.
final class WallpaperDesktopGestures {
    enum Source { case monitor, panel }
    private typealias Event = (phase: WallpaperPointerPhase, point: CGPoint, count: Int)
    private final class Gesture {
        let source: Source
        var allowed: Bool?
        var events: [Event] = []
        var finished = false
        init(source: Source, allowed: Bool?) {
            self.source = source
            self.allowed = allowed
        }
    }

    private let deliver: (WallpaperPointerPhase, CGPoint, Int) -> Void
    private var pending: [Gesture] = []
    private var active: Gesture?
    private var deliveredPoint: CGPoint?
    var isTrackingPanel: Bool { active?.source == .panel }

    init(deliver: @escaping (WallpaperPointerPhase, CGPoint, Int) -> Void) {
        self.deliver = deliver
    }

    func receive(_ phase: WallpaperPointerPhase, at point: CGPoint, count: Int, from source: Source,
                 validate: ((@escaping (Bool) -> Void) -> Void)? = nil) {
        if phase == .down {
            if let active {
                active.events.append((.cancel, point, 0))
                active.finished = true
            }
            let press = Gesture(source: source, allowed: validate == nil ? true : nil)
            press.events.append((phase, point, count))
            pending.append(press)
            active = press
            if let validate {
                validate { [weak self, weak press] allowed in
                    press?.allowed = allowed
                    self?.drain()
                }
            }
        } else {
            guard let press = active, press.source == source else { return }
            press.events.append((phase, point, count))
            if phase == .up || phase == .cancel {
                press.finished = true
                active = nil
            }
        }
        drain()
    }

    func reset() {
        active = nil
        pending.removeAll()
        if let point = deliveredPoint {
            deliveredPoint = nil
            deliver(.cancel, point, 0)
        }
    }

    private func drain() {
        while let press = pending.first, let allowed = press.allowed {
            let events = press.events
            press.events.removeAll(keepingCapacity: true)
            if allowed {
                for event in events {
                    deliveredPoint = event.phase == .up || event.phase == .cancel ? nil : event.point
                    deliver(event.phase, event.point, event.count)
                }
            }
            guard press.finished else { return }
            pending.removeFirst()
        }
    }
}
