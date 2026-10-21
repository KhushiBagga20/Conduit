//
//  FilesPage.swift
//  Conduit
//
//  The phone's files, the way Finder shows a disk: a folder at a time,
//  folders first. Drop files from Finder to send them to the phone; select
//  and Download to bring them here; double-click a file to edit it in its
//  Mac app, with each save written back to the phone. Over adb — USB, Wi-Fi
//  debugging or the phone's hotspot. Nothing else is ever overwritten.
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
        Group {
            if store.files.isAvailable {
                VStack(spacing: 0) {
                    table
                    if !store.files.editing.isEmpty {
                        Divider()
                        EditingStrip()
                    }
                    if !store.files.transfers.isEmpty {
                        Divider()
                        TransfersStrip()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Files", systemImage: "folder")
                } description: {
                    Text("Files move over adb. Plug the phone in, or connect it over Wi-Fi debugging — or over its own hotspot, from Devices.")
                }
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

    // MARK: - The list

    private var table: some View {
        Table(store.files.entries, selection: $selection) {
            TableColumn("Name") { file in
                Label {
                    Text(file.name).lineLimit(1)
                } icon: {
                    Image(systemName: file.isFolder ? "folder.fill" : Self.symbol(for: file.name))
                        .foregroundStyle(file.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            TableColumn("Size") { file in
                Text(file.isFolder ? "—" : Int64(clamping: file.size).formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 130)
            TableColumn("Date Modified") { file in
                Text(file.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 170, max: 230)
        }
        .contextMenu(forSelectionType: PhoneFile.ID.self) { ids in
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
        } primaryAction: { ids in
            guard ids.count == 1, let file = store.files.entries.first(where: { ids.contains($0.id) }) else { return }
            open(file)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            store.commands?.uploadToPhone(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
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

    private static func symbol(for name: String) -> String {
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
