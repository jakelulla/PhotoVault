import SwiftUI

// MARK: - Search-math chip editor (shared)

/// Horizontal chip row for CLIP vector arithmetic: each chip adds (+) or
/// subtracts (−) a text term from the active query embedding. Shared by
/// SearchView (text-anchored math) and SimilarPhotosView (image-anchored
/// math) so both surfaces look and behave identically.
struct MathChipsEditor: View {
    @Binding var plusTerms: [String]
    @Binding var minusTerms: [String]
    /// Called after any chip mutation. Owners re-rank immediately — the
    /// composite-embedding search is vDSP dot products over stored vectors,
    /// fast enough that no debounce is needed.
    var onChange: () -> Void

    @State private var draft = ""
    @State private var draftIsMinus = false
    @FocusState private var draftFocused: Bool

    private var isActive: Bool { !plusTerms.isEmpty || !minusTerms.isEmpty }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isActive {
                    // Math-mode marker: results are ranked by a composite
                    // vector, not the plain structured/caption search.
                    Text("∑")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tint)
                }
                ForEach(plusTerms, id: \.self) { term in
                    chip(term, minus: false)
                }
                ForEach(minusTerms, id: \.self) { term in
                    chip(term, minus: true)
                }
                addField
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ term: String, minus: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(minus ? "−" : "+") \(term)")
            Button {
                if minus { minusTerms.removeAll { $0 == term } }
                else { plusTerms.removeAll { $0 == term } }
                onChange()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .font(.caption.bold())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((minus ? Color.red : Color.green).opacity(0.15), in: Capsule())
        .foregroundStyle(minus ? Color.red : Color.green)
    }

    private var addField: some View {
        HStack(spacing: 4) {
            // Sign toggle: decides whether the next committed term adds to
            // or subtracts from the query vector.
            Button {
                draftIsMinus.toggle()
            } label: {
                Image(systemName: draftIsMinus ? "minus.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(draftIsMinus ? Color.red : Color.green)
            }
            .buttonStyle(.plain)
            TextField(draftIsMinus ? "remove term" : "add term", text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .focused($draftFocused)
                .frame(minWidth: 80, maxWidth: 140)
                .onSubmit(commitDraft)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private func commitDraft() {
        let term = draft.trimmingCharacters(in: .whitespaces).lowercased()
        draft = ""
        guard !term.isEmpty else { return }
        if draftIsMinus {
            guard !minusTerms.contains(term) else { return }
            minusTerms.append(term)
        } else {
            guard !plusTerms.contains(term) else { return }
            plusTerms.append(term)
        }
        // Keep the keyboard up so several chips can be entered in a row.
        draftFocused = true
        onChange()
    }
}

// MARK: - Smart folder editor (teach-your-own live folders)

/// Create or edit a live smart folder: free-text query, optional anchor
/// photo (its stored CLIP image embedding), comma-separated minus terms,
/// and a sensitivity slider mapped to the folder's match floor. Match count
/// and preview re-evaluate on commit (slider release / field submit) — not
/// per keystroke or per slider tick — because each evaluation scores the
/// whole library.
struct SmartFolderEditor: View {
    let folderID: String?              // nil → create flow (shows name field)
    @ObservedObject var store = PhotoStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var query: String
    @State private var anchorAssetID: String?
    @State private var minusText: String
    @State private var minScore: Float

    @State private var matchCount = 0
    @State private var preview: [LocalPhoto] = []
    @State private var engineUnavailable = false

    /// `initialMinScore` lets the presenting surface seed the floor it was
    /// actually ranking with (e.g. SimilarPhotosView's 0.45 chip floor) —
    /// otherwise the saved folder silently drops photos the user was looking
    /// at when they tapped Save. nil → the calibrated default.
    init(folderID: String?, initialQuery: String, initialAnchor: String?,
         initialMinus: String = "", initialMinScore: Float? = nil) {
        self.folderID = folderID
        // Editing an existing folder: the store is the source of truth, so
        // prefill from it; the passed initials cover the create flow (e.g.
        // seeded from the More Like This chips).
        let existing = folderID.flatMap { id in
            PhotoStore.shared.folders.first { $0.id == id }
        }
        let anchor = existing?.anchorAssetID ?? initialAnchor
        _name = State(initialValue: "")
        _query = State(initialValue: existing?.query ?? initialQuery)
        _anchorAssetID = State(initialValue: anchor)
        _minusText = State(initialValue: existing?.minusQuery ?? initialMinus)
        _minScore = State(initialValue: existing?.minScore
                          ?? initialMinScore
                          ?? Self.defaultScore(anchored: anchor != nil))
    }

    /// CLIP score scales differ by query kind: image-anchored composites
    /// live in the image–image range (similarPhotos floor 0.55), text-only
    /// in the caption range (floor 0.25) — hence separate slider ranges and
    /// defaults.
    private static func defaultScore(anchored: Bool) -> Float {
        anchored ? 0.55 : 0.25
    }
    private var scoreRange: ClosedRange<Float> {
        anchorAssetID != nil ? 0.45...0.80 : 0.18...0.35
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var minusList: [String] {
        minusText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    /// A folder needs at least one positive component (query text or anchor
    /// photo) — minus terms alone would compose a "visual opposite" vector
    /// that matches nothing meaningful.
    private var hasDefinition: Bool { !trimmedQuery.isEmpty || anchorAssetID != nil }
    private var canSave: Bool {
        hasDefinition && (folderID != nil
                          || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if folderID == nil {
                    Section("Name") {
                        TextField("Folder name", text: $name)
                    }
                }

                Section {
                    TextField("e.g. \"golden retriever at the beach\"", text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(recompute)
                } header: {
                    Text("Look For")
                } footer: {
                    if anchorAssetID != nil {
                        Text("Optional — added on top of the anchor photo.")
                    }
                }

                if let anchor = anchorAssetID {
                    Section("Anchor Photo") {
                        HStack(spacing: 12) {
                            Color.clear
                                .frame(width: 60, height: 60)
                                .overlay {
                                    PHImageView(assetID: anchor,
                                                targetSize: CGSize(width: 120, height: 120))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Matches rank by similarity to this photo.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                // Dropping the anchor changes the score scale
                                // (image–image runs much higher than
                                // text–image), so snap the slider back to the
                                // text-only default rather than leaving an
                                // out-of-range value.
                                anchorAssetID = nil
                                minScore = Self.defaultScore(anchored: false)
                                recompute()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    TextField("e.g. screenshots, memes", text: $minusText)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(recompute)
                } header: {
                    Text("But Not (comma separated)")
                }

                Section {
                    Slider(value: $minScore, in: scoreRange) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Looser").font(.caption2)
                    } maximumValueLabel: {
                        Text("Stricter").font(.caption2)
                    } onEditingChanged: { editing in
                        // Commit on release only — re-scoring the library on
                        // every tick would stutter the drag.
                        if !editing { recompute() }
                    }
                } header: {
                    Text("Sensitivity")
                } footer: {
                    if engineUnavailable {
                        Text("Live preview needs the on-device models, which aren't available here (e.g. in the Simulator). The folder will still work on a real device.")
                    } else if hasDefinition {
                        Text("\(matchCount) matching photo\(matchCount == 1 ? "" : "s")")
                    } else {
                        Text("Add a search or keep an anchor photo to preview matches.")
                    }
                }

                previewSection
            }
            .navigationTitle(folderID == nil ? "New Smart Folder" : "Edit Smart Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .task { recompute() }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if !preview.isEmpty {
            Section("Preview") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2),
                                         count: 4),
                          spacing: 2) {
                    ForEach(preview) { photo in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                PHImageView(assetID: photo.assetID,
                                            targetSize: CGSize(width: 160, height: 160))
                            }
                            .clipped()
                    }
                }
                .listRowInsets(EdgeInsets())
            }
        } else if hasDefinition && !engineUnavailable {
            Section("Preview") {
                Text("No matches at this sensitivity — try moving the slider toward Looser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recompute() {
        guard hasDefinition else {
            matchCount = 0
            preview = []
            return
        }
        guard let emb = store.compositeQueryEmbedding(
            anchorAssetID: anchorAssetID,
            baseText: trimmedQuery.isEmpty ? nil : trimmedQuery,
            minus: minusList
        ) else {
            // nil → text encoder unavailable (simulator) or encode failure.
            // Saving stays allowed: the definition evaluates fine on device.
            engineUnavailable = true
            matchCount = 0
            preview = []
            return
        }
        engineUnavailable = false
        let hits = store.searchByEmbedding(emb, floor: minScore)
        matchCount = hits.count
        preview = hits.prefix(30).map(\.photo)
    }

    private func save() {
        let q = trimmedQuery
        // Persist minScore only when the embedding path is actually needed
        // (anchor or minus terms force it) or the user moved the slider off
        // the default. An untouched text-only folder keeps minScore nil so
        // photosForFolder routes it through searchPhotos, preserving the
        // richer structured filters (people / places / years).
        let isDefault = abs(minScore - Self.defaultScore(anchored: anchorAssetID != nil)) < 0.0005
        let needsEmbedding = anchorAssetID != nil || !minusList.isEmpty
        let scoreToSave: Float? = (needsEmbedding || !isDefault) ? minScore : nil

        let id: String
        if let folderID {
            id = folderID
        } else {
            id = store.createFolder(name: name.trimmingCharacters(in: .whitespaces),
                                    query: q.isEmpty ? nil : q).id
        }
        store.updateSmartFolder(id: id,
                                query: q,
                                anchorAssetID: anchorAssetID,
                                minusQuery: minusText.trimmingCharacters(in: .whitespaces),
                                minScore: scoreToSave)
        dismiss()
    }
}
