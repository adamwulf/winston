import SwiftUI
import TelegramLink
import WinstonCore
import WinstonLogging

/// The TDLib login steps: phone number, then code, then the 2FA password, driven by `AuthState`.
struct LoginView: View {
    private static let log = Logger(label: "app.login")
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var error: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Winston")
                .font(.largeTitle.bold())
            step
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 360)
        .padding()
        .onChange(of: model.authState) {
            input = ""
            error = nil
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.authState {
        case .starting, .closed, .ready:
            if let startError = model.startError {
                Text("Telegram couldn't start: \(startError)\nQuit and reopen Winston to try again.")
            } else {
                ProgressView("Connecting…")
            }
        case .needsPhoneNumber:
            Text("Enter your phone number, with the country code.")
            TextField("+1 555 123 4567", text: $input)
                #if os(iOS)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                #endif
                .onSubmit { submit { try await model.submitPhoneNumber(input) } }
            submitButton("Send Code") { try await model.submitPhoneNumber(input) }
        case .needsCode:
            Text("Enter the code Telegram sent to your other Telegram apps.")
            TextField("Code", text: $input)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .onSubmit { submit { try await model.submitCode(input) } }
            submitButton("Log In") { try await model.submitCode(input) }
        case .needsPassword(let hint):
            Text("Enter your two-step verification password.")
            SecureField("Password", text: $input)
                .textContentType(.password)
                .onSubmit { submit { try await model.submitPassword(input) } }
            if !hint.isEmpty {
                Text("Hint: \(hint)")
                    .foregroundStyle(.secondary)
            }
            submitButton("Log In") { try await model.submitPassword(input) }
        case .loggingOut:
            ProgressView("Logging out…")
        case .unsupported(let reason):
            // Either a login step Winston doesn't handle, or a setup failure such as a bad api_id/api_hash.
            Text("Winston can't continue logging in:")
            Text(reason)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func submitButton(_ title: String, action: @escaping () async throws -> Void) -> some View {
        Button {
            submit(action)
        } label: {
            if isSubmitting {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSubmitting || input.isEmpty)
    }

    private func submit(_ action: @escaping () async throws -> Void) {
        guard !isSubmitting, !input.isEmpty else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await action()
            } catch {
                // The step's state only: never what was typed (phone number, code, or password).
                Self.log.error("login step failed", error.logContext(["state": model.authState.logName]))
                self.error = userMessage(for: error)
            }
        }
    }
}
