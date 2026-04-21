import SwiftUI
import UniformTypeIdentifiers

struct ShelfContainerView: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    var onClose: () -> Void = {}
    var onResize: (_ expanded: Bool) -> Void = { _ in }
    var onOpenShelf: (UUID) -> Void = { _ in }

    @Namespace private var ns
    @State private var isExpanded = false
    @State private var dropTargeted = false
    @State private var selection: Set<UUID> = []

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    private var transitionAnimation: Animation {
        .spring(response: 0.5, dampingFraction: 0.78)
    }

    var body: some View {
        ZStack {
            if isExpanded {
                ExpandedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    selection: $selection,
                    onCollapse: { toggle(to: false) },
                    onClose: onClose,
                    onOpenShelf: onOpenShelf
                )
                .transition(.opacity)
            } else {
                CollapsedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    items: items,
                    isDragging: manager.isDragging,
                    onClose: onClose,
                    onOpenDocuments: { toggle(to: true) },
                    onDragStart: { manager.isDragging = true },
                    onDragEnd: { manager.isDragging = false }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            DropTargetOverlay(active: dropTargeted && !manager.isDragging)
        }
        .onDrop(
            of: [UTType.fileURL, UTType.image, UTType.plainText, UTType.utf8PlainText],
            isTargeted: $dropTargeted,
            perform: handleDrop
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        if manager.isDragging { return false }
        var handled = false
        let targetShelfID = shelfID
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, _ in
                    let url: URL? = {
                        if let url = item as? URL { return url }
                        if let data = item as? Data {
                            return URL(dataRepresentation: data, relativeTo: nil)
                        }
                        if let str = item as? String {
                            return URL(string: str)
                        }
                        return nil
                    }()
                    guard let url else { return }
                    Task { @MainActor in manager.addFile(url: url, to: targetShelfID) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, _ in
                    guard let data else { return }
                    let ext: String = {
                        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
                        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
                        return "img"
                    }()
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Shelf-\(UUID().uuidString).\(ext)")
                    do {
                        try data.write(to: tmp)
                        Task { @MainActor in manager.addFile(url: tmp, to: targetShelfID) }
                    } catch {
                        NSLog("Shelf: failed to write dropped image: \(error)")
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                handled = true
                let uti = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
                    ? UTType.utf8PlainText.identifier
                    : UTType.plainText.identifier
                provider.loadItem(forTypeIdentifier: uti, options: nil) { item, _ in
                    let text: String? = {
                        if let s = item as? String { return s }
                        if let data = item as? Data { return String(data: data, encoding: .utf8) }
                        return nil
                    }()
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in manager.addText(text, to: targetShelfID) }
                }
            }
        }
        return handled
    }

    private func toggle(to expanded: Bool) {
        guard expanded != isExpanded else { return }
        onResize(expanded)
        withAnimation(transitionAnimation) {
            isExpanded = expanded
        }
    }
}

