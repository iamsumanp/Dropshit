import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ShelfContainerView: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    var onClose: () -> Void = {}
    var onResize: (_ expanded: Bool) -> Void = { _ in }
    var onDockChanged: (_ docked: Bool) -> Void = { _ in }

    @Namespace private var ns
    @State private var isExpanded = false
    @State private var isDocked = false
    @State private var dropTargeted = false
    @State private var selection: Set<UUID> = []
    // Sticky once true: lets the collapsed view show its X close button
    // after the user empties a populated shelf, but stays hidden while a
    // shake gesture is mid-flight (shelf created empty, no items yet).
    @State private var hasEverHadItems = false

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    private var transitionAnimation: Animation {
        .spring(response: 0.5, dampingFraction: 0.78)
    }

    var body: some View {
        ZStack {
            if isDocked {
                DockedTabView(
                    onExpand: { toggleDock(to: false) },
                    dropTargeted: dropTargeted
                )
                .transition(.opacity)
            } else if isExpanded {
                ExpandedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    selection: $selection,
                    onCollapse: { toggle(to: false) },
                    onClose: onClose
                )
                .padding(10)
                .transition(.opacity)
            } else {
                CollapsedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    items: items,
                    isDragging: manager.isDragging,
                    showCloseWhenEmpty: hasEverHadItems,
                    onClose: onClose,
                    onOpenDocuments: { toggle(to: true) },
                    onDock: { toggleDock(to: true) },
                    onDragStart: { manager.isDragging = true },
                    onDragEnd: { manager.isDragging = false }
                )
                .padding(10)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if !isDocked {
                DropTargetOverlay(active: dropTargeted && !manager.isDragging)
            }
        }
        // `UTType.item` is the root of the UTI hierarchy — registering it
        // makes SwiftUI accept any drag. The other specific types stay in
        // the list because SwiftUI restricts which identifiers we're
        // allowed to call `loadItem(forTypeIdentifier:)` against to those
        // listed here; without them, file/text/image loads silently
        // return nothing.
        .onDrop(
            of: [
                UTType.item,
                UTType.fileURL,
                UTType.url,
                UTType.image,
                UTType.plainText,
                UTType.utf8PlainText,
                UTType.data,
            ],
            isTargeted: $dropTargeted,
            perform: handleDrop
        )
        .onReceive(manager.undockRequested) { id in
            guard id == shelfID, isDocked else { return }
            withAnimation(transitionAnimation) { isDocked = false }
        }
        // Empty-but-expanded is a dead-end UX (nothing to do, nothing to
        // show), so fall back to collapsed and let that view handle the
        // empty case.
        .onChange(of: items.count) { newCount in
            if newCount == 0, isExpanded {
                toggle(to: false)
            }
            if newCount > 0 { hasEverHadItems = true }
        }
        .onChange(of: dropTargeted) { newValue in
            manager.setDropTargeted(shelfID: shelfID, newValue)
        }
        .onAppear {
            if !items.isEmpty { hasEverHadItems = true }
        }
        .onDisappear {
            // Make sure a panel that closes mid-drop doesn't leave its
            // shelf marked as a drop target forever.
            manager.setDropTargeted(shelfID: shelfID, false)
        }
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
            } else if provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.directory.identifier) {
                // Folder drag: Finder offers BOTH `public.folder` and a
                // synthesized `public.zip-archive` representation. The
                // typed-data fallback below would happily pick the zip
                // (because it has a .zip filename extension) and stage
                // it as a random archive. Match the folder type first
                // and pull the actual directory via loadFileRepresentation
                // so the entry shows up as the original folder.
                handled = true
                let folderUTI = provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
                    ? UTType.folder.identifier
                    : UTType.directory.identifier
                _ = provider.loadFileRepresentation(forTypeIdentifier: folderUTI) { tempURL, _ in
                    guard let tempURL else { return }
                    // The system deletes tempURL after this callback
                    // returns, so copy into our managed temp directory.
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(tempURL.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: tempURL, to: dest)
                        Task { @MainActor in manager.addFile(url: dest, to: targetShelfID) }
                    } catch {
                        NSLog("Shelf: failed to copy dropped folder: \(error)")
                    }
                }
            } else if let typeID = provider.registeredTypeIdentifiers.first(where: {
                // A registered UTI with a preferred filename extension
                // (e.g. `net.daringfireball.markdown` → "md", `public.swift-source`
                // → "swift") signals that this is a real file drag — even
                // when SwiftUI hasn't surfaced `public.file-url` and there's
                // no `suggestedName`. Pull the bytes and stage as a temp
                // file so the entry shows up as a proper file rather than
                // being misclassified as a text snippet by the next branch.
                UTType($0)?.preferredFilenameExtension != nil
            }) {
                handled = true
                Self.stageFromProvider(
                    provider: provider,
                    typeID: typeID,
                    targetShelfID: targetShelfID,
                    manager: manager
                )
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, _ in
                    guard let data else { return }
                    let ext: String = {
                        if let source = CGImageSourceCreateWithData(data as CFData, nil),
                           let cfType = CGImageSourceGetType(source),
                           let type = UTType(cfType as String),
                           let ext = type.preferredFilenameExtension {
                            return ext
                        }
                        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
                        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
                        return "img"
                    }()
                    // Deterministic name from content hash so dropping the
                    // same image twice lands at the same path and is caught
                    // by the shelf's duplicate check.
                    let digest = SHA256.hash(data: data)
                    let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Shelf-\(hash).\(ext)")
                    do {
                        if !FileManager.default.fileExists(atPath: tmp.path) {
                            try data.write(to: tmp)
                        }
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
            } else if let typeID = provider.registeredTypeIdentifiers.first {
                // Final catch-all: load whatever data we can and stage it.
                handled = true
                Self.stageFromProvider(
                    provider: provider,
                    typeID: typeID,
                    targetShelfID: targetShelfID,
                    manager: manager
                )
            }
        }
        return handled
    }

    /// Tries to stage a dropped item by its file representation first so the
    /// original filename survives (works for both real file URLs and file
    /// promises), and only falls back to writing the raw data with a
    /// synthesized name when the source has no file representation.
    private static func stageFromProvider(
        provider: NSItemProvider,
        typeID: String,
        targetShelfID: UUID,
        manager: ShelfManager
    ) {
        _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { tempURL, _ in
            if let tempURL {
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(tempURL.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: tempURL, to: dest)
                    Task { @MainActor in manager.addFile(url: dest, to: targetShelfID) }
                    return
                } catch {
                    NSLog("Shelf: failed to copy dropped file representation: \(error)")
                }
            }
            // No file representation — fall back to raw data with the
            // suggested name (or "Dropped" if even that is missing).
            let suggested = provider.suggestedName ?? "Dropped"
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                guard let data, !data.isEmpty else { return }
                let url = stageTempFile(
                    data: data,
                    suggestedName: suggested,
                    typeID: typeID
                )
                guard let url else { return }
                Task { @MainActor in manager.addFile(url: url, to: targetShelfID) }
            }
        }
    }

    /// Writes drag payload data to a temp file using the suggested filename
    /// (extension preserved when present) so the shelf can display it as a
    /// regular file entry. The hash suffix dedupes repeat drops of the same
    /// content under the shelf's "already on shelf" check.
    private static func stageTempFile(
        data: Data,
        suggestedName: String,
        typeID: String
    ) -> URL? {
        let stem: String
        let ext: String
        if let dotRange = suggestedName.range(of: ".", options: .backwards) {
            stem = String(suggestedName[..<dotRange.lowerBound])
            ext = String(suggestedName[dotRange.upperBound...])
        } else {
            stem = suggestedName
            ext = UTType(typeID)?.preferredFilenameExtension ?? "bin"
        }
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        let safeStem = stem.isEmpty ? "Dropped" : stem
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeStem)-\(hash).\(ext)")
        do {
            if !FileManager.default.fileExists(atPath: tmp.path) {
                try data.write(to: tmp)
            }
            return tmp
        } catch {
            NSLog("Shelf: failed to stage dropped data: \(error)")
            return nil
        }
    }

    private func toggle(to expanded: Bool) {
        guard expanded != isExpanded else { return }
        onResize(expanded)
        withAnimation(transitionAnimation) {
            isExpanded = expanded
        }
    }

    private func toggleDock(to docked: Bool) {
        guard docked != isDocked else { return }
        onDockChanged(docked)
        withAnimation(transitionAnimation) {
            isDocked = docked
        }
    }
}

