import SwiftUI

/// The Slideshows hub: prebuilt one-tap shows (people stories, year in review,
/// on this day, folders) plus a "describe it" field that turns any search —
/// structured filters + CLIP — into a slideshow. Everything is generated
/// on-device from the local index; nothing here touches the network.
struct SlideshowsHubView: View {
    @ObservedObject private var store = PhotoStore.shared
    @ObservedObject private var notifications = NotificationManager.shared

    @State private var active: Slideshow?
    @State private var customQuery = ""
    @State private var emptyMessage: String?
    /// Non-nil while the rename sheet is up for that saved show.
    @State private var renaming: SavedSlideshow?
    @State private var renameText = ""

    private var trimmedQuery: String {
        customQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCurrentQuerySaved: Bool {
        store.isSlideshowSaved(query: trimmedQuery)
    }

    /// Named people first (bigger clusters first inside each half).
    private var people: [PersonCluster] {
        store.clusters
            .filter { $0.mergedInto == nil && !$0.isDeleted && $0.photoCount >= 5 }
            .sorted {
                let lhsNamed = !($0.name ?? "").isEmpty
                let rhsNamed = !($1.name ?? "").isEmpty
                if lhsNamed != rhsNamed { return lhsNamed }
                return $0.photoCount > $1.photoCount
            }
    }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        List {
            // People stories.
            if !people.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(people.prefix(20)) { cluster in
                                Button {
                                    play(SlideshowBuilder.person(cluster))
                                } label: {
                                    VStack(spacing: 6) {
                                        PHFaceView(assetID: cluster.representativeAssetID,
                                                   faceRect: cluster.faceRect)
                                            .frame(width: 72, height: 72)
                                            .clipShape(Circle())
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.body)
                                                    .foregroundStyle(.white, .tint)
                                            }
                                        Text(cluster.name?.isEmpty == false ? cluster.name! : "Someone")
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 76)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
                } header: {
                    Text("People")
                } footer: {
                    Text("A chronological story of each person, set to music.")
                }
            }

            // Memory reminders. Opt-in and off by default: scheduling
            // notifications someone didn't ask for is both rude and an App
            // Review risk. The permission prompt happens on the toggle, not
            // at launch.
            Section {
                Toggle(isOn: Binding(
                    get: { notifications.memoriesEnabled },
                    set: { on in Task { await notifications.setMemoriesEnabled(on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me about memories")
                        Text("A daily nudge when this day has photos from past years.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Prebuilt moments.
            Section("Moments") {
                hubRow(icon: "calendar", title: "On This Day",
                       subtitle: "Today across the years") {
                    play(SlideshowBuilder.onThisDay())
                }
                hubRow(icon: "sparkles", title: "\(currentYear) in Review",
                       subtitle: "The best of this year so far") {
                    play(SlideshowBuilder.yearInReview(currentYear))
                }
                hubRow(icon: "clock.arrow.circlepath", title: "\(currentYear - 1) in Review",
                       subtitle: "Last year's highlights") {
                    play(SlideshowBuilder.yearInReview(currentYear - 1))
                }
            }

            // Folders as slideshows.
            if !store.folders.isEmpty {
                Section("Folders") {
                    ForEach(store.folders) { folder in
                        hubRow(icon: folder.isSmart ? "sparkles" : "folder",
                               title: folder.name,
                               subtitle: folder.isSmart ? "Smart folder" : nil) {
                            play(SlideshowBuilder.folder(folder))
                        }
                    }
                }
            }

            // Saved shows. Above "Describe It" so a just-saved show is visible
            // without scrolling past the field that created it.
            if !store.savedSlideshows.isEmpty {
                Section {
                    ForEach(store.savedSlideshows) { show in
                        Button {
                            play(SlideshowBuilder.saved(show))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bookmark.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(show.name).foregroundStyle(.primary)
                                    // Only show the query when the name has
                                    // drifted from it — otherwise it's noise.
                                    if show.name.lowercased() != show.query.lowercased() {
                                        Text(show.query)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "play.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteSlideshow(id: show.id)
                            } label: { Label("Delete", systemImage: "trash") }
                            Button {
                                renaming = show
                                renameText = show.name
                            } label: { Label("Rename", systemImage: "pencil") }
                            .tint(.orange)
                        }
                    }
                } header: {
                    Text("Saved")
                } footer: {
                    Text("Saved shows re-run their search each time you play them, so they pick up new photos automatically.")
                }
            }

            // Describe it.
            Section {
                HStack(spacing: 10) {
                    TextField("beach sunsets with the kids…", text: $customQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { playCustom() }
                    Button {
                        saveCustom()
                    } label: {
                        Image(systemName: isCurrentQuerySaved ? "bookmark.fill" : "bookmark")
                            .font(.title3)
                    }
                    .disabled(trimmedQuery.isEmpty)
                    .accessibilityLabel(isCurrentQuerySaved ? "Saved" : "Save slideshow")
                    Button {
                        playCustom()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                    }
                    .disabled(trimmedQuery.isEmpty)
                    .accessibilityLabel("Play slideshow")
                }
                // Plain style so the two icons register as separate taps —
                // in a List row the default style makes the whole row one hit
                // target and either button fires the other's action.
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            } header: {
                Text("Describe It")
            } footer: {
                Text("Anything you can search you can watch — people, places, dates, and free-form descriptions, combined. Tap the bookmark to keep one.")
            }
        }
        .navigationTitle("Slideshows")
        .fullScreenCover(item: $active) { slideshow in
            SlideshowPlayerView(slideshow: slideshow)
        }
        .alert("Not enough photos",
               isPresented: Binding(get: { emptyMessage != nil },
                                    set: { if !$0 { emptyMessage = nil } })) {
            Button("OK", role: .cancel) { emptyMessage = nil }
        } message: {
            Text(emptyMessage ?? "")
        }
        .alert("Rename Slideshow",
               isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let show = renaming { store.renameSlideshow(id: show.id, name: renameText) }
                renaming = nil
            }
        } message: {
            Text("Only the name changes — it keeps matching \u{201C}\(renaming?.query ?? "")\u{201D}.")
        }
    }

    private func hubRow(icon: String, title: String, subtitle: String?,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }

    private func play(_ slideshow: Slideshow?) {
        if let slideshow {
            active = slideshow
        } else {
            emptyMessage = "That slideshow needs at least 3 photos. Try another, or index more of your library first."
        }
    }

    private func playCustom() {
        let query = trimmedQuery
        guard !query.isEmpty else { return }
        if let show = SlideshowBuilder.custom(query: query) {
            active = show
        } else {
            emptyMessage = noMatchMessage(for: query)
        }
    }

    /// Save the typed query as a reusable show. Builds it first so a query that
    /// matches nothing reports that instead of saving a show that can never
    /// play; the store collapses a repeat save of the same search.
    private func saveCustom() {
        let query = trimmedQuery
        guard !query.isEmpty else { return }
        guard SlideshowBuilder.custom(query: query) != nil else {
            emptyMessage = noMatchMessage(for: query)
            return
        }
        store.saveSlideshow(query: query)
    }

    private func noMatchMessage(for query: String) -> String {
        "No photos matched \u{201C}\(query)\u{201D}. Try different words — or add a person, place, or year."
    }
}

/// Entry card for FoldersGrid, visually consistent with its siblings.
struct SlideshowsEntryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Slideshows")
                .font(.subheadline.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text("Stories set to music")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
