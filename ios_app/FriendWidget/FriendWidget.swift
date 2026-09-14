//
//  FriendWidget.swift
//  FriendWidget
//

import PetCore
import SwiftUI
import WidgetKit

nonisolated struct FriendEntry: TimelineEntry {
    let date: Date
    let name: String?
    let state: FriendSurfaceState?
    let skin: InstalledSkin?
}

/// Reads what the app saved in the App Group. The first entry is the friend's latest state; the next six are
/// hourly check-in lines from the phrasebook, so the widget keeps talking while the app stays closed.
/// No FoundationModels here: widgets can't run it.
nonisolated struct FriendTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FriendEntry {
        FriendEntry(date: .now, name: "Your friend", state: FriendSurfaceState(presence: .here, mood: .content, action: .idle, line: "Hi!"),
                    skin: SkinInstaller.current(in: SharedStore.skinsRoot))
    }

    func getSnapshot(in context: Context, completion: @escaping (FriendEntry) -> Void) {
        completion(entries(from: .now, skin: SkinInstaller.current(in: SharedStore.skinsRoot)).first ?? placeholder(in: context))
    }

    /// Asks the backend where the friend is (falling back to what the app last saved) and follows the account's
    /// skin, then builds the entries.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FriendEntry>) -> Void) {
        Task { @MainActor in
            let api = AppConfig.makeAPIClient()
            let owner = try? await api.presence().owner
            let skin = await currentSkin(api: api)
            let entries = entries(from: .now, owner: owner, skin: skin)
            completion(Timeline(entries: entries, policy: .after(entries.last?.date ?? .now.addingTimeInterval(3600))))
        }
    }

    /// A skin picked (or revoked) on another device arrives as a widget push while the app may not be running:
    /// when the account's pick differs from what's installed, download it here.
    @MainActor private func currentSkin(api: APIClient) async -> InstalledSkin? {
        let store = SkinStore(root: SharedStore.skinsRoot)
        if api.isSignedIn, let settings = try? await api.syncSettings(), settings.skinId != store.current?.pickID {
            await store.sync(api: api)
        }
        return store.current
    }

    func entries(from now: Date, owner: PresenceOwner? = nil, skin: InstalledSkin?) -> [FriendEntry] {
        guard let friend = SharedStore.loadFriend(), friend.isReady else {
            return [FriendEntry(date: now, name: nil, state: nil, skin: skin)]
        }
        var current = SharedStore.loadSurface()
        if let owner, let saved = current {
            current = FriendSurfaceState(presence: owner == .mac ? .onMac : .here, mood: saved.mood, action: saved.action, line: saved.line)
        } else if owner == .mac {
            current = FriendSurfaceState(presence: .onMac, mood: .content, action: .idle, line: "")
        }
        var entries = [FriendEntry(date: now, name: friend.name, state: current, skin: skin)]
        guard let phrasebook = friend.phrasebook, current?.presence != .onMac else { return entries }
        for hour in 1...6 {
            guard let line = phrasebook.reaction(for: .checkIn, mood: current?.mood) else { break }
            let date = now.addingTimeInterval(Double(hour) * 3600)
            let state = FriendSurfaceState(presence: .here, mood: line.mood, action: line.action, line: line.dialogue, updatedAt: date)
            entries.append(FriendEntry(date: date, name: friend.name, state: state, skin: skin))
        }
        return entries
    }
}

struct FriendWidgetView: View {
    let entry: FriendEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if let skin = entry.skin, entry.name != nil, entry.state?.presence != .onMac {
                    PixelImage(url: skin.mini(entry.state?.mood ?? .content))
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: entry.state?.presence == .onMac ? "laptopcomputer" : "cat.fill")
                        .font(.title2)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name ?? "befriend").font(.headline)
                Text(line).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 8) {
                if let state = entry.state, state.presence == .here, let skin = entry.skin {
                    PixelImage(url: skin.still(state.action, state.mood))
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: entry.name == nil ? "cat" : "laptopcomputer")
                        .font(.system(size: 40))
                }
                Text(line)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }

    private var line: String {
        guard entry.name != nil else { return "Open befriend to meet your friend." }
        return entry.state?.displayLine ?? "…"
    }
}

struct FriendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FriendWidget", provider: FriendTimelineProvider()) { entry in
            FriendWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Your friend")
        .description("See what your friend is up to.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        .pushHandler(FriendWidgetPushHandler.self)
    }
}

/// Uploads the widget push token, which lets the backend reload the widget when the friend moves between devices
/// or the account's skin changes.
nonisolated struct FriendWidgetPushHandler: WidgetPushHandler {
    init() {}

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = pushInfo.token.hexString
        Task { @MainActor in
            try? await AppConfig.makeAPIClient().updatePushTokens(PushTokens(apnsEnv: AppConfig.apnsEnvironment, widgetPushToken: token))
        }
    }
}
