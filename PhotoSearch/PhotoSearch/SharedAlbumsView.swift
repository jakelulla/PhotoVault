import CloudKit
import SwiftUI
import UIKit

/// The Shared Albums screen. This is the ONLY UI entry point that touches
/// CloudKit, and only via its `.task` (which calls `refreshAvailability()`).
/// Nothing here runs at app launch.
struct SharedAlbumsView: View {
    @ObservedObject private var store = SharedAlbumStore.shared

    @State private var showCreate = false
    @State private var newName = ""
    /// The resolved invite target: the album plus its LIVE server CKShare. We
    /// only set this once the share is fetched, so the system sheet always gets
    /// a real share (never an unsaved placeholder).
    @State private var inviteTarget: InviteTarget?
    @State private var creating = false
    @State private var preparingInvite = false
    @State private var createError: String?

    var body: some View {
        Group {
            switch store.state {
            case .unavailable(let reason):
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
            case .loading where store.albums.isEmpty:
                ProgressView("Loading Shared Albums…")
            case .ready, .loading, .idle, .error:
                content
            }
        }
        .navigationTitle("Shared Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled({ if case .unavailable = store.state { return true } else { return false } }())
            }
        }
        // CloudKit is only ever touched from here. Load the local cache first
        // for an instant offline view, then check availability + refresh.
        .task {
            store.loadLocalCache()
            await store.refreshAvailability()
            if case .unavailable = store.state { return }
            await store.loadAlbums()
            // Register silent push subscriptions for delta sync. Internally
            // gated on isAvailable AND not-running-tests, and idempotent — so
            // this is the single, post-launch, user-reachable trigger point.
            await store.registerSubscriptionsIfNeeded()
        }
        .alert("New Shared Album", isPresented: $showCreate) {
            TextField("Album name", text: $newName)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Create an album you can invite others to. Photos and the album live in your iCloud.")
        }
        .alert("Couldn't Create Album",
               isPresented: Binding(get: { createError != nil },
                                    set: { if !$0 { createError = nil } })) {
            Button("OK", role: .cancel) { createError = nil }
        } message: {
            Text(createError ?? "")
        }
        // Present the invite (UICloudSharingController) once we have resolved the
        // album's LIVE CKShare from the server.
        .sheet(item: $inviteTarget) { target in
            CloudSharingControllerView(album: target.album, share: target.share)
                .ignoresSafeArea()
        }
        .overlay {
            if preparingInvite { ProgressView("Preparing invite…").controlSize(.large) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.albums.isEmpty {
            ContentUnavailableView {
                Label("No Shared Albums yet", systemImage: "person.2.crop.square.stack")
            } description: {
                Text("Create a shared album to collect photos with friends and family. Everyone you invite can add their own.")
            } actions: {
                Button {
                    newName = ""
                    showCreate = true
                } label: {
                    Label("Create Shared Album", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(creating)
            }
        } else {
            List {
                ForEach(store.albums) { album in
                    NavigationLink {
                        SharedAlbumDetailView(album: album)
                    } label: {
                        SharedAlbumRow(album: album)
                    }
                    // Owners can (re)open the system invite sheet via a swipe
                    // action or context menu — tapping the row now OPENS the
                    // album (Phase 4) rather than presenting the invite.
                    .swipeActions(edge: .trailing) {
                        if album.isOwnedByMe {
                            Button {
                                Task { await presentInvite(for: album) }
                            } label: {
                                Label("Invite", systemImage: "person.badge.plus")
                            }
                            .tint(.blue)
                        }
                    }
                    .contextMenu {
                        if album.isOwnedByMe {
                            Button {
                                Task { await presentInvite(for: album) }
                            } label: {
                                Label("Invite People", systemImage: "person.badge.plus")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if creating { ProgressView().controlSize(.large) }
            }
            .refreshable { await store.loadAlbums() }
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        creating = true
        defer { creating = false }
        do {
            let album = try await store.createAlbum(named: name)
            // On success, resolve the share and present the invite sheet.
            await presentInvite(for: album)
        } catch {
            createError = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Resolve the album's live CKShare, then present the invite sheet. Failures
    /// (offline, unavailable) surface in the create-error alert and simply don't
    /// open the sheet — no crash.
    private func presentInvite(for album: SharedAlbum) async {
        preparingInvite = true
        defer { preparingInvite = false }
        do {
            let share = try await CloudKitService.shared.liveShare(
                for: album.zoneID, title: album.name)
            inviteTarget = InviteTarget(album: album, share: share)
        } catch {
            createError = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// A resolved invite: an album plus the LIVE server CKShare to present. Held in
/// SwiftUI state so the sheet always receives a real, saved share.
private struct InviteTarget: Identifiable {
    let album: SharedAlbum
    let share: CKShare
    var id: String { album.id }
}

/// One album row: name, owner badge, photo count.
private struct SharedAlbumRow: View {
    let album: SharedAlbum

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                Image(systemName: album.isOwnedByMe ? "person.2.fill" : "tray.and.arrow.down.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(ownerBadge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(album.photoCount)")
                    .font(.subheadline.monospacedDigit())
                Text(album.photoCount == 1 ? "photo" : "photos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var ownerBadge: String {
        if album.isOwnedByMe { return "Owned by you" }
        if let owner = album.ownerName { return "Shared by \(owner)" }
        return "Shared with you"
    }
}

// MARK: - UICloudSharingController wrapper (the invite entry point)

/// Presents the system share sheet for an album's LIVE zone-wide CKShare. The
/// share is resolved by the caller (presentInvite) and passed in, so the
/// controller is always initialized with a real, server-saved share — the
/// supported `init(share:container:)` contract. The coordinator is the delegate;
/// it holds the album value (a struct, no cycle) and does NOT strong-ref the
/// SwiftUI view, so there is no retain cycle. Note `UICloudSharingController.delegate`
/// is WEAK; the Coordinator stays alive because SwiftUI's Context retains it for
/// the representable's lifetime while the sheet is presented.
struct CloudSharingControllerView: UIViewControllerRepresentable {
    let album: SharedAlbum
    let share: CKShare

    func makeCoordinator() -> Coordinator { Coordinator(album: album) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: share, container: CloudKitService.shared.container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    /// Delegate for the system invite UI. All access is on the main actor
    /// (UIKit). Holds the album by value and owns nothing that points back, so
    /// there is no cycle. The controller's `delegate` is weak; SwiftUI's Context
    /// keeps this Coordinator alive for the representable's lifetime.
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let album: SharedAlbum

        init(album: SharedAlbum) { self.album = album }

        // The system controller asks for these to render the invite UI.
        func itemTitle(for csc: UICloudSharingController) -> String? { album.name }

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            // TODO(upload-phase): use the album's cover photo bytes. Nil is valid
            // — the system shows a generic icon.
            nil
        }

        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            // Surface to console; the user already sees the system error UI.
            // Nothing to crash on here — degrade quietly.
            #if DEBUG
            print("[SharedAlbums] failed to save share: \(error)")
            #endif
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            // Record the participants we shared with for the "same people again"
            // affordance, then refresh. A freshly invited (pending) participant
            // has NO userRecordID yet — CloudKit only associates an iCloud user
            // record once they accept — so we also key off the participant's
            // lookupInfo (email / phone), which is populated at invite time. Once
            // they accept and we re-fetch, the recordName path fills in too.
            let participantIDs: [String] = (csc.share?.participants ?? [])
                .compactMap { p -> String? in
                    if let rec = p.userIdentity.userRecordID?.recordName { return rec }
                    if let lookup = p.userIdentity.lookupInfo {
                        if let email = lookup.emailAddress { return "email:\(email)" }
                        if let phone = lookup.phoneNumber { return "phone:\(phone)" }
                    }
                    return nil
                }
            Task { @MainActor in
                SharedAlbumStore.shared.noteShared(with: participantIDs)
                await SharedAlbumStore.shared.loadAlbums()
            }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Task { @MainActor in
                await SharedAlbumStore.shared.loadAlbums()
            }
        }
    }
}

// MARK: - Entry point card for FoldersGrid

/// A card consistent with FoldersGrid's other cards that navigates to the
/// Shared Albums screen. Dropped into FoldersGrid as a "Shared Albums" section.
struct SharedAlbumsEntryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "person.2.crop.square.stack.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Shared Albums")
                .font(.subheadline.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text("Share with people")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
