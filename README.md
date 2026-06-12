# PhotoSearch

A SwiftUI iOS app + Python backend for face- and content-based photo search over
the `test_images/` library.

- **People** — every face appearing in 20+ photos (tunable), most frequent first; name each inline.
- **Search** — combine four optional fields; any left blank is ignored:
  - **Names** (multiple, AND) — photos containing *all* the named people.
  - **Caption** — an OpenCLIP text query ("a baby wearing a birthday crown"); floor 0.25.
  - **Timestamp** — `YYYY`, `YYYY-MM`, or `YYYY-MM-DD`.
  - **Location** — reverse-geocoded from EXIF GPS; substring match ("Hawaii", "California").
- **Photos** — after granting photo access, browse the device's real photo library; full-screen view swipes through.

The app requests **photo-library access** on first launch; the Photos tab then reads
the device library (PHAsset). The same photos are indexed by the backend, which powers
People + Search.

## Architecture

iOS can't run InsightFace/OpenCLIP, so a local backend does the ML and the app
talks to it over HTTP. Browsing reads the phone's photo library directly; People and
Search query the backend (which indexes the same photos).

```
algorithm_scripting/utils.py   your face pipeline (reused as-is by the indexer)
backend/
  build_index.py   detect+cluster faces, CLIP-encode images, read timestamps
  server.py        FastAPI: /api/people, /api/search, image serving
  clip_model.py    shared OpenCLIP loader (ViT-B/32, OpenAI weights)
  index/           generated artifacts (photos.json, clip.npy, people.json, faces/)
PhotoSearch/       the iOS app (3 tabs, talks to 127.0.0.1:8000)
```

## Dataset

`test_images/` holds the photos (currently flattened from the macOS Photos library;
the prior family-photo set is backed up at `test_images_family_backup/`). To rebuild
the set from a Photos library:

```bash
cd backend
./prep_import.sh                 # flatten originals -> stills (HEIC->JPEG, skip video) into ../_import
mv ../test_images ../old && mv ../_import ../test_images
./index.sh                       # slow one-time pass: faces + CLIP + EXIF time/GPS
```

Then import the same stills into the Simulator's Photos app so the app can see them:

```bash
xcrun simctl boot "iPhone 17 Pro"
find "$PWD/../test_images" -type f \( -name '*.jpg' -o -name '*.png' \) -print0 \
  | xargs -0 -n 40 xcrun simctl addmedia "iPhone 17 Pro"
```

`index/names.json` (the names you assign in the app) is preserved across rebuilds.

## Run it

```bash
./go.sh           # starts the backend if needed, builds the app, launches the Simulator
```

Or step by step:

```bash
cd backend && ./serve.sh     # backend API on http://127.0.0.1:8000  (leave running)
# in another terminal:
./build.sh && ./run.sh       # build + launch the app
```

Pick a different simulator with `SIM_DEVICE="iPhone 17" ./go.sh`.

## Notes

- The Simulator reaches the Mac's backend at `127.0.0.1:8000`. `Info.plist` carries
  an App Transport Security exception so plain HTTP to localhost is allowed.
- Face identities are precomputed in the index; the server only loads CLIP at
  runtime (for caption text). Search combines: names/timestamp filter, caption ranks.
- Tuning (`EPS`, `MIN_SAMPLES`, `MATCH_THRESHOLD`, `CAPTION_FLOOR`) lives in
  `backend/build_index.py` and `backend/server.py`.
- **Simulator photo permission:** `simctl privacy grant photos com.jakelulla.PhotoSearch`
  only sticks if run *after* `simctl install` (reinstalling resets the app's TCC). On a
  real device or by hand, just tap **Allow Access → Allow Full Access**.
