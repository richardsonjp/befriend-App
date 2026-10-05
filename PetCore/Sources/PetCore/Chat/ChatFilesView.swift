//
//  ChatFilesView.swift
//  PetCore
//
//  Adding files to chat. The same + menu everywhere (Photos Library, Choose Files…,
//  Paste), plus drag and drop and ⌘V on the Mac. Audio and video start in the device's language; their card or row
//  has a menu to transcribe them again in another one.
//

import FoundationModels
import PhotosUI
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: Adding

/// Everything that adds files to one scope: the chat composer's. Attach its pickers with
/// `.fileAdding(_:)`.
@MainActor @Observable
final class FileAdder {
    let library: ChatLibrary
    let scope: ChatDocument.Scope
    var importing = false
    var pickingPhotos = false
    var photos: [PhotosPickerItem] = []

    static let fileTypes: [UTType] = [.pdf, .image, .audio, .movie, .text, .sourceCode]
    /// What Paste takes from the clipboard as files.
    static let pasteTypes: [UTType] = [.fileURL, .movie, .audio, .pdf, .image]

    init(library: ChatLibrary, scope: ChatDocument.Scope) {
        self.library = library
        self.scope = scope
    }

    func add(_ url: URL, temporary: Bool = false) {
        library.add(url, scope: scope, temporary: temporary)
    }

    func add(_ urls: [URL]) { urls.forEach { add($0) } }

    func addPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let picked = try? await item.loadTransferable(type: PickedMedia.self) else { return }
                add(picked.url, temporary: true)
            }
        }
    }

    /// Copied files arrive as file URLs; screenshots, copied images and videos as data, saved to a temporary file.
    func add(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add(url) }
                }
                continue
            }
            guard let type = Self.pasteTypes.dropFirst().first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            let name = provider.suggestedName ?? "Pasted"
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { file, _, _ in
                guard let file, let copy = Self.temporaryCopy(of: file, name: name, type: type) else { return }
                Task { @MainActor in self.add(copy, temporary: true) }
            }
        }
    }

    /// Paste from the menu: files and images are attached; plain text comes back for the message box.
    func paste() -> String? {
        #if os(macOS)
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls)
            return nil
        }
        let png = board.data(forType: .png)
        if let data = png ?? board.data(forType: .tiff),
           let copy = Self.temporaryFile(data, name: "Pasted image", ext: png != nil ? "png" : "tiff") {
            add(copy, temporary: true)
            return nil
        }
        return board.string(forType: .string)
        #else
        let board = UIPasteboard.general
        let providers = board.itemProviders.filter { provider in
            Self.pasteTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        if !providers.isEmpty {
            add(providers)
            return nil
        }
        return board.string
        #endif
    }

    nonisolated static func temporaryCopy(of file: URL, name: String, type: UTType) -> URL? {
        let ext = file.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "dat") : file.pathExtension
        guard let folder = temporaryFolder() else { return nil }
        let copy = folder.appending(path: "\(name).\(ext)")
        return (try? FileManager.default.copyItem(at: file, to: copy)).map { copy }
    }

    nonisolated static func temporaryFile(_ data: Data, name: String, ext: String) -> URL? {
        guard let folder = temporaryFolder() else { return nil }
        let file = folder.appending(path: "\(name).\(ext)")
        return (try? data.write(to: file)).map { file }
    }

    /// A folder of its own, so a copy keeps its readable name.
    private nonisolated static func temporaryFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)).map { folder }
    }
}

extension View {
    /// The pickers a `FileAdder` shows, and dropping files onto this view.
    func fileAdding(_ adder: FileAdder) -> some View {
        modifier(FileAdding(adder: adder))
    }
}

private struct FileAdding: ViewModifier {
    @Bindable var adder: FileAdder

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $adder.importing, allowedContentTypes: FileAdder.fileTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { adder.add(urls) }
            }
            .photosPicker(isPresented: $adder.pickingPhotos, selection: $adder.photos, matching: .any(of: [.images, .videos]))
            .onChange(of: adder.photos) { _, items in
                guard !items.isEmpty else { return }
                adder.photos = []
                adder.addPhotos(items)
            }
            .dropDestination(for: URL.self) { urls, _ in
                adder.add(urls)
                return !urls.isEmpty
            }
    }
}

/// The + menu: Photos Library, Choose Files…, Paste. Pasted text goes to `pastedText` (the message box).
struct AddFilesMenu<Label: View>: View {
    let adder: FileAdder
    var pastedText: ((String) -> Void)?
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Button("Photos Library", systemImage: "photo.on.rectangle") { adder.pickingPhotos = true }
            Button("Choose Files…", systemImage: "folder") { adder.importing = true }
            Divider()
            Button("Paste", systemImage: "doc.on.clipboard") {
                if let text = adder.paste(), !text.isEmpty { pastedText?(text) }
            }
        } label: {
            label()
        }
    }
}

/// A photo or video from Photos, copied to a temporary file (Vision and AVFoundation read files).
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try copy($0.file) }
        FileRepresentation(importedContentType: .image) { try copy($0.file) }
    }

    private static func copy(_ file: URL) throws -> PickedMedia {
        guard let copy = FileAdder.temporaryCopy(of: file, name: file.deletingPathExtension().lastPathComponent, type: .item) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return PickedMedia(url: copy)
    }
}

// MARK: One file, as the cards and rows show it

/// A file being added, or added: what the composer's cards draw.
struct ChatFileItem: Identifiable {
    enum Status {
        case working(String)
        case failed(String)
        case ready(ChatDocument)
    }

