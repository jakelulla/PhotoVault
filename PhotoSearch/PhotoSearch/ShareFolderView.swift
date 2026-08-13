import CloudKit
import SwiftUI
import UIKit

/// Turns one of the user's normal (non-smart) folders into a shared album, then
/// hands them the SAME invite affordances a freshly created shared album gets:
/// an in-app "Invite Friend" flow (primary) and a "Share via Link" system sheet
/// (secondary). Presented as a sheet from the folder's context menu / toolbar.
///
/// Flow (reworked for seamlessness + idempotency):
///   1. On appear, RESOLVE the album — the one this folder was already shared
///      as (persisted folderID → albumID link in SharedAlbumStore), or a fresh
///      one. Sharing the same folder twice, or retrying after a failure, always
///      lands on ONE album — never a duplicate.
///   2. The invite affordances appear IMMEDIATELY (the album + its share exist
///      as soon as step 1 finishes); the photo upload continues alongside with
///      a visible progress bar. Uploads dedupe by contentHash in the store, so
///      a retry/re-share adds only new photos.
///   3. The upload runs in an UNSTRUCTURED task owned by the singleton store's
///      published state — dismissing this sheet does not cancel it.
///
/// Like the rest of the shared-albums stack, EVERY CloudKit touch flows through
/// SharedAlbumStore, which guards on `CloudKitService.isAvailable`. On the
/// simulator / in tests the resolve lands in the unavailable path and the view
/// shows the "Sign in to iCloud" state — it does no network work and is inert
/// in the regression gate.
struct ShareFolderView: View {
    /// The folder being shared. We snapshot its id + name + member asset IDs up
    /// front. `folderID` keys the persisted folder→album link.
    let folderID: String?
    let folderName: String
    let assetIDs: [String]

    @ObservedObject private var store = SharedAlbumStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Drives the linear flow: preparing → ready(album) | unavailable | error.
    private enum Phase: Equatable {
        case preparing
        case ready(SharedAlbum)
        case unavailable(reason: String)
        case failed(message: String)
    }
    @State private var phase: Phase = .preparing
    /// Kicks off the resolve exactly once even if the body re-evaluates.
    @State private var started = false

    /// The photo upload's lifecycle, separate from the album's (an upload
    /// hiccup must not hide the invite affordances — the album exists).
    private enum UploadState: Equatable {
        case idle
        case running
        case done(added: Int, alreadyShared: Int)
        case failed(message: String)
    }
    @State private var uploadState: UploadState = .idle

    /// The invite affordances (mirror SharedAlbumsView's own state).
    @State private var friendInviteAlbum: SharedAlbum?
    @State private var inviteTarget: InviteTarget?
    @State private var preparingInvite = false
    /// A link-invite failure shows inline — it must NOT tear down the ready UI.
    @State private var linkError: String?

