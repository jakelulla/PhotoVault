import AVKit
import CloudKit
import PhotosUI
import SwiftUI
import UIKit

/// The contents of one shared album: a thumbnails-first grid of its photos.
///
/// Loading strategy (Phase 4): the grid fetches records with `desiredKeys` that
/// EXCLUDE the full image (CloudKitService.loadPhotos), so we only download
/// ~256px thumbnails up front. The full-resolution bytes are pulled lazily, on
/// tap, by the full-screen viewer. Pull-to-refresh re-fetches; an "Add Photos"
/// toolbar button presents a PHPicker and contributes the selection.
///
/// Like the rest of the shared-albums stack, every CloudKit touch flows through
/// SharedAlbumStore, which guards on `CloudKitService.isAvailable`. On the
/// simulator / in tests this view's `.task` lands in the unavailable path and
/// does no network work.
struct SharedAlbumDetailView: View {
    let album: SharedAlbum

    @ObservedObject private var store = SharedAlbumStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var opened: SharedPhoto?
    @State private var showPeople = false
    @State private var friendInviteAlbum: SharedAlbum?
    @State private var confirmDelete = false
    @State private var actionError: String?
    /// On-device CLIP search over this album (device only).
    @State private var searchText = ""
    @State private var searchResults: [SharedPhoto]?
    /// Save-all confirmation + completion toast.
    @State private var confirmSaveAll = false
    @State private var saveToast: String?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var photos: [SharedPhoto] { store.photosByAlbum[album.id] ?? [] }
    private var isLoading: Bool { store.loadingPhotos.contains(album.id) }
    private var uploadFraction: Double? { store.uploadProgress[album.id] }
    private var saveFraction: Double? { store.savingToLibrary[album.id] }
    /// What the grid shows: search results when a query is active, else all.
    private var displayPhotos: [SharedPhoto] { searchResults ?? photos }

