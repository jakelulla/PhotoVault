import CloudKit
import SwiftUI
import UIKit

/// The Friends screen: claim a username (onboarding), manage a local friends
/// list, and add friends by username. Reachable from SharedAlbumsView's toolbar.
///
/// Like the rest of the shared-albums stack, every CloudKit touch flows through
/// InvitationStore / DirectoryService, which guard on `CloudKitService.isAvailable`.
/// On the simulator / in tests this view's `.task` lands in the unavailable path
/// and does no network work.
struct FriendsView: View {
    @ObservedObject private var store = InvitationStore.shared
    @ObservedObject private var requests = RequestStore.shared

    @State private var showOnboarding = false
    @State private var showAddFriend = false
    @State private var addError: String?
    @State private var showAvatarPicker = false
    @State private var showFacePhotoPicker = false
    @State private var showCompose = false

    var body: some View {
        Group {
            if store.needsOnboarding {
                onboardingPrompt
            } else {
                friendsList
            }
        }
        .navigationTitle("Friends")
        .toolbar {
            if !store.needsOnboarding {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showAddFriend = true
                        } label: {
                            Label("Add Friend", systemImage: "person.badge.plus")
                        }
                        // Compose a photo request (pick a friend → description →
                        // date/range → face filter → send). Reachable here AND from
                        // the Shared Albums "+" menu.
                        Button {
                            showCompose = true
                        } label: {
                            Label("Request Photos", systemImage: "square.and.arrow.down.on.square")
                        }
                        .disabled(store.friends.isEmpty)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        // Hydrate local cache for an instant view; no CloudKit at launch.
        .task { store.loadLocalCache(); requests.loadLocalCache() }
        .sheet(isPresented: $showOnboarding) {
            UsernameOnboardingView()
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendView()
        }
        .sheet(isPresented: $showCompose) {
            ComposeRequestView()
        }
        .sheet(isPresented: $showAvatarPicker) {
            FacePhotoPickerView(mode: .publicAvatar)
        }
        .sheet(isPresented: $showFacePhotoPicker) {
            FacePhotoPickerView(mode: .privateFace)
        }
    }

    /// Profile-photos section: a PUBLIC avatar (decorative; shown to friends) and
    /// a PRIVATE face photo (local only; used solely to find the user in a
    /// friend's library for face-filtered requests — never uploaded).
    @ViewBuilder
    private var profileSection: some View {
        Section {
            Button {
                showAvatarPicker = true
            } label: {
                HStack {
                    profileAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Public avatar").foregroundStyle(.primary)
                        Text(store.myProfile?.avatarData == nil ? "Not set — shown to friends" : "Tap to change")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                showFacePhotoPicker = true
            } label: {
                HStack {
                    Image(systemName: requests.hasPrivateFacePhoto
                          ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                        .font(.title2).foregroundStyle(.tint).frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private face photo").foregroundStyle(.primary)
                        Text(requests.hasPrivateFacePhoto
                             ? "Set — stays on this device, used only for face-filtered requests"
                             : "Set one to request photos you’re in")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if requests.hasPrivateFacePhoto {
                Button(role: .destructive) {
                    requests.clearPrivateFacePhoto()
                } label: {
                    Label("Remove face photo", systemImage: "trash")
                }
            }
        } header: {
            Text("Your profile")
        } footer: {
            Text("Your private face photo never leaves the device. For a face-filtered request, only a private, friends-only match is shared — never the public directory.")
        }
    }

    @ViewBuilder
    private var profileAvatar: some View {
        ZStack {
            Circle().fill(Color(.secondarySystemBackground))
            if let data = store.myProfile?.avatarData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").foregroundStyle(.tint)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private var onboardingPrompt: some View {
        ContentUnavailableView {
            Label("Set up your username", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Pick a username so friends can find you and invite you to shared albums.")
        } actions: {
            Button {
                showOnboarding = true
            } label: {
                Label("Choose Username", systemImage: "at")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var friendsList: some View {
        List {
            profileSection
            if store.friends.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No friends yet", systemImage: "person.2")
                    } description: {
                        Text("Add friends by username to invite them to shared albums and request photos.")
                    } actions: {
                        Button {
                            showAddFriend = true
                        } label: {
                            Label("Add Friend", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Section {
                    ForEach(store.friends) { friend in
                        FriendRow(friend: friend)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.removeFriend(store.friends[index]) }
                    }
                } header: {
                    if let me = store.myProfile {
                        Text("You are @\(me.username)")
                    }
                }
            }
        }
    }
}

/// One friend row: display name + @username.
private struct FriendRow: View {
    let friend: Friend

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))
                Image(systemName: "person.fill")
                    .foregroundStyle(.tint)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName).font(.body)
                Text("@\(friend.username)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Username onboarding

/// Lightweight sheet to claim a username. Shows taken/error states inline.
struct UsernameOnboardingView: View {
    @ObservedObject private var store = InvitationStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var displayName = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Display name (optional)", text: $displayName)
                } header: {
                    Text("Choose a username")
                } footer: {
                    Text("2–30 characters: letters, numbers, and . _ - — friends use this to find you.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Your Username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Claim") { Task { await claim() } }
                        .disabled(working || !UserProfile.isValidUsername(username))
                }
            }
            .overlay {
                if working { ProgressView().controlSize(.large) }
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func claim() async {
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            _ = try await store.claimUsername(
                username,
                displayName: displayName.isEmpty ? nil : displayName)
            dismiss()
        } catch {
            errorMessage = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Add friend

/// Sheet to add a friend by username (search → add).
struct AddFriendView: View {
    @ObservedObject private var store = InvitationStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Friend's username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Enter the exact username your friend chose.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(working || username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .overlay {
                if working { ProgressView().controlSize(.large) }
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func add() async {
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            _ = try await store.addFriend(byUsername: username)
            dismiss()
        } catch {
            errorMessage = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Invite a friend to an album (friend picker)

/// Sheet listing the user's friends so they can be invited to a specific album,
/// fully in-app (programmatic share + public-DB invitation, no share sheet).
struct InviteFriendView: View {
    let album: SharedAlbum

    @ObservedObject private var store = InvitationStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var inviting: String?       // friend.id currently being invited
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Group {
                if store.needsOnboarding {
                    ContentUnavailableView {
                        Label("Set up your username first", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("Claim a username in Friends before inviting people.")
                    }
                } else if store.friends.isEmpty {
                    ContentUnavailableView {
                        Label("No friends to invite", systemImage: "person.2")
                    } description: {
                        Text("Add friends by username in the Friends screen, then invite them here.")
                    }
                } else {
                    List {
                        if let statusMessage {
                            Section {
                                Label(statusMessage,
                                      systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                                    .foregroundStyle(isError ? .red : .green)
                                    .font(.callout)
                            }
                        }
                        Section("Invite to \(album.name)") {
                            ForEach(store.friends) { friend in
                                Button {
                                    Task { await invite(friend) }
                                } label: {
                                    HStack {
                                        FriendLabel(friend: friend)
                                        Spacer()
                                        if inviting == friend.id {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "paperplane")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                }
                                .disabled(inviting != nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Invite Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { store.loadLocalCache() }
    }

    private func invite(_ friend: Friend) async {
        inviting = friend.id
        statusMessage = nil
        defer { inviting = nil }
        do {
            try await store.invite(friend, to: album)
            isError = false
            statusMessage = "Invited @\(friend.username)."
        } catch {
            isError = true
            statusMessage = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

private struct FriendLabel: View {
    let friend: Friend
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(friend.displayName).foregroundStyle(.primary)
            Text("@\(friend.username)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Invitation inbox

/// A sheet listing pending invitations with Accept / Decline. Presented from
/// SharedAlbumsView when invitations exist.
struct InvitationInboxView: View {
    @ObservedObject private var store = InvitationStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var busy: String?           // invitation.id being accepted

    var body: some View {
        NavigationStack {
            Group {
                if store.pendingInvitations.isEmpty {
                    ContentUnavailableView {
                        Label("No invitations", systemImage: "tray")
                    } description: {
                        Text("Invitations to shared albums will appear here.")
                    }
                } else {
                    List {
                        ForEach(store.pendingInvitations) { invitation in
                            InvitationRow(
                                invitation: invitation,
                                busy: busy == invitation.id,
                                onAccept: { Task { await accept(invitation) } },
                                onDecline: { store.decline(invitation) })
                        }
                    }
                }
            }
            .navigationTitle("Invitations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func accept(_ invitation: Invitation) async {
        busy = invitation.id
        defer { busy = nil }
        await store.accept(invitation)
    }
}

private struct InvitationRow: View {
    let invitation: Invitation
    let busy: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(invitation.albumName).font(.headline)
                Text("from @\(invitation.fromUsername)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(role: .destructive) { onDecline() } label: {
                    Text("Decline")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                Spacer()
                Button { onAccept() } label: {
                    if busy { ProgressView() } else { Text("Accept") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
    }
}