private struct DockedTabView: View {
    let onExpand: () -> Void
    let dropTargeted: Bool

    @State private var hovering = false

    var body: some View {
        Color.clear
            .overlay {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        Color.white.opacity(dropTargeted ? 1 : (hovering ? 0.95 : 0.65))
                    )
                    // Nudge the chevron to match the visible portion of the
                    // panel (right side is clipped past the screen edge).
                    .offset(x: -6)
            }
            .contentShape(Rectangle())
            // Trace the panel's actual outer corner radius (22, set on the
            // FloatingPanel rootLayer) so the highlight hugs the visible
            // capsule instead of an inset rectangle. Negative padding pulls
            // the stroke flush with the panel's outline; the right edge is
            // clipped offscreen by the dock offset and never shows anyway.
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(dropTargeted ? 1 : 0),
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
            .onTapGesture(perform: onExpand)
            .animation(.easeOut(duration: 0.15), value: dropTargeted)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

enum ShelfViewMode: String {
    case grid
    case list
}

private struct ExpandedShelfView: View {
    let namespace: Namespace.ID
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    @Binding var selection: Set<UUID>
    let onCollapse: () -> Void
    let onClose: () -> Void

    @AppStorage("shelf.viewMode") private var viewModeRaw: String = ShelfViewMode.grid.rawValue
    @State private var draggingIDs: Set<UUID> = []

