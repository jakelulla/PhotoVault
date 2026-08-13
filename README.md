# PhotoVault

A fully **on-device** iOS photo app: natural-language search, face/people
organization, and private photo sharing — with **no backend and no network**.
All ML runs locally via CoreML; your photos never leave your device except
through Apple's iCloud when you explicitly share an album.

> The Xcode target and bundle id are still `com.jakelulla.PhotoSearch` (the app
> began life as "PhotoSearch"); the shipping display name is **PhotoVault**.

## Features

**Find & organize — fully on-device**
- **Search** — natural-language CLIP caption search ("a baby wearing a birthday
  crown"), combinable with people, places, and date filters.
- **People** — on-device face detection + clustering (SCRFD + ArcFace); name,
  merge, and browse.
- **Places** — reverse-geocoded from photo GPS, with a map.
- **Duplicates** — near-duplicate detection + one-tap cleanup.
- **Smart folders** — saved natural-language queries that auto-update, plus
  zero-shot auto-categories.

**Differentiators**
- **Search Math** — refine results with +/− term chips (composes CLIP vectors).
- **Together** — multi-person relationship timelines (first photo together,
  shared places, year sparkline).
- **Watch Them Grow** — a scrubbable best-face-per-year filmstrip for any
  person, with collage export.
- **Moment Reels** — auto-playing story reels that seek each video to its
  best-matching frame, with stitched export.

**Shared albums** — branch `shared-albums`, CloudKit-backed, serverless
- Create shared albums, add photos, view + sync between people.
- **In-app friends + invitations** — add friends by username, invite and accept
  entirely in-app (no share sheet), using CloudKit's public database as a
  serverless directory + invitation inbox.
- **Photo requests** — ask a friend for photos by description + date range +
  optional face filter ("only photos I'm in"); their device searches their own
  library, builds a folder, they review it, and share it back.
- **Privacy:** photos live in private/shared iCloud zones; the public database
  holds only usernames + invitation pointers; face-matching embeddings are
  delivered ephemerally through a private, invite-only share and never touch the
  public database.

## Privacy

All indexing and inference is on-device (CoreML). There is no server. The app
makes no third-party network calls — only Apple's `CLGeocoder` (place names)
and, for shared albums only, Apple **CloudKit**.

## Architecture

Fully on-device. Key pieces (under `PhotoSearch/PhotoSearch/`):

- `ML/OnDeviceMLEngine.swift` — CoreML inference: CLIP ViT-B/32 (image + text,
  with a Swift BPE tokenizer), SCRFD face detection, ArcFace face embeddings.
  Models are palettized (`.mlmodelc`, ~161 MB bundle), validated at 98.6% on the
  LFW face-verification benchmark.
- `Indexer.swift` — pipelined indexing of the photo library (foreground +
  background via `BGProcessingTask`).
- `PhotoStore.swift` — the on-device data store (photos, face clusters,
  locations, folders, embeddings) with binary embedding storage.
- `CloudKitService.swift`, `SharedAlbum*.swift`, `DirectoryService.swift`,
  `InvitationStore.swift`, `RequestStore.swift` — the CloudKit shared-albums,
  friends, and photo-request layer.

The former Python backend and all other retired material (benchmark harnesses,
exploration notebooks, old test data) live under **`unused/`** — see
`unused/README.md`. Nothing there is built or run by the app; the LFW /
embedding-parity benchmarks in it remain the tool to reach for after any model
regeneration.

## Build & run

Open `PhotoSearch/PhotoSearch.xcodeproj` in Xcode, pick a simulator or device,
and Run (⌘R). Or from the command line:

```bash
# build
xcodebuild -project PhotoSearch/PhotoSearch.xcodeproj -scheme PhotoSearch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# test (62 tests)
xcodebuild -project PhotoSearch/PhotoSearch.xcodeproj -scheme PhotoSearch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The CoreML models don't load on the Simulator, so search/People need a real
device; the core app and the full test suite build and run on the Simulator.

## Shared albums setup (CloudKit)

Shared albums require the **paid Apple Developer Program** and CloudKit config:

1. **Capabilities** (Xcode → Signing & Capabilities, app target): **iCloud →
   CloudKit** (container `iCloud.com.jakelulla.PhotoSearch`), **Push
   Notifications**, and **Background Modes → Remote notifications**.
2. **CloudKit Dashboard** ([icloud.developer.apple.com](https://icloud.developer.apple.com),
   Development environment, **Public** database): the record types auto-create
   on first use, then add a **Queryable** index on `toUserRecordID` for both
   **`Invitation`** and **`PhotoRequest`** (the receiving inboxes query on it).
   `UserProfile` and `FacePayload` need no indexes.
3. Testing needs **two devices with two different iCloud accounts**. Deploy the
   schema to **Production** before shipping.

Public-DB record types: `UserProfile` (username directory), `Invitation`,
`PhotoRequest`. Private/shared zones carry albums and photos; `FacePayload`
(ephemeral, private database) carries the face-match embedding for a request;
`MyProfilePointer` (private database, default zone) remembers the claimed
username so a reinstall / second device recovers its identity. All record
types auto-create in the Development environment on first use — remember to
deploy the schema (including the two Queryable indexes) to **Production**
before shipping.

Share links (`https://www.icloud.com/share/…`) require the app's scene
delegate (`SceneDelegate` in `PhotoSearchApp.swift`) — iOS delivers CloudKit
share acceptance ONLY to the window-scene delegate in a SwiftUI app, both warm
(`windowScene(_:userDidAcceptCloudKitShareWith:)`) and at cold launch
(`connectionOptions.cloudKitShareMetadata`). Do not remove it.
