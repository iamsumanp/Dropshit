import CryptoKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfContainerView: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    /// True for shake-created shelves, which auto-close via the shake-release
    /// watcher and shouldn't show an X in their fresh-empty state. Menu-created
    /// shelves have no auto-close path, so they always need the X.
    var isEphemeral: Bool = false
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
                    onClose: onClose,
                    onDock: { toggleDock(to: true) }
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
                    showCloseWhenEmpty: hasEverHadItems || !isEphemeral,
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
        // AppKit-level drop target — keeps the green "+" copy badge from
        // showing up on the cursor (SwiftUI's `.onDrop` always negotiates as
        // `.copy`, which paints the badge; we want a clean cursor instead).
        .overlay(
            ShelfDropTarget(
                isTargeted: $dropTargeted,
                allowDrop: { !manager.isDragging },
                onDrop: handleDrop
            )
        )
        .onReceive(manager.undockRequested) { id in
            guard id == shelfID, isDocked else { return }
            withAnimation(transitionAnimation) { isDocked = false }
        }
        .onReceive(manager.collapseRequested) { id in
            // External nudge (e.g. outside-click setting) — only act if the
            // signal is for our shelf and we're currently expanded. Going
            // through the normal toggle path keeps the panel resize +
            // SwiftUI animation in lockstep.
            guard id == shelfID, isExpanded else { return }
            toggle(to: false)
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

    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        if manager.isDragging { return false }
        let target = shelfID

        // 1. File URLs — covers both files and folders. Finder always vends
        // `.fileURL` for folders to AppKit destinations, so we don't need the
        // separate `public.folder` branch the SwiftUI version had to carry.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            for url in urls {
                manager.addFile(url: url, to: target)
            }
            return true
        }

        // 2. File promises — sources like Mail, Photos, and some browsers
        // vend the file lazily via NSFilePromiseReceiver. The receiver writes
        // the real bytes into our temp dir, then we add it to the shelf.
        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            let dest = FileManager.default.temporaryDirectory
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: dest,
                    options: [:],
                    operationQueue: queue
                ) { url, error in
                    if let error {
                        NSLog("Shelf: file promise failed — \(error)")
                        return
                    }
                    Task { @MainActor in manager.addFile(url: url, to: target) }
                }
            }
            return true
        }

        // 3. Image data without a fileURL — e.g. dragging an image straight
        // out of a webpage. Stage as PNG with a content-hash filename so a
        // repeat drop hits the shelf's duplicate guard.
        if let images = pasteboard.readObjects(
            forClasses: [NSImage.self], options: nil
        ) as? [NSImage], !images.isEmpty {
            var staged = false
            for image in images {
                guard
                    let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                let hash = SHA256.hash(data: png)
                    .map { String(format: "%02x", $0) }
                    .joined().prefix(16)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Shelf-\(hash).png")
                do {
                    if !FileManager.default.fileExists(atPath: tmp.path) {
                        try png.write(to: tmp)
                    }
                    manager.addFile(url: tmp, to: target)
                    staged = true
                } catch {
                    NSLog("Shelf: failed to write dropped image: \(error)")
                }
            }
            if staged { return true }
        }

        // 4. Plain text — pasted/dragged snippets. addText takes care of
        // staging a backing temp .txt so Open / Reveal work.
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manager.addText(text, to: target)
            return true
        }

        return false
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
    let onDock: () -> Void

    @AppStorage("shelf.viewMode") private var viewModeRaw: String = ShelfViewMode.grid.rawValue
    @State private var draggingIDs: Set<UUID> = []

    // Folder navigation: empty stack = shelf root (showing ShelfItems);
    // non-empty stack's `last` is the currently-displayed folder, with its
    // children cached in `folderContents`. The cache survives pop/push so
    // navigating back is instant.
    @State private var folderStack: [URL] = []
    @State private var folderContents: [URL: [FolderEntry]] = [:]
    @State private var loadingFolders: Set<URL> = []
    @State private var navDirection: NavDirection = .forward
    /// Selection inside the folder browser — keyed by `FolderEntry.id`.
    /// Cleared on push/pop because each level renders a fresh entry list
    /// with new UUIDs, so carrying selection across levels would just hold
    /// stale identifiers.
    @State private var folderSelection: Set<UUID> = []

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

    private var currentFolderURL: URL? { folderStack.last }
    private var inFolder: Bool { !folderStack.isEmpty }
    private var currentEntries: [FolderEntry] {
        currentFolderURL.flatMap { folderContents[$0] } ?? []
    }
    private var isCurrentFolderLoading: Bool {
        guard let url = currentFolderURL else { return false }
        return folderContents[url] == nil && loadingFolders.contains(url)
    }

    private var countTitle: String {
        items.count == 1 ? "1 File" : "\(items.count) Files"
    }

    private var headerPrimary: String {
        if let url = currentFolderURL { return url.lastPathComponent }
        if let n = shelf?.name, !n.isEmpty { return n }
        return countTitle
    }

    private var headerSubtitle: String {
        if inFolder {
            let shelfTitle = (shelf?.name?.isEmpty == false ? shelf?.name : nil) ?? "Shelf"
            let parents = folderStack.dropLast().map(\.lastPathComponent)
            let crumbs = ([shelfTitle] + parents).joined(separator: " › ")
            let countLabel: String
            if isCurrentFolderLoading {
                countLabel = "loading…"
            } else {
                let n = currentEntries.count
                countLabel = n == 1 ? "1 item" : "\(n) items"
            }
            return "\(crumbs) · \(countLabel)"
        }
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
        .onTapGesture {
            selection.removeAll()
            folderSelection.removeAll()
        }
        .onReceive(manager.selectAllRequested) { id in
            // Cmd-A from the app-level key monitor. Routes to the right
            // selection set depending on what the user is actually looking at.
            guard id == shelfID else { return }
            if inFolder {
                folderSelection = Set(currentEntries.map(\.id))
            } else {
                selection = Set(items.map(\.id))
            }
        }
        .onReceive(manager.copyRequested) { id in
            // Cmd-C: write the URLs of the current selection to the
            // pasteboard. Empty selection is a no-op so we don't accidentally
            // clobber the user's clipboard.
            guard id == shelfID else { return }
            let urls: [URL]
            if inFolder {
                urls = currentEntries
                    .filter { folderSelection.contains($0.id) }
                    .map(\.url)
            } else {
                urls = items
                    .filter { selection.contains($0.id) }
                    .compactMap(\.fileURL)
            }
            guard !urls.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CircularIconButton(systemName: "chevron.left", action: handleBack)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if inFolder {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                    } else if let accent = shelf?.accent {
                        ShelfAccentBadge(accent: accent, size: 10)
                    }
                    Text(headerPrimary)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !inFolder, shelf?.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            // Quick-dock to the right edge — same animation as the grab
            // handle in the collapsed view, surfaced here so the user
            // doesn't need to collapse first to park the panel. Sized
            // smaller than the primary back button so it sits comfortably
            // alongside the view-mode toggle.
            CircularIconButton(
                systemName: "arrow.right.to.line",
                action: onDock,
                size: 22,
                iconSize: 9
            )
            ViewModeToggle(
                mode: Binding(
                    get: { viewMode },
                    set: { viewModeRaw = $0.rawValue }
                )
            )
            if !inFolder {
                ShelfActionMenu(manager: manager, shelfID: shelfID)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if inFolder {
                folderContentBody
                    .id(currentFolderURL?.path ?? "folder-root")
                    .transition(navTransition)
            } else {
                shelfContentBody
                    .id("shelf-root")
                    .transition(navTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var navTransition: AnyTransition {
        switch navDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .back:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    @ViewBuilder
    private var shelfContentBody: some View {
        switch viewMode {
        case .grid: shelfGrid
        case .list: shelfList
        }
    }

    @ViewBuilder
    private var folderContentBody: some View {
        if isCurrentFolderLoading {
            VStack(spacing: 10) {
                ProgressView().progressViewStyle(.circular)
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.38))
                Text("Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewMode {
            case .grid: folderGrid
            case .list: folderList
            }
        }
    }

    private func dragSet(for itemID: UUID) -> Set<UUID> {
        if selection.contains(itemID) && selection.count > 1 {
            return selection
        }
        return [itemID]
    }

    // MARK: - Folder navigation

    private func handleBack() {
        if inFolder {
            popFolder()
        } else {
            onCollapse()
        }
    }

    private func enterFolder(_ url: URL) {
        guard folderStack.last != url else { return }
        navDirection = .forward
        loadFolderIfNeeded(url)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            folderStack.append(url)
            selection.removeAll()
            folderSelection.removeAll()
        }
    }

    private func popFolder() {
        guard !folderStack.isEmpty else { return }
        navDirection = .back
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            _ = folderStack.removeLast()
            folderSelection.removeAll()
        }
    }

    private func handleEntryActivation(_ entry: FolderEntry) {
        if entry.isDirectory { enterFolder(entry.url) }
    }

    private func handleEntryDoubleClick(_ entry: FolderEntry) {
        if entry.isDirectory {
            enterFolder(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func loadFolderIfNeeded(_ url: URL) {
        if folderContents[url] != nil || loadingFolders.contains(url) { return }
        loadingFolders.insert(url)
        Task.detached(priority: .userInitiated) {
            let entries = readDirectory(url: url)
            await MainActor.run {
                folderContents[url] = entries
                loadingFolders.remove(url)
            }
        }
    }

    private var shelfGrid: some View {
        let target = shelfID
        let sel = $selection
        // Newest-first in the expanded view so the just-dropped tile lands at
        // the top of the grid where the user is looking. Storage order stays
        // append-at-end (the collapsed stack still puts the newest tile on top).
        let displayed = Array(items.reversed())
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                ForEach(displayed) { item in
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
                        },
                        onNavigateInto: {
                            if let url = item.fileURL { enterFolder(url) }
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

    private var shelfList: some View {
        let target = shelfID
        let sel = $selection
        let displayed = Array(items.reversed())
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(displayed) { item in
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
                        },
                        onNavigateInto: {
                            if let url = item.fileURL { enterFolder(url) }
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                ForEach(currentEntries) { entry in
                    FolderEntryGridCell(
                        entry: entry,
                        isSelected: folderSelection.contains(entry.id),
                        onClick: { modifiers in handleFolderClick(entry: entry, modifiers: modifiers) },
                        onDoubleClick: { handleEntryDoubleClick(entry) },
                        onNavigateInto: { enterFolder(entry.url) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(currentEntries) { entry in
                    FolderEntryListItem(
                        entry: entry,
                        isSelected: folderSelection.contains(entry.id),
                        onClick: { modifiers in handleFolderClick(entry: entry, modifiers: modifiers) },
                        onDoubleClick: { handleEntryDoubleClick(entry) },
                        onNavigateInto: { enterFolder(entry.url) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleFolderClick(entry: FolderEntry, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if folderSelection.contains(entry.id) {
                folderSelection.remove(entry.id)
            } else {
                folderSelection.insert(entry.id)
            }
        } else {
            folderSelection = [entry.id]
        }
    }

    private func handleClick(itemID: UUID, modifiers: NSEvent.ModifierFlags) {
        // Card clicks always go to selection. Folders are entered via the
        // inline chevron button rendered next to their name — that's the
        // only navigation affordance, so a stray card click can't accidentally
        // descend into a folder while the user is just trying to select it.
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
        return HStack(spacing: 8) {
            Spacer()
            if inFolder {
                let allSelected = !currentEntries.isEmpty
                    && folderSelection.count == currentEntries.count
                let someSelected = !folderSelection.isEmpty
                SelectAllButton(
                    allSelected: allSelected,
                    someSelected: someSelected,
                    enabled: !currentEntries.isEmpty,
                    action: {
                        if allSelected {
                            folderSelection.removeAll()
                        } else {
                            folderSelection = Set(currentEntries.map(\.id))
                        }
                    }
                )
            } else {
                let allSelected = !items.isEmpty && selection.count == items.count
                let someSelected = !selection.isEmpty
                SelectAllButton(
                    allSelected: allSelected,
                    someSelected: someSelected,
                    enabled: !items.isEmpty,
                    action: {
                        if allSelected {
                            selection.removeAll()
                        } else {
                            selection = Set(items.map(\.id))
                        }
                    }
                )
            }
            RevealInFinderButton(enabled: revealEnabled, action: revealAction)
            Spacer()
        }
    }

    private var revealEnabled: Bool {
        if inFolder { return currentFolderURL != nil }
        return !items.isEmpty
    }

    private func revealAction() {
        if let url = currentFolderURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let urls = items.compactMap { $0.fileURL }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private enum NavDirection {
    case forward, back
}

/// Small circular chevron button rendered next to a folder name in the grid
/// label area (below the card). Clicking it descends into the folder; the
/// surrounding card click is reserved for selection so users can pick up a
/// folder without accidentally navigating into it.
private struct InlineNavigateChevron: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 14, height: 14)
                .background(
                    Circle()
                        .fill(Color.white.opacity(hovering ? 0.22 : 0.12))
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Lightweight description of a single child inside a folder being browsed.
/// Created on-demand when the user navigates into a folder; not persisted.
struct FolderEntry: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let isDirectory: Bool
    let displayName: String
    let byteSize: Int64?
    let pixelSize: CGSize?

    init(
        id: UUID = UUID(),
        url: URL,
        isDirectory: Bool,
        displayName: String,
        byteSize: Int64? = nil,
        pixelSize: CGSize? = nil
    ) {
        self.id = id
        self.url = url
        self.isDirectory = isDirectory
        self.displayName = displayName
        self.byteSize = byteSize
        self.pixelSize = pixelSize
    }
}

/// Synchronously enumerates the immediate children of `url`. Intended to be
/// called from a detached task — it's blocking I/O. Hidden files are skipped
/// to match Finder's default view. We deliberately don't pass
/// `.skipsPackageDescendants` because the user explicitly clicked the
/// chevron to descend; macOS would otherwise return `[]` for any directory
/// it considers a package (`.app`, `.bundle`, but also some user-named dirs
/// with extensions registered as packages — e.g. a folder called `dist.js`
/// shows zero children even when it has gigabytes of content).
private func readDirectory(url: URL) -> [FolderEntry] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentTypeKey]
    let urls: [URL]
    do {
        urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
    } catch {
        NSLog("Shelf: readDirectory failed for %@ — %@",
              url.path as NSString, error as NSError)
        return []
    }
    let entries = urls.map { childURL -> FolderEntry in
        let values = try? childURL.resourceValues(forKeys: Set(keys))
        let isDir = values?.isDirectory ?? false
        let bytes: Int64? = isDir ? nil : values?.fileSize.map(Int64.init)
        // Pull pixel dimensions for image children so the grid cell can pre-size
        // itself before the QL thumbnail arrives — keeps the layout from
        // jumping when previews crossfade in.
        let pixelSize: CGSize? = {
            guard !isDir,
                  let type = values?.contentType,
                  type.conforms(to: .image)
            else { return nil }
            return ShelfItem.readImagePixelSize(url: childURL)
        }()
        return FolderEntry(
            url: childURL,
            isDirectory: isDir,
            displayName: childURL.lastPathComponent,
            byteSize: bytes,
            pixelSize: pixelSize
        )
    }
    return entries.sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

/// Grid cell for a single child inside a folder being browsed. Mirrors
/// DocumentGridItem's visual language (card shadow, hover lift, label below)
/// but loads its thumbnail lazily and has no shelf-specific affordances
/// (no remove button, no shelf context menu).
private struct FolderEntryGridCell: View {
    let entry: FolderEntry
    let isSelected: Bool
    /// Receives the click's modifier flags so the caller can implement
    /// cmd-click toggling. Plain click selects only this entry; navigating
    /// into a folder requires the inline chevron next to the name.
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let onNavigateInto: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var thumbnailIsIcon = true

    private static let cardLongSide: CGFloat = 100
    private static let labelMinWidth: CGFloat = 90

    private var cardSize: CGSize {
        if let s = entry.pixelSize, s.width > 0, s.height > 0 {
            let aspect = s.width / s.height
            if aspect.isFinite, aspect > 0 {
                if aspect >= 1 {
                    return CGSize(width: Self.cardLongSide, height: Self.cardLongSide / aspect)
                } else {
                    return CGSize(width: Self.cardLongSide * aspect, height: Self.cardLongSide)
                }
            }
        }
        return CGSize(width: 78, height: 100)
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
                        provider: { [entry.url] },
                        onStart: {},
                        onEnd: {},
                        onClick: onClick,
                        onDoubleClick: onDoubleClick,
                        visibleCardSize: { size }
                    )
                )
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
                .onHover { hovering = $0 }
                .frame(height: Self.cardLongSide, alignment: .bottom)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isDirectory {
                        InlineNavigateChevron(action: onNavigateInto)
                    }
                }
                Text(metaText)
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
        .onAppear { loadThumbnailIfNeeded() }
    }

    private var metaText: String {
        if entry.isDirectory {
            if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
            return "Folder"
        }
        if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
        let ext = entry.url.pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    @ViewBuilder
    private func cardFace(size: CGSize) -> some View {
        let isImageEntry = !entry.isDirectory && entry.pixelSize != nil
        if let thumb = thumbnail {
            if isImageEntry, !thumbnailIsIcon {
                // Real photo preview: fill the whole card, rounded corners.
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
            } else {
                // Everything else (folder icon, app icon, document preview) —
                // render flush against the panel without a white "paper"
                // backdrop, matching the rest of the shelf's visual language.
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        }
    }

    private func loadThumbnailIfNeeded() {
        if thumbnail != nil { return }
        // Workspace icon shows up immediately so the cell isn't a blank
        // square while QL renders. For images we then upgrade to QL's
        // photo thumbnail; for everything else we ask QL only for the
        // higher-resolution icon representation — otherwise QL renders
        // the file's contents on a white "page", which leaks into the
        // shelf's dark UI as a paper-like backdrop.
        thumbnail = NSWorkspace.shared.icon(forFile: entry.url.path)
        thumbnailIsIcon = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let isImageEntry = !entry.isDirectory && entry.pixelSize != nil
        let reprTypes: QLThumbnailGenerator.Request.RepresentationTypes =
            isImageEntry ? .all : .icon
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url,
            size: CGSize(width: 256, height: 320),
            scale: scale,
            representationTypes: reprTypes
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            let isIcon = (rep.type == .icon)
            DispatchQueue.main.async {
                self.thumbnail = image
                self.thumbnailIsIcon = isIcon
            }
        }
    }
}

/// List-view counterpart to FolderEntryGridCell.
private struct FolderEntryListItem: View {
    let entry: FolderEntry
    let isSelected: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let onNavigateInto: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(entry.displayName)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(metaText)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)

            if entry.isDirectory {
                InlineNavigateChevron(action: onNavigateInto)
                    .frame(width: 16, height: 16)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor
                      : Color.white.opacity(hovering ? 0.06 : 0))
        )
        .overlay(
            ShelfDragOverlay(
                provider: { [entry.url] },
                onStart: {},
                onEnd: {},
                onClick: onClick,
                onDoubleClick: onDoubleClick
            )
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onAppear { loadThumbnail() }
    }

    private var metaText: String {
        if entry.isDirectory {
            if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
            return "Folder"
        }
        if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
        let ext = entry.url.pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumb = thumbnail {
            ZStack {
                Color.white.opacity(0.97)
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            }
        } else {
            ZStack {
                Color.white.opacity(0.10)
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }

    private func loadThumbnail() {
        thumbnail = NSWorkspace.shared.icon(forFile: entry.url.path)
    }
}

/// Pill that toggles selection across every item in the shelf. Once items
/// are selected, dragging any tile drags the whole selection (existing
/// behavior in DocumentGridItem / DocumentListItem).
private struct SelectAllButton: View {
    let allSelected: Bool
    let someSelected: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Hide the leading glyph entirely when nothing is selected —
                // the pill reads as a neutral "Select All" affordance until
                // the user picks at least one item.
                if someSelected {
                    Image(systemName: allSelected
                          ? "checkmark.circle.fill"
                          : "circle.dashed")
                        .font(.system(size: 11, weight: .medium))
                }
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
    /// Invoked when the user taps the inline chevron next to a directory's
    /// name. Plain card clicks do not trigger this — the chevron is the
    /// only navigation affordance.
    let onNavigateInto: () -> Void

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
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isDirectory {
                        InlineNavigateChevron(action: onNavigateInto)
                    }
                }
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
    let onNavigateInto: () -> Void

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
                } else if item.isDirectory {
                    InlineNavigateChevron(action: onNavigateInto)
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
