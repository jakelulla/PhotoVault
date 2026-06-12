import MapKit
import SwiftUI

/// Distinct tagged places. Tap a thumbnail to see its photos.
struct LocationsView: View {
    @EnvironmentObject private var folderStore: FolderStore
    @ObservedObject private var store = PhotoStore.shared
    @State private var labels: [String: String] = [:]
    @State private var openLocation: LocalLocation?
    @State private var showMap = false
    @FocusState private var focusedLocation: String?

    private var locations: [LocalLocation] { store.locations.filter { $0.count > 0 } }

    var body: some View {
        NavigationStack {
            Group {
                if locations.isEmpty {
                    ContentUnavailableView(
                        "No tagged places",
                        systemImage: "mappin.slash",
                        description: Text("None of your indexed photos have location data yet.")
                    )
                } else if showMap {
                    PlacesMapView(locations: locations) { openLocation = $0 }
                } else {
                    List {
                        Section {
                            ForEach(locations) { location in
                                LocationRow(
                                    location: location,
                                    label: labelBinding(for: location.name),
                                    focusedLocation: $focusedLocation,
                                    onOpen: { openLocation = location },
                                    onSave: { saveLabel(location.name) }
                                )
                            }
                        } footer: {
                            Text("Tap a place to see its photos. Add a label — searching either the label or the place name both work.")
                        }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMap.toggle()
                    } label: {
                        Image(systemName: showMap ? "list.bullet" : "map")
                    }
                }
            }
            .navigationDestination(item: $openLocation) { location in
                LocationPhotosView(location: location)
            }
        }
        .onAppear { for l in locations { labels[l.name] = l.alias ?? "" } }
        .onChange(of: focusedLocation) { previous, _ in
            if let previous { saveLabel(previous) }
        }
    }

    private func labelBinding(for name: String) -> Binding<String> {
        Binding(get: { labels[name] ?? "" }, set: { labels[name] = $0 })
    }

    private func saveLabel(_ name: String) {
        PhotoStore.shared.setLocationAlias(name: name, alias: labels[name] ?? "")
    }
}

private struct LocationRow: View {
    let location: LocalLocation
    @Binding var label: String
    var focusedLocation: FocusState<String?>.Binding
    let onOpen: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                PHImageView(assetID: location.coverAssetID,
                            targetSize: CGSize(width: 128, height: 128))
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Add a label", text: $label)
                    .textInputAutocapitalization(.words)
                    .focused(focusedLocation, equals: location.name)
                    .onSubmit(onSave)
                    .submitLabel(.done)
                Text(location.name)
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(location.count) photo\(location.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Map of places

/// Every tagged place as a pin (cover photo + count) at the average
/// coordinate of its photos. Tap a pin to open that place's photos.
private struct PlacesMapView: View {
    let locations: [LocalLocation]
    let onOpen: (LocalLocation) -> Void

    private var annotated: [(location: LocalLocation, coordinate: CLLocationCoordinate2D)] {
        locations.compactMap { loc in
            PhotoStore.shared.coordinate(for: loc).map { (loc, $0) }
        }
    }

    var body: some View {
        Map {
            ForEach(annotated, id: \.location.id) { entry in
                Annotation(entry.location.displayName, coordinate: entry.coordinate) {
                    Button { onOpen(entry.location) } label: {
                        VStack(spacing: 0) {
                            PHImageView(assetID: entry.location.coverAssetID,
                                        targetSize: CGSize(width: 120, height: 120))
                                .frame(width: 44, height: 44)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(.white, lineWidth: 2))
                                .shadow(radius: 3)
                            Text("\(entry.location.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.tint, in: Capsule())
                                .offset(y: -6)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }
}