    /// Upload fraction for the album being prepared (nil when absent).
    private var uploadFraction: Double? {
        guard case .ready(let album) = phase else { return nil }
        return store.uploadProgress[album.id]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .preparing:
                    preparingView
                case .ready(let album):
                    readyView(album: album)
                case .unavailable(let reason):
                    unavailableView(reason: reason)
                case .failed(let message):
                    failedView(message: message)
                }
            }
            .navigationTitle("Share Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // In-app friend invite (programmatic share, no share sheet).
            .sheet(item: $friendInviteAlbum) { album in
                InviteFriendView(album: album)
            }
            // Secondary "Share via Link" system sheet, once the live share resolves.
            .sheet(item: $inviteTarget) { target in
                CloudSharingControllerView(album: target.album, share: target.share)
                    .ignoresSafeArea()
            }
            .overlay {
                if preparingInvite {
                    ProgressView("Preparing invite…").controlSize(.large)
                }
            }
        }
        .interactiveDismissDisabled(phase == .preparing)
        // The single, user-reachable CloudKit trigger for this view. Runs once.
        .task {
            guard !started else { return }
            started = true
            await prepare()
        }
    }

    // MARK: - Phases

    private var preparingView: some View {
        VStack(spacing: 16) {
            ProgressView {
                Text("Setting up shared album…")
                    .font(.subheadline)
            }
        }
    }

    private func readyView(album: SharedAlbum) -> some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("“\(album.name)” is shared", systemImage: "checkmark.circle")
            } description: {
                VStack(spacing: 10) {
                    Text("Invite friends so they can view and add their own photos.")
                    uploadStatusLine
                }
            } actions: {
                Button {
                    friendInviteAlbum = album
                } label: {
                    Label("Invite Friend", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    linkError = nil
                    Task { await presentLinkInvite(for: album) }
                } label: {
                    Label("Share via Link", systemImage: "link")
                }
                .buttonStyle(.bordered)
                if case .failed = uploadState {
                    Button {
                        startUpload(into: album)
                    } label: {
                        Label("Retry Upload", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                if let linkError {
                    Label(linkError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// One line under the header narrating the photo upload: progress while
    /// running, a concrete outcome when finished, the reason on failure.
    @ViewBuilder
    private var uploadStatusLine: some View {
        switch uploadState {
        case .idle:
            EmptyView()
        case .running:
            VStack(spacing: 6) {
                ProgressView(value: uploadFraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
                Text(uploadFraction.map { "Adding photos… \(Int($0 * 100))%" }
                     ?? "Adding photos…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .done(let added, let alreadyShared):
            Label {
                Text(uploadDoneText(added: added, alreadyShared: alreadyShared))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func uploadDoneText(added: Int, alreadyShared: Int) -> String {
        switch (added, alreadyShared) {
        case (0, 0):
            return "No photos to add."
        case (0, _):
            return "All \(alreadyShared) photo\(alreadyShared == 1 ? " is" : "s are") already in the album."
        case (_, 0):
            return "\(added) photo\(added == 1 ? "" : "s") added."
        default:
            return "\(added) photo\(added == 1 ? "" : "s") added (\(alreadyShared) already there)."
        }
    }

    private func unavailableView(reason: String) -> some View {
        ContentUnavailableView {
            Label("Sign in to iCloud", systemImage: "icloud.slash")
        } description: {
            Text(reason)
        } actions: {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func failedView(message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t share this folder", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button {
                Task { await prepare() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    /// Resolve the shared album for this folder (reuse the linked one or create
    /// fresh), show the invite affordances, and kick off the photo upload
    /// alongside. Failures map to the right phase: the benign unavailable case
    /// (simulator / signed out) shows the sign-in state, anything else shows a
    /// retryable error. Retrying is SAFE: the folder→album link + contentHash
    /// dedupe make it idempotent.
    private func prepare() async {
        phase = .preparing
        // Hydrate from disk only when nothing is loaded yet — re-loading the
        // cache here would clobber a fresher in-memory server view. (The
        // folder→album links hydrate lazily inside the store either way.)
        if store.albums.isEmpty { store.loadLocalCache() }

        let resolvable = SharedAlbumStore.resolvableAssetIDs(from: assetIDs)
        // Nothing shareable AND this folder was never shared before → don't
        // create an empty album; explain instead. (If it WAS shared before, fall
        // through — the user still gets the existing album's invite tools.)
        if resolvable.isEmpty,
           folderID.flatMap({ store.linkedAlbumID(forFolder: $0) }) == nil {
            phase = .failed(message: "This folder has no photos still in your library to share.")
            return
        }

        do {
            let album = try await store.shareFolder(folderID: folderID, named: folderName)
            phase = .ready(album)
            if !resolvable.isEmpty {
                startUpload(into: album, assetIDs: resolvable)
            }
        } catch let error as SharedAlbumError {
            if case .unavailable(let reason) = error {
                phase = .unavailable(reason: reason)
            } else {
                phase = .failed(message: error.localizedDescription)
            }
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Upload the folder's members into the album in an UNSTRUCTURED task, so
    /// dismissing the sheet never cancels it (the store publishes progress the
    /// album detail view also shows). Dedupe in the store makes retries safe.
    ///
    /// If an upload for this album is ALREADY running (this sheet was re-opened
    /// mid-upload, or an add is in flight from the detail view), the store
    /// rejects the second call (it would race the dedupe). We wait for the
    /// running upload to finish, then run OUR pass exactly once — the
    /// contentHash dedupe makes that pass add only whatever is still missing,
    /// so the reported counts stay accurate and nothing duplicates.
    private func startUpload(into album: SharedAlbum,
                             assetIDs: [String]? = nil,
                             isRetryAfterWait: Bool = false) {
        let ids = assetIDs ?? SharedAlbumStore.resolvableAssetIDs(from: self.assetIDs)
        guard !ids.isEmpty else {
            uploadState = .done(added: 0, alreadyShared: 0)
            return
        }
        uploadState = .running
        Task { @MainActor in
            do {
                let outcome = try await SharedAlbumStore.shared.addPhotosReportingCount(
                    localAssetIDs: ids, toAlbum: album)
                uploadState = .done(added: outcome.saved,
                                    alreadyShared: outcome.duplicates)
            } catch SharedAlbumError.uploadAlreadyInProgress where !isRetryAfterWait {
                // Wait out the in-flight upload (cheap main-actor polling),
                // then run our own deduped pass once.
                while SharedAlbumStore.shared.uploadProgress[album.id] != nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                startUpload(into: album, assetIDs: ids, isRetryAfterWait: true)
            } catch {
                uploadState = .failed(
                    message: (error as? SharedAlbumError)?.localizedDescription
                        ?? error.localizedDescription)
            }
        }
    }

    /// Resolve the album's live CKShare and present the system invite sheet
    /// (mirrors SharedAlbumsView.presentInvite). Failure shows INLINE — the
    /// album exists and is shared; a transient link hiccup must not replace the
    /// ready UI with a dead-end error screen.
    private func presentLinkInvite(for album: SharedAlbum) async {
        preparingInvite = true
        defer { preparingInvite = false }
        do {
            let share = try await CloudKitService.shared.liveShare(
                for: album.zoneID, title: album.name)
            inviteTarget = InviteTarget(album: album, share: share)
        } catch {
            linkError = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// A resolved invite: an album plus the LIVE server CKShare to present. Held in
/// SwiftUI state so the sheet always receives a real, saved share. (Mirrors the
/// private type in SharedAlbumsView; declared here so this file is standalone.)
struct InviteTarget: Identifiable {
    let album: SharedAlbum
    let share: CKShare
    var id: String { album.id }
}
