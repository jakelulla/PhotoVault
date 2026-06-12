import SwiftUI

/// Shown on the Search tab before any query: On This Day + Trips.
struct MemoriesHome: View {
    @ObservedObject private var store = PhotoStore.shared

    var body: some View {
        let onThisDay = store.onThisDay()
        let trips = store.trips

        if onThisDay.isEmpty && trips.isEmpty {
            ContentUnavailableView(
                "Search your photos",
                systemImage: "magnifyingglass",
                description: Text("Try a person's name, a year, or a place — e.g. \"Mom 2021\" or \"Paris\"."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !onThisDay.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("On This Day")
                                .font(.title3.bold())
                                .padding(.horizontal, 16)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(onThisDay) { group in
                                        NavigationLink {
                                            OnThisDayPhotosView(group: group)
                                        } label: {
                                            OnThisDayCard(group: group)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    if !trips.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Trips")
                                .font(.title3.bold())
                                .padding(.horizontal, 16)
                            VStack(spacing: 14) {
                                ForEach(trips) { trip in
                                    NavigationLink {
                                        TripPhotosView(trip: trip)
                                    } label: {
                                        TripCard(trip: trip)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - On This Day

private struct OnThisDayCard: View {
    let group: PhotoStore.OnThisDayGroup

    var body: some View {
        Color.clear
            .frame(width: 150, height: 200)
            .overlay {
                if let cover = group.photos.first {
                    PHImageView(assetID: cover.assetID,
                                targetSize: CGSize(width: 300, height: 400))
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(group.year))
                        .font(.headline.bold()).foregroundStyle(.white)
                    Text(group.yearsAgo == 1 ? "1 year ago" : "\(group.yearsAgo) years ago")
                        .font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
    }
}

struct OnThisDayPhotosView: View {
    let group: PhotoStore.OnThisDayGroup

    var body: some View {
        PhotoResultsGrid(results: group.photos)
            .navigationTitle("On This Day · \(String(group.year))")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Trips

private struct TripCard: View {
    let trip: PhotoStore.Trip

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                PHImageView(assetID: trip.coverAssetID,
                            targetSize: CGSize(width: 700, height: 400))
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.name)
                        .font(.title3.bold()).foregroundStyle(.white)
                    Text("\(trip.dateRangeText) · \(trip.photos.count) photos")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
    }
}

struct TripPhotosView: View {
    let trip: PhotoStore.Trip

    var body: some View {
        PhotoResultsGrid(results: trip.photos)
            .navigationTitle(trip.name)
            .navigationBarTitleDisplayMode(.inline)
    }
}
