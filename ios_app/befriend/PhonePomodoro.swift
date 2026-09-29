//
//  PhonePomodoro.swift
//  befriend
//

import AudioToolbox
import PetCore
import UserNotifications

/// How the iPhone marks the end of a focus (M10). The app is usually suspended when it ends, so a running focus
/// schedules its own notification; in the app a chime plays instead.
enum PhonePomodoro {
    private static let identifier = "pomodoro"
    /// Bumped by every schedule; a permission answer that arrives after a newer schedule adds nothing.
    private static var generation = 0

    /// Replaces the pending notification with one for the running focus's end, if any.
    static func schedule(_ state: Pomodoro) {
        generation += 1
        let mine = generation
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard let endsAt = state.endsAt, endsAt > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Focus done 🍅"
        content.body = "Nice work. Take a breather."
        content.sound = state.settings.sound ? .default : nil
        let request = UNNotificationRequest(
            identifier: identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: endsAt.timeIntervalSinceNow, repeats: false)
        )
        // Asks the first time only; denied notifications just stay silent.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                if granted, mine == generation { try? await center.add(request) }
            }
        }
    }

    static func chime(_ next: Pomodoro) {
        if next.settings.sound { AudioServicesPlaySystemSound(1007) }
    }
}
