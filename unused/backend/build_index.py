"""Build the photo search index over test_images/.

One-time (slow, CPU) pass that produces everything the server needs at runtime:

    index/photos.json   list of {photo_id, path, timestamp, person_ids}
    index/clip.npy       (N, 512) CLIP image embeddings, aligned to photos.json
    index/people.json    [{id, count}] sorted by photo count (most popular first)
    index/names.json     {person_id: name}  (preserved across rebuilds)
    index/faces/<id>.jpg  representative face crop per person

Face identities reuse the algorithm_scripting/utils.py pipeline:
detect -> embed -> DBSCAN cluster -> per-person prototypes -> assign every face.
CLIP image embeddings power caption search; EXIF gives timestamps.

Run:  ./venv/bin/python build_index.py
"""

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from tqdm import tqdm

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
IMAGES_ROOT = ROOT / "test_images"
INDEX_DIR = HERE / "index"
FACES_DIR = INDEX_DIR / "faces"

# The face pipeline lives in the notebook's utils.py. We import it LAZILY (inside
# the functions that need it) rather than at module top, because:
#   1. importing utils constructs the InsightFace models (~1.7 GB), and
#   2. InsightFace/onnxruntime leaks ~90 MB per processed image at the C level
#      that NOTHING reclaims until the process exits (verified: del+gc+recreate
#      and disabling the ORT arena all fail to free it).
# So the heavy per-image work runs in short-lived **worker subprocesses** (one
# per block of images) that exit to release the leak; the long-lived driver only
# accumulates the small results and does the final clustering. See main().
sys.path.insert(0, str(ROOT / "algorithm_scripting"))

# Number of images per worker subprocess. ~90 MB/image leak + ~1.7 GB models
# keeps a worker's peak RSS near 25 GB at this size — comfortably under typical
# RAM while minimizing how often we pay the model-load cost.
BLOCK = 256


def write_status(processed, total, running=True, done=False):
    try:
        (INDEX_DIR / "status.json").write_text(json.dumps(
            {"running": running, "processed": processed, "total": total, "done": done}))
    except Exception:
        pass

# Tuning. EPS/MATCH_THRESHOLD tightened from the notebook's 0.45/0.30 to keep
# look-alike people (e.g. siblings) from merging: EPS 0.40 makes DBSCAN require
# closer faces to link a cluster, and a face is only labeled as a known person
# when it's >=0.42 cosine-similar to that person's prototype (was 0.30, which let
# borderline look-alikes bleed together). Stricter can split one person into two
# clusters — those merge back easily in-app; un-mixing two merged people can't.
EPS = 0.40
MIN_SAMPLES = 3
MATCH_THRESHOLD = 0.42

# Above this many faces, use FAISS for the neighbor graph instead of sklearn's
# brute-force cosine DBSCAN (which is O(n^2) and becomes the build's wall).
FAISS_THRESHOLD = 20_000


def cluster_faces_scalable(
    embeddings: np.ndarray,
    eps: float = EPS,
    min_samples: int = MIN_SAMPLES,
) -> np.ndarray:
    """Identity clusters that scale to hundreds of thousands of faces.

    For small inputs this defers to the notebook's exact cosine DBSCAN. For
    large inputs it builds the eps-radius neighbor graph with FAISS (inner
    product on L2-normalized embeddings == cosine similarity), then runs
    DBSCAN on that precomputed sparse graph — same DBSCAN semantics, but the
    expensive all-pairs step is replaced by FAISS range search.
    """
    n = len(embeddings)
    if n < FAISS_THRESHOLD:
        from utils import cluster_faces  # lazy: avoids loading face models early
        return cluster_faces(embeddings, eps=eps, min_samples=min_samples)

    try:
        import faiss
        from scipy.sparse import csr_matrix
        from sklearn.cluster import DBSCAN
    except ImportError:
        print("faiss/scipy unavailable — falling back to brute-force cosine DBSCAN")
        return cluster_faces(embeddings, eps=eps, min_samples=min_samples)

    x = np.ascontiguousarray(embeddings, dtype="float32")  # already L2-normalized
    d = x.shape[1]

    # IVF keeps range search sub-quadratic. nlist ~ 4*sqrt(n) is a common rule.
    nlist = int(min(8192, max(64, 4 * np.sqrt(n))))
    quantizer = faiss.IndexFlatIP(d)
    index = faiss.IndexIVFFlat(quantizer, d, nlist, faiss.METRIC_INNER_PRODUCT)
    index.train(x)
    index.add(x)
    index.nprobe = min(nlist, 32)

    # cosine_distance <= eps  <=>  cosine_similarity >= 1 - eps
    lims, sims, ids = index.range_search(x, 1.0 - eps)

    counts = np.diff(lims).astype(np.intp)       # faiss lims are uint64
    rows = np.repeat(np.arange(n), counts)
    dist = np.maximum(1.0 - sims, 1e-6)           # keep explicit so CSR doesn't drop zeros
    graph = csr_matrix((dist, (rows, ids.astype(np.intp))), shape=(n, n))
    graph = graph.maximum(graph.T)       # symmetrize (IVF can be one-sided)

    db = DBSCAN(eps=eps, min_samples=min_samples, metric="precomputed")
    return db.fit_predict(graph)


