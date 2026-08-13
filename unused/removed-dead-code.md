# Removed dead code (2026-07-16 cleanup)

Small in-app functions deleted because nothing called them. Archived verbatim
in case any is wanted again; all were verified caller-free by grep at removal
time, and the full versions live in git history on branch `shared-albums`.

## SharedAlbumStore.addPhotos (wrapper)
Every caller migrated to `addPhotosReportingCount`.
```swift
func addPhotos(localAssetIDs: [String], toAlbum album: SharedAlbum) async {
    _ = try? await addPhotosReportingCount(localAssetIDs: localAssetIDs, toAlbum: album)
}
```

## DirectoryService.deleteSentInvitation
Sender-side invitation cleanup that never got a call site (the recipient's
local handled-set makes it unnecessary for correctness).
```swift
func deleteSentInvitation(id: String) async {
    guard (try? await requireAvailable()) != nil else { return }
    let recordID = CKRecord.ID(recordName: id)
    _ = try? await publicDB.deleteRecord(withID: recordID)
}
```

## ChangeTokenCache.removeZoneToken
Exact duplicate of `removeZone`, which is the variant in use.

## AppGroupSummary.read (app target)
The app only writes the App Group summary; the widget/share extensions read it
via their own self-contained copies of the struct.

## knownParticipantIDs / noteShared / rememberParticipants (+ shared_participants.json)
Write-only state for a "share with the same people again" affordance that was
never built; the People sheet (live CKShare participants) superseded the idea.
Removed the property, its persistence, and both `noteShared` call sites
(InvitationStore.invite and the UICloudSharingController didSaveShare hook,
which had collected participant IDs solely to feed it).
