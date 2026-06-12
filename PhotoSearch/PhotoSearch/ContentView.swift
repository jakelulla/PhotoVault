import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var library = PhotoLibraryModel()
    @StateObject private var indexer = Indexer()
    @StateObject private var folderStore = FolderStore()

    var body: some View {
        Group {
            switch library.status {
            case .authorized, .limited:
                MainTabs()
                    .environmentObject(library)
                    .environmentObject(indexer)
                    .environmentObject(folderStore)
                    .task {
                        await indexer.indexNewPhotos(from: library)
                    }
                    // Photos taken (or synced in) after launch: the library's
                    // change observer bumps the token; index the new arrivals.
                    .onChange(of: library.libraryChangeToken) {
                        Task { await indexer.indexNewPhotos(from: library) }
                    }
            case .denied, .restricted:
                AccessDeniedView()
            default:
                RequestAccessView(library: library)
            }
        }
        .onAppear { library.refreshStatus() }
    }
}

private struct MainTabs: View {
    @EnvironmentObject private var indexer: Indexer
    @State private var selectedTab = 0

    private var showProgress: Bool {
        indexer.enqueueing || (indexer.total > 0 && indexer.processed < indexer.total)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(0)
            PeopleView()
                .tabItem { Label("People", systemImage: "person.2.fill") }
                .tag(1)
            LocationsView()
                .tabItem { Label("Places", systemImage: "mappin.and.ellipse") }
                .tag(2)
            LibraryBrowseView()
                .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                .tag(3)
        }
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                // System slot above the floating tab bar (same mechanism as
                // Music's mini player). The modifier must come OFF when idle —
                // an empty accessory still draws its glass capsule. The
                // explicit selection binding keeps the current tab across the
                // structural change when indexing finishes.
                if showProgress {
                    tabs.tabViewBottomAccessory {
                        CompactIndexingBar(processed: indexer.processed, total: indexer.total)
                    }
                } else {
                    tabs
                }
            } else {
                tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                    if showProgress {
                        IndexingProgressBar(processed: indexer.processed, total: indexer.total)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showProgress)
    }
}

/// One-line progress pill content for the iOS 26 tab-bar accessory slot.
private struct CompactIndexingBar: View {
    let processed: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            if total > 0 {
                ProgressView(value: Double(processed), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                Text("\(processed)/\(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Indexing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct IndexingProgressBar: View {
    let processed: Int
    let total: Int

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label("Indexing", systemImage: "wand.and.sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if total > 0 {
                    Text("\(processed) / \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if total > 0 {
                ProgressView(value: Double(processed), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

private struct RequestAccessView: View {
    @ObservedObject var library: PhotoLibraryModel

    var body: some View {
        ContentUnavailableView {
            Label("Search Your Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Grant access to your photo library. Your photos appear right away, and PhotoSearch indexes them in the background so you can search by person, caption, date, and place.")
        } actions: {
            Button("Allow Access") { library.requestAccess() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Photo Access", systemImage: "lock.fill")
        } description: {
            Text("Enable photo access for PhotoSearch in Settings to browse and search your library.")
        } actions: {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
