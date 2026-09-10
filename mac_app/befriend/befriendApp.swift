//
//  befriendApp.swift
//  befriend
//
//  Created by Richardson Jayaputra on 10/09/26.
//

import AppKit
import SwiftUI

@main
struct befriendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // ponytail: agent app (LSUIElement): the friend lives in PetPanel, sign-in in its own NSWindow.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MacController()
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenu(controller: controller)
        Task { await controller.start() }
    }
}
