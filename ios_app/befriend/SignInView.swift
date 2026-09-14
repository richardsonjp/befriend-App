//
//  SignInView.swift
//  befriend
//

import AuthenticationServices
import GoogleSignIn
import PetCore
import SwiftUI
import UIKit

struct SignInView: View {
    let model: AppModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var appleNonce = Nonce.random()
    @State private var showEmail = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            CharacterView(skin: model.skins.current, action: .wave, mood: .excited)
            Text("befriend").font(.largeTitle.bold())
            Text("A small friend who lives on your iPhone and your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.email]
                request.nonce = Nonce.sha256(appleNonce) // Apple signs the hash; the backend checks the raw value
            } onCompletion: { result in
                Task { await appleCompleted(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)

            Button {
                Task { await signInWithGoogle() }
            } label: {
                Text("Continue with Google").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button("Continue with email") { showEmail = true }

            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .controlSize(.large)
        .padding(24)
        .disabled(busy)
        .sheet(isPresented: $showEmail) {
            EmailAuthView(model: model)
        }
    }

    private func appleCompleted(_ result: Result<ASAuthorization, Error>) async {
        let nonce = appleNonce
        appleNonce = Nonce.random()
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                model.errorMessage = "Sign in with Apple didn't finish. Please try again."
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                model.errorMessage = "Sign in with Apple didn't finish. Please try again."
                return
            }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            busy = true
            defer { busy = false }
            await model.signIn {
                try await model.api.signInWithApple(identityToken: identityToken, authorizationCode: code, nonce: nonce, device: .current)
            }
        }
    }

    private func signInWithGoogle() async {
        guard !(Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "").isEmpty else {
            model.errorMessage = "Google sign-in isn't set up in this build."
            return
        }
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else { return }

        let nonce = Nonce.random() // Google puts the raw nonce in the ID token
        busy = true
        defer { busy = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil, additionalScopes: nil, nonce: nonce)
            guard let idToken = result.user.idToken?.tokenString else {
                model.errorMessage = "Google sign-in didn't finish. Please try again."
                return
            }
            await model.signIn {
                try await model.api.signInWithGoogle(idToken: idToken, nonce: nonce, device: .current)
            }
        } catch {
            if (error as NSError).code != GIDSignInError.canceled.rawValue {
                model.errorMessage = "Google sign-in didn't finish. Please try again."
            }
        }
    }
}
