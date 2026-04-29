import SwiftUI

struct CollapsedShelfView: View {
    let namespace: Namespace.ID
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    var items: [ShelfItem] = []
    var isDragging: Bool = false
    /// Owned by the parent so the flag survives the expanded↔collapsed
    /// view swap. Lets us show the X on the empty state after the user
    /// has emptied a shelf, while keeping it hidden during an in-flight
    /// shake gesture (shelf starts empty and items haven't landed yet).
    var showCloseWhenEmpty: Bool = false
    var onClose: () -> Void = {}
    var onOpenDocuments: () -> Void = {}
    var onDock: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}

    @State private var stackHovering = false

    private var shelf: Shelf? { manager.shelf(id: shelfID) }

    private var pillTitle: String {
        if let n = shelf?.name, !n.isEmpty { return n }
        if items.count == 1 { return items[0].displayName }
        return "\(items.count) Files"
    }

    var body: some View {
        ZStack {
            if items.isEmpty {
                Text("Drop files here")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)

                if showCloseWhenEmpty {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            CircularIconButton(systemName: "xmark", action: onClose)
                            Spacer()
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                StackedDocumentPreview(
                    namespace: namespace,
                    items: items,
                    onDragStart: onDragStart,
                    onDragEnd: onDragEnd
                )
                .scaleEffect(stackHovering ? 1.03 : 1.0)
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: stackHovering)
                .onHover { stackHovering = $0 }
                .opacity(isDragging ? 0 : 1)
                .scaleEffect(isDragging ? 0.9 : 1)
                .animation(.easeOut(duration: 0.2), value: isDragging)

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        CircularIconButton(systemName: "xmark", action: onClose)
                        Spacer()
                        if let accent = shelf?.accent {
                            ShelfAccentBadge(accent: accent, size: 10)
                                .padding(.trailing, 2)
                        }
                        if shelf?.pinned == true {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.75))
                                .padding(.trailing, 2)
                        }
                        ShelfActionMenu(manager: manager, shelfID: shelfID)
                    }

                    Spacer(minLength: 0)

                    DocumentsPill(title: pillTitle, action: onOpenDocuments)
                }

                GrabHandle(onTap: onDock)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(y: -12)
            }
        }
    }
}

