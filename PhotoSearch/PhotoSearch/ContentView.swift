import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var library = PhotoLibraryModel()
    @StateObject private var indexer = Indexer()

    /// Unit tests run inside this host app and drive PhotoStore.shared
    /// directly. Without this gate the launch-time indexer walks the
    /// simulator's real photo library and calls store.index() concurrently
    /// with the tests, leaking real assets into the singleton mid-test (a
    /// non-hermetic flake). Skip all auto-indexing when hosting XCTest.
    private static let runningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some View {
        Group {
            switch library.status {
            case .authorized, .limited:
                MainTabs()
                    .environmentObject(library)
                    .environmentObject(indexer)
                    .task {
                        guard !Self.runningTests else { return }
                        await indexer.indexNewPhotos(from: library)
                        // Memory notifications are scheduled from the index, so
                        // refresh the window once this pass has added whatever
                        // it found. Internally a no-op when opted out.
                        await NotificationManager.shared.rescheduleMemoryNotifications()
                    }
                    // Belt-and-braces backfill trigger: the indexer fires one
                    // after each pass, but a pass over a big library can take
                    // hours — this gets old photos their face/sharpness data
                    // after launch settles instead of waiting for the pass.
                    // ~5s of clear air for first paint and indexing spin-up;
                    // a no-op once every photo carries the data.
                    .task {
                        guard !Self.runningTests else { return }
                        guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
                        await SharpnessBackfill.shared.runIfNeeded(library: library)
                    }
                    // Photos taken (or synced in) after launch: the library's
                    // change observer bumps the token; index the new arrivals.
                    .onChange(of: library.libraryChangeToken) {
                        guard !Self.runningTests else { return }
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
    /// Observed for the share-accepted confirmation only: a tapped iCloud share
    /// link can land on ANY tab, so the toast lives at the tab-root level. The
    /// property is only ever set by real device share flows — inert in tests.
    @ObservedObject private var sharedAlbums = SharedAlbumStore.shared
    /// Cross-tab navigation intents (notification taps, widget deep links).
    @ObservedObject private var router = AppRouter.shared

    private var showProgress: Bool {
        indexer.enqueueing || (indexer.total > 0 && indexer.processed < indexer.total)
    }

    /// Bumped each time the ALREADY-SELECTED Search tab is tapped again.
    /// SearchView watches it and clears back to its pre-search state — the
    /// standard iOS "tap the current tab to get back to the top" gesture.
    @State private var searchResetToken = 0

    /// Wraps the plain selection binding so a re-tap is observable. SwiftUI
    /// still calls the setter when the tapped tab equals the current one,
    /// which is the only hook for this gesture.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == 0 && selectedTab == 0 { searchResetToken += 1 }
                selectedTab = newValue
            }
        )
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            SearchView(resetToken: searchResetToken)
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
        // Confirmation that a shared album was just joined (link tap or in-app
        // invite accept). Lives at the tab root: the link path can fire while
        // ANY tab is frontmost, and this is the only place the user is
        // guaranteed to see it.
        .alert("Joined \u{201C}\(sharedAlbums.acceptedShareToast ?? "")\u{201D}",
               isPresented: Binding(get: { sharedAlbums.acceptedShareToast != nil },
                                    set: { if !$0 { sharedAlbums.acceptedShareToast = nil } })) {
            Button("OK", role: .cancel) { sharedAlbums.acceptedShareToast = nil }
        } message: {
            Text("Find it under Photos → Shared Albums. It may take a moment to fill in.")
        }
        // Notification tap / widget deep link → straight to Shared Albums,
        // regardless of which tab is frontmost.
        .sheet(isPresented: $router.showSharedAlbums) {
            NavigationStack { SharedAlbumsView() }
        }
        // A tapped memory notification plays that day's story straight away —
        // the notification promised the memory, so don't make them go find it.
        .fullScreenCover(isPresented: $router.showOnThisDay) {
            OnThisDayCover()
        }
        .onOpenURL { url in
            if url.scheme == "photovault", url.host == "shared" {
                router.showSharedAlbums = true
            }
        }
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

/// Destination for a memory-notification tap. Builds today's story on
/// appearance; if the photos behind it are gone (deleted since the
/// notification was scheduled), it says so instead of showing a blank player.
private struct OnThisDayCover: View {
    @Environment(\.dismiss) private var dismiss
    @State private var slideshow: Slideshow?
    @State private var built = false

    var body: some View {
        Group {
            if let slideshow {
                SlideshowPlayerView(slideshow: slideshow)
            } else if built {
                ContentUnavailableView {
                    Label("Nothing to show", systemImage: "calendar")
                } description: {
                    Text("Those photos are no longer in your library.")
                } actions: {
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            slideshow = SlideshowBuilder.onThisDay()
            built = true
        }
    }
}

private struct RequestAccessView: View {
    @ObservedObject var library: PhotoLibraryModel

    var body: some View {
        ContentUnavailableView {
            Label("Search Your Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Grant access to your photo library. Your photos appear right away, and PhotoTrove indexes them in the background so you can search by person, caption, date, and place. Everything happens on your device — nothing is uploaded.")
        } actions: {
            Button("Allow Access") { library.requestAccess() }
                .buttonStyle(.borderedProminent)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Photo Access", systemImage: "lock.fill")
        } description: {
            Text("Enable photo access for PhotoTrove in Settings to browse and search your library.")
        } actions: {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
