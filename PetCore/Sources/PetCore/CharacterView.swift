//
//  CharacterView.swift
//  PetCore
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The friend in the account's skin: a flipbook of the clip's PNG frames at the skin's fps. Widgets and Live
/// Activities can't animate; they draw `PixelImage` stills (frame 0) instead.
public struct CharacterView: View {
    /// 32-pixel skins at exactly 2×.
    public static let size: CGFloat = 64

    let skin: InstalledSkin?
    let action: PetAction
    let mood: PetMood
    /// Plays the walk cycle instead of the action (the Mac moving the friend around).
    let walking: Bool
    /// Mirrors the friend; skins draw it heading right.
    let facingLeft: Bool
    /// Plays `focus` instead of the action: the friend studying alongside a pomodoro.
    let focusing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(skin: InstalledSkin?, action: PetAction, mood: PetMood, walking: Bool = false, facingLeft: Bool = false,
                focusing: Bool = false) {
        self.skin = skin
        self.action = action
        self.mood = mood
        self.walking = walking
        self.facingLeft = facingLeft
        self.focusing = focusing
    }

    public var body: some View {
        Group {
            if let skin {
                let clip = skin.clip(walking ? InstalledSkin.walk : focusing ? InstalledSkin.focus : action.rawValue, mood.rawValue)
                if reduceMotion {
                    PixelImage(url: skin.frame(clip, 0))
                } else {
                    Flipbook(skin: skin, clip: clip, loops: walking || focusing || !action.isOneShot)
                        .id("\(skin.folder.path)|\(clip.name)") // a new clip starts from frame 0
                }
            } else {
                // ponytail: only when even the built-in skin couldn't be unpacked (a full disk).
                Image(systemName: "cat.fill").font(.system(size: 44)).foregroundStyle(.orange)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .scaleEffect(x: facingLeft ? -1 : 1)
    }
}

/// Steps through a clip's frames; a one-shot holds its last frame.
private struct Flipbook: View {
    let skin: InstalledSkin
    let clip: SkinManifest.Clip
    let loops: Bool
    @State private var start = Date.now

    var body: some View {
        let fps = Double(skin.manifest.fps)
        TimelineView(.periodic(from: start, by: 1 / fps)) { context in
            let step = max(0, Int(context.date.timeIntervalSince(start) * fps))
            // ponytail: re-reads a tiny PNG per frame; cache decoded images if profiling ever shows it
            PixelImage(url: skin.frame(clip, loops ? step % clip.frames : min(step, clip.frames - 1)))
        }
    }
}

/// A pixel-art PNG scaled up without smoothing, so every pixel stays a crisp square.
public struct PixelImage: View {
    let source: Source

    enum Source {
        case file(URL)
        case data(Data)
    }

    public init(url: URL) {
        source = .file(url)
    }

    /// A PNG already in memory, e.g. a shop preview.
    public init(data: Data) {
        source = .data(data)
    }

    public var body: some View {
        if let image = Self.load(source) {
            image.interpolation(.none).resizable().scaledToFit()
        } else {
            // The file went away mid-switch (another process pruned it); the next redraw finds the new skin.
            Image(systemName: "cat.fill").resizable().scaledToFit().foregroundStyle(.orange)
        }
    }

    private static func load(_ source: Source) -> Image? {
        #if canImport(UIKit)
        switch source {
        case .file(let url): UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        case .data(let data): UIImage(data: data).map { Image(uiImage: $0) }
        }
        #else
        switch source {
        case .file(let url): NSImage(contentsOf: url).map { Image(nsImage: $0) }
        case .data(let data): NSImage(data: data).map { Image(nsImage: $0) }
        }
        #endif
    }
}
