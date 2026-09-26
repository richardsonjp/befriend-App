//
//  MacPomodoro.swift
//  befriend
//

import AppKit
import PetCore
import UserNotifications

/// How the Mac marks a pomodoro phase end (M10): a chime and a notification.
enum MacPomodoro {
    static func announce(ended: PomodoroPhase, next: Pomodoro) {
        if next.settings.sound { NSSound(named: "Glass")?.play() }
        let content = UNMutableNotificationContent()
        switch ended {
        case .focus:
            content.title = "Focus done 🍅"
            content.body = next.phase == .longBreak ? "Time for a long break." : "Time for a short break."
        case .shortBreak, .longBreak:
            content.title = "Break's over"
            content.body = next.status == .running ? "Focus started." : "Ready to focus?"
        }
        let center = UNUserNotificationCenter.current()
        // Asks the first time only; denied notifications just stay silent.
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "pomodoro", content: content, trigger: nil))
        }
    }
}