private struct ExpandedShelfView: View {
    let namespace: Namespace.ID
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    @Binding var selection: Set<UUID>
    let onCollapse: () -> Void
    let onClose: () -> Void
    var onOpenShelf: (UUID) -> Void = { _ in }

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: 3)
    }

    private var title: String {
        if items.count == 1 { return items[0].displayName }
        return "\(items.count) Files"
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            content
            Spacer(minLength: 0)
            revealButton
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CircularIconButton(systemName: "chevron.left", action: onCollapse)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(manager.displayTotalSize(of: shelfID))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                CircularIconButton(
                    systemName: "doc.on.clipboard",
                    action: { manager.addFromClipboard(to: shelfID) }
                )
                RecentShelvesMenu(
                    manager: manager,
                    currentShelfID: shelfID,
                    onOpenShelf: onOpenShelf
                )
                CircularIconButton(
                    systemName: "trash",
                    action: { manager.clear(shelfID: shelfID) }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            grid
                .opacity(manager.isDragging ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: manager.isDragging)
        }
    }

    private var grid: some View {
        let target = shelfID
        let sel = $selection
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .center, spacing: 22) {
                ForEach(items) { item in
                    DocumentGridItem(
                        item: item,
                        manager: manager,
                        shelfID: target,
                        isSelected: sel.wrappedValue.contains(item.id),
                        selectedURLsProvider: {
                            // If clicked tile is part of a multi-selection, drag all.
                            let selectedIDs = sel.wrappedValue
                            if selectedIDs.contains(item.id) && selectedIDs.count > 1 {
                                return manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                                    .compactMap { $0.fileURL }
                            }
                            return item.fileURL.map { [$0] } ?? []
                        },
                        onRemove: { manager.removeItem(id: item.id, from: target) },
                        onClick: { modifiers in
                            if modifiers.contains(.command) {
                                if sel.wrappedValue.contains(item.id) {
                                    sel.wrappedValue.remove(item.id)
                                } else {
                                    sel.wrappedValue.insert(item.id)
                                }
                            } else {
                                sel.wrappedValue = [item.id]
                            }
                        },
                        onDragStart: { manager.isDragging = true },
                        onDragEnd: { manager.isDragging = false }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
        )
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                Color.white.opacity(0.18),
                style: StrokeStyle(lineWidth: 1, dash: [6, 6])
            )
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.45))
                    Text("Shake files out of Finder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text("or drop them here to add")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            )
            .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
    }

    private var revealButton: some View {
        HStack {
            Spacer()
            RevealInFinderButton(enabled: !items.isEmpty, action: revealInFinder)
            Spacer()
        }
    }

    private func revealInFinder() {
        let urls = items.compactMap { $0.fileURL }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private struct RecentShelvesMenu: View {
    @ObservedObject var manager: ShelfManager
    let currentShelfID: UUID
    let onOpenShelf: (UUID) -> Void

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        Menu {
            if manager.shelves.count > 1 {
                ForEach(manager.shelves.reversed()) { shelf in
                    Button(action: { onOpenShelf(shelf.id) }) {
                        HStack {
                            Text(label(for: shelf))
                            if shelf.id == currentShelfID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                    )
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
    }

    private func label(for shelf: Shelf) -> String {
        let count = shelf.items.count
        let countLabel = count == 1 ? "1 file" : "\(count) files"
        let time = Self.timeFormatter.localizedString(for: shelf.createdAt, relativeTo: Date())
        return "\(countLabel) · \(time)"
    }
}

private struct DocumentGridItem: View {
    let item: ShelfItem
    let manager: ShelfManager
    let shelfID: UUID
    let isSelected: Bool
    let selectedURLsProvider: () -> [URL]
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            cardFace
            .frame(width: 110, height: 140)
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.14),
                    radius: hovering ? 18 : 12, x: 0, y: hovering ? 10 : 6)
            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
            .scaleEffect(hovering ? 1.03 : 1.0)
            .offset(y: hovering ? -3 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 1 : 0), lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            )
            .overlay(
                ShelfDragOverlay(
                    provider: selectedURLsProvider,
                    onStart: onDragStart,
                    onEnd: onDragEnd,
                    menuBuilder: {
                        ShelfContextMenu.make(for: item, shelfID: shelfID, manager: manager)
                    },
                    onClick: onClick,
                    onDoubleClick: {
                        if let url = item.fileURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.black.opacity(0.6), Color.white)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
            .onHover { hovering = $0 }

            VStack(spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.displayMeta)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: 110)
        }
    }

    @ViewBuilder
    private var cardFace: some View {
        if renderFlush, let thumb = item.thumbnail {
            if item.type == .image {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 110, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 110, height: 140)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
                previewContent
                    .padding(12)
            }
        }
    }

    private var renderFlush: Bool {
        if item.type == .image { return true }
        return item.thumbnailIsIcon
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if item.type == .text, let text = item.textContent {
            Text(text)
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.78))
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
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.black.opacity(0.35))
        }
    }
}

enum ShelfDragProvider {
    static func make(for item: ShelfItem) -> NSItemProvider {
        if let url = item.fileURL {
            if FileManager.default.fileExists(atPath: url.path),
               let provider = NSItemProvider(contentsOf: url) {
                provider.suggestedName = url.lastPathComponent
                return provider
            }
            let fallback = NSItemProvider(object: url as NSURL)
            fallback.suggestedName = url.lastPathComponent
            return fallback
        }
        if let text = item.textContent {
            return NSItemProvider(object: text as NSString)
        }
        return NSItemProvider()
    }
}

private struct DropTargetOverlay: View {
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(active ? 1 : 0), lineWidth: 3)
            .padding(-16)
            .animation(.easeOut(duration: 0.15), value: active)
            .allowsHitTesting(false)
    }
}

private struct RevealInFinderButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                Text("Reveal in Finder")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(enabled ? 0.92 : 0.4))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(hovering && enabled ? 0.16 : 0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            )
            .scaleEffect(hovering && enabled ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}
