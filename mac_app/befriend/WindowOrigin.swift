//
//  WindowOrigin.swift
//  befriend
//
//  Where a box to explain was taken (M31 F): the app and window under its centre and, in a browser, the tab's site.
//  Window titles come with the Screen Recording permission the capture already needs; a browser's address is asked
//  for by AppleScript (a one-time Automation prompt per browser) and only its domain is kept. Private windows and
//  password managers give the app's name only.
//

import AppKit
import PetCore

nonisolated enum WindowOrigin {
    /// Browsers that tell their tab's address; Firefox can't, so it gets the window title only.
    private static let safari = "com.apple.Safari"
    private static let chromium: Set = ["com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser"]
    private static let passwordManagers: Set = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                                                "com.apple.Passwords", "com.apple.keychainaccess"]

    /// The topmost window (not befriend's) under the centre of `box`, in AppKit screen coordinates.
    @MainActor static func at(_ box: CGRect) async -> ScreenExplainer.Origin? {
        // CGWindowList counts from the top-left of the main display; AppKit from its bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? box.maxY
        let centre = CGPoint(x: box.midX, y: mainHeight - box.midY)
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = windows.first(where: { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let bounds = info[kCGWindowBounds as String] as CFTypeRef?,
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return false }
            return rect.contains(centre)
        }), let pid = window[kCGWindowOwnerPID as String] as? pid_t,
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }

        let name = app.localizedName ?? window[kCGWindowOwnerName as String] as? String ?? "An app"
        let bundle = app.bundleIdentifier ?? ""
        let title = window[kCGWindowName as String] as? String
        if passwordManagers.contains(bundle) { return .init(app: name, hidden: true) }
        guard bundle == safari || chromium.contains(bundle) else { return .init(app: name, title: title) }
        let tab = await Task.detached { () -> (address: String, private: Bool)? in Self.tab(of: bundle, titled: title) }.value
        if tab?.private == true { return .init(app: name, hidden: true) }
        return .init(app: name, title: title, domain: tab.flatMap { ScreenExplainer.Origin.domain(from: $0.address) })
    }

    /// The address of the tab in the browser window with this title (else its front window), and whether it's private.
    /// Nil when Automation is denied or the browser doesn't answer.
    private static func tab(of bundle: String, titled title: String?) -> (address: String, private: Bool)? {
        let name = (title ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // ponytail: Safari doesn't tell scripts a window is private, so those pass as normal; detect via AX if it matters.
        let tab = bundle == safari ? "current tab" : "active tab"
        let source = """
            tell application id "\(bundle)"
                set w to front window
                try
                    set w to first window whose name is "\(name)"
                end try
                set m to ""
                try
                    set m to (mode of w) as text
                end try
                return (URL of \(tab) of w) & linefeed & m
            end tell
            """
        var error: NSDictionary?
        guard let lines = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue?
            .components(separatedBy: "\n"), let address = lines.first, !address.isEmpty else { return nil }
        return (address, lines.dropFirst().first == "incognito")
    }
}
