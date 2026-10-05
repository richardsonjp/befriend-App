//
//  ShareViewController.swift
//  ExplainShare
//
//  Share › befriend on a screenshot (M31): crop to the part you mean, and the friend explains it right here. The
//  explanation is saved in the App Group, and befriend moves it into its chat when it next comes to the front.
//

import PetCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let done: () -> Void = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ExplainShareView(load: { [weak self] in await self?.sharedImage() }, done: done))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// The shared image, at most 2048 pixels on its long side.
    private func sharedImage() async -> UIImage? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
              let data = await withCheckedContinuation({ (done: CheckedContinuation<Data?, Never>) in
                  _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in done.resume(returning: data) }
              }),
              let image = UIImage(data: data) else { return nil }
        return image.scaled(toLongSide: 2048)
    }
}

private struct ExplainShareView: View {
    let load: () async -> UIImage?
    let done: () -> Void
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var thread: ChatThread?
    /// Off: explained on this iPhone only. On: what it is gets looked up on the web as well.
    @AppStorage("explain.web") private var web = false

    var body: some View {
        NavigationStack {
            Group {
                if let thread {
                    ScreenExplainView(thread: thread, web: web, openChat: nil, close: done)
                } else if let image {
                    CropView(image: image, web: $web, explain: explain, cancel: done)
                } else if loaded {
                    ContentUnavailableView("No picture to explain", systemImage: "photo",
                                           description: Text("Share a screenshot or a photo with befriend."))
                } else {
                    ProgressView()
                }
            }
            .toolbar(thread == nil ? .visible : .hidden, for: .navigationBar)
        }
        .task {
            image = await load()
            loaded = true
        }
    }

    private func explain(_ cropped: UIImage) {
        guard let root = ExplainInbox.newLibrary(), let png = cropped.pngData() else { return done() }
        let thread = ChatThread(Conversation(), library: ChatLibrary(root: root), friend: nil)
        self.thread = thread
        thread.explain(screenshot: png, web: web)
    }
}

/// The screenshot with a box over the part to explain: drag to draw a new box; the whole picture until you do.
private struct CropView: View {
    let image: UIImage
    @Binding var web: Bool
    let explain: (UIImage) -> Void
    let cancel: () -> Void
    /// The box in the picture's own 0…1 coordinates.
    @State private var box = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        GeometryReader { geometry in
            let fitted = Self.fit(image.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: fitted.width, height: fitted.height)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: fitted))
                    path.addRect(CGRect(x: box.minX * fitted.width, y: box.minY * fitted.height,
                                        width: box.width * fitted.width, height: box.height * fitted.height))
                }
                .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle()
                    .strokeBorder(.white, lineWidth: 2)
                    .frame(width: box.width * fitted.width, height: box.height * fitted.height)
                    .offset(x: box.minX * fitted.width, y: box.minY * fitted.height)
            }
            .frame(width: fitted.width, height: fitted.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { drag in
                let a = Self.unit(drag.startLocation, in: fitted), b = Self.unit(drag.location, in: fitted)
                box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Screenshot. Drag to choose the part to explain.")
        }
        .padding()
        .navigationTitle("Explain")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            ToolbarItem(placement: .bottomBar) {
                Toggle(isOn: $web) { Label("Search the web too", systemImage: "globe") }
                    .toggleStyle(.button)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Explain") { explain(image.cropped(to: box)) }
                    .disabled(box.width < 0.02 || box.height < 0.02)
            }
        }
    }

    static func fit(_ size: CGSize, in space: CGSize) -> CGSize {
        let scale = min(space.width / max(size.width, 1), space.height / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func unit(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }
}

private extension UIImage {
    func scaled(toLongSide limit: CGFloat) -> UIImage {
        let long = max(size.width, size.height) * scale
        guard long > limit else { return self }
        let factor = limit / long
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.width * scale * factor, height: size.height * scale * factor), format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale * factor, height: size.height * scale * factor))) }
    }

    /// The part inside `box` (0…1 of the picture).
    func cropped(to box: CGRect) -> UIImage {
        let upright = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = scale; return f }())
            .image { _ in draw(at: .zero) } // bakes in the orientation
        guard let cg = upright.cgImage else { return self }
        let pixels = CGRect(x: box.minX * CGFloat(cg.width), y: box.minY * CGFloat(cg.height),
                            width: box.width * CGFloat(cg.width), height: box.height * CGFloat(cg.height)).integral
        guard let part = cg.cropping(to: pixels) else { return self }
        return UIImage(cgImage: part)
    }
}
