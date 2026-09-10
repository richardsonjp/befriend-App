//
//  StatusMenu.swift
//  befriend
//

import AppKit
import PetCore

/// The menu bar item: activity sync controls, sign in/out, quit. Rebuilt each time it opens.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: MacController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(controller: MacController) {
        self.controller = controller
        super.init()
        item.button?.image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "befriend")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch controller.stage {
        case .ready:
            let pause = NSMenuItem(title: "Pause Activity Sync", action: #selector(togglePause), keyEquivalent: "")
            pause.state = controller.settings.logSyncPaused ? .on : .off
            menu.addItem(pause.targeted(self))

            let appName = controller.frontmostApp
            let stop = NSMenuItem(title: appName.map { "Stop Tracking “\($0)”" } ?? "Stop Tracking an App", action: appName == nil ? nil : #selector(stopTracking), keyEquivalent: "")
            menu.addItem(stop.targeted(self))
            menu.addItem(NSMenuItem(title: "Delete Synced Activity…", action: #selector(deleteActivity), keyEquivalent: "").targeted(self))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "").targeted(self))
        case .waitingForFriend:
            menu.addItem(NSMenuItem(title: "Show Setup…", action: #selector(showWindow), keyEquivalent: "").targeted(self))
            menu.addItem(NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "").targeted(self))
        case .signedOut, .launching:
            menu.addItem(NSMenuItem(title: "Sign In…", action: #selector(showWindow), keyEquivalent: "").targeted(self))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit befriend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func togglePause() {
        Task { await controller.togglePause() }
    }

    @objc private func stopTracking() {
        Task { await controller.stopTrackingFrontmostApp() }
    }

    @objc private func deleteActivity() {
        let alert = NSAlert()
        alert.messageText = "Delete your synced activity?"
        alert.informativeText = "The app switches and away times befriend has synced are deleted from our server. Your friend stays."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await controller.deleteActivity() }
    }

    @objc private func signOut() {
        Task { await controller.signOut() }
    }

    @objc private func showWindow() {
        controller.reopenWindow()
    }
}

private extension NSMenuItem {
    func targeted(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
