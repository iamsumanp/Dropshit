import SwiftUI

struct CollapsedShelfView: View {
    let namespace: Namespace.ID
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    var items: [ShelfItem] = []
    var isDragging: Bool = false
    var onClose: () -> Void = {}
    var onOpenDocuments: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}

    @State private var stackHovering = false

    private var pillTitle: String {
        if items.count == 1 {
            return items[0].displayName
        }
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
                    HStack {
                        CircularIconButton(systemName: "xmark", action: onClose)
                        Spacer()
                        ShelfActionMenu(manager: manager, shelfID: shelfID)
                    }

                    Spacer(minLength: 0)

                    DocumentsPill(title: pillTitle, action: onOpenDocuments)
                }
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
        .frame(width: 150, height: 170)
    }

    @ViewBuilder
    private func cardView(for item: ShelfItem, isFront: Bool) -> some View {
        if renderFlush(for: item), let thumb = item.thumbnail {
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

    private func renderFlush(for item: ShelfItem) -> Bool {
        if item.type == .image { return true }
        return item.thumbnailIsIcon
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
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("›")
                    .font(.system(size: 15, weight: .semibold))
                    .offset(y: -1)
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
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
