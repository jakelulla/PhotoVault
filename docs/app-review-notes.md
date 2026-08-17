# App Review Notes — PhotoTrove

Paste the section below into **App Store Connect → App Review Information →
Notes**. Everything above the line is guidance for you, not for the reviewer.

## Before you submit — checklist

- [ ] CloudKit schema deployed to **Production** (Dashboard → Deploy Schema to
      Production). Includes the new `AbuseReport` record type.
- [ ] Queryable indexes exist in Production on `Invitation.toUserRecordID`,
      `PhotoRequest.toUserRecordID`, and `UserProfile.username`.
- [ ] Push verified on a real device from a TestFlight build (`aps-environment`
      resolves to production there, not the `development` value in the
      entitlements file).
- [ ] Privacy policy and support URLs filled in.
- [ ] Nutrition labels match `PrivacyInfo.xcprivacy`: **User ID** and **Name**,
      both linked to the user, purpose *App Functionality*, no tracking.
- [ ] Demo video recorded of the two-device sharing flow (see below).

## Why a demo video is not optional

Shared albums, friends, invitations, and photo requests all need **two iCloud
accounts on two devices**. A reviewer working alone on one device cannot
exercise any of it, and "feature appears not to work" is a Guideline 2.1
rejection. Record a single screen capture showing: claim username on device A →
add friend by username on device B → send invite → accept on B → contribute a
photo → it appears on A. Upload it and link it in the notes.

---

## Reviewer notes (paste this)

**PhotoTrove is a fully on-device photo search and organization app.** All
machine learning — natural-language photo search, face detection and grouping,
duplicate detection — runs locally via CoreML. No photo is ever uploaded for
processing and there is no application server.

**First launch requires indexing.** After granting photo access the app indexes
the library on-device. On a large library this takes a while and search results
improve as it progresses; a progress bar is shown above the tab bar. For a fast
review, please use a test device with a small photo library (20–50 photos).

**Optional account.** The app is fully functional with no account. A username is
only needed to share albums with other people. Claiming one writes a public
CloudKit record containing the username, an optional display name, and the
iCloud user record ID — nothing else, and no photos.

**Account deletion:** Photos tab → gear icon (top left) → Settings → Account →
Delete Account. This removes the public username record, the private username
pointer, and all pending invitations and photo requests in both directions.
(The button appears only once a username has been claimed, since there is no
account to delete before that.)

**Blocking and reporting**, for the user-generated content in shared albums:
- Friends tab → long-press any friend → **Block** or **Report**
- Invitations inbox → swipe any invitation → **Block** or **Report**
- Blocked list is managed at Settings → Blocked
- Reporting also blocks the reported user immediately
- Reports are delivered to our CloudKit dashboard and reviewed within 24 hours
- Support contact: support@phototrove.app (also linked in Settings → Support)

**Testing shared albums requires two accounts.** The invitation flow depends on
two distinct iCloud accounts on two devices. A demo video of the full flow is
linked below. If you would like us to invite a reviewer-controlled Apple ID to a
live shared album instead, we are happy to do so — please let us know the ID.

**Third-party content:** none. No SDKs, no analytics, no advertising, no
tracking. The only network calls are Apple CloudKit (shared albums only) and
Apple's CLGeocoder for place names.