private struct StackedDocumentPreview: View {
    let namespace: Namespace.ID
    let items: [ShelfItem]
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}

    private struct Layer {
        let rotation: Double
        let x: CGFloat
        let y: CGFloat
        let scale: CGFloat
        let opacity: Double
    }

    private let layerTable: [Layer] = [
        .init(rotation:   9, x:   7, y:  -5, scale: 0.82, opacity: 0.80),
        .init(rotation:  -9, x:  -9, y:  -2, scale: 0.86, opacity: 0.90),
        .init(rotation:   4, x:   5, y:   2, scale: 0.92, opacity: 0.96),
        .init(rotation:   0, x:   0, y:   0, scale: 1.0,  opacity: 1.0),
    ]

    private var visibleStack: [ShelfItem] {
        Array(items.suffix(layerTable.count))
    }

    var body: some View {
        let stack = visibleStack
        let layerStart = layerTable.count - stack.count

        ZStack {
            ForEach(Array(stack.enumerated()), id: \.element.id) { idx, item in
                let layer = layerTable[layerStart + idx]
                let isFront = idx == stack.count - 1

                cardView(for: item, isFront: isFront)
                    .overlay(
                        Group {
                            if isFront {
                                ShelfDragOverlay(
                                    provider: { items.compactMap { $0.fileURL } },
                                    onStart: onDragStart,
                                    onEnd: onDragEnd
                                )
                            }
                        }
                    )
                    .rotationEffect(.degrees(layer.rotation))
                    .offset(x: layer.x, y: layer.y)
                    .scaleEffect(layer.scale)
                    .opacity(layer.opacity)
                    .zIndex(Double(idx))
            }
        }
        .frame(width: 160, height: 170)
    }

    /// Card footprint that honors the image's true aspect ratio so a landscape
    /// photo isn't cropped into a portrait box (and vice versa). The longer
    /// side is capped at `longSide` to keep the stack visually balanced.
    /// Prefers `item.pixelSize` (set synchronously from file metadata) over
    /// the thumbnail's pixel dimensions — otherwise the card resizes when QL
    /// replaces the placeholder icon, which reads as a jitter on drop.
    private static func cardSize(for item: ShelfItem) -> CGSize {
        let portraitFallback = CGSize(width: 92, height: 118)
        let longSide: CGFloat = 122
        let aspect: CGFloat? = {
            if let s = item.pixelSize, s.width > 0, s.height > 0 {
                return s.width / s.height
            }
            return item.thumbnail.flatMap(aspectRatio(of:))
        }()
        guard let aspect, aspect.isFinite, aspect > 0
        else { return portraitFallback }
        if aspect >= 1 {
            return CGSize(width: longSide, height: longSide / aspect)
        } else {
            return CGSize(width: longSide * aspect, height: longSide)
        }
    }

    private static func aspectRatio(of image: NSImage) -> CGFloat? {
        // Pixel dimensions on the underlying representation are the most
        // reliable source — NSImage.size can lie when the image has multiple
        // reps or has been resized by Quick Look.
        if let rep = image.representations.first {
            let w = CGFloat(rep.pixelsWide)
            let h = CGFloat(rep.pixelsHigh)
            if w > 0, h > 0 { return w / h }
        }
        let s = image.size
        if s.width > 0, s.height > 0 { return s.width / s.height }
        return nil
    }

    @ViewBuilder
    private func cardView(for item: ShelfItem, isFront: Bool) -> some View {
        if item.type == .image {
            let size = Self.cardSize(for: item)
            Group {
                if item.thumbnailIsIcon {
                    // QL preview pending — show a quiet skeleton sized at
                    // the photo's real aspect, not the JPEG-icon's aspect.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                } else if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                        )
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(isFront ? 0.28 : 0.18),
                    radius: isFront ? 14 : 8,
                    x: 0, y: isFront ? 6 : 3)
            .modifier(FrontMatchedGeometry(active: isFront, namespace: namespace))
        } else if item.thumbnailIsIcon, let thumb = item.thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 92, height: 118)
                .shadow(color: .black.opacity(isFront ? 0.28 : 0.18),
                        radius: isFront ? 14 : 8,
                        x: 0, y: isFront ? 6 : 3)
                .modifier(FrontMatchedGeometry(active: isFront, namespace: namespace))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.97))
                .overlay(
                    ThumbnailView(item: item)
                        .padding(6)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                )
                .frame(width: 92, height: 118)
                .shadow(color: .black.opacity(isFront ? 0.20 : 0.14),
                        radius: isFront ? 18 : 12,
                        x: 0, y: isFront ? 10 : 6)
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                .modifier(FrontMatchedGeometry(active: isFront, namespace: namespace))
        }
    }

}

private struct ThumbnailView: View {
    let item: ShelfItem

    var body: some View {
        Group {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if item.type == .text, let text = item.textContent {
                Text(text)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(
                        LinearGradient(
                            colors: [.black, .black, .black.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.black.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyStackPreview: View {
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.38))
            Text("Drop or shake here")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .frame(width: 92, height: 118)
        .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
    }
}

struct CircularIconButton: View {
    let systemName: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hovering ? 0.20 : 0.10))
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                    )
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .frame(width: 30, height: 30)
            .scaleEffect(hovering ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct DocumentsPill: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("›")
                    .font(.system(size: 12, weight: .semibold))
                    .offset(y: -1)
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(height: 26)
            .padding(.horizontal, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.18 : 0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            )
            .scaleEffect(hovering ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct GrabHandle: View {
    var onTap: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.75 : 0.28))
            .frame(width: 40, height: 4)
            .shadow(color: Color.white.opacity(hovering ? 0.55 : 0),
                    radius: hovering ? 6 : 0)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { onTap?() }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

enum ShelfMatchedGeometry {
    static let card = "shelf.card"
}

private struct FrontMatchedGeometry: ViewModifier {
    let active: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if active {
            content.matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
        } else {
            content
        }
    }
}
