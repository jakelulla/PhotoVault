import SwiftUI

/// Fill a destination by DESCRIBING what belongs in it, instead of hunting
/// photos down by hand and adding them back.
///
/// Deliberately mirrors ComposeRequestView (the photo-request composer): a
/// description, an optional date window, and an optional person — because that
/// is the same question, just pointed at your own library instead of a friend's.
/// The matching reuses `PhotoStore.photosMatching`, the exact call a friend's
/// device runs when fulfilling a request.
///
/// Serves two destinations, which is the point: after a friend fulfils an
/// "Aruba" request and shares an album back, adding YOUR Aruba photos to it
/// should be the same gesture that produced the request — not a scroll through
/// the whole camera roll.
struct PhotoQuerySearchView: View {
    /// Shown in the copy so the sheet says where photos are going.
    let destinationName: String
    /// Photos already present, filtered out of results. Empty when the
    /// destination dedupes for itself (shared albums do).
    var excluding: Set<String> = []
    /// Extra line under the form explaining what adding will do.
    var footerNote: String?
    /// Performs the add. Async + throwing so an uploading destination can
    /// report progress and surface a real failure.
    let onAdd: ([String]) async throws -> Void

    @ObservedObject private var store = PhotoStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var errorMessage: String?

    @State private var description = ""
    @State private var useDates = false
    @State private var useRange = true
    @State private var day = Date()
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var rangeEnd = Date()
    @State private var personClusterID: Int?

    @State private var results: [LocalPhoto] = []
    @State private var selected: Set<String> = []
    @State private var hasSearched = false
    @State private var searching = false

    /// Named people only — an unnamed cluster has nothing to call it in a menu.
    private var namedPeople: [PersonCluster] {
        store.clusters
            .filter { $0.mergedInto == nil && !$0.isDeleted && !($0.name ?? "").isEmpty }
            .sorted { $0.photoCount > $1.photoCount }
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A search needs at least one constraint — otherwise it returns the whole
    /// library, which is not a search.
    private var canSearch: Bool {
        !trimmedDescription.isEmpty || useDates || personClusterID != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasSearched {
                    resultsList
                } else {
                    queryForm
                }
            }
            .navigationTitle(hasSearched ? "Matches" : "Add by Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasSearched ? "Back" : "Cancel") {
                        if hasSearched { hasSearched = false; selected = [] } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if hasSearched {
                        if adding {
                            ProgressView()
                        } else {
                            Button("Add \(selected.count)") { add() }
                                .disabled(selected.isEmpty)
                        }
                    } else {
                        Button("Search") { runSearch() }
                            .disabled(!canSearch || searching)
                    }
                }
            }
            .alert("Couldn\u{2019}t add photos",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Query

    private var queryForm: some View {
        Form {
            Section {
                TextField("e.g. beach day, birthday cake", text: $description)
                    .autocorrectionDisabled()
            } header: {
                Text("What belongs in this folder?")
            } footer: {
                Text("Described in plain language — the same search the rest of the app uses.")
            }

            Section("Who") {
                Picker("Person", selection: $personClusterID) {
                    Text("Anyone").tag(Int?.none)
                    ForEach(namedPeople) { person in
                        Text(person.name ?? "").tag(Int?.some(person.id))
                    }
                }
                if namedPeople.isEmpty {
                    Text("Name someone in the People tab to filter by them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("When") {
                Toggle("Limit by date", isOn: $useDates)
                if useDates {
                    Toggle("Date range", isOn: $useRange)
                    if useRange {
                        DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                        DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
                    } else {
                        DatePicker("On", selection: $day, displayedComponents: .date)
                    }
                }
            }

            Section {
                Text(footerNote
                     ?? "Photos are added to “\(destinationName)”. Originals stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing matched that. Try a broader description, or widen the dates.")
            } actions: {
                Button("Edit Search") { hasSearched = false }
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            GeometryReader { geo in
                let spacing: CGFloat = 2
                let side = (geo.size.width - spacing * 2) / 3
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                             count: 3),
                              spacing: spacing) {
                        ForEach(results) { photo in
                            Button { toggle(photo.assetID) } label: {
                                cell(photo.assetID, side: side)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("\(results.count) match\(results.count == 1 ? "" : "es")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(selected.count == results.count ? "Deselect All" : "Select All") {
                        selected = selected.count == results.count
                            ? [] : Set(results.map(\.assetID))
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private func cell(_ id: String, side: CGFloat) -> some View {
        let isSel = selected.contains(id)
        return PHImageView(assetID: id, targetSize: CGSize(width: side * 2, height: side * 2))
            .frame(width: side, height: side)
            .clipped()
            .contentShape(Rectangle())
            .opacity(isSel ? 0.6 : 1)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: isSel ? 3 : 0))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(.white, isSel ? Color.accentColor : .black.opacity(0.45))
                    .padding(5)
            }
    }

    // MARK: - Actions

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func runSearch() {
        searching = true
        defer { searching = false }

        // A person filter is expressed as a name in the query string, because
        // that is exactly how the search engine already resolves people — no
        // second code path, and it composes with the description for free.
        var query = trimmedDescription
        if let id = personClusterID,
           let name = store.clusters.first(where: { $0.id == id })?.name, !name.isEmpty {
            query = query.isEmpty ? name : "\(name) \(query)"
        }

        let cal = Calendar.current
        if useDates {
            let from = useRange ? rangeStart : cal.startOfDay(for: day)
            let to = useRange ? rangeEnd
                              : (cal.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day)
            results = store.photosMatching(description: query, from: from, to: to)
        } else if query.isEmpty {
            results = []
        } else {
            results = store.searchPhotos(query: query)
        }

        // Photos already at the destination are dropped: offering to add what
        // is already there is noise, and it makes the match count misleading.
        if !excluding.isEmpty {
            results = results.filter { !excluding.contains($0.assetID) }
        }

        selected = Set(results.map(\.assetID))   // opt-out, not opt-in
        hasSearched = true
    }

    private func add() {
        let ids = Array(selected)
        Task {
            adding = true
            defer { adding = false }
            do {
                try await onAdd(ids)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
