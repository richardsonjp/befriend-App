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
    /// A line about an earlier chat (M19): tapping the widget opens its follow-up.
    var followUp: ChatFollowUp? = nil
    /// What the Lock Screen shows instead of a chat topic: an encouraging line from the same batch.
    var lockLine: String? = nil
}

/// Reads what the app saved in the App Group: an encouraging line an hour, written ahead by the app's on-device
/// model (widgets can't run FoundationModels). Without them yet, the friend's latest state and hourly check-in
/// lines from the phrasebook.
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
        let encouragements = encouragementEntries(from: now, name: friend.name, onMac: owner == .mac, skin: skin)
        guard encouragements.isEmpty else { return encouragements }
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

    /// The line whose hour it is, then the ones still to come.
    private func encouragementEntries(from now: Date, name: String, onMac: Bool, skin: InstalledSkin?) -> [FriendEntry] {
        let lines = SharedStore.loadEncouragements()
        let current = lines.lastIndex { $0.state.updatedAt <= now.timeIntervalSince1970 } ?? 0
        let encouraging = lines.filter { $0.followUp == nil }.map(\.state.line)
        return lines.dropFirst(current).enumerated().map { offset, entry in
            let line = entry.state
            let state = FriendSurfaceState(presence: onMac ? .onMac : .here, mood: line.mood, action: line.action, line: line.line,
                                           updatedAt: Date(timeIntervalSince1970: line.updatedAt))
            let lockLine = entry.followUp == nil ? nil : (encouraging.isEmpty ? Self.lockFallback : encouraging[offset % encouraging.count])
            return FriendEntry(date: max(now, Date(timeIntervalSince1970: line.updatedAt)), name: name, state: state, skin: skin,
                               followUp: entry.followUp, lockLine: lockLine)
        }
    }

    private static let lockFallback = "You've got this!"
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
                Text(entry.lockLine ?? line).font(.caption).lineLimit(2) // chat topics stay off the Lock Screen
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
            .widgetURL(entry.followUp?.url)
        }
    }

    private var line: String {
        guard entry.name != nil else { return "Open befriend to meet your friend." }
        guard let state = entry.state else { return "…" }
        return state.line.isEmpty ? state.displayLine : state.line // encouragement shows even while the friend is on the Mac
    }
}

struct FriendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FriendWidget", provider: FriendTimelineProvider()) { entry in
            FriendWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
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
