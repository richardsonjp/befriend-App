//
//  EmailAuthView.swift
//  befriend
//

import PetCore
import SwiftUI

/// Email sign-in and registration (with the 6-digit verification code).
struct EmailAuthView: View {
    let model: AppModel

    private enum Step { case credentials, verify }

    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.credentials
    @State private var isNewAccount = false
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .credentials:
                    Picker("Account", selection: $isNewAccount) {
                        Text("Sign in").tag(false)
                        Text("Create account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)

                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(isNewAccount ? .newPassword : .password)
                    } footer: {
                        if isNewAccount { Text("At least 8 characters.") }
                    }

                    Button(isNewAccount ? "Create account" : "Sign in") { Task { await submit() } }
                        .disabled(busy || !email.contains("@") || password.count < (isNewAccount ? 8 : 1))
                    if !isNewAccount {
                        Button("I have a verification code") { step = .verify }
                            .disabled(busy || !email.contains("@") || password.isEmpty)
                    }

                case .verify:
                    Section {
                        TextField("6-digit code", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                    } footer: {
                        Text("We sent a code to \(email).")
                    }
                    Button("Verify") { Task { await verify() } }
                        .disabled(busy || code.count != 6)
                    Button("Send a new code") { Task { await resend() } }
                        .disabled(busy)
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if let notice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(step == .verify ? "Verify your email" : "Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        await perform {
            if isNewAccount {
                try await model.api.register(email: email, password: password)
                step = .verify
            } else {
                try await model.api.login(email: email, password: password, device: .current)
                await finish()
            }
        }
    }

    private func verify() async {
        await perform {
            try await model.api.verifyEmail(email: email, code: code)
            try await model.api.login(email: email, password: password, device: .current)
            await finish()
        }
    }

    private func resend() async {
        await perform {
            try await model.api.resendCode(email: email)
            notice = "If that email needs a code, a new one is on its way."
        }
    }

    private func finish() async {
        dismiss()
        await model.refresh()
    }

    private func perform(_ action: () async throws -> Void) async {
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            try await action()
        } catch APIError.server(status: 401, _, _) where step == .credentials {
            self.error = "Wrong email or password, or the email isn't verified yet."
        } catch {
            self.error = AppModel.message(for: error)
        }
    }
}
