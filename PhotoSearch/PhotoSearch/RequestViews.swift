import CloudKit
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Compose a photo request (requester side)

/// Sheet to ask a friend for photos: pick a friend, type a description, choose a
/// date or date range, and a 3-way face filter (default "Only photos I'm in").
/// Sending a face-filtered request requires a PRIVATE face photo to be set — the
/// UI prompts to set one if missing. The biometric never touches the public DB;
/// see RequestStore.sendRequest → DirectoryService.sendPhotoRequest.
struct ComposeRequestView: View {
    @ObservedObject private var invitations = InvitationStore.shared
    @ObservedObject private var requests = RequestStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFriendID: String?
    @State private var description = ""
    @State private var useRange = false
    @State private var day = Date()
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var rangeEnd = Date()
    @State private var faceFilter: FaceFilter = .onlyMe

    @State private var sending = false
    @State private var errorMessage: String?
    @State private var showFacePhotoPicker = false
    /// Shown after a successful send when the face filter had to be downgraded to
    /// "any photos" (we couldn't stand up the ephemeral face share).
    @State private var downgradeNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                friendSection
                Section("What are you looking for?") {
                    TextField("e.g. concert, beach day", text: $description)
                        .autocorrectionDisabled()
                }
                dateSection
                faceFilterSection
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Request Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(!canSend || sending)
                }
            }
            .overlay { if sending { ProgressView("Sending…").controlSize(.large) } }
            .sheet(isPresented: $showFacePhotoPicker) {
                FacePhotoPickerView(mode: .privateFace)
            }
            .alert("Sent without the face filter",
                   isPresented: Binding(get: { downgradeNotice != nil },
                                        set: { if !$0 { downgradeNotice = nil } })) {
                Button("OK") { dismiss() }
            } message: { Text(downgradeNotice ?? "") }
            .task { invitations.loadLocalCache(); requests.loadLocalCache() }
        }
        .interactiveDismissDisabled(sending)
    }

    @ViewBuilder
    private var friendSection: some View {
        if invitations.friends.isEmpty {
            Section {
                Label("Add a friend in Friends first.", systemImage: "person.2")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Ask") {
                Picker("Friend", selection: $selectedFriendID) {
                    Text("Choose a friend").tag(String?.none)
                    ForEach(invitations.friends) { friend in
                        Text("@\(friend.username)").tag(Optional(friend.id))
                    }
                }
            }
        }
    }

    private var dateSection: some View {
        Section("When") {
            Toggle("Date range", isOn: $useRange)
            if useRange {
                DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
            } else {
                DatePicker("On", selection: $day, displayedComponents: .date)
            }
        }
    }

    private var faceFilterSection: some View {
        Section {
            Picker("Faces", selection: $faceFilter) {
                ForEach(FaceFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            if faceFilter.needsFace && !requests.hasPrivateFacePhoto {
                Button {
                    showFacePhotoPicker = true
                } label: {
                    Label("Set a photo of your face", systemImage: "person.crop.circle.badge.exclamationmark")
                }
            }
        } header: {
            Text("Face filter")
        } footer: {
            Text(faceFilter.needsFace
                 ? "Your face photo stays on your device. Only a private, friends-only match is shared — never on the public directory."
                 : "No face filter — every matching photo is a candidate.")
        }
    }

    private var canSend: Bool {
        guard selectedFriendID != nil else { return false }
        // A blank description is intentionally allowed (a pure date/face request),
        // so there is no description check here.
        if faceFilter.needsFace && !requests.hasPrivateFacePhoto { return false }
        return true
    }

    private var window: (Date, Date) {
        let cal = Calendar.current
        if useRange {
            let start = cal.startOfDay(for: min(rangeStart, rangeEnd))
            let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: max(rangeStart, rangeEnd)) ?? rangeEnd
            return (start, end)
        } else {
            let start = cal.startOfDay(for: day)
            let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
            return (start, end)
        }
    }

    private func send() async {
        guard let fid = selectedFriendID,
              let friend = invitations.friends.first(where: { $0.id == fid }) else { return }
        sending = true
        errorMessage = nil
        defer { sending = false }
        let (start, end) = window
        do {
            let outcome = try await requests.sendRequest(
                to: friend,
                description: description.trimmingCharacters(in: .whitespaces),
                from: start, to: end,
                faceFilter: faceFilter)
            // Fast-path cleanup of the ephemeral face zone after the friend has had
            // a chance to build. This is a best-effort OPTIMIZATION only — it does
            // NOT survive app suspension; the durable guarantee is the persisted
            // pending-zone set swept at next launch (RequestStore.sweepPending
            // EphemeralFaceZones), recorded inside sendRequest. We don't block the
            // UI on it; the requester owns it and never relies on the friend.
            if let zoneID = outcome.ephemeralZoneID {
                Task.detached {
                    try? await Task.sleep(for: .seconds(600))
                    await RequestStore.shared.cleanupEphemeralFaceZone(zoneID)
                }
            }
            // Disclose a face-filter downgrade (#9) before dismissing; otherwise
            // dismiss immediately.
            if outcome.downgradedToAny {
                downgradeNotice = "We couldn't set up the private face match, so we sent this as a request for ANY matching photos. @\(friend.username) will see every photo that matches — not just ones you're in."
            } else {
                dismiss()
            }
        } catch {
            errorMessage = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Request inbox (friend side)

/// A sheet listing pending photo requests with "Build & Share" and "Dismiss".
/// Build & Share runs `fulfill` then pushes a review grid.
struct RequestInboxView: View {
    @ObservedObject private var requests = RequestStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var building: String?       // request.id being built
    @State private var reviewing: RequestStore.FulfillResult?

    var body: some View {
        NavigationStack {
            Group {
                if requests.pendingRequests.isEmpty {
                    ContentUnavailableView {
                        Label("No requests", systemImage: "tray")
                    } description: {
                        Text("Requests from friends for photos will appear here.")
                    }
                } else {
                    List {
                        ForEach(requests.pendingRequests) { request in
                            RequestRow(
                                request: request,
                                busy: building == request.id,
                                onBuild: { Task { await build(request) } },
                                onDismiss: { requests.dismiss(request) })
                        }
                    }
                }
            }
            .navigationTitle("Photo Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $reviewing) { result in
                RequestReviewView(result: result)
            }
        }
    }

    private func build(_ request: PhotoRequest) async {
        building = request.id
        defer { building = nil }
        let result = await requests.fulfill(request: request)
        reviewing = result
    }
}

private struct RequestRow: View {
    let request: PhotoRequest
    let busy: Bool
    let onBuild: () -> Void
    let onDismiss: () -> Void

    private var dateText: String {
        let cal = Calendar.current
        if cal.isDate(request.startDate, inSameDayAs: request.endDate) {
            return request.startDate.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(request.startDate.formatted(date: .abbreviated, time: .omitted)) – \(request.endDate.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.requestDescription.isEmpty ? "Photos" : request.requestDescription)
                    .font(.headline)
                Text("from @\(request.fromUsername) · \(dateText)")
                    .font(.caption).foregroundStyle(.secondary)
                if request.faceFilter.needsFace {
                    Label(request.faceFilter.label, systemImage: "person.crop.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(role: .destructive) { onDismiss() } label: { Text("Dismiss") }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(busy)
                Spacer()
                Button { onBuild() } label: {
                    if busy { ProgressView() } else { Label("Build & Share", systemImage: "wand.and.stars") }
                }
                .buttonStyle(.borderedProminent)
                        .fixedSize(horizontal: true, vertical: false)
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Review grid (friend deselects, then shares back)

/// The friend reviews the candidate set the build produced. Every photo starts
/// SELECTED; the friend taps to deselect any they don't want to share. "Share"
/// builds a folder + a shared album of the KEPT photos and shares it back to the
/// requester as a normal shared-album invitation. The friend ALWAYS reviews —
/// nothing is auto-shared (it's their own library + consent).
struct RequestReviewView: View {
    /// The build result. `@State` (seeded from the passed-in value) so a "retry"
    /// can re-run the build and replace it in place when the face filter was
    /// initially unavailable.
    @State var result: RequestStore.FulfillResult

    @Environment(\.dismiss) private var dismiss

    /// Asset IDs currently KEPT. Starts as ALL candidates only when the face
    /// filter was applied (or not requested); starts EMPTY when the filter was
    /// requested but could not be applied, so we never pre-share an over-broad set.
    @State private var kept: Set<String> = []
    @State private var sharing = false
    @State private var retrying = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var done = false
    /// Tracks whether we've already seeded `kept`, so a re-render doesn't reset it.
    @State private var seeded = false

    private let columns = 3
    private let spacing: CGFloat = 2

    /// The face filter was requested but couldn't be applied — drives the
    /// empty-pre-selection + retry affordance and the warning copy.
    private var faceFilterUnavailable: Bool {
        result.faceFilterStatus == .unavailable
    }

    var body: some View {
        Group {
            if result.candidateAssetIDs.isEmpty {
                ContentUnavailableView {
                    Label("No matching photos", systemImage: "photo.on.rectangle")
                } description: {
                    // Only claim the face filter applied when it actually did.
                    let appliedFilterNote = result.faceFilterStatus == .applied
                        ? " with that face filter." : "."
                    Text("Nothing in your library matched “\(result.request.requestDescription)” for that time" +
                         appliedFilterNote)
                }
            } else {
                VStack(spacing: 0) {
                    if faceFilterUnavailable { faceFilterUnavailableBanner }
                    grid
                }
            }
        }
        .navigationTitle("Review (\(kept.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await share() }
                } label: {
                    if sharing { ProgressView() } else { Text("Share") }
                }
                .disabled(kept.isEmpty || sharing || done)
            }
        }
        .onAppear {
            // Seed the selection ONCE. Pre-select the whole grid only when the
            // face filter was applied or not requested; when it was requested but
            // unavailable, start with NOTHING selected (privacy: never default to
            // sharing an unfiltered set for an .onlyMe/.withoutMe request).
            guard !seeded else { return }
            seeded = true
            kept = faceFilterUnavailable ? [] : Set(result.candidateAssetIDs)
        }
        .alert("Share Result",
               isPresented: Binding(get: { statusMessage != nil },
                                    set: { if !$0 { statusMessage = nil } })) {
            Button("OK") { if !isError { dismiss() } }
        } message: { Text(statusMessage ?? "") }
    }

    /// Warning + retry shown when the requested face filter couldn't be applied.
    /// The grid below it shows the UNFILTERED matches with nothing pre-selected.
    private var faceFilterUnavailableBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn’t apply the face filter", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("We couldn’t fetch @\(result.request.fromUsername)’s private face match, so these are ALL photos matching the description and dates — not just the ones they asked for. Tap Retry, or pick photos manually before sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await retry() }
            } label: {
                if retrying {
                    ProgressView()
                } else {
                    Label("Retry the face filter", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(retrying || sharing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12))
    }

    /// Re-run the build (re-attempts the share accept + face match). On success
    /// the grid becomes the genuinely-filtered set and the whole grid is
    /// pre-selected; on continued failure we stay in the unavailable state.
    private func retry() async {
        retrying = true
        defer { retrying = false }
        let fresh = await RequestStore.shared.fulfill(request: result.request)
        result = fresh
        // Re-seed the selection to match the new status.
        kept = (fresh.faceFilterStatus == .unavailable) ? [] : Set(fresh.candidateAssetIDs)
    }

    private var grid: some View {
        GeometryReader { geo in
            let side = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                          spacing: spacing) {
                    ForEach(result.candidateAssetIDs, id: \.self) { assetID in
                        let isKept = kept.contains(assetID)
                        Button { toggle(assetID) } label: {
                            PHImageView(assetID: assetID,
                                        targetSize: CGSize(width: side * 2, height: side * 2))
                                .frame(width: side, height: side)
                                .clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isKept ? Color.accentColor : .white)
                                        .background(Circle().fill(.black.opacity(0.35)).padding(2))
                                        .padding(5)
                                }
                                .opacity(isKept ? 1 : 0.45)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .allowsHitTesting(!sharing)
    }

    private func toggle(_ id: String) {
        if kept.contains(id) { kept.remove(id) } else { kept.insert(id) }
    }

    private func share() async {
        sharing = true
        defer { sharing = false }
        let keptIDs = result.candidateAssetIDs.filter { kept.contains($0) }
        guard !keptIDs.isEmpty else { return }
        do {
            // shareBack now throws on a zero/failed upload, so reaching here means
            // a VERIFIED non-zero share. Only THEN do we mark the request fulfilled
            // and report success — with the actually-saved count, not the kept
            // count (a partial upload could save fewer than were selected).
            let saved = try await RequestFulfillment.shareBack(result: result, keptAssetIDs: keptIDs)
            RequestStore.shared.markFulfilled(result.request)
            isError = false
            statusMessage = "Shared \(saved) photo\(saved == 1 ? "" : "s") back to @\(result.request.fromUsername)."
            done = true
        } catch {
            // Upload/invite failed: the request stays PENDING (we did NOT mark it
            // fulfilled), so the friend can retry. Surface the error.
            isError = true
            statusMessage = (error as? SharedAlbumError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Share-back orchestration

/// Pure orchestration helper for the friend's "Share" step: stage the kept photos
/// in a local folder, create a shared album, upload the photos, and invite the
/// requester. Reuses the existing shared-album machinery end to end so the
/// requester receives it as a normal shared-album invitation. @MainActor because
/// it touches the @MainActor stores.
@MainActor
enum RequestFulfillment {
    /// Returns the number of photos actually uploaded (verified > 0). The caller
    /// shows "Shared N photos" only on the returned count and only because we got
    /// here (a zero/failed upload throws instead).
    @discardableResult
    static func shareBack(result: RequestStore.FulfillResult, keptAssetIDs: [String]) async throws -> Int {
        let albumStore = SharedAlbumStore.shared
        let invitations = InvitationStore.shared

        // A clear album name from the request.
        let desc = result.request.requestDescription.trimmingCharacters(in: .whitespaces)
        let albumName = desc.isEmpty
            ? "Photos for @\(result.request.fromUsername)"
            : "\(desc) for @\(result.request.fromUsername)"

        // Stage locally (so the friend has a record of what they shared).
        _ = PhotoStore.shared.buildFolder(named: albumName, assetIDs: keptAssetIDs)

        // Create the shared album + upload the kept photos. Use the COUNT-REPORTING
        // upload variant and gate everything below on a verified non-zero save: a
        // partial/failed upload throws (or returns 0), so we NEVER invite + report
        // success while leaving the requester an empty album and the request gone.
        let album = try await albumStore.createAlbum(named: albumName)
        let outcome = try await albumStore.addPhotosReportingCount(
            localAssetIDs: keptAssetIDs, toAlbum: album)
        let saved = outcome.saved
        guard saved > 0 else {
            throw SharedAlbumError.cloudKit(
                "Couldn't upload the photos. Your request is still pending — try sharing again.")
        }

        // Invite the requester back as a participant. Reuse the friend invite if
        // we already have them as a friend; otherwise share by their record ID.
        if let friend = invitations.friends.first(where: { $0.userRecordID == result.request.fromUserRecordID }) {
            try await invitations.invite(friend, to: album)
        } else {
            // Not in our friends list — share directly to the requester's record
            // ID and write the invitation ourselves.
            guard let me = invitations.myProfile else {
                throw SharedAlbumError.cloudKit("Claim a username before sharing.")
            }
            let url = try await DirectoryService.shared.shareAlbum(
                album, toUserRecordID: result.request.fromUserRecordID)
            try await DirectoryService.shared.sendInvitation(
                toUserRecordID: result.request.fromUserRecordID,
                fromUsername: me.username,
                album: album,
                shareURL: url)
        }
        return saved
    }
}

// MARK: - Profile / face photo picker

/// A PHPicker-backed sheet that returns the chosen image's bytes and stores them
/// as either the PRIVATE face photo (local only) or the PUBLIC avatar.
struct FacePhotoPickerView: View {
    enum Mode { case privateFace, publicAvatar }
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: mode == .privateFace ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text(mode == .privateFace
                     ? "Pick a clear photo of just your face. It stays on this device and is only used to find you in a friend’s library — privately."
                     : "Pick a public avatar shown to friends. It’s decorative only and never used to match faces.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                PhotosPicker(selection: $item, matching: .images) {
                    Text("Choose Photo")
                }
                .buttonStyle(.borderedProminent)
                        .fixedSize(horizontal: true, vertical: false)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.callout)
                }
            }
            .padding()
            .navigationTitle(mode == .privateFace ? "Your Face Photo" : "Your Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay { if working { ProgressView().controlSize(.large) } }
            .onChange(of: item) { _, newItem in
                guard let newItem else { return }
                Task { await load(newItem) }
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func load(_ item: PhotosPickerItem) async {
        working = true
        errorMessage = nil
        defer { working = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Couldn't read that photo."
            return
        }
        switch mode {
        case .privateFace:
            if RequestStore.shared.setPrivateFacePhoto(data) {
                dismiss()
            } else {
                errorMessage = "Couldn't process that photo."
            }
        case .publicAvatar:
            do {
                try await RequestStore.shared.setPublicAvatar(data)
                dismiss()
            } catch {
                errorMessage = (error as? SharedAlbumError)?.localizedDescription
                    ?? error.localizedDescription
            }
        }
    }
}
