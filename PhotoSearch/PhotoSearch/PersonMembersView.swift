import SwiftUI

/// Shows the face clusters merged into a person — allows unmerging individual clusters.
struct PersonMembersView: View {
    let cluster: PersonCluster
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PhotoStore.shared

    private var members: [PersonCluster] { store.mergeMembers(ofCluster: cluster.id) }

    var body: some View {
        NavigationStack {
            Group {
                if members.count <= 1 {
                    ContentUnavailableView(
                        "Not merged",
                        systemImage: "person.crop.circle",
                        description: Text("This person is a single face cluster — nothing to unmerge.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(members) { member in
                                MemberRow(member: member) {
                                    PhotoStore.shared.unmergeCluster(member.id)
                                    onChanged()
                                    if members.count <= 1 { dismiss() }
                                }
                            }
                        } footer: {
                            Text("These face clusters were merged. Unmerge any that don't belong.")
                        }
                    }
                }
            }
            .navigationTitle(cluster.name ?? "Merged Faces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct MemberRow: View {
    let member: PersonCluster
    let onUnmerge: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PHFaceView(assetID: member.representativeAssetID, faceRect: member.faceRect)
                .frame(width: 56, height: 56)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(member.mergedInto == nil ? "Primary" : "Merged in")
                    .font(.subheadline)
                Text("\(member.photoCount) photos")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if member.mergedInto != nil {
                Button("Unmerge", action: onUnmerge)
                    .buttonStyle(.bordered).tint(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