def dhash(pil_img, hash_size: int = 8) -> int:
    """64-bit perceptual hash (difference hash). Near-identical images (incl.
    re-encoded / resized copies) get hashes a small Hamming distance apart."""
    img = pil_img.convert("L").resize((hash_size + 1, hash_size), Image.Resampling.LANCZOS)
    px = np.asarray(img, dtype=np.int16)
    diff = px[:, 1:] > px[:, :-1]
    bits = 0
    for v in diff.flatten():
        bits = (bits << 1) | int(v)
    return bits


def find_images() -> list[Path]:
    return sorted(
        p for p in IMAGES_ROOT.rglob("*")
        if p.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )


def _reverse_geocode(lat: float, lon: float) -> str:
    """Nearest 'City, State, CountryCode' for a coordinate (offline)."""
    import reverse_geocoder as rg
    r = rg.search((lat, lon), mode=1)[0]
    parts = [r.get("name"), r.get("admin1"), r.get("cc")]
    return ", ".join(p for p in parts if p)


def _gps_to_decimal(values, ref: str) -> float:
    """EXIF (deg, min, sec) rational + N/S/E/W ref -> signed decimal degrees."""
    d, m, s = (float(x) for x in values)
    dec = d + m / 60.0 + s / 3600.0
    return -dec if ref in ("S", "W") else dec


def read_exif_meta(path: Path) -> tuple[str, str | None, float | None, float | None]:
    """Return (timestamp_iso, location_str, lat, lon).

    Timestamp falls back to file mtime. Location comes from EXIF GPS,
    reverse-geocoded to a place name; None when the photo isn't geotagged
    (as with all of test_images — but real iOS photos usually are).
    """
    timestamp = None
    location = lat = lon = None
    try:
        exif = Image.open(path)._getexif() or {}
        raw = exif.get(36867) or exif.get(306)  # DateTimeOriginal, DateTime
        if raw:
            timestamp = datetime.strptime(raw, "%Y:%m:%d %H:%M:%S").isoformat()

        gps = exif.get(34853)  # GPSInfo: 1=latRef 2=lat 3=lonRef 4=lon
        if gps and 2 in gps and 4 in gps:
            lat = _gps_to_decimal(gps[2], gps.get(1, "N"))
            lon = _gps_to_decimal(gps[4], gps.get(3, "E"))
            location = _reverse_geocode(lat, lon)
    except Exception:
        pass

    if timestamp is None:
        timestamp = datetime.fromtimestamp(path.stat().st_mtime).isoformat()
    return timestamp, location, lat, lon


def read_meta(path: Path) -> tuple[str, str | None, float | None, float | None]:
    """Capture metadata for one image. Prefers a <name>.json sidecar written by
    the upload endpoint (PhotoKit's creationDate + GPS — authoritative, since our
    JPEG re-encode strips EXIF), and falls back to EXIF / file mtime otherwise.
    """
    side = path.with_suffix(".json")
    if side.exists():
        try:
            m = json.loads(side.read_text())
            created = m.get("created")
            lat = m.get("lat")
            lon = m.get("lon")
            location = None
            if lat is not None and lon is not None:
                try:
                    location = _reverse_geocode(lat, lon)
                except Exception:
                    location = None
            if created:
                return created, location, lat, lon
            # Sidecar has GPS but no date: keep GPS, get the date from EXIF/mtime.
            ts, exif_loc, exif_lat, exif_lon = read_exif_meta(path)
            return (ts, location or exif_loc,
                    lat if lat is not None else exif_lat,
                    lon if lon is not None else exif_lon)
        except Exception:
            pass
    return read_exif_meta(path)


