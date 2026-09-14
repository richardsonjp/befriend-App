//
//  CharacterView.swift
//  PetCore
//

import Lottie
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The friend in the account's skin: the skin's Lottie playing the action's marker with the mood's face shown.
/// Widgets and Live Activities can't host Lottie; they draw `PixelImage` stills instead.
public struct CharacterView: View {
    /// 32-pixel skins at exactly 2×.
    public static let size: CGFloat = 64

    let skin: InstalledSkin?
    let action: PetAction
    let mood: PetMood

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(skin: InstalledSkin?, action: PetAction, mood: PetMood) {
        self.skin = skin
        self.action = action
        self.mood = mood
    }

    public var body: some View {
        Group {
            if let skin, reduceMotion {
                PixelImage(url: skin.still(action, mood))
            } else if let skin {
                animation(skin)
            } else {
                // ponytail: only when even the built-in skin couldn't be unpacked (a full disk).
                Image(systemName: "cat.fill").font(.system(size: 44)).foregroundStyle(.orange)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    private func animation(_ skin: InstalledSkin) -> some View {
        var view = LottieView { LottieAnimation.filepath(skin.lottieURL.path) }
            .configuration(LottieConfiguration(renderingEngine: .coreAnimation))
            .resizable()
            .playbackMode(.playing(.marker(action.rawValue, loopMode: action.isOneShot ? .playOnce : .loop)))
        for face in PetMood.allCases {
            view = view.valueProvider(
                FloatValueProvider(face == mood ? 100 : 0),
                for: AnimationKeypath(keypath: "\(InstalledSkin.faceLayer(face)).Transform.Opacity")
            )
        }
        return view.id(skin.folder) // a new skin or version loads a new animation
    }
}

/// A pixel-art PNG scaled up without smoothing, so every pixel stays a crisp square.
public struct PixelImage: View {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        if let image = Self.load(url) {
            image.interpolation(.none).resizable().scaledToFit()
        } else {
            // The file went away mid-switch (another process pruned it); the next redraw finds the new skin.
            Image(systemName: "cat.fill").resizable().scaledToFit().foregroundStyle(.orange)
        }
    }

    private static func load(_ url: URL) -> Image? {
        #if canImport(UIKit)
        UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #else
        NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #endif
    }
}
