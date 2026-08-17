import SwiftUI

/// The app's Settings screen. Beyond the usual toggles it carries two things
/// the App Store requires of any app with accounts and user-generated content:
/// in-app account deletion (Guideline 5.1.1(v)) and a reachable blocklist plus
/// support contact (Guideline 1.2).
struct SettingsView: View {
    @ObservedObject private var invitations = InvitationStore.shared
    @ObservedObject private var notifications = NotificationManager.shared
    @ObservedObject private var safety = SafetyStore.shared

    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var deleted = false

    /// Where abuse reports and support mail go. Apple requires published
    /// contact information for apps carrying user-generated content.
    static let supportEmail = "support@phototrove.app"

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            // MARK: Account
            Section {
                if let profile = invitations.myProfile {
                    LabeledContent("Username", value: profile.username)
                    if profile.displayName != profile.username {
                        LabeledContent("Display name", value: profile.displayName)
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        if deleting {
                            HStack(spacing: 8) { ProgressView(); Text("Deleting…") }
                        } else {
                            Text("Delete Account")
                        }
                    }
                    .disabled(deleting)
                } else {
                    Text("No account yet")
                        .foregroundStyle(.secondary)
                    Text("You only need one to share albums with friends. Your photos and search work without it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                if invitations.myProfile != nil {
                    Text("Deleting removes your username from the public directory along with all pending invitations and photo requests. Your photos stay on this device.")
                }
            }

            // MARK: Blocked
            Section {
                if safety.blocked.isEmpty {
                    Text("No blocked users")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(safety.blocked) { user in
                        HStack {
                            Text(user.displayName)
                            Spacer()
                            Button("Unblock") { safety.unblock(userRecordID: user.userRecordID) }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            } header: {
                Text("Blocked")
            } footer: {
                Text("Blocked people can't reach your invitation or photo-request inbox, and their albums stay hidden.")
            }

            // MARK: Notifications
            Section("Notifications") {
                Toggle(isOn: Binding(
                    get: { notifications.memoriesEnabled },
                    set: { on in Task { await notifications.setMemoriesEnabled(on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memory reminders")
                        Text("A daily nudge when this day has photos from past years.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Privacy
            Section {
                Label("All search and face grouping runs on this device",
                      systemImage: "iphone.gen3")
                Label("No analytics, no tracking, no third-party servers",
                      systemImage: "hand.raised")
                Label("Only shared albums use iCloud, and only when you share",
                      systemImage: "icloud")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Photos are never uploaded for indexing. Face embeddings never leave this device except through a private, invite-only share you start.")
            }

            // MARK: Support
            Section("Support") {
                Link(destination: URL(string: "mailto:\(Self.supportEmail)")!) {
                    Label("Contact support", systemImage: "envelope")
                }
                LabeledContent("Version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your account?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your username, friends list, and all pending invitations and photo requests are removed. Albums other people already accepted stay in their iCloud — we can't reach those. Your photos are untouched. This can't be undone.")
        }
        .alert("Couldn't delete account",
               isPresented: Binding(get: { deleteError != nil },
                                    set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Account deleted", isPresented: $deleted) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your username is no longer in the directory. You can claim a new one any time.")
        }
    }

    private func performDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await invitations.deleteAccount()
            deleted = true
        } catch {
            deleteError = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Report sheet

/// Report a person for abuse. Reporting also blocks them — someone who reports
/// a user shouldn't need a second action to stop seeing them.
struct ReportUserView: View {
    let userRecordID: String
    let username: String
    /// Free-form note about WHERE this came from (an album name, "photo
    /// request", a comment) so a report is actionable in the dashboard.
    let context: String

    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .harassment
    @State private var details = ""
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
                Section("Details (optional)") {
                    TextField("What happened?", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Text("We review reports within 24 hours. \(username) will also be blocked, so you stop seeing their invitations and albums right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Report \(username)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(sending)
                }
            }
            .alert("Couldn't send report",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Report sent", isPresented: $sent) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Thanks — we'll review it. \(username) is now blocked.")
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await SafetyStore.shared.report(
                reportedUserRecordID: userRecordID,
                reportedUsername: username,
                reason: reason,
                details: details,
                context: context)
            sent = true
        } catch {
            // The block already happened locally, so say so — the user's
            // safety action succeeded even though the upload didn't.
            errorMessage = "\(error.localizedDescription)\n\n\(username) has still been blocked on this device."
        }
    }
}
