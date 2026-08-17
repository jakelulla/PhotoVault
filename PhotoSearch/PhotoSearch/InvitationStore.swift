import CloudKit
import Foundation
import UIKit

/// Owns the FRIENDS / PROFILE / INVITATION state for the view layer. Mirrors
/// SharedAlbumStore's idiom exactly: a `@MainActor` `ObservableObject` singleton,
/// JSON persistence in the app's documents dir (the same `photosearch` folder),
/// `@Published` state the views observe, and — crucially — NOTHING runs at init
/// or at app launch.
///
/// Every CloudKit entry point first refreshes account status and short-circuits
/// on `CloudKitService.isAvailable == false`, and the launch/push-reachable
/// paths additionally gate on `runningTests`. On the simulator and in the test
/// suite those entry points are never reached at launch, and even if called they
/// fall through to the unavailable path — so this stack is provably inert in the
/// regression gate.
@MainActor
final class InvitationStore: ObservableObject {
    static let shared = InvitationStore()

    /// The current user's claimed public profile, once known. Cached locally so
    /// the invite flow can stamp `fromUsername` without a round-trip, and so the
    /// UI knows whether onboarding is needed.
    @Published private(set) var myProfile: UserProfile?

    /// The user's local friends list (one-way add; the album invite is consent).
    @Published private(set) var friends: [Friend] = []

    /// Pending invitations addressed to me, already filtered against the
    /// handled-set, newest first. Drives the inbox banner/sheet.
    @Published private(set) var pendingInvitations: [Invitation] = []

    /// The most recent inbox-fetch failure, user-facing. Load-bearing signal:
    /// a missing Queryable index on `Invitation.toUserRecordID` (the classic
    /// production misconfiguration) makes every fetch fail — silently swallowing
    /// that rendered the whole invite flow as "no invitations" with no clue.
    @Published private(set) var inboxError: String?

    /// True while a public-DB op (claim, add friend, send invite, fetch inbox)
    /// is in flight — for spinners. Coarse-grained on purpose.
    @Published private(set) var isWorking = false

    private let directory = DirectoryService.shared
    private let cloud = CloudKitService.shared

    /// Invitations the user already accepted/declined, so they don't re-show.
    /// We persist this SET (rather than deleting the sender's public record,
    /// which the recipient generally can't) and treat it as the source of truth.
    private var handled = HandledInvitations()

    /// True once the invitation subscription has been registered this launch, so
    /// we don't re-register on every appearance. Reset only on relaunch.
    private var subscriptionRegistered = false

    /// True once profile recovery has been attempted this launch, so the
    /// app-activation hook doesn't hit the private DB on every foreground for
    /// users who simply never claimed a username.
    private var profileRecoveryAttempted = false

    /// Mirrors ContentView.runningTests — skip launch/push-reachable CloudKit
    /// work in the XCTest host even if some entry point is exercised.
    private static let runningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private init() {}

    // MARK: - Storage paths (same documents/photosearch dir as SharedAlbumStore)

