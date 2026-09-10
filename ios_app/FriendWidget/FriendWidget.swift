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
}

/// Reads what the app saved in the App Group. The first entry is the friend's latest state; the next six are
/// hourly check-in lines from the phrasebook, so the widget keeps talking while the app stays closed.
/// No FoundationModels here: widgets can't run it.
nonisolated struct FriendTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FriendEntry {
        FriendEntry(date: .now, name: "Your friend", state: FriendSurfaceState(presence: .here, mood: .content, action: .idle, line: "Hi!"))
    }

    func getSnapshot(in context: Context, completion: @escaping (FriendEntry) -> Void) {
        completion(entries(from: .now).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FriendEntry>) -> Void) {
        let entries = entries(from: .now)
        completion(Timeline(entries: entries, policy: .after(entries.last?.date ?? .now.addingTimeInterval(3600))))
    }

    func entries(from now: Date) -> [FriendEntry] {
        guard let friend = SharedStore.loadFriend(), friend.isReady else {
            return [FriendEntry(date: now, name: nil, state: nil)]
        }
        let current = SharedStore.loadSurface()
        var entries = [FriendEntry(date: now, name: friend.name, state: current)]
        guard let phrasebook = friend.phrasebook, current?.presence != .onMac else { return entries }
        for hour in 1...6 {
            guard let line = phrasebook.reaction(for: .checkIn, mood: current?.mood) else { break }
            let date = now.addingTimeInterval(Double(hour) * 3600)
            let state = FriendSurfaceState(presence: .here, mood: line.mood, action: line.action, line: line.dialogue, updatedAt: date)
            entries.append(FriendEntry(date: date, name: friend.name, state: state))
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
                Image(systemName: entry.state?.presence == .onMac ? "laptopcomputer" : "cat.fill")
                    .font(.title2)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name ?? "befriend").font(.headline)
                Text(line).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 8) {
                if let state = entry.state, state.presence == .here {
                    PlaceholderCharacterView(action: state.action, mood: state.mood, isStatic: true)
                        .scaleEffect(0.75)
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

/// Uploads the widget push token, which lets the backend reload the widget when the friend moves between devices.
nonisolated struct FriendWidgetPushHandler: WidgetPushHandler {
    init() {}

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = pushInfo.token.hexString
        Task { @MainActor in
            try? await AppConfig.makeAPIClient().updatePushTokens(PushTokens(apnsEnv: AppConfig.apnsEnvironment, widgetPushToken: token))
        }
    }
}