    private var viewMode: ShelfViewMode {
        get { ShelfViewMode(rawValue: viewModeRaw) ?? .grid }
    }

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    // Adaptive columns let the row pack as many cards as fit; LazyVGrid's
    // .center alignment then centers the row when there are fewer items than
    // columns (so 1 or 2 files don't pin to the left).
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 96, maximum: 116), spacing: 16, alignment: .top)]
    }

    private var shelf: Shelf? { manager.shelf(id: shelfID) }

    private var countTitle: String {
        items.count == 1 ? "1 File" : "\(items.count) Files"
    }

    private var headerPrimary: String {
        if let n = shelf?.name, !n.isEmpty { return n }
        return countTitle
    }

    private var headerSubtitle: String {
        let size = manager.displayTotalSize(of: shelfID)
        if shelf?.name?.isEmpty == false {
            return size == "—" ? countTitle : "\(countTitle) · \(size)"
        }
        return size
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            content
            Spacer(minLength: 0)
            revealButton
        }
        // Clear selection on any tap that wasn't claimed by a tile, header
        // button, or the reveal pill. ShelfDragOverlay's NSView consumes
        // tile clicks before they reach this gesture, so this only fires
        // on empty/black-space clicks.
        .contentShape(Rectangle())
        .onTapGesture { selection.removeAll() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CircularIconButton(systemName: "chevron.left", action: onCollapse)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let accent = shelf?.accent {
                        ShelfAccentBadge(accent: accent, size: 10)
                    }
                    Text(headerPrimary)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if shelf?.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            ViewModeToggle(
                mode: Binding(
                    get: { viewMode },
                    set: { viewModeRaw = $0.rawValue }
                )
            )
            ShelfActionMenu(manager: manager, shelfID: shelfID)
        }
    }

    @ViewBuilder
    private var content: some View {
        // Empty case is handled by auto-collapsing in ShelfContainerView,
        // so the expanded view only ever needs to render the populated grid
        // or list.
        switch viewMode {
        case .grid:
            grid
        case .list:
            list
        }
    }

    private func dragSet(for itemID: UUID) -> Set<UUID> {
        if selection.contains(itemID) && selection.count > 1 {
            return selection
        }
        return [itemID]
    }


    private var grid: some View {
        let target = shelfID
        let sel = $selection
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                ForEach(items) { item in
                    DocumentGridItem(
                        item: item,
                        manager: manager,
                        shelfID: target,
                        isSelected: sel.wrappedValue.contains(item.id),
                        isBeingDragged: draggingIDs.contains(item.id),
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
                        onClick: { modifiers in handleClick(itemID: item.id, modifiers: modifiers) },
                        onDragStart: {
                            manager.isDragging = true
                            draggingIDs = dragSet(for: item.id)
                        },
                        onDragEnd: {
                            manager.isDragging = false
                            draggingIDs.removeAll()
                        }
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

    private var list: some View {
        let target = shelfID
        let sel = $selection
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    DocumentListItem(
                        item: item,
                        manager: manager,
                        shelfID: target,
                        isSelected: sel.wrappedValue.contains(item.id),
                        isBeingDragged: draggingIDs.contains(item.id),
                        selectedURLsProvider: {
                            let selectedIDs = sel.wrappedValue
                            if selectedIDs.contains(item.id) && selectedIDs.count > 1 {
                                return manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                                    .compactMap { $0.fileURL }
                            }
                            return item.fileURL.map { [$0] } ?? []
                        },
                        onRemove: { manager.removeItem(id: item.id, from: target) },
                        onClick: { modifiers in handleClick(itemID: item.id, modifiers: modifiers) },
                        onDragStart: {
                            manager.isDragging = true
                            draggingIDs = dragSet(for: item.id)
                        },
                        onDragEnd: {
                            manager.isDragging = false
                            draggingIDs.removeAll()
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleClick(itemID: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(itemID) {
                selection.remove(itemID)
            } else {
                selection.insert(itemID)
            }
        } else {
            selection = [itemID]
        }
    }

    private var revealButton: some View {
        let allSelected = !items.isEmpty && selection.count == items.count
        return HStack(spacing: 8) {
            Spacer()
            SelectAllButton(
                allSelected: allSelected,
                enabled: !items.isEmpty,
                action: {
                    if allSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(items.map(\.id))
                    }
                }
            )
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

/// Pill that toggles selection across every item in the shelf. Once items
/// are selected, dragging any tile drags the whole selection (existing
/// behavior in DocumentGridItem / DocumentListItem).
private struct SelectAllButton: View {
    let allSelected: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: allSelected
                      ? "checkmark.circle.fill"
                      : "circle.dashed")
                    .font(.system(size: 11, weight: .medium))
                Text(allSelected ? "Deselect All" : "Select All")
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

private struct DocumentGridItem: View {
    let item: ShelfItem
    let manager: ShelfManager
    let shelfID: UUID
    let isSelected: Bool
    let isBeingDragged: Bool
    let selectedURLsProvider: () -> [URL]
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    @State private var hovering = false

    private static let defaultCardSize = CGSize(width: 78, height: 100)
    private static let cardLongSide: CGFloat = 100
    private static let labelMinWidth: CGFloat = 90

    private var cardSize: CGSize {
        guard item.type == .image else { return Self.defaultCardSize }
        // Prefer the file's own pixel dimensions — set synchronously in
        // ShelfManager.addFile — so the card lands at the right aspect on
        // the very first render. The thumbnail-derived aspect was wrong
        // until QL replaced the placeholder icon, causing a visible
        // resize/jitter mid-drop.
        let aspectFromMeta: CGFloat? = {
            guard let s = item.pixelSize, s.width > 0, s.height > 0 else { return nil }
            return s.width / s.height
        }()
        let aspect = aspectFromMeta
            ?? item.thumbnail.flatMap(Self.aspectRatio(of:))
            ?? 1
        guard aspect.isFinite, aspect > 0 else { return Self.defaultCardSize }
        if aspect >= 1 {
            return CGSize(width: Self.cardLongSide, height: Self.cardLongSide / aspect)
        } else {
            return CGSize(width: Self.cardLongSide * aspect, height: Self.cardLongSide)
        }
    }

    var body: some View {
        let size = cardSize
        VStack(spacing: 8) {
            cardFace(size: size)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.14),
                    radius: hovering ? 18 : 12, x: 0, y: hovering ? 10 : 6)
            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
            .scaleEffect(hovering ? 1.03 : 1.0)
            .offset(y: hovering ? -3 : 0)
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
                    },
                    visibleCardSize: { size }
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
            // Uniform vertical slot equal to the long-side cap so short
            // (landscape) cards sit on the same baseline as tall (portrait)
            // ones — that keeps the title/meta labels aligned across the row.
            .frame(height: Self.cardLongSide, alignment: .bottom)

            VStack(spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.displayMeta)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(isSelected ? 0.75 : 0.5))
                    .lineLimit(1)
            }
            .frame(width: max(size.width, Self.labelMinWidth))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 1 : 0))
        )
        .opacity(isBeingDragged ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isBeingDragged)
    }

    @ViewBuilder
    private func cardFace(size: CGSize) -> some View {
        if item.type == .image, item.thumbnailIsIcon {
            // Real photo preview is still being rendered by QL. Showing the
            // generic JPEG/HEIC type icon stretched into the photo's frame
            // looks like a flash of a different image, so render a quiet
            // skeleton instead and crossfade to the real thumbnail when it
            // arrives.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: size.width, height: size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .transition(.opacity)
        } else if renderFlush, let thumb = item.thumbnail {
            if item.type == .image {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity)
            } else {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
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

    private static func aspectRatio(of image: NSImage) -> CGFloat? {
        if let rep = image.representations.first {
            let w = CGFloat(rep.pixelsWide)
            let h = CGFloat(rep.pixelsHigh)
            if w > 0, h > 0 { return w / h }
        }
        let s = image.size
        if s.width > 0, s.height > 0 { return s.width / s.height }
        return nil
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

private struct ViewModeToggle: View {
    @Binding var mode: ShelfViewMode

    var body: some View {
        HStack(spacing: 2) {
            ViewModeSegment(target: .grid, systemName: "square.grid.2x2.fill", mode: $mode)
            ViewModeSegment(target: .list, systemName: "list.bullet", mode: $mode)
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct ViewModeSegment: View {
    let target: ShelfViewMode
    let systemName: String
    @Binding var mode: ShelfViewMode

    @State private var hovering = false

    var body: some View {
        let active = mode == target
        // contentShape() on the label is what makes the whole 26×22 area
        // hit-testable — without it, only the icon glyph itself catches
        // clicks and the list icon "feels dead" until hovered.
        Button {
            mode = target
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(active ? 0.98 : (hovering ? 0.85 : 0.55)))
                .frame(width: 26, height: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            Color.white.opacity(
                                active ? 0.20 : (hovering ? 0.10 : 0)
                            )
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct DocumentListItem: View {
    let item: ShelfItem
    let manager: ShelfManager
    let shelfID: UUID
    let isSelected: Bool
    let isBeingDragged: Bool
    let selectedURLsProvider: () -> [URL]
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(item.displayName)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(item.displayMeta)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.8 : 0.5))
                .lineLimit(1)

            ZStack {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.black.opacity(0.5), Color.white.opacity(0.95))
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 1 : 0))
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
        .onHover { hovering = $0 }
        .opacity(isBeingDragged ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isBeingDragged)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumb = item.thumbnail {
            if item.type == .image {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.97)
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                }
            }
        } else if item.type == .text {
            ZStack {
                Color.white.opacity(0.10)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        } else {
            ZStack {
                Color.white.opacity(0.10)
                Image(systemName: "doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
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
        // Trace the panel's outer rounded shape directly. Earlier this
        // overlay used `.padding(-10)` to push out past FloatingPanelContent's
        // 10pt margin, but that padding has since moved into each shelf
        // branch — extending here would just clip beyond the panel bounds.
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(active ? 1 : 0), lineWidth: 3)
            .animation(.easeOut(duration: 0.15), value: active)
            .allowsHitTesting(false)
    }
}

struct ShelfAccentBadge: View {
    let accent: ShelfAccent
    var size: CGFloat = 10

    var body: some View {
        switch accent {
        case .color(let hex):
            Circle()
                .fill(Color(nsColor: NSColor(hex: hex) ?? .systemGray))
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        case .emoji(let glyph):
            Text(glyph)
                .font(.system(size: size + 2))
                .frame(width: size + 4, height: size + 4)
        }
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