def _process_block(paths: list[Path], base: int, total: int) -> dict:
    """Run faces + CLIP over `paths` in THIS (short-lived) process.

    `base`/`total` are only for progress reporting (this block covers global
    indices base..base+len(paths)). Returns the block's partial results; the
    parent merges them. All the leaky InsightFace work happens here and is
    reclaimed when this process exits.
    """
    from utils import load_image, get_faces       # noqa: E402  (lazy, see top)
    from clip_model import ClipEncoder            # noqa: E402

    clip = ClipEncoder(want_image=True)
    photos: list[dict] = []                       # block-local meta (no photo_id yet)
    clip_rows: list[np.ndarray] = []
    face_embs: list[np.ndarray] = []
    face_local_idx: list[int] = []                # index into THIS block's photos
    face_bbox: list[tuple] = []

    CHUNK = 64
    for start in range(0, len(paths), CHUNK):
        chunk_pils: list = []
        for path in paths[start:start + CHUNK]:
            # One unreadable/corrupt image must never kill the block: do all the
            # throwing work first, commit to the parallel arrays only on success
            # so photos/clip_rows stay aligned.
            try:
                img = load_image(path)
                if img is None:
                    continue
                local_id = len(photos)
                rel = str(path.relative_to(IMAGES_ROOT))
                timestamp, location, lat, lon = read_meta(path)
                # Read device_id from sidecar if present.
                device_id = ""
                _side = path.with_suffix(".json")
                if _side.exists():
                    try:
                        device_id = json.loads(_side.read_text()).get("device_id", "") or ""
                    except Exception:
                        pass
                pil = Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
                # Hash via PIL decode so it matches upload-time hashing.
                phash = dhash(Image.open(path).convert("RGB"))
                faces = [
                    (f.normed_embedding, tuple(float(v) for v in f.bbox))
                    for f in get_faces(img)
                ]
            except Exception as exc:
                print(f"  skipping unreadable image {path}: {exc}")
                continue

            photos.append({
                "path": rel, "timestamp": timestamp, "location": location,
                "lat": lat, "lon": lon, "phash": phash, "device_id": device_id,
            })
            chunk_pils.append(pil)
            for emb, bbox in faces:
                face_embs.append(emb)
                face_local_idx.append(local_id)
                face_bbox.append(bbox)

        if chunk_pils:
            clip_rows.extend(clip.encode_images(chunk_pils))
        # Keep status.json fresh so the server never mistakes a live worker for a
        # crashed one, and so progress advances smoothly within a block.
        write_status(base + min(start + CHUNK, len(paths)), total)

    return {
        "photos": photos,
        "clip": np.stack(clip_rows).astype(np.float32) if clip_rows
                else np.zeros((0, 512), np.float32),
        "face_embs": np.stack(face_embs).astype(np.float32) if face_embs
                     else np.zeros((0, 512), np.float32),
        "face_local_idx": np.asarray(face_local_idx, np.int64),
        "face_bbox": np.asarray(face_bbox, np.float32).reshape(-1, 4),
    }


def _run_worker(manifest: str, start: int, end: int, out_prefix: str) -> None:
    """Worker entry point (a separate process): process manifest[start:end]."""
    all_paths = [Path(line) for line in Path(manifest).read_text().splitlines() if line]
    total = len(all_paths)
    res = _process_block(all_paths[start:end], base=start, total=total)
    np.savez(
        out_prefix + ".npz",
        clip=res["clip"], face_embs=res["face_embs"],
        face_local_idx=res["face_local_idx"], face_bbox=res["face_bbox"],
    )
    Path(out_prefix + ".json").write_text(json.dumps(res["photos"]))


