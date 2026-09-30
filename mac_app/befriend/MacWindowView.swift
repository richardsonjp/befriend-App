//
//  MacWindowView.swift
//  befriend
//

import AppKit
import AuthenticationServices
import CoreImage.CIFilterBuiltins
import PetCore
import SwiftUI

/// The window a signed-out (or not-yet-hatched) Mac shows.
struct MacWindowView: View {
    let controller: MacController

    var body: some View {
        VStack(spacing: 20) {
            switch controller.stage {
            case .waitingForFriend:
                WaitingView(skin: controller.skins.current)
            default:
                SignInView(controller: controller)
            }
        }
        .padding(28)
        .frame(width: 420, height: 600)
    }
}

private struct WaitingView: View {
    let skin: InstalledSkin?

    var body: some View {
        Spacer()
        CharacterView(skin: skin, action: .sleep, mood: .sleepy)
        Text("Finish setting up your friend on iPhone").font(.title2.bold()).multilineTextAlignment(.center)
        Text("Answer a few questions in befriend on your iPhone. Your friend appears here once it hatches.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        ProgressView()
        Spacer()
    }
}

private struct SignInView: View {
    let controller: MacController

    @State private var appleNonce = Nonce.random()
    @State private var showEmail = false
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        Text("Bring your friend to this Mac").font(.title2.bold())

        VStack(spacing: 10) {
            if let pairing = controller.pairing, let url = controller.pairingURL, let qr = Self.qrImage(for: url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .accessibilityLabel("Pairing QR code")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(pairing.expiresAt.timeIntervalSince(context.date)))
                    Text("Code \(pairing.code) · new code in \(seconds)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(width: 200, height: 200)
            }
            Text("Open the Camera on your iPhone and point it at the code.")
                .multilineTextAlignment(.center)
        }

        Divider()

        VStack(spacing: 10) {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
                request.nonce = Nonce.sha256(appleNonce)
            } onCompletion: { result in
                let nonce = appleNonce
                appleNonce = Nonce.random()
                Task { await run { await controller.appleSignInCompleted(result, nonce: nonce) } }
            }
            .frame(height: 32)

            Button("Continue with Google") { Task { await run { await controller.signInWithGoogle() } } }
                .frame(maxWidth: .infinity)

            if showEmail {
                TextField("Email", text: $email).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
                Button("Sign in") { Task { await run { await controller.signInWithEmail(email: email, password: password) } } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!email.contains("@") || password.isEmpty)
            } else {
                Button("Use email instead") { showEmail = true }
                    .buttonStyle(.link)
            }
        }
        .disabled(busy)

        if let error = controller.errorMessage {
            Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
        }
    }

    private func run(_ action: () async -> Void) async {
        busy = true
        await action()
        busy = false
    }

    static func qrImage(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
