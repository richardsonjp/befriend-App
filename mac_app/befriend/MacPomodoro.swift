//
//  MacPomodoro.swift
//  befriend
//

import AppKit
import PetCore
import UserNotifications

/// How the Mac marks the end of a focus (M10): a chime and a notification.
enum MacPomodoro {
    static func announce(_ after: Pomodoro) {
        if after.settings.sound { NSSound(named: "Glass")?.play() }
        let content = UNMutableNotificationContent()
        content.title = "Focus done 🍅"
        content.body = "Nice work. Take a breather."
        let center = UNUserNotificationCenter.current()
        // Asks the first time only; denied notifications just stay silent.
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "pomodoro", content: content, trigger: nil))
        }
    }
}
