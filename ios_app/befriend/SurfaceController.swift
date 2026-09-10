//
//  SurfaceController.swift
//  befriend
//

import ActivityKit
import Foundation
import os
import PetCore
import WidgetKit

/// Keeps the Lock Screen / Dynamic Island activity and the widget in step with the friend, and uploads the push
/// tokens the backend uses to update them while the app isn't running.
final class SurfaceController {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "surfaces")
    private static let startDates = UserDefaults(suiteName: AppConfig.appGroup)

    private let api: APIClient
    private var tokenTasks: [Task<Void, Never>] = []
    private var observedActivities: Set<String> = []

    init(api: APIClient) {
        self.api = api
    }

    func friendReady(_ friend: FriendProfile, state: FriendSurfaceState) {
        observeTokens()
        SharedStore.saveSurface(state)
        WidgetCenter.shared.reloadAllTimelines()

        let activities = Activity<FriendActivityAttributes>.activities
        // One friend on the Lock Screen: end extras (e.g. a push-to-start that raced the app).
        for extra in activities.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        if let existing = activities.first {
            observeUpdateToken(of: existing)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(
                attributes: FriendActivityAttributes(friendName: friend.name),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: .token
            )
            Self.startDates?.set(Date.now, forKey: activity.id)
            observeUpdateToken(of: activity)
        } catch {
            Self.log.error("Starting the Live Activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(with reaction: PetReaction) {
        let state = FriendSurfaceState(presence: .here, mood: reaction.mood, action: reaction.action, line: reaction.dialogue)
        SharedStore.saveSurface(state)
        WidgetCenter.shared.reloadAllTimelines()
        for activity in Activity<FriendActivityAttributes>.activities {
            Task { await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate)) }
        }
    }

    func signedOut() {
        tokenTasks.forEach { $0.cancel() }
        tokenTasks = []
        observedActivities = []
        for activity in Activity<FriendActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        Self.startDates?.removePersistentDomain(forName: AppConfig.appGroup)
        SharedStore.saveSurface(nil)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Push-to-start lets the backend bring the activity back after it ends (8 hours, or the user dismissed it).
    private func observeTokens() {
        guard tokenTasks.isEmpty else { return }
        tokenTasks.append(Task { [api] in
            for await token in Activity<FriendActivityAttributes>.pushToStartTokenUpdates {
                try? await api.updatePushTokens(PushTokens(apnsEnv: AppConfig.apnsEnvironment, laPushToStartToken: token.hexString))
            }
        })
        tokenTasks.append(Task { [weak self] in
            for await activity in Activity<FriendActivityAttributes>.activityUpdates {
                self?.observeUpdateToken(of: activity)
            }
        })
    }

    private func observeUpdateToken(of activity: Activity<FriendActivityAttributes>) {
        guard observedActivities.insert(activity.id).inserted else { return }
        // Activities started by push-to-start weren't requested here: they start about when we first see them.
        let startedAt = Self.startDates?.object(forKey: activity.id) as? Date ?? .now
        Self.startDates?.set(startedAt, forKey: activity.id)
        tokenTasks.append(Task { [api] in
            for await token in activity.pushTokenUpdates {
                try? await api.updatePushTokens(PushTokens(apnsEnv: AppConfig.apnsEnvironment, laPushToken: token.hexString, laStartedAt: startedAt))
            }
        })
    }
}
