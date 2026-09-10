//
//  CheckIn.swift
//  befriend
//

import BackgroundTasks
import os

/// The hourly background refresh that lets the friend check in while the app is closed.
enum CheckIn {
    static let taskIdentifier = "com.richardsonjp.befriend.checkin"
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "check-in")

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskScheduler is unavailable in the simulator.
            log.notice("Check-in not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }
}
