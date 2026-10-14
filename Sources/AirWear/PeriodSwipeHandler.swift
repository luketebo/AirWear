import AppKit
import SwiftUI

/// Observe trackpad scroll gestures inside the report without intercepting vertical scrolling.
struct PeriodSwipeHandler: NSViewRepresentable {
    var enabled: Bool
    var navigate: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.navigate = navigate
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var enabled = false
        var navigate: ((Int) -> Void)?
        private var monitor: Any?
        private var horizontal: CGFloat = 0
        private var vertical: CGFloat = 0
        private var didNavigate = false

        func install(on view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let self, let view, self.enabled,
                      let window = view.window, event.window === window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                      event.hasPreciseScrollingDeltas else { return event }
                if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                    self.horizontal = 0
                    self.vertical = 0
                    self.didNavigate = false
                }
                // Momentum belongs to the same swipe and must never advance another period.
                guard event.momentumPhase.isEmpty, !event.phase.isEmpty else { return event }
                self.horizontal += event.scrollingDeltaX
                self.vertical += event.scrollingDeltaY
                let isHorizontal = abs(self.horizontal) > 50 && abs(self.horizontal) > abs(self.vertical) * 1.5
                guard isHorizontal else { return event }
                if !self.didNavigate {
                    self.didNavigate = true
                    self.navigate?(self.horizontal > 0 ? -1 : 1)
                }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
