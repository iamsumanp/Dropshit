import AppKit
import SwiftUI

final class FloatingPanel<Content: View>: NSPanel {
    init(contentRect: NSRect, @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow

        let root = FloatingPanelRootView(frame: contentRect)
        root.wantsLayer = true
        root.layer?.cornerRadius = 22
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true

        // Liquid-glass approximation: HUD-style vibrant blur behind a
        // specular highlight gradient and a subtle inner stroke. When the
        // project moves to the macOS 26 SDK, swap `FloatingPanelContent`
        // for a `.glassEffect(in: RoundedRectangle(...))` wrapper and
        // drop the blur view.
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.isEmphasized = false
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.translatesAutoresizingMaskIntoConstraints = false

        let hosting = FirstMouseHostingView(
            rootView: FloatingPanelContent(content: content)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(blur)
        root.addSubview(hosting)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            hosting.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that delivers the first click even when the panel isn't key.
/// Without this, clicks on a non-key `.nonactivatingPanel` only bring the panel
/// to key state and the underlying SwiftUI view never sees the event.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Injects `QuickLookController.shared` into the shelf panel's responder chain
/// so QLPreviewPanel can discover a controller and the space key is routed to it.
private final class FloatingPanelRootView: NSView {
    override var nextResponder: NSResponder? {
        get {
            QuickLookController.shared.nextResponder = super.nextResponder
            return QuickLookController.shared
        }
        set { super.nextResponder = newValue }
    }

    override var acceptsFirstResponder: Bool { true }
}

private struct FloatingPanelContent<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Flat darkening wash — uniform top to bottom.
            Color.black.opacity(0.20)
                .allowsHitTesting(false)

            // Subtle even stroke — no top-weighted gradient.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                .allowsHitTesting(false)

            // No padding here — each shelf view applies its own margin so
            // that compact states (e.g. docked) can fill the panel edge-to-
            // edge and accept drops across the full visible surface.
            content
        }
        .ignoresSafeArea()
    }
}