    private static let storeDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("photosearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var friendsURL: URL { storeDir.appendingPathComponent("friends.json") }
    private static var profileURL: URL { storeDir.appendingPathComponent("my_profile.json") }
    private static var handledURL: URL { storeDir.appendingPathComponent("handled_invitations.json") }

    // MARK: - Local cache (pure I/O — safe at any time, never CloudKit)

    /// Hydrate friends + profile + handled-set from disk. Tolerant of
    /// missing/corrupt files (treats as empty). Called from the views' `.task`
    /// for an instant offline view; never at launch.
    func loadLocalCache() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.friendsURL),
           let cached = try? dec.decode([Friend].self, from: data) {
            friends = cached
        }
        if let data = try? Data(contentsOf: Self.profileURL),
           let cached = try? dec.decode(UserProfile.self, from: data) {
            myProfile = cached
        }
        if let data = try? Data(contentsOf: Self.handledURL),
           let cached = try? JSONDecoder().decode(HandledInvitations.self, from: data) {
            handled = cached
        }
    }

    private func persistFriends() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(friends).write(to: Self.friendsURL, options: .atomic)
    }

    private func persistProfile() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let profile = myProfile {
            try? enc.encode(profile).write(to: Self.profileURL, options: .atomic)
        }
    }

    private func persistHandled() {
        try? JSONEncoder().encode(handled).write(to: Self.handledURL, options: .atomic)
    }

    // MARK: - Account deletion

    /// Delete this user's account: erase the public directory presence, then
    /// wipe every local trace of it. Required by App Store Guideline 5.1.1(v).
    ///
    /// The user's PHOTOS are never touched — they were always local, and the
    /// account is only the username other people can find you by. Shared albums
    /// already accepted by others stay in those people's iCloud, which we can
    /// neither reach nor revoke; the confirmation copy says so plainly rather
    /// than implying a reach we don't have.
    func deleteAccount() async throws {
        guard !Self.runningTests else { return }
        isWorking = true
        defer { isWorking = false }

        // Remote first: if this throws, local state is untouched and the user
        // can retry rather than being left with a half-deleted account they
        // can no longer see or manage.
        try await directory.deleteAccount()

        myProfile = nil
        friends = []
        pendingInvitations = []
        handled = HandledInvitations()
        inboxError = nil
        for url in [Self.friendsURL, Self.profileURL, Self.handledURL] {
            try? FileManager.default.removeItem(at: url)
        }
        SafetyStore.shared.clearAll()
        AppGroupSummaryWriter.refresh()
    }

    // MARK: - Profile / onboarding

    /// True when the user has not yet claimed a username. The UI uses this to
    /// present onboarding before Friends / invites.
    var needsOnboarding: Bool { myProfile == nil }

    /// Claim (or update) a username for the current user. On success caches the
    /// profile locally and publishes it. Throws `SharedAlbumError` (notably
    /// `.usernameTaken` / `.unavailable`) for the onboarding UI to surface.
    @discardableResult
    func claimUsername(_ username: String, displayName: String?) async throws -> UserProfile {
        isWorking = true
        defer { isWorking = false }
        let profile = try await directory.claimUsername(username, displayName: displayName)
        myProfile = profile
        persistProfile()
        // Best-effort private-DB pointer so a reinstall / second device can
        // recover this identity instead of demanding a new username.
        await directory.saveUsernamePointer(profile.username)
        return profile
    }

    /// Recover this account's claimed username from the private-DB pointer when
    /// the local profile cache is missing (reinstall, second device). Without
    /// this, that device would prompt for a NEW username and never register the
    /// invitation subscription. Gated in tests and on availability; no-op when a
    /// profile is already known.
    func recoverProfileIfNeeded() async {
        guard !Self.runningTests, myProfile == nil, !profileRecoveryAttempted else { return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        profileRecoveryAttempted = true
        if let profile = await directory.recoverMyProfile() {
            myProfile = profile
            persistProfile()
        }
    }

    /// Called when the app becomes active. Hydrates the local cache and — when
    /// the user actually uses the social layer (a LOCAL profile exists) —
    /// refreshes the invitation inbox and ensures its push subscription is
    /// registered. This is what lets invitations surface without a manual trip
    /// to the Shared Albums screen every launch.
    ///
    /// Deliberately NO profile recovery here: recovery hits CloudKit, and this
    /// hook fires at every cold launch — for a user who never used sharing that
    /// would violate the no-CloudKit-at-launch rule. Recovery runs only at
    /// explicit feature entry (SharedAlbumsView / InviteFriendView).
    func onAppActivate() async {
        guard !Self.runningTests else { return }
        if myProfile == nil { loadLocalCache() }
        guard myProfile != nil else { return }
        await refreshPendingInvitations()
        await registerInvitationSubscriptionIfNeeded()
    }

    /// Set my PUBLIC avatar (decorative; never used for face matching). Updates
    /// the public UserProfile record and refreshes the cached profile + avatar
    /// bytes locally. Throws `.unavailable` when signed out, or `.cloudKit` when
    /// no profile exists yet. Routed here so the @Published myProfile updates.
    func setMyAvatar(_ data: Data) async throws {
        isWorking = true
        defer { isWorking = false }
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            throw SharedAlbumError.unavailable(reason: "Sign in to iCloud to set an avatar")
        }
        guard let username = myProfile?.username else {
            throw SharedAlbumError.cloudKit("Claim a username before setting an avatar.")
        }
        let updated = try await directory.setProfileAvatar(data, forUsername: username)
        myProfile = updated
        persistProfile()
    }

    /// Best-effort refresh of my profile from the directory (e.g. to confirm the
    /// cached username still resolves). No-op when unavailable or not onboarded.
    func refreshMyProfile() async {
        guard !Self.runningTests else { return }
        guard let username = myProfile?.username else { return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        if let fresh = await directory.profile(forUsername: username),
           fresh.userRecordID == myProfile?.userRecordID {
            myProfile = fresh
            persistProfile()
        }
    }

    // MARK: - Friends

    /// Add a friend by username: resolve their public profile and store it
    /// locally. Throws `.cloudKit` (with a friendly message) when no such
    /// username exists, or `.unavailable` when signed out.
    @discardableResult
    func addFriend(byUsername username: String) async throws -> Friend {
        isWorking = true
        defer { isWorking = false }
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            throw SharedAlbumError.unavailable(reason: "Sign in to iCloud to add friends")
        }
        guard let profile = try await directory.findProfile(username: username) else {
            throw SharedAlbumError.cloudKit("No one found with that username.")
        }
        // Don't befriend yourself.
        if let mine = myProfile?.userRecordID, mine == profile.userRecordID {
            throw SharedAlbumError.cloudKit("That's you!")
        }
        let friend = Friend(profile: profile)
        if let idx = friends.firstIndex(where: { $0.userRecordID == friend.userRecordID }) {
            friends[idx] = friend            // refresh display name/case
        } else {
            friends.append(friend)
        }
        friends.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        persistFriends()
        return friend
    }

    /// Remove a friend from the local list. Pure local mutation.
    func removeFriend(_ friend: Friend) {
        friends.removeAll { $0.userRecordID == friend.userRecordID }
        persistFriends()
    }

    // MARK: - Inviting a friend to an album (fully in-app, no share sheet)

    /// Share `album` with `friend` programmatically and write the invitation into
    /// the public inbox. Requires the user to have a profile (for `fromUsername`).
    /// Records the participant for the "same people again" affordance via
    /// SharedAlbumStore. Throws on failure (the UI surfaces it).
    func invite(_ friend: Friend, to album: SharedAlbum) async throws {
        isWorking = true
        defer { isWorking = false }
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            throw SharedAlbumError.unavailable(reason: "Sign in to iCloud to invite friends")
        }
        guard let me = myProfile else {
            // Caller should have onboarded first; guard anyway.
            throw SharedAlbumError.cloudKit("Claim a username before inviting friends.")
        }
        let shareURL = try await directory.shareAlbum(album, toUserRecordID: friend.userRecordID)
        try await directory.sendInvitation(
            toUserRecordID: friend.userRecordID,
            fromUsername: me.username,
            album: album,
            shareURL: shareURL)
    }

    // MARK: - Invitation inbox

    /// Fetch pending invitations addressed to me, filter out already-handled
    /// ones, and publish them newest-first. Tolerant of availability failure
    /// (keeps whatever is cached/empty). Gated in tests. Called from the Shared
    /// Albums view's `.task` and from the push hook — never at launch.
    func refreshPendingInvitations() async {
        guard !Self.runningTests else { return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let fetched = try await directory.fetchPendingInvitations()
            // Blocked senders never reach the inbox. Filtering on the receiving
            // device is what actually protects the user — a serverless design
            // can't stop the send.
            pendingInvitations = SafetyStore.shared.filterBlocked(
                handled.unhandled(fetched), senderID: \.fromUserRecordID)
            inboxError = nil
            // Widget badge stays honest with the inbox.
            AppGroupSummaryWriter.refresh()
        } catch {
            // Surface the failure (small banner in the UI) instead of silently
            // rendering an empty inbox — a missing Queryable index on
            // toUserRecordID fails EVERY fetch and was invisible before.
            inboxError = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
            #if DEBUG
            print("[Invitations] fetch failed: \(error)")
            #endif
        }
    }

    /// Accept an invitation: resolve + accept the share, mark it handled locally,
    /// remove it from the published list, and reload albums (with the same
    /// zone-propagation retry the link path gets) so it actually appears.
    /// THROWS on failure so the inbox UI can show why — a silent no-op here left
    /// the user staring at a spinner that "did nothing".
    func accept(_ invitation: Invitation) async throws {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            throw SharedAlbumError.unavailable(
                reason: "Sign in to iCloud to accept invitations")
        }
        isWorking = true
        defer { isWorking = false }
        try await directory.acceptInvitation(invitation)
        markHandled(invitation)
        // The album now lives in the shared DB — refresh with the propagation
        // retry so the new album shows without a manual pull-to-refresh.
        // Deliberately NO acceptedShareToast here: that alert lives at the tab
        // root and can't present over the open inbox sheet — and the user is
        // already watching the invitation disappear and the album appear.
        await SharedAlbumStore.shared.reloadAfterAccept()
        // Sync pushes should flow even if the user never opens the Shared
        // Albums screen this launch. Idempotent + internally gated.
        await SharedAlbumStore.shared.registerSubscriptionsIfNeeded()
    }

    /// Decline an invitation: mark it handled locally so it stops re-showing.
    /// No CloudKit work — the recipient generally can't delete the sender's
    /// public record, so the local handled-set is the source of truth.
    func decline(_ invitation: Invitation) {
        markHandled(invitation)
    }

    private func markHandled(_ invitation: Invitation) {
        handled.mark(invitation.id)
        persistHandled()
        pendingInvitations.removeAll { $0.id == invitation.id }
    }

    // MARK: - Subscription registration (silent push for the inbox)

    /// Register the invitation-inbox query subscription if not already done this
    /// launch. Idempotent and gated: skips in tests, when iCloud is unavailable,
    /// or once already done. Registers for remote notifications (same pattern as
    /// SharedAlbumStore.registerSubscriptionsIfNeeded) so the silent push is
    /// delivered. Called from the Shared Albums view's `.task`, never at launch.
    func registerInvitationSubscriptionIfNeeded() async {
        guard !Self.runningTests else { return }
        guard !subscriptionRegistered else { return }
        guard myProfile != nil else { return }   // no inbox without a profile
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        // The CKQuerySubscription only delivers if the app is registered for
        // remote notifications. SharedAlbumsView's flow registers via
        // SharedAlbumStore, but THIS path is also reachable from onAppActivate
        // alone — without this call, an invitation push would never arrive.
        UIApplication.shared.registerForRemoteNotifications()
        do {
            try await directory.registerInvitationSubscription()
            subscriptionRegistered = true
        } catch {
            // Subscriptions are an optimization; a failure just means we rely on
            // pull/appear-driven inbox refresh. No error banner.
            #if DEBUG
            print("[Invitations] subscription registration failed: \(error)")
            #endif
        }
    }
}
