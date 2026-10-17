import StudyCore
import StudyUI
import SwiftUI

/// Mail account settings (Settings ▸ Accounts, next to the Claude key): name, email address, uni
/// account name, password, and the servers (the university's, disclosed on demand). Section content: put
/// it in the settings' grouped `Form`.
///
/// Save logs in first (`MailActions.verifyAccount`, which sends nothing), then puts the password
/// in the Keychain (`services.secrets`, item `account.passwordKey`) and saves the row, which never
/// holds the password. The password field is never filled from the Keychain: a stored password
/// shows as dots in its prompt, and is used only while the servers are the ones it was saved for.
/// A failed login shows the reason under the field.
public struct MailAccountSettingsView: View {
    private let accountsQuery: FetchAll<MailAccount>
    private var account: MailAccount? { accountsQuery.wrappedValue.first }

    @Environment(\.studyServices) private var services
    @Environment(\.mailActions) private var actions
    @State private var form = MailAccountForm()
    @State private var filledFrom: MailAccount?
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var phase: Phase = .idle
    @State private var showsServers = false

    enum Phase: Equatable {
        case idle
        case working
        case connected
        case saved
        case failed(String)
    }

    public init() {
        accountsQuery = FetchAll(MailAccount.order(by: \.createdAt))
    }

    private var isDirty: Bool {
        !password.isEmpty || form != (filledFrom.map(MailAccountForm.init) ?? MailAccountForm())
    }

    private var canSubmit: Bool {
        phase != .working && services != nil && form.isComplete && (!password.isEmpty || storedPasswordApplies)
    }

    /// The stored password goes only to the servers it was saved for.
    private var storedPasswordApplies: Bool {
        guard hasStoredPassword, let account else { return false }
        return MailAccountSaver.sameServers(form.account(updating: account), account)
    }

    /// Why the last attempt failed: this form's, else the sync engine's last error.
    private var failure: String? {
        if case .failed(let reason) = phase { return reason }
        if phase == .idle, !isDirty { return account?.lastError }
        return nil
    }

