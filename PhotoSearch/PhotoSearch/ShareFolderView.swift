import CloudKit
import SwiftUI
import UIKit

/// Turns one of the user's normal (non-smart) folders into a shared album, then
/// hands them the SAME invite affordances a freshly created shared album gets:
/// an in-app "Invite Friend" flow (primary) and a "Share via Link" system sheet
/// (secondary). Presented as a sheet from the folder's context menu / toolbar.
///
/// Flow:
///   1. On appear, create a shared album named after the folder and upload the
///      folder's member photos into it (SharedAlbumStore.shareFolder, which
///      itself reuses createAlbum + addPhotosReportingCount — no duplicated
///      upload logic here). Progress is shown from `store.uploadProgress`.
///   2. On success, show the invite affordances for the new album.
///
/// Like the rest of the shared-albums stack, EVERY CloudKit touch flows through
/// SharedAlbumStore, which guards on `CloudKitService.isAvailable`. On the
/// simulator / in tests the create/upload lands in the unavailable path and the
/// view shows the "Sign in to iCloud" state — it does no network work and is
/// inert in the regression gate.
struct ShareFolderView: View {
    /// The folder being shared. We snapshot its name + member asset IDs up front.
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
    /// Kicks off the create+upload exactly once even if the body re-evaluates.
    @State private var started = false

    /// The invite affordances (mirror SharedAlbumsView's own state).
    @State private var friendInviteAlbum: SharedAlbum?
    @State private var inviteTarget: InviteTarget?
    @State private var preparingInvite = false

    /// Upload fraction for the album currently being prepared (nil when absent).
    private var uploadFraction: Double? {
        guard case .ready(let album) = phase else {
            // While preparing we don't yet know the album id, so read the most
            // recent in-flight fraction if any single upload is running.
            return store.uploadProgress.values.first
        }
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
            ProgressView(value: uploadFraction) {
                Text(uploadFraction == nil
                     ? "Creating shared album…"
                     : "Adding \(assetIDs.count) photo\(assetIDs.count == 1 ? "" : "s")…")
                    .font(.subheadline)
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)
            if let f = uploadFraction {
                Text("\(Int(f * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readyView(album: SharedAlbum) -> some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("“\(album.name)” is shared", systemImage: "checkmark.circle")
            } description: {
                Text("Invite friends so they can view and add their own photos.")
            } actions: {
                Button {
                    friendInviteAlbum = album
                } label: {
                    Label("Invite Friend", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await presentLinkInvite(for: album) }
                } label: {
                    Label("Share via Link", systemImage: "link")
                }
                .buttonStyle(.bordered)
            }
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

    /// Create the shared album from the folder + upload its photos. Maps failures
    /// to the right phase: the benign unavailable case (simulator / signed out)
    /// shows the sign-in state, anything else shows a retryable error.
    private func prepare() async {
        phase = .preparing
        do {
            let album = try await store.shareFolder(named: folderName, localAssetIDs: assetIDs)
            phase = .ready(album)
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

    /// Resolve the album's live CKShare and present the system invite sheet
    /// (mirrors SharedAlbumsView.presentInvite).
    private func presentLinkInvite(for album: SharedAlbum) async {
        preparingInvite = true
        defer { preparingInvite = false }
        do {
            let share = try await CloudKitService.shared.liveShare(
                for: album.zoneID, title: album.name)
            inviteTarget = InviteTarget(album: album, share: share)
        } catch {
            phase = .failed(message: (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription)
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
