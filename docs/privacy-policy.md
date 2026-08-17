# PhotoTrove Privacy Policy

_Last updated: 14 August 2026_

> **You must host this at a public URL** (GitHub Pages works) and enter that URL
> in App Store Connect. Replace the contact address if support@phototrove.app is
> not yet live. This is a good-faith draft written from what the code actually
> does — have a lawyer review it before launch if you can.

## The short version

PhotoTrove runs on your device. Your photos are never uploaded to us, we have no
server, and we collect no analytics. The only information we can see is a
username you choose to create, and only if you choose to create one.

## What stays on your device

All of the following happen locally on your iPhone and never leave it:

- **Photo indexing and search.** Natural-language search, captions, and image
  understanding run through CoreML models bundled in the app.
- **Faces and people.** Face detection, grouping, and any names you assign are
  computed and stored on device. Face data is never uploaded.
- **Places.** Location names come from your photos' own GPS metadata, resolved
  through Apple's geocoder. We never receive your location.
- **Everything you organize.** Folders, smart folders, saved slideshows, and
  search history are stored only on your device.

We cannot see your photos. There is no mechanism by which we could.

## What we collect, and only if you create an account

You do **not** need an account to use PhotoTrove. An account exists solely so
friends can find you to share albums.

If you claim a username, the following is written to a public Apple CloudKit
database that we can read:

| Data | Why |
|---|---|
| Username | So friends can find you by name |
| Display name (optional) | Shown alongside your username |
| iCloud user record ID | Apple's identifier used to deliver invitations |

That is the complete list. No email address, no phone number, no photos, no
location, no device identifiers.

We use this only to operate the friends and sharing features. We do not sell it,
share it with third parties, or use it for advertising. **We do not track you**,
and the app contains no analytics or advertising SDKs.

## Shared albums

When you share an album, the photos go into Apple's iCloud, into a private share
that only invited people can open. They are stored under your iCloud account and
the accounts of people you invite. **We cannot read them.**

Face-matching data used by the "photo request" feature is delivered through a
private, invite-only share and is deleted after use. It never touches the public
database.

## Reports

If you report someone, we receive the reporting and reported user IDs, the
reason, any note you write, and where it happened. We use this only to review
the report and act on it, normally within 24 hours.

## Deleting your account and data

**Settings → Account → Delete Account** (the gear icon on the Photos tab)
permanently removes your username record, your username pointer, and all pending
invitations and photo requests in both directions.

Your photos are unaffected — they were always yours and always local. Albums
that other people already accepted remain in their iCloud accounts; we cannot
reach or revoke those. To remove the app's local data entirely, delete the app.

## Children

PhotoTrove is not directed at children under 13, and we do not knowingly collect
information from them.

## Changes

If this policy changes materially we will update this page and the date above.

## Contact

Questions, requests, or reports: **support@phototrove.app**