def refresh_meta() -> None:
    """Patch capture date + place into photos.json from upload sidecars — no ML,
    no clustering, runs in seconds. Lets the metadata backfill (which changes
    only date/GPS, never pixels) apply without a full rebuild. Only touches
    photos that actually have a sidecar; everything else is left untouched."""
    photos_path = INDEX_DIR / "photos.json"
    if not photos_path.exists():
        print("no photos.json yet — nothing to refresh")
        return
    photos = json.loads(photos_path.read_text())
    changed = 0
    for p in photos:
        path = IMAGES_ROOT / p["path"]
        if not path.with_suffix(".json").exists():
            continue
        ts, loc, lat, lon = read_meta(path)            # prefers the sidecar
        before = (p.get("timestamp"), p.get("location"), p.get("lat"), p.get("lon"))
        if before != (ts, loc, lat, lon):
            p["timestamp"], p["location"], p["lat"], p["lon"] = ts, loc, lat, lon
            changed += 1
    photos_path.write_text(json.dumps(photos))
    print(f"meta refresh: updated {changed}/{len(photos)} photos")


def _run_blocks(paths: list[Path]) -> dict:
    """Run faces + CLIP over `paths` via short-lived worker subprocesses (one per
    block of BLOCK images) so the InsightFace C-level leak is reclaimed on each
    worker's exit. Aggregates the small results in this (flat-memory) driver.

    Returns photos (meta dicts, no photo_id yet), the stacked clip matrix, face
    embeddings, face_photo_idx (0-based into the returned photos), and bboxes.
    Shared by the full build (main) and the incremental update.
    """
    tmp = INDEX_DIR / "_build_tmp"
    tmp.mkdir(exist_ok=True)
    # Pin the exact file list (uploads may keep arriving mid-build) so every
    # worker sees the same ordering/indices as this driver.
    manifest = tmp / "manifest.txt"
    manifest.write_text("\n".join(str(p) for p in paths))

    photos: list[dict] = []
    clip_parts: list[np.ndarray] = []
    face_embs_parts: list[np.ndarray] = []
    face_photo_idx: list[int] = []       # 0-based index into `photos`
    face_bbox_parts: list[np.ndarray] = []

    print(f"==> indexing in worker blocks of {BLOCK} "
          f"({(len(paths) + BLOCK - 1) // BLOCK} blocks)...")
    for bstart in tqdm(range(0, len(paths), BLOCK)):
        bend = min(bstart + BLOCK, len(paths))
        out_prefix = str(tmp / f"block_{bstart}")
        proc = subprocess.run(
            [sys.executable, str(HERE / "build_index.py"),
             "--worker", str(manifest), str(bstart), str(bend), out_prefix],
            cwd=str(HERE),
        )
        if proc.returncode != 0 or not Path(out_prefix + ".npz").exists():
            print(f"  worker for [{bstart}:{bend}] failed (rc={proc.returncode}); "
                  f"skipping these images")
            write_status(bend, len(paths))
            continue

        data = np.load(out_prefix + ".npz")
        metas = json.loads(Path(out_prefix + ".json").read_text())
        offset = len(photos)
        photos.extend(metas)
        clip_parts.append(data["clip"])
        if data["face_embs"].shape[0]:
            face_embs_parts.append(data["face_embs"])
            face_bbox_parts.append(data["face_bbox"])
            face_photo_idx.extend((offset + data["face_local_idx"]).tolist())

        for ext in (".npz", ".json"):
            try:
                os.remove(out_prefix + ext)
            except OSError:
                pass
        write_status(bend, len(paths))

    return {
        "photos": photos,
        "clip": np.concatenate(clip_parts) if clip_parts else np.zeros((0, 512), np.float32),
        "face_embs": np.concatenate(face_embs_parts) if face_embs_parts
                     else np.zeros((0, 512), np.float32),
        "face_photo_idx": face_photo_idx,
        "face_bbox": np.concatenate(face_bbox_parts) if face_bbox_parts
                     else np.zeros((0, 4), np.float32),
    }


def _ensure_aux_files() -> None:
    """Create the user-editable side files if missing (preserved across builds)."""
    for name, default in (("names.json", "{}"), ("hidden.json", "[]"),
                          ("aliases.json", "{}"), ("location_aliases.json", "{}"),
                          ("deleted_photos.json", "[]"), ("ungrouped.json", "[]"),
                          ("manual_dups.json", "[]"),
                          ("folders.json", '[{"id":"favorites","name":"Favorites"}]'),
                          ("photo_folders.json", "{}")):
        p = INDEX_DIR / name
        if not p.exists():
            p.write_text(default)


