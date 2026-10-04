//
//  ExplainInbox.swift
//  PetCore
//
//  Where the iPhone's share extension leaves explained screenshots for the app (M31): each one is a small chat
//  library in the App Group, which the app adopts into its own chat when it comes to the front.
//

import Foundation

public nonisolated enum ExplainInbox {
    public static let appGroup = "group.com.richardsonjp.befriend"

    static func folder(in container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)) -> URL? {
        container?.appending(path: "Explained", directoryHint: .isDirectory)
    }

    /// A fresh library folder for one explanation (the share extension's).
    public static func newLibrary() -> URL? {
        folder()?.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Moves every waiting explanation into the app's chat.
    @MainActor public static func adoptAll(into library: ChatLibrary, container: URL? = nil) {
        guard let folder = container.map({ folder(in: $0) }) ?? folder(),
              let waiting = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for one in waiting where one.hasDirectoryPath { library.adopt(from: one) }
    }
}