    var body: some View {
        Group {
            if photos.isEmpty && isLoading {
                ProgressView("Loading photos…")
            } else if photos.isEmpty {
                ContentUnavailableView {
                    Label("No photos yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Tap + to add photos to this album. Everyone you've invited can add their own.")
                } actions: {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Add Photos", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(uploadFraction != nil)
                }
            } else {
                grid
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(uploadFraction != nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showPeople = true
                    } label: {
                        Label("People", systemImage: "person.2")
                    }
                    if album.isOwnedByMe {
                        Button {
                            friendInviteAlbum = album
                        } label: {
                            Label("Invite Friend", systemImage: "person.badge.plus")
                        }
                    }
                    Button {
                        confirmSaveAll = true
                    } label: {
                        Label("Save All to Library", systemImage: "square.and.arrow.down")
                    }
                    .disabled(photos.isEmpty || saveFraction != nil)
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(album.isOwnedByMe ? "Delete Album" : "Leave Album",
                              systemImage: album.isOwnedByMe ? "trash" : "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Save \(photos.count) item\(photos.count == 1 ? "" : "s") to your library?",
            isPresented: $confirmSaveAll, titleVisibility: .visible
        ) {
            Button("Save All") {
                let all = photos
                Task {
                    let result = await store.saveToLibrary(all, from: album)
                    if result.saved > 0 {
                        saveToast = "Saved \(result.saved) item\(result.saved == 1 ? "" : "s") to your library. They'll be indexed and searchable shortly."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies land in your photo library and get indexed for search automatically.")
        }
        .alert("Saved", isPresented: Binding(get: { saveToast != nil },
                                             set: { if !$0 { saveToast = nil } })) {
            Button("OK", role: .cancel) { saveToast = nil }
        } message: {
            Text(saveToast ?? "")
        }
        // On-device CLIP search over the album's photos (device only — the
        // models don't load on the simulator, so the field hides there).
        .modifier(SharedSearchModifier(
            enabled: store.sharedSearchAvailable,
            text: $searchText))
        .task(id: searchText) {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { searchResults = nil; return }
            // Small debounce so we don't embed on every keystroke.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            searchResults = await store.searchShared(album: album, query: query)
        }
        .sheet(isPresented: $showPeople) {
            AlbumPeopleView(album: album)
        }
        .sheet(item: $friendInviteAlbum) { album in
            InviteFriendView(album: album)
        }
        .confirmationDialog(
            album.isOwnedByMe
                ? "Delete \u{201C}\(album.name)\u{201D} for everyone?"
                : "Leave \u{201C}\(album.name)\u{201D}?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(album.isOwnedByMe ? "Delete Album" : "Leave Album", role: .destructive) {
                Task {
                    do {
                        try await store.deleteAlbum(album)
                        dismiss()
                    } catch {
                        actionError = store.errorText(for: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(album.isOwnedByMe
                 ? "The album, its photos, and everyone's access are removed. Photos stay in contributors' own libraries."
                 : "The album disappears from your list. The owner and other members keep it.")
        }
        .alert("Couldn't Complete That",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if let fraction = uploadFraction {
                    ProgressView(value: fraction) {
                        Text("Adding photos… \(Int(fraction * 100))%")
                            .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
                if let fraction = saveFraction {
                    ProgressView(value: fraction) {
                        Text("Saving to library… \(Int(fraction * 100))%")
                            .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        // The ONLY CloudKit touch from this view, and only after appear — never
        // at launch. Loads the album's thumbnails-first photo list.
        .task {
            await store.loadPhotos(forAlbum: album)
        }
        .refreshable {
            await store.loadPhotos(forAlbum: album)
        }
        .sheet(isPresented: $showPicker) {
            SharedAlbumPhotoPicker { localIDs in
                guard !localIDs.isEmpty else { return }
                // Call the THROWING variant so a failure surfaces a concrete,
                // persistent reason (the store records it in `albumAlert`, which
                // drives the alert below) instead of a transient "Adding…" that
                // silently reverts to an empty grid.
                Task {
                    do {
                        _ = try await store.addPhotosReportingCount(
                            localAssetIDs: localIDs, toAlbum: album)
                    } catch {
                        // Backstop: ensure a message even if a future path throws
                        // before recording one (the store normally already has).
                        if store.albumAlert[album.id] == nil {
                            store.albumAlert[album.id] = .init(
                                title: "Couldn't Add Photos",
                                message: store.errorText(for: error))
                        }
                    }
                }
            }
        }
        // Surface the concrete failure (mapped CKError) for THIS album — the
        // contribute or reload reason — as a persistent alert. Requirement:
        // "Adding…" must be followed by a visible reason on failure.
        .alert(
            store.albumAlert[album.id]?.title ?? "",
            isPresented: Binding(
                get: { store.albumAlert[album.id] != nil },
                set: { if !$0 { store.albumAlert[album.id] = nil } }),
            presenting: store.albumAlert[album.id]
        ) { _ in
            Button("OK", role: .cancel) { store.albumAlert[album.id] = nil }
        } message: { info in
            Text(info.message)
        }
        .fullScreenCover(item: $opened) { photo in
            SharedPhotoViewer(photo: photo, album: album)
        }
    }

    private var grid: some View {
        ScrollView {
            if searchResults != nil {
                HStack {
                    Text("\(displayPhotos.count) match\(displayPhotos.count == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(displayPhotos) { photo in
                    SharedThumbView(data: store.cachedThumbnail(for: photo))
                        .aspectRatio(1, contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            if photo.isVideo {
                                Label(photo.durationText, systemImage: "play.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    .padding(4)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if let count = store.reactionsByPhoto[photo.id]?.count, count > 0 {
                                Label("\(count)", systemImage: "heart.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    .padding(4)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { opened = photo }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// Conditionally attaches `.searchable` — the shared-album CLIP search only
/// exists where the on-device models load (never on the simulator).
private struct SharedSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic),
                               prompt: "Search this album")
        } else {
            content
        }
    }
}

// MARK: - People sheet (participants + acceptance status)

/// Who is on this album's share, with their live acceptance status ("Joined" /
/// "Invited") — the sender's ONLY feedback loop for in-app invites. Owners get
/// an Invite Friend shortcut. Names resolve through the local friends list
/// (@username) when CloudKit doesn't provide one.
struct AlbumPeopleView: View {
    let album: SharedAlbum

    @ObservedObject private var invitations = InvitationStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var participants: [AlbumParticipant]?
    @State private var loading = true
    @State private var friendInviteAlbum: SharedAlbum?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Checking members…")
                } else if let participants, !participants.isEmpty {
                    List {
                        Section {
                            ForEach(participants) { person in
                                participantRow(person)
                            }
                        } footer: {
                            Text("“Invited” means they haven't opened the invitation yet.")
                        }
                        if album.isOwnedByMe {
                            Section {
                                Button {
                                    friendInviteAlbum = album
                                } label: {
                                    Label("Invite Friend", systemImage: "person.badge.plus")
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Couldn't load members", systemImage: "person.2.slash")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $friendInviteAlbum) { album in
                InviteFriendView(album: album)
            }
        }
        .task {
            invitations.loadLocalCache()
            await load()
        }
    }

    private func load() async {
        loading = true
        participants = await SharedAlbumStore.shared.participants(for: album)
        loading = false
    }

    private func participantRow(_ person: AlbumParticipant) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))
                Image(systemName: person.isOwner ? "crown.fill" : "person.fill")
                    .foregroundStyle(.tint)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: person))
                    .font(.body)
                HStack(spacing: 6) {
                    if person.isOwner {
                        Text("Owner").font(.caption).foregroundStyle(.secondary)
                    }
                    if !person.canWrite && !person.isOwner {
                        Text("View only").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if !person.isOwner && !person.status.isEmpty {
                Text(person.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(person.status == "Joined" ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (person.status == "Joined" ? Color.green : Color.orange).opacity(0.15),
                        in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    /// Prefer "You", then a friend's @username, then CloudKit's name.
    private func displayName(for person: AlbumParticipant) -> String {
        if person.isMe { return "You" }
        if let record = person.userRecordID,
           let friend = invitations.friends.first(where: { $0.userRecordID == record }) {
            return "\(friend.displayName) (@\(friend.username))"
        }
        return person.displayName
    }
}

// MARK: - CKAsset-backed thumbnail

/// Displays a thumbnail from raw JPEG bytes (decoded off the main thread). The
/// bytes come from a CKAsset that SharedAlbumStore already read into memory, so
/// there is no per-cell network or file I/O here — just a decode. Falls back to
/// a placeholder while decoding or when bytes are absent.
struct SharedThumbView: View {
    let data: Data?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: data) { await decode() }
    }

    private func decode() async {
        guard let data else { image = nil; return }
        // Decode off the main actor to keep scrolling smooth.
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
        image = decoded
    }
}

// MARK: - Full-screen viewer (lazy full image / video)

/// Full-screen view of one shared photo or video. Photos pull the
/// full-resolution CKAsset bytes lazily; videos fetch the movie file to a temp
/// URL and play in an AVPlayer. Shows the contributor ("Added by @sam"), a ❤️
/// toggle + comments, and Save to Library. Tap or the ✕ dismisses.
private struct SharedPhotoViewer: View {
    let photo: SharedPhoto
    let album: SharedAlbum

    @ObservedObject private var store = SharedAlbumStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var fullImage: UIImage?
    @State private var player: AVPlayer?
    @State private var videoURL: URL?
    @State private var loading = true
    @State private var showComments = false
    @State private var saving = false
    @State private var savedToast = false

    private var reactions: [SharedReaction] { store.reactionsByPhoto[photo.id] ?? [] }
    private var comments: [SharedComment] { store.commentsByPhoto[photo.id] ?? [] }
    private var hearted: Bool { store.myReaction(to: photo) != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .padding()
                    }
                }
                Spacer()
                bottomBar
            }
        }
        .task {
            await store.loadParticipantNamesIfNeeded(for: album)
            if photo.isVideo {
                let database = album.isOwnedByMe
                    ? CloudKitService.shared.privateDB : CloudKitService.shared.sharedDB
                if let url = try? await CloudKitService.shared.fullAssetFileURL(
                    for: photo, database: database) {
                    videoURL = url
                    let player = AVPlayer(url: url)
                    self.player = player
                    player.play()
                }
            } else {
                let data = await store.fullImage(for: photo, in: album)
                if let data, let img = UIImage(data: data) { fullImage = img }
            }
            loading = false
        }
        .onDisappear {
            player?.pause()
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        }
        .sheet(isPresented: $showComments) {
            SharedCommentsSheet(photo: photo, album: album)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var content: some View {
        if photo.isVideo {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if loading {
                ZStack {
                    thumbnailPlaceholder
                    ProgressView("Loading video…").tint(.white)
                }
            } else {
                ContentUnavailableView("Couldn't load video",
                                       systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            }
        } else if let fullImage {
            Image(uiImage: fullImage)
                .resizable()
                .scaledToFit()
                .onTapGesture { dismiss() }
        } else if loading {
            ZStack {
                thumbnailPlaceholder
                ProgressView().tint(.white)
            }
        } else {
            ContentUnavailableView("Couldn't load photo",
                                   systemImage: "exclamationmark.triangle")
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var thumbnailPlaceholder: some View {
        if let thumb = store.cachedThumbnail(for: photo),
           let img = UIImage(data: thumb) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .blur(radius: 8)
        } else {
            Color.black
        }
    }

    /// Attribution + social actions + save, over a soft gradient.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let contributor = store.contributorDisplayName(for: photo) {
                Text("Added by \(contributor)\(photo.captureDate.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 22) {
                Button {
                    Task { await store.toggleReaction(on: photo, in: album) }
                } label: {
                    Label("\(reactions.count)", systemImage: hearted ? "heart.fill" : "heart")
                        .foregroundStyle(hearted ? .red : .white)
                }
                Button {
                    showComments = true
                } label: {
                    Label("\(comments.count)", systemImage: "bubble.right")
                        .foregroundStyle(.white)
                }
                Spacer()
                Button {
                    saving = true
                    Task {
                        let result = await store.saveToLibrary([photo], from: album)
                        saving = false
                        savedToast = result.saved > 0
                    }
                } label: {
                    if saving {
                        ProgressView().tint(.white)
                    } else if savedToast {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(.white)
                    }
                }
                .disabled(saving)
            }
            .font(.title3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

// MARK: - Comments sheet

/// Comments on one shared photo: newest at the bottom, with a compose field.
private struct SharedCommentsSheet: View {
    let photo: SharedPhoto
    let album: SharedAlbum

    @ObservedObject private var store = SharedAlbumStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var sending = false

    private var comments: [SharedComment] { store.commentsByPhoto[photo.id] ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if comments.isEmpty {
                    ContentUnavailableView {
                        Label("No comments yet", systemImage: "bubble.right")
                    } description: {
                        Text("Say something about this photo.")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(comments) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(store.authorDisplayName(comment.authorID,
                                                             fallback: comment.authorName))
                                    .font(.caption.bold())
                                Spacer()
                                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(comment.text)
                                .font(.callout)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                }
                Divider()
                HStack(spacing: 10) {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let text = draft
                        sending = true
                        Task {
                            if await store.addComment(text, on: photo, in: album) {
                                draft = ""
                            }
                            sending = false
                        }
                    } label: {
                        if sending { ProgressView() }
                        else { Image(systemName: "paperplane.fill") }
                    }
                    .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - PHPicker wrapper

/// A thin PHPickerViewController wrapper that returns the selected assets'
/// `localIdentifier`s (so the store can re-fetch full-res bytes via PHAsset,
/// reusing the app's existing read access — no new permission this phase). The
/// picker filters to images only. Multi-select is enabled.
struct SharedAlbumPhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0   // 0 = unlimited multi-select
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: ([String]) -> Void
        init(onPicked: @escaping ([String]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController,
                    didFinishPicking results: [PHPickerResult]) {
            // `assetIdentifier` is non-nil because the picker was created with an
            // explicit photoLibrary (.shared()), which grants identifier access.
            let ids = results.compactMap(\.assetIdentifier)
            picker.dismiss(animated: true)
            onPicked(ids)
        }
    }
}
