//
//  FilesPage.swift
//  Conduit
//
//  The phone's files, the way Finder shows a disk: a folder at a time,
//  folders first, as a list or as icons with the phone's own thumbnails.
//  Drop files from Finder to send them to the phone; drag them out, or
//  select and Download, to bring them here; double-click a file to edit it
//  in its Mac app, with each save written back to the phone. Over adb — USB,
//  Wi-Fi debugging or the phone's hotspot. Nothing else is ever overwritten.
//

import AppKit
import ConduitDesign
import ConduitState
import SwiftUI
import UniformTypeIdentifiers

struct FilesPage: View {
    @Environment(ConduitStore.self) private var store

    @State private var selection = Set<PhoneFile.ID>()
    @State private var naming = false
    @State private var newFolderName = ""
    @State private var confirmingDelete = false
    @State private var dropTargeted = false
    @AppStorage("files.sort") private var sortKey = FileSort.created
    @AppStorage("files.ascending") private var ascending = false
    @AppStorage("files.view") private var viewMode = FileView.list

    private static let places: [(title: String, folder: String, symbol: String)] = [
        ("Phone Storage", "", "iphone"),
        ("Downloads", "Download", "arrow.down.circle"),
        ("Camera", "DCIM/Camera", "camera"),
        ("Pictures", "Pictures", "photo"),
        ("Documents", "Documents", "doc"),
        ("Movies", "Movies", "film"),
        ("Music", "Music", "music.note"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if store.files.isAvailable {
                browser
                if !store.files.editing.isEmpty {
                    Divider()
                    EditingStrip()
                }
            } else {
                ContentUnavailableView {
                    Label("Files", systemImage: "folder")
                } description: {
                    Text("Files move over adb. Plug the phone in, or connect it over Wi-Fi debugging — or over its own hotspot, from Devices. Files sent from the phone's Conduit app arrive without it.")
                }
                .frame(maxHeight: .infinity)
            }
            // Files the phone sends over Conduit Link show here too, with or
            // without adb.
            if !store.files.transfers.isEmpty {
                Divider()
                TransfersStrip()
            }
        }
        .navigationTitle(folderTitle)
        .toolbar { toolbar }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newFolderName)
            Button("Create") { store.commands?.createPhoneFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In \(folderTitle) on the phone.")
        }
        .confirmationDialog(deleteQuestion, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                store.commands?.deletePhoneFiles(selected)
                selection.removeAll()
            }
        } message: {
            Text("This deletes them from the phone. It can't be undone.")
        }
        .task(id: store.files.isAvailable) {
            if store.files.isAvailable { store.commands?.refreshPhoneFolder() }
        }
    }

    // MARK: - The folder

    private var browser: some View {
        Group {
            switch viewMode {
            case .list: list
            case .icons: icons
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            store.commands?.uploadToPhone(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { overlay }
    }

    /// Folders stay on top, as in Finder; within them, the chosen order.
    private var sortedEntries: [PhoneFile] {
        let sorted = store.files.entries.sorted(using: comparator)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    private var comparator: KeyPathComparator<PhoneFile> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch sortKey {
        case .name: return KeyPathComparator(\.name, comparator: .localizedStandard, order: order)
        case .created: return KeyPathComparator(\.createdOrModified, order: order)
        case .modified: return KeyPathComparator(\.modified, order: order)
        case .size: return KeyPathComparator(\.size, order: order)
        }
    }

    /// The table's column headers and the Sort By menu set the same order.
    private var sortOrder: Binding<[KeyPathComparator<PhoneFile>]> {
        Binding(
            get: { [comparator] },
            set: { orders in
                guard let first = orders.first else { return }
                ascending = first.order == .forward
                sortKey = FileSort.allCases.first { $0.keyPath == first.keyPath } ?? sortKey
            })
    }

    private var list: some View {
        Table(of: PhoneFile.self, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { file in
                HStack(spacing: 8) {
                    FileThumbnail(file: file, size: 26)
                    Text(file.name).lineLimit(1)
                }
            }
            TableColumn("Date Created", value: \.createdOrModified) { file in
                Text(file.createdOrModified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 160, max: 220)
            TableColumn("Date Modified", value: \.modified) { file in
                Text(file.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 160, max: 220)
            TableColumn("Size", value: \.size) { file in
                Text(file.isFolder ? "—" : Int64(clamping: file.size).formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 130)
        } rows: {
            ForEach(sortedEntries) { file in
                TableRow(file)
                    .draggable(dragItem(for: file))
            }
        }
        .contextMenu(forSelectionType: PhoneFile.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            guard ids.count == 1, let file = store.files.entries.first(where: { ids.contains($0.id) }) else { return }
            open(file)
        }
    }

    private var icons: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 12)], spacing: 16) {
                ForEach(sortedEntries) { file in
                    FileTile(file: file, isSelected: selection.contains(file.id))
                        .onTapGesture(count: 2) { open(file) }
                        .onTapGesture { select(file) }
                        .contextMenu { menu(for: selection.contains(file.id) ? selection : [file.id]) }
                        .draggable(dragItem(for: file))
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onTapGesture { selection.removeAll() }
    }

    /// A click selects; Command-click adds to or takes from the selection.
    private func select(_ file: PhoneFile) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
        } else {
            selection = [file.id]
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<PhoneFile.ID>) -> some View {
        let files = store.files.entries.filter { ids.contains($0.id) }
        if files.count == 1, let file = files.first {
            Button("Open") { open(file) }
            if !file.isFolder {
                Button("Open a Copy") { store.commands?.openPhoneFile(file) }
            }
        }
        if !files.isEmpty {
            Button("Download") { download(files) }
            Divider()
            Button("Delete…", role: .destructive) {
                selection = ids
                confirmingDelete = true
            }
        }
    }

    /// Dropped in Finder, a file is brought over first and then handed on.
    private func dragItem(for file: PhoneFile) -> PhoneFileDrag {
        let store = store
        return PhoneFileDrag(file: file) { @MainActor file in
            guard let commands = store.commands else { throw CocoaError(.fileNoSuchFile) }
            return try await commands.exportPhoneFile(file)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(4)
                .allowsHitTesting(false)
        } else if store.files.isLoading && store.files.entries.isEmpty {
            ProgressView()
        } else if let error = store.files.error {
            ContentUnavailableView {
                Label("Couldn't Open This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { store.commands?.refreshPhoneFolder() }
            }
        } else if store.files.entries.isEmpty && !store.files.isLoading {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("Drop files here to send them to the phone."))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { goUp() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!store.files.isAvailable || store.files.folder == FilesState.root)
                .help("The folder this one is in")
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(Self.places, id: \.title) { place in
                    Button { go(to: place.folder) } label: { Label(place.title, systemImage: place.symbol) }
                }
            } label: {
                Label("Go To", systemImage: "folder")
            }
            .disabled(!store.files.isAvailable)
            .help("Jump to a common folder")
        }
        ToolbarItem {
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(FileView.list)
                Label("Icons", systemImage: "square.grid.2x2").tag(FileView.icons)
            }
            .pickerStyle(.segmented)
            .help("Show the folder as a list or as icons")
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $sortKey) {
                    ForEach(FileSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: $ascending) {
                    Text(sortKey.descendingTitle).tag(false)
                    Text(sortKey.ascendingTitle).tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort by name, date created, date modified or size")
        }
        ToolbarItemGroup {
            Button { newFolderName = ""; naming = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .help("Make a folder here on the phone")
            Button { chooseUploads() } label: { Label("Send to Phone", systemImage: "square.and.arrow.up") }
                .help("Send files from this Mac into this folder")
            Button { download(selected) } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .disabled(selected.isEmpty)
                .help("Download the selected items to \(store.preferences.phoneDownloadsFolder.lastPathComponent) on this Mac")
            Button { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                .disabled(selected.isEmpty)
                .help("Delete the selected items from the phone")
            Button { store.commands?.refreshPhoneFolder() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Read this folder again")
        }
    }

    // MARK: - Actions

    private var selected: [PhoneFile] {
        store.files.entries.filter { selection.contains($0.id) }
    }

    private var folderTitle: String {
        let folder = store.files.folder
        return folder == FilesState.root ? "Phone Storage" : (folder as NSString).lastPathComponent
    }

    private var deleteQuestion: String {
        let files = selected
        return files.count == 1 ? "Delete “\(files[0].name)” from the phone?" : "Delete \(files.count) items from the phone?"
    }

    /// A folder opens here; a file opens in its Mac app for editing.
    private func open(_ file: PhoneFile) {
        if file.isFolder {
            selection.removeAll()
            store.commands?.openPhoneFolder(file.path)
        } else {
            store.commands?.editPhoneFile(file)
        }
    }

    private func go(to place: String) {
        selection.removeAll()
        store.commands?.openPhoneFolder(place.isEmpty ? FilesState.root : "\(FilesState.root)/\(place)")
    }

    private func goUp() {
        selection.removeAll()
        let parent = (store.files.folder as NSString).deletingLastPathComponent
        store.commands?.openPhoneFolder(parent.hasPrefix(FilesState.root) ? parent : FilesState.root)
    }

    private func download(_ files: [PhoneFile]) {
        guard !files.isEmpty else { return }
        store.commands?.downloadPhoneFiles(files, to: store.preferences.phoneDownloadsFolder)
    }

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to Phone"
        panel.message = "Choose files or folders to send to \(folderTitle) on the phone."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        store.commands?.uploadToPhone(panel.urls)
    }

    static func isVideo(_ name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func symbol(for name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// Files open in Mac apps, whose saves go back to the phone.
private struct EditingStrip: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editing").font(.headline)
            ForEach(store.files.editing) { session in
                HStack(spacing: 10) {
                    Image(systemName: "pencil.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).lineLimit(1).truncationMode(.middle)
                        Text(Self.describe(session.status))
                            .font(.caption)
                            .foregroundStyle(Self.isProblem(session.status) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if let copy = session.workingCopy {
                        Button("Show Copy") { NSWorkspace.shared.activateFileViewerSelecting([copy]) }
                            .buttonStyle(.link)
                    }
                    Button("Done") { store.commands?.stopEditing(id: session.id) }
                        .help("Stop sending this file's saves to the phone")
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private static func describe(_ status: EditSession.Status) -> String {
        switch status {
        case .opening: "Opening…"
        case .editing: "Each save goes back to the phone."
        case .saving: "Saving to the phone…"
        case .saved(let date): "Saved to the phone at \(date.formatted(date: .omitted, time: .shortened))."
        case .savedBeside(let name): "The phone's copy changed meanwhile, so this save went beside it, as “\(name)”."
        case .failed(let message): message
        }
    }

    private static func isProblem(_ status: EditSession.Status) -> Bool {
        switch status {
        case .savedBeside, .failed: true
        default: false
        }
    }
}

/// What is moving, each way, with a way to stop it.
private struct TransfersStrip: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                if store.files.transfers.contains(where: \.isFinished) {
                    Button("Clear Finished") { store.commands?.clearFinishedTransfers() }
                        .buttonStyle(.link)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.files.transfers.reversed()) { transfer in
                        TransferRow(transfer: transfer)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(12)
        .background(.bar)
    }
}

private struct TransferRow: View {
    @Environment(ConduitStore.self) private var store
    let transfer: FileTransfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .toMac ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer(minLength: 8)
            if !transfer.isFinished {
                Button { store.commands?.cancelTransfer(id: transfer.id) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop this transfer")
            } else if case .done = transfer.status, let url = transfer.savedTo {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var detail: some View {
        switch transfer.status {
        case .waiting:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .moving:
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                Text(amount).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .done:
            Text(transfer.direction == .toMac ? "Downloaded" : "On the phone").font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var fraction: Double {
        transfer.bytesTotal == 0 ? 0 : min(Double(transfer.bytesDone) / Double(transfer.bytesTotal), 1)
    }

    private var amount: String {
        let done = Int64(clamping: transfer.bytesDone).formatted(.byteCount(style: .file))
        guard transfer.bytesTotal > 0 else { return done }
        return "\(done) of \(Int64(clamping: transfer.bytesTotal).formatted(.byteCount(style: .file)))"
    }
}

// MARK: - Sorting and views

enum FileSort: String, CaseIterable {
    case name, created, modified, size

    var title: String {
        switch self {
        case .name: "Name"
        case .created: "Date Created"
        case .modified: "Date Modified"
        case .size: "Size"
        }
    }

    var ascendingTitle: String {
        switch self {
        case .name: "A to Z"
        case .created, .modified: "Oldest First"
        case .size: "Smallest First"
        }
    }

    var descendingTitle: String {
        switch self {
        case .name: "Z to A"
        case .created, .modified: "Newest First"
        case .size: "Largest First"
        }
    }

    var keyPath: PartialKeyPath<PhoneFile> {
        switch self {
        case .name: \PhoneFile.name
        case .created: \PhoneFile.createdOrModified
        case .modified: \PhoneFile.modified
        case .size: \PhoneFile.size
        }
    }
}

enum FileView: String {
    case list, icons
}

/// A phone file on its way out of Conduit in a drag. Finder asks for the
/// file only when it is dropped; it is brought over then.
struct PhoneFileDrag: Transferable {
    let file: PhoneFile
    let export: @MainActor @Sendable (PhoneFile) async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { drag in
            SentTransferredFile(try await drag.export(drag.file))
        }
        .suggestedFileName { $0.file.name }
    }
}

/// Android's own thumbnail for a photo or video; a symbol for anything else.
struct FileThumbnail: View {
    @Environment(ConduitStore.self) private var store
    let file: PhoneFile
    let size: CGFloat

    private static let images = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: file.isFolder ? "folder.fill" : FilesPage.symbol(for: file.name))
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(file.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.1), style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if image != nil, FilesPage.isVideo(file.name) {
                Image(systemName: "play.fill")
                    .font(.system(size: max(7, size * 0.16)))
                    .foregroundStyle(.white)
                    .padding(max(2, size * 0.05))
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(max(2, size * 0.05))
            }
        }
        .task(id: file.path) {
            guard file.hasThumbnail else { return }
            store.commands?.requestThumbnail(for: file)
            // Held until the row leaves the screen, which cancels the task.
            try? await Task.sleep(for: .seconds(3600))
            if Task.isCancelled { store.commands?.cancelThumbnail(for: file) }
        }
    }

    private var image: NSImage? {
        guard let data = store.files.thumbnails[file.path] else { return nil }
        let key = "\(file.path)|\(data.count)" as NSString
        if let cached = Self.images.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        Self.images.setObject(image, forKey: key)
        return image
    }
}

/// One item in the icon view.
private struct FileTile: View {
    let file: PhoneFile
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            FileThumbnail(file: file, size: 100)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.secondary.opacity(0.25) : .clear))
            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.accentColor : .clear))
        }
        .frame(width: 136)
        .contentShape(Rectangle())
    }
}