    let id: UUID
    let name: String
    let kind: ChatDocumentKind
    let scope: ChatDocument.Scope
    let language: String?
    let status: Status

    var detail: String {
        switch status {
        case .working(let status): return status
        case .failed(let reason): return reason
        case .ready(let document):
            let passages = document.passages.count == 1 ? "1 passage" : "\(document.passages.count) passages"
            return [document.url?.host()?.replacingOccurrences(of: "www.", with: "") ?? kind.title, passages, document.note]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    var isWorking: Bool { if case .working = status { true } else { false } }
    var isFailed: Bool { if case .failed = status { true } else { false } }
    var isMedia: Bool { kind == .audio || kind == .video }
}

extension ChatLibrary {
    /// Files being added first, then the added ones, newest first.
    func items(in scope: ChatDocument.Scope) -> [ChatFileItem] {
        jobs.filter { $0.scope == scope }.map { job in
            ChatFileItem(id: job.id, name: job.name, kind: job.kind, scope: scope, language: job.language,
                         status: job.failure.map(ChatFileItem.Status.failed) ?? .working(job.status))
        } + documents.filter { $0.scope == scope }.map { document in
            ChatFileItem(id: document.id, name: document.name, kind: document.kind, scope: scope, language: document.language,
                         status: .ready(document))
        }
    }
}

extension ChatDocumentKind {
    var title: String {
        switch self {
        case .text: "Text"
        case .pdf: "PDF"
        case .image: "Image"
        case .audio: "Audio"
        case .video: "Video"
        case .web: "Web"
        case .memory: "Remembered"
        }
    }

    var tint: Color {
        switch self {
        case .text: .gray
        case .pdf: .red
        case .image: .blue
        case .audio: .pink
        case .video: .purple
        case .web: .teal
        case .memory: .purple
        }
    }
}

/// A thumbnail for images and videos, a tinted type tile for the rest; a spinner while it's being added.
struct FileIcon: View {
    let item: ChatFileItem
    let library: ChatLibrary
    var size: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        shape
            .fill(item.kind.tint.gradient)
            .overlay {
                if let url = library.thumbnail(for: item.id), let image = Self.load(url) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind.symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
                }
            }
            .overlay {
                if item.isWorking {
                    ZStack {
                        Color.black.opacity(0.35)
                        ProgressView().controlSize(.small).tint(.white)
                    }
                } else if item.isFailed {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .accessibilityHidden(true)
    }

    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: Spoken language

/// The languages speech-to-text and the friend's model support, loaded once.
@MainActor @Observable
final class ChatLanguages {
    static let shared = ChatLanguages()
    private(set) var speech: [Locale] = []
    @ObservationIgnored private var loading = false

    /// What the on-device model reads and answers in.
    var model: [String] {
        Set(SystemLanguageModel.default.supportedLanguages.compactMap { language in
            language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
        }).sorted()
    }

    func load() async {
        guard speech.isEmpty, !loading else { return }
        loading = true
        speech = await SpeechTranscriber.supportedLocales.sorted { Self.name($0) < Self.name($1) }
    }

    /// Full name, for lists: "English (United States)".
    static func name(_ identifier: String?) -> String {
        guard let identifier else { return "Language" }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Short, for the cards: "English (US)".
    static func shortName(_ identifier: String?) -> String {
        guard let identifier else { return "Language" }
        let locale = Locale(identifier: identifier)
        let language = locale.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? identifier
        return locale.region.map { "\(language) (\($0.identifier))" } ?? language
    }

    static func name(_ locale: Locale) -> String { name(locale.identifier) }
}

/// "English ⌄": transcribes the file again in another language. Off once its source is gone (after a relaunch).
struct SpokenLanguageMenu: View {
    let item: ChatFileItem
    let library: ChatLibrary

    var body: some View {
        let languages = ChatLanguages.shared
        let changeable = library.canTranscribeAgain(item.id)
        HStack(spacing: 4) {
            Menu {
                ForEach(languages.speech, id: \.identifier) { locale in
                    Button(ChatLanguages.name(locale)) { library.transcribe(item.id, in: locale) }
                }
            } label: {
                Text(ChatLanguages.shortName(item.language)).font(.caption)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            .disabled(!changeable)
            .help(changeable ? "The language spoken in this file" : "Add the file again to change its language")
            .accessibilityLabel("Spoken language, \(ChatLanguages.name(item.language))")
            LanguageHelp()
        }
        .font(.caption)
        .task { await languages.load() }
    }
}

/// (?) with which languages work: click it, or hover on the Mac.
struct LanguageHelp: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Which languages work")
        #if os(macOS)
        .onHover { shown = $0 }
        #endif
        .popover(isPresented: $shown) {
            LanguageList().presentationCompactAdaptation(.popover)
        }
    }
}

private struct LanguageList: View {
    var body: some View {
        let languages = ChatLanguages.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Supported languages").font(.headline)
                Text("Speech-to-text only understands some languages. Pick the one spoken in the file.")
                    .font(.callout).foregroundStyle(.secondary)
                section("Speech-to-text", languages.speech.map(ChatLanguages.name))
                section("Your friend reads and answers in", languages.model)
                Text("Files in other languages are still searched by shared words, like names.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: 300, alignment: .leading)
        }
        .frame(maxHeight: 420)
        .task { await languages.load() }
    }

    private func section(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(names.isEmpty ? "Loading…" : Array(Set(names)).sorted().joined(separator: ", ")).font(.callout)
        }
    }
}