def _cleanup_tmp() -> None:
    try:
        for f in (INDEX_DIR / "_build_tmp").glob("*"):
            f.unlink()
        (INDEX_DIR / "_build_tmp").rmdir()
    except OSError:
        pass


def incremental() -> None:
    """Index only photos not already in photos.json, assigning their faces to the
    EXISTING people (prototypes) — no full re-cluster, so it finishes in seconds
    for a handful of new photos instead of ~1.5 hr. New *people* only appear after
    a full rebuild (POST /api/reindex); known people get tagged immediately."""
    INDEX_DIR.mkdir(exist_ok=True)
    FACES_DIR.mkdir(exist_ok=True)
    photos_path = INDEX_DIR / "photos.json"
    clip_path = INDEX_DIR / "clip.npy"
    if not photos_path.exists() or not clip_path.exists():
        print("no existing index — running a full build instead")
        return main()

    existing = json.loads(photos_path.read_text())
    have_paths = {p["path"] for p in existing}

    all_paths = find_images()
    new_paths = [p for p in all_paths if str(p.relative_to(IMAGES_ROOT)) not in have_paths]

    print(f"incremental: {len(new_paths)} new image(s)")
    write_status(len(existing), len(existing) + len(new_paths))
    if not new_paths:
        write_status(len(existing), len(existing), running=False, done=True)
        return

    res = _run_blocks(new_paths)
    new_photos = res["photos"]

    if not new_photos:
        write_status(len(existing), len(existing), running=False, done=True)
        return

    base = len(existing)
    for i, p in enumerate(new_photos):
        p["photo_id"] = base + i

    # Assign each new face to the nearest existing prototype (>= threshold).
    all_face_embs = res["face_embs"]
    all_face_idx  = list(res["face_photo_idx"])
    protos_path = INDEX_DIR / "prototypes.npy"
    protos = np.load(protos_path) if protos_path.exists() else np.zeros((0, 512), np.float32)
    new_people = [set() for _ in new_photos]
    if len(all_face_embs) and len(protos):
        sims = all_face_embs @ protos.T
        nearest = sims.argmax(axis=1)
        best = sims.max(axis=1)
        for fi, (pid, s) in enumerate(zip(nearest, best)):
            if s >= MATCH_THRESHOLD:
                new_people[all_face_idx[fi]].add(int(pid))
    for i, p in enumerate(new_photos):
        p["person_ids"] = sorted(new_people[i])

    # Append: clip rows + photo records, then recompute people counts cheaply.
    clip = np.load(clip_path)
    np.save(clip_path, np.vstack([clip, res["clip"]]).astype(np.float32))
    photos = existing + new_photos
    counts: dict[int, int] = {}
    for p in photos:
        for pid in p.get("person_ids", []):
            counts[pid] = counts.get(pid, 0) + 1
    people = sorted(({"id": pid, "count": c} for pid, c in counts.items()),
                    key=lambda r: r["count"], reverse=True)

    photos_path.write_text(json.dumps(photos))
    (INDEX_DIR / "people.json").write_text(json.dumps(people))
    _ensure_aux_files()
    _cleanup_tmp()
    write_status(len(photos), len(photos), running=False, done=True)
    print(f"\n==> incremental update: +{len(new_photos)} photos"
          f"\n    total now {len(photos)}, clip {np.load(clip_path).shape}")


