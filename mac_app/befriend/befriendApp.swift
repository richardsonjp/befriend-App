//
//  befriendApp.swift
//  befriend
//
//  Created by Richardson Jayaputra on 10/09/26.
//

import SwiftUI

@main
struct befriendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // ponytail: agent app (LSUIElement) — the pet lives in PetPanel, no SwiftUI windows.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pet = PetStateMachine()
    private let brain = PetBrain()
    private var panel: PetPanel?
    private var monitor: TriggerMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        brain.onReaction = { [pet] in pet.apply($0) }
        let panel = PetPanel(rootView: PetView(pet: pet, simulate: { [brain] in brain.handle($0) }))
        panel.orderFrontRegardless()
        self.panel = panel

        let monitor = TriggerMonitor { [brain] in brain.handle($0) }
        monitor.start()
        self.monitor = monitor
    }
}
