//
//  ChatSyncViews.swift
//  PetCore
//
//  Chat sync in the sidebar (M23): how it's going, and on the Mac the QR code that brings the key to the iPhone
//  (or from it).
//

import CoreImage.CIFilterBuiltins
import SwiftUI

struct ChatSyncStatus: View {
    let sync: ChatSync
    @State private var showingCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            Button("Sync with iPhone…") { showingCode = true }
                .controlSize(.small)
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .sheet(isPresented: $showingCode) { ChatSyncCodeSheet(sync: sync) }
        #endif
    }

    private var text: String {
        switch sync.status {
        case .starting, .syncing: "Syncing chats…"
        case .synced(let date): "Chats synced \(date.formatted(.relative(presentation: .named)))"
        case .offline(let reason): reason
        case .needsKey:
            #if os(macOS)
            "Scan this Mac's code with your iPhone to sync chats."
            #else
            "To sync chats, open Chat on your Mac, choose Sync with iPhone…, and scan the code with your iPhone's Camera."
            #endif
        }
    }

    private var symbol: String {
        switch sync.status {
        case .starting, .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud"
        case .offline: "icloud.slash"
        case .needsKey: "lock.icloud"
        }
    }
}

#if os(macOS)
/// The Mac's code: the iPhone's Camera opens it in befriend, which asks before sending the chat key.
struct ChatSyncCodeSheet: View {
    let sync: ChatSync
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 16) {
            Text("Sync chats with your iPhone").font(.title2.bold())
            Group {
                if let image {
                    Image(decorative: image, scale: 2).interpolation(.none).resizable().frame(width: 220, height: 220)
                } else {
                    ProgressView().frame(width: 220, height: 220)
                }
            }
            .accessibilityLabel("Chat sync code")
            Text("Scan with your iPhone's Camera, then tap Sync in befriend. Your chats are encrypted with a key that only your devices hold.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Label(sync.hasKey ? "This Mac has your chats' key" : "Waiting for your iPhone…",
                  systemImage: sync.hasKey ? "checkmark.seal" : "hourglass")
                .font(.caption)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 380)
        .onAppear {
            var components = URLComponents(string: "befriend://chatsync")!
            components.queryItems = sync.invite().queryItems
            image = components.url.flatMap(Self.code)
        }
        .onDisappear { sync.stopInviting() }
    }

    static func code(_ url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
#endif