def main() -> None:
    INDEX_DIR.mkdir(exist_ok=True)
    FACES_DIR.mkdir(exist_ok=True)

    paths = find_images()
    print(f"found {len(paths)} images under {IMAGES_ROOT}")
    write_status(0, len(paths))

    if not paths:
        print("no images found — nothing to index. "
              "Add .jpg/.jpeg/.png files to test_images/ and re-run "
              "(HEIC must be converted first, e.g. via prep_import.sh).")
        write_status(0, 0, running=False, done=True)
        return

    res = _run_blocks(paths)
    photos = res["photos"]
    for i, p in enumerate(photos):
        p["photo_id"] = i
    face_photo_idx = res["face_photo_idx"]
    face_bbox = res["face_bbox"]

    if not photos:
        print("no readable images found — nothing to index.")
        write_status(0, 0, running=False, done=True)
        return

    clip_matrix = res["clip"]
    np.save(INDEX_DIR / "clip.npy", clip_matrix)

    if res["face_embs"].shape[0]:
        from utils import build_prototypes      # lazy: only the driver's final step
        embeddings = res["face_embs"].astype(np.float32)
        print(f"==> clustering {len(embeddings)} faces...")
        cluster_ids = cluster_faces_scalable(embeddings, eps=EPS, min_samples=MIN_SAMPLES)
        prototypes, _ = build_prototypes(embeddings, cluster_ids)
        # Persist prototypes so uploaded photos can assign new faces to existing
        # people (person id == prototype row index).
        np.save(INDEX_DIR / "prototypes.npy", prototypes)

        # Assign every face to its nearest prototype (>= threshold), else -1.
        sims = embeddings @ prototypes.T               # (F, P)
        nearest = sims.argmax(axis=1)
        best_sim = sims.max(axis=1)
        face_person = np.where(best_sim >= MATCH_THRESHOLD, nearest, -1)

        # Per-photo set of person ids.
        photo_people: list[set] = [set() for _ in photos]
        for fi, pid in enumerate(face_person):
            if pid >= 0:
                photo_people[face_photo_idx[fi]].add(int(pid))

        # Person popularity = number of distinct photos they appear in.
        counts: dict[int, int] = {}
        for people in photo_people:
            for pid in people:
                counts[pid] = counts.get(pid, 0) + 1

        # Representative face crop per person = the face most similar to its prototype.
        best_face_for: dict[int, tuple[float, int]] = {}  # pid -> (sim, face_idx)
        for fi, pid in enumerate(face_person):
            if pid < 0:
                continue
            s = float(best_sim[fi])
            if pid not in best_face_for or s > best_face_for[pid][0]:
                best_face_for[pid] = (s, fi)

        for pid, (_, fi) in best_face_for.items():
            photo_idx = face_photo_idx[fi]
            src = IMAGES_ROOT / photos[photo_idx]["path"]
            img = cv2.imread(str(src))
            if img is None:
                continue
            x1, y1, x2, y2 = (int(v) for v in face_bbox[fi])
            pad = int(0.25 * max(x2 - x1, y2 - y1))
            h, w = img.shape[:2]
            crop = img[max(0, y1 - pad):min(h, y2 + pad), max(0, x1 - pad):min(w, x2 + pad)]
            if crop.size:
                cv2.imwrite(str(FACES_DIR / f"{pid}.jpg"), crop)

        people = sorted(
            ({"id": pid, "count": c} for pid, c in counts.items()),
            key=lambda r: r["count"],
            reverse=True,
        )
        for i, p in enumerate(photos):
            p["person_ids"] = sorted(photo_people[i])
    else:
        people = []
        for p in photos:
            p["person_ids"] = []

    (INDEX_DIR / "photos.json").write_text(json.dumps(photos))
    (INDEX_DIR / "people.json").write_text(json.dumps(people))

    _ensure_aux_files()   # preserve user-assigned names / hidden / aliases / deleted
    _cleanup_tmp()        # remove the per-block scratch dir

    write_status(len(photos), len(photos), running=False, done=True)
    print(
        f"\n==> index built: {len(photos)} photos, {len(people)} people, "
        f"clip {clip_matrix.shape}"
    )
    for r in people[:5]:
        print(f"   person {r['id']}: {r['count']} photos")


if __name__ == "__main__":
    # Worker mode: `build_index.py --worker <manifest> <start> <end> <out_prefix>`
    # processes one block in an isolated process (so the InsightFace C-level leak
    # is reclaimed on exit). Otherwise run the driver.
    if len(sys.argv) >= 6 and sys.argv[1] == "--worker":
        _run_worker(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
    elif len(sys.argv) >= 2 and sys.argv[1] == "--meta-only":
        refresh_meta()
    elif len(sys.argv) >= 2 and sys.argv[1] == "--incremental":
        incremental()
    else:
        main()
