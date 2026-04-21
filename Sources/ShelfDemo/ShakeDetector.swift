import AppKit
import QuartzCore

/// Detects a horizontal "shake" gesture during a left-mouse drag anywhere on the system.
/// Works while the user is actively dragging files out of Finder (or anything else).
///
/// Note: macOS may prompt for accessibility permission the first time a global monitor is
/// installed in some environments. Mouse-drag monitoring generally works without it, but
/// if shakes aren't detected, grant the app access under System Settings → Privacy &
/// Security → Accessibility.
final class ShakeDetector {
    var onShake: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private struct Sample {
        let time: CFTimeInterval
        let x: CGFloat
    }

    private var samples: [Sample] = []
    private var lastShakeTime: CFTimeInterval = 0

    // Tunables
    private let window: CFTimeInterval = 0.45
    private let minReversals = 4           // ≥2 full back-and-forth sweeps
    private let minTravelPerLeg: CGFloat = 12
    private let cooldown: CFTimeInterval = 0.8

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        samples.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            samples.removeAll()
        case .leftMouseDragged:
            let now = CACurrentMediaTime()
            let x = NSEvent.mouseLocation.x
            samples.append(Sample(time: now, x: x))
            samples.removeAll { now - $0.time > window }
            if detectShake() {
                guard now - lastShakeTime > cooldown else { return }
                lastShakeTime = now
                samples.removeAll()
                DispatchQueue.main.async { [weak self] in
                    self?.onShake?()
                }
            }
        default:
            break
        }
    }

    private func detectShake() -> Bool {
        guard samples.count >= 4 else { return false }

        var reversals = 0
        var legTravel: CGFloat = 0
        var lastDir: Int = 0

        for i in 1..<samples.count {
            let dx = samples[i].x - samples[i - 1].x
            let dir = dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0)
            if dir == 0 { continue }

            if dir == lastDir {
                legTravel += abs(dx)
            } else {
                if lastDir != 0 && legTravel >= minTravelPerLeg {
                    reversals += 1
                }
                legTravel = abs(dx)
                lastDir = dir
            }
        }
        return reversals >= minReversals
    }
}