    public var body: some View {
        Section("Mail") {
            TextField("Name", text: $form.displayName)
            TextField("Email Address", text: $form.emailAddress)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
            TextField("Account Name", text: $form.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("Password", text: $password, prompt: Text(storedPasswordApplies ? "••••••••" : ""))
                .onSubmit { if canSubmit { Task { await save() } } }
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Servers", isExpanded: $showsServers) {
                ServerRow(title: "IMAP", host: $form.imapHost, port: $form.imapPort, security: $form.imapSecurity)
                ServerRow(title: "SMTP", host: $form.smtpHost, port: $form.smtpPort, security: $form.smtpSecurity)
                ServerRow(
                    title: "SMTP Fallback", host: $form.smtpFallbackHost, port: $form.smtpFallbackPort,
                    security: $form.smtpFallbackSecurity
                )
            }
            HStack(spacing: 8) {
                if phase == .connected || phase == .saved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Connected"))
                }
                Spacer()
                Button("Test Connection") { Task { await test() } }
                    .disabled(!canSubmit)
                if isDirty {
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit)
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(true)
                }
            }
        }
        .task(id: account) { fill() }
        .onChange(of: form) { if phase != .working { phase = .idle } }
        .onChange(of: password) { if phase != .working { phase = .idle } }
    }

    /// Fills the form from the stored row (once per change of the row; typing is kept otherwise).
    private func fill() {
        guard account != filledFrom || filledFrom == nil else { return }
        let previous = filledFrom.map(MailAccountForm.init) ?? MailAccountForm()
        if form == previous { form = account.map(MailAccountForm.init) ?? MailAccountForm() }
        filledFrom = account
        if let account, let services {
            hasStoredPassword = services.secrets.hasSecret(for: account.passwordKey)
        } else {
            hasStoredPassword = false
        }
    }

    private var saver: MailAccountSaver? {
        services.map { MailAccountSaver(services: $0, actions: actions) }
    }

    private func test() async {
        guard let saver else { return }
        phase = .working
        do {
            try await saver.verify(form: form, password: password, existing: account)
            phase = .connected
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save() async {
        guard let saver else { return }
        phase = .working
        do {
            let saved = try await saver.save(form: form, password: password, existing: account)
            password = ""
            hasStoredPassword = true
            form = MailAccountForm(saved)
            filledFrom = saved
            phase = .saved
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Host, port and security of one server.
private struct ServerRow: View {
    let title: LocalizedStringKey
    @Binding var host: String
    @Binding var port: Int
    @Binding var security: MailSecurity

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("Host", text: $host, prompt: Text(verbatim: ""))
                    .labelsHidden()
                    .autocorrectionDisabled()
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 52)
                Picker("Security", selection: $security) {
                    Text("TLS").tag(MailSecurity.tls)
                    Text("STARTTLS").tag(MailSecurity.startTLS)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// The settings form's fields; defaults are the university's student servers.
struct MailAccountForm: Equatable, Sendable {
    var displayName = ""
    var emailAddress = ""
    var username = ""
    var imapHost = MailAccount.exampleIMAPHost
    var imapPort = 993
    var imapSecurity: MailSecurity = .tls
    var smtpHost = MailAccount.exampleSMTPHost
    var smtpPort = 587
    var smtpSecurity: MailSecurity = .startTLS
    var smtpFallbackHost = MailAccount.exampleSMTPFallbackHost
    var smtpFallbackPort = 465
    var smtpFallbackSecurity: MailSecurity = .tls

    init() {}

    init(_ account: MailAccount) {
        displayName = account.displayName
        emailAddress = account.emailAddress
        username = account.username
        imapHost = account.imapHost
        imapPort = account.imapPort
        imapSecurity = account.imapSecurity
        smtpHost = account.smtpHost
        smtpPort = account.smtpPort
        smtpSecurity = account.smtpSecurity
        smtpFallbackHost = account.smtpFallbackHost ?? ""
        smtpFallbackPort = account.smtpFallbackPort ?? 465
        smtpFallbackSecurity = account.smtpFallbackSecurity ?? .tls
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Enough to log in: an account name, an address, both servers.
    var isComplete: Bool {
        !trimmed(username).isEmpty && MailText.isAddress(trimmed(emailAddress))
            && !trimmed(imapHost).isEmpty && !trimmed(smtpHost).isEmpty
            && (1...65535).contains(imapPort) && (1...65535).contains(smtpPort)
    }

    /// The row to save: `existing` (keeping its id, sync state and creation date) with these
    /// fields, its Keychain item named after the account name.
    func account(updating existing: MailAccount?) -> MailAccount {
        let username = trimmed(self.username)
        var account = existing ?? MailAccount(username: username)
        account.displayName = trimmed(displayName)
        account.emailAddress = trimmed(emailAddress)
        account.username = username
        account.imapHost = trimmed(imapHost)
        account.imapPort = imapPort
        account.imapSecurity = imapSecurity
        account.smtpHost = trimmed(smtpHost)
        account.smtpPort = smtpPort
        account.smtpSecurity = smtpSecurity
        let fallback = trimmed(smtpFallbackHost)
        account.smtpFallbackHost = fallback.isEmpty ? nil : fallback
        account.smtpFallbackPort = fallback.isEmpty ? nil : smtpFallbackPort
        account.smtpFallbackSecurity = fallback.isEmpty ? nil : smtpFallbackSecurity
        account.keychainItem = SecretKey.uniPassword(username: username).rawValue
        account.isEnabled = true
        return account
    }
}

/// Verifies and saves the account: the login check first, then the password into the Keychain,
/// then the row (which names the Keychain item, never the password).
struct MailAccountSaver: Sendable {
    let services: StudyServices
    let actions: MailActions

    enum Failure: LocalizedError, Equatable {
        case missingPassword
        case incomplete

        var errorDescription: String? {
            switch self {
            case .missingPassword: String(localized: "Enter the password.")
            case .incomplete: String(localized: "Enter the email address and account name.")
            }
        }
    }

    /// Logs in with the typed password, else the stored one (same servers only); sends nothing,
    /// stores nothing.
    func verify(form: MailAccountForm, password: String, existing: MailAccount?) async throws {
        guard form.isComplete else { throw Failure.incomplete }
        let account = form.account(updating: existing)
        try await actions.verifyAccount(account, try secret(typed: password, account: account, existing: existing))
    }

    @discardableResult
    func save(form: MailAccountForm, password: String, existing: MailAccount?) async throws -> MailAccount {
        guard form.isComplete else { throw Failure.incomplete }
        var account = form.account(updating: existing)
        let secret = try secret(typed: password, account: account, existing: existing)
        try await actions.verifyAccount(account, secret)
        try services.secrets.setSecret(secret, for: account.passwordKey)
        if let old = existing?.passwordKey, old != account.passwordKey {
            try? services.secrets.removeSecret(for: old)
        }
        account.lastError = nil
        let saved = try await services.records.save(account)
        await actions.accountSaved(saved.id)
        return saved
    }

    /// The typed password, else the one stored for this (or the previous) account name, but only
    /// while every server is the one it was saved for: a changed host or port (a typo, or one
    /// someone talked the student into) must not receive the uni password without it being typed.
    private func secret(typed: String, account: MailAccount, existing: MailAccount?) throws -> String {
        if !typed.isEmpty { return typed }
        guard let existing, Self.sameServers(account, existing) else { throw Failure.missingPassword }
        for key in [account.passwordKey, existing.passwordKey] {
            if let stored = try services.secrets.secret(for: key), !stored.isEmpty { return stored }
        }
        throw Failure.missingPassword
    }

    /// Host, port and security of IMAP, SMTP and the SMTP fallback are the same: where the
    /// password goes.
    static func sameServers(_ account: MailAccount, _ other: MailAccount) -> Bool {
        func servers(_ account: MailAccount) -> [String] {
            [
                account.imapHost.lowercased(), String(account.imapPort), "\(account.imapSecurity)",
                account.smtpHost.lowercased(), String(account.smtpPort), "\(account.smtpSecurity)",
                account.smtpFallbackHost?.lowercased() ?? "", account.smtpFallbackPort.map(String.init) ?? "",
                account.smtpFallbackSecurity.map { "\($0)" } ?? "",
            ]
        }
        return servers(account) == servers(other)
    }
}
