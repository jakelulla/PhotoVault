"""PhotoSearch backend API.

Serves the prebuilt index (run build_index.py first) to the iOS app:

    GET  /api/people?top=5             top-N most-photographed people
    POST /api/people/{id}/name         assign a name to a person
    GET  /api/search                   names (AND) + caption + timestamp; blanks ignored
    GET  /api/face/{person_id}         representative face crop
    GET  /api/photo/{photo_id}         full image
    GET  /api/thumb/{photo_id}         thumbnail

Only CLIP (text) is loaded at runtime — face identities are precomputed in the
index, so caption search is the sole live model dependency.
"""

import asyncio
import io
import json
import re
import subprocess
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

import numpy as np
from fastapi import FastAPI, File, HTTPException, Query, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from PIL import Image
from pydantic import BaseModel

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
IMAGES_ROOT = ROOT / "test_images"
INDEX_DIR = HERE / "index"
FACES_DIR = INDEX_DIR / "faces"
THUMB_CACHE_DIR = INDEX_DIR / "thumb_cache"

# CLIP caption-relevance floor: below this, a photo is "unrelated" to the text.
# Per the notebook's ViT-B/32 calibration: >0.30 strongly related,
# 0.22-0.30 loosely related, <0.22 unrelated.
CAPTION_FLOOR = 0.25
DEFAULT_LIMIT = 200

# Two photos are "duplicates" if their perceptual hashes are within this many
# bits (same threshold the uploader uses to skip re-adds). Used to group
# near-identical photos so each shows once with a count. 7/64 ~= 89% identical —
# a little looser than 5 so near-misses (re-crops, light edits) still group,
# while staying tight enough to avoid chaining unrelated photos.
_DUP_HAMMING = 7
_POPCOUNT_LUT = np.array([bin(i).count("1") for i in range(256)], dtype=np.uint8)


class Store:
    """Loads index artifacts; holds mutable names; lazily loads CLIP for captions."""

    def __init__(self):
        # Start blank if there's no index yet (e.g. fresh slate) — the app can
        # then upload photos and trigger /api/reindex to populate it.
        INDEX_DIR.mkdir(exist_ok=True)
        if (INDEX_DIR / "photos.json").exists():
            self.photos = json.loads((INDEX_DIR / "photos.json").read_text())
        else:
            self.photos = []
        if (INDEX_DIR / "clip.npy").exists():
            self.clip = np.load(INDEX_DIR / "clip.npy")
        else:
            self.clip = np.zeros((0, 512), dtype=np.float32)
        self.names = self._load_json("names.json", {})
        self.hidden = set(self._load_json("hidden.json", []))
        # aliases: merged_person_id (str) -> canonical_person_id (int). Lets two
        # face clusters that are really the same person (e.g. a kid over the years)
        # be fused without rebuilding the index.
        self.aliases = {int(k): int(v) for k, v in self._load_json("aliases.json", {}).items()}
        # User-provided labels for places: {canonical_location_string: alias}.
        self.location_aliases = self._load_json("location_aliases.json", {})
        # Soft-deleted photo ids (hidden from the app, file kept on disk).
        self.deleted = set(self._load_json("deleted_photos.json", []))
        # Photo ids the user marked "not duplicates" — excluded from grouping so
        # they show individually (persisted, survives rebuilds).
        self.ungrouped = set(self._load_json("ungrouped.json", []))
        # Manually merged groups [[id, id, …], …] — user-dragged duplicates that
        # may have different phashes.  Applied on top of the phash-based groups.
        self.manual_dups: list[list[int]] = self._load_json("manual_dups.json", [])
        # User-defined folders: [{id, name}, ...]. Favorites is pre-seeded.
        self.folders: list[dict] = self._load_json("folders.json", [{"id": "favorites", "name": "Favorites"}])
        # folder_id -> list of photo indices in that folder.
        self.photo_folders: dict[str, list[int]] = self._load_json("photo_folders.json", {})
        self._clip_encoder = None  # lazy
        # Precompute parsed timestamps for fast filtering.
        self._dates = [self._parse_iso(p["timestamp"]) for p in self.photos]
        # Raw (pre-merge) per-cluster photo counts + the set of original cluster ids.
        self.raw_counts: dict[int, int] = {}
        for p in self.photos:
            for pid in p.get("person_ids", []):
                self.raw_counts[pid] = self.raw_counts.get(pid, 0) + 1
        self.all_person_ids = set(self.raw_counts)
        self._compute_dups()
        self._recompute()

    @staticmethod
    def _load_json(name: str, default):
        path = INDEX_DIR / name
        return json.loads(path.read_text()) if path.exists() else default

    def _compute_dups(self):
        """Group near-identical photos by perceptual-hash Hamming distance
        (union-find, threshold _DUP_HAMMING). Sets dup_rep[i] = the group's
        representative photo id (lowest id), and dup_members[rep] = all member
        ids. Depends only on pixels, so it's computed once per load."""
        n = len(self.photos)
        self.dup_rep = list(range(n))
        self.dup_members: dict[int, list[int]] = {}
        if n == 0:
            return
        ph = np.array([int(p.get("phash") or 0) for p in self.photos], dtype=np.uint64)
        b = ph.view(np.uint8).reshape(n, 8)
        parent = list(range(n))

        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        ungrouped = self.ungrouped
        for i in range(n):
            if i in ungrouped:                 # "not duplicates" — never links
                continue
            ham = _POPCOUNT_LUT[b[i + 1:] ^ b[i]].sum(axis=1)
            for j in np.nonzero(ham <= _DUP_HAMMING)[0]:
                jj = i + 1 + int(j)
                if jj in ungrouped:
                    continue
                ri, rj = find(i), find(jj)
                if ri != rj:
                    parent[ri] = rj

        # Apply manually merged groups on top of phash-based ones.
        for group in self.manual_dups:
            valid = [i for i in group if 0 <= i < n]
            for i in range(1, len(valid)):
                ri, rj = find(valid[0]), find(valid[i])
                if ri != rj:
                    parent[ri] = rj

        groups: dict[int, list[int]] = {}
        for i in range(n):
            groups.setdefault(find(i), []).append(i)
        for mem in groups.values():
            if len(mem) < 2:
                continue
            rep = min(mem)
            members = sorted(mem)
            for m in members:
                self.dup_rep[m] = rep
            self.dup_members[rep] = members

    def dup_count(self, i: int) -> int:
        """How many non-deleted photos are in photo i's duplicate group (incl. i)."""
        rep = self.dup_rep[i] if i < len(self.dup_rep) else i
        mem = self.dup_members.get(rep)
        if not mem:
            return 1
        return sum(1 for m in mem if m not in self.deleted)

    def canonical(self, pid: int) -> int:
        """Follow the merge chain to a person's canonical id."""
        seen = set()
        while pid in self.aliases and pid not in seen:
            seen.add(pid)
            pid = self.aliases[pid]
        return pid

    def _recompute(self):
        """Recompute canonical person set per photo + per-person photo counts.
        Call after any merge/delete so derived views stay consistent."""
        self.photo_people = []          # list[set[int]] of canonical ids per photo
        counts: dict[int, int] = {}
        for i, p in enumerate(self.photos):
            ids = {self.canonical(pid) for pid in p.get("person_ids", [])}
            self.photo_people.append(ids)
            if i in self.deleted:
                continue                # deleted photos don't count toward people
            for cid in ids:
                counts[cid] = counts.get(cid, 0) + 1
        self.counts = counts
        # People list = canonical people, most frequent first.
        self.people = sorted(
            ({"id": cid, "count": c} for cid, c in counts.items()),
            key=lambda r: r["count"], reverse=True,
        )

    @staticmethod
    def _parse_iso(s: str):
        try:
            dt = datetime.fromisoformat(s)
            # Normalize to naive: capture dates from the app's metadata backfill
            # carry a timezone (…Z) while older EXIF/mtime dates don't, and mixing
            # the two breaks every date sort. Drop tzinfo so all dates compare.
            return dt.replace(tzinfo=None) if dt.tzinfo is not None else dt
        except Exception:
            return None

    def save_names(self):
        (INDEX_DIR / "names.json").write_text(json.dumps(self.names))

    def save_hidden(self):
        (INDEX_DIR / "hidden.json").write_text(json.dumps(sorted(self.hidden)))

    def save_aliases(self):
        (INDEX_DIR / "aliases.json").write_text(
            json.dumps({str(k): v for k, v in self.aliases.items()}))

    def save_location_aliases(self):
        (INDEX_DIR / "location_aliases.json").write_text(json.dumps(self.location_aliases))

    def save_deleted(self):
        (INDEX_DIR / "deleted_photos.json").write_text(json.dumps(sorted(self.deleted)))

    def save_ungrouped(self):
        (INDEX_DIR / "ungrouped.json").write_text(json.dumps(sorted(self.ungrouped)))

    def save_manual_dups(self):
        (INDEX_DIR / "manual_dups.json").write_text(json.dumps(self.manual_dups))

    def save_folders(self):
        (INDEX_DIR / "folders.json").write_text(json.dumps(self.folders))

    def save_photo_folders(self):
        (INDEX_DIR / "photo_folders.json").write_text(json.dumps(self.photo_folders))

    def encode_text(self, text: str) -> np.ndarray:
        if self._clip_encoder is None:
            from clip_model import ClipEncoder
            self._clip_encoder = ClipEncoder(want_image=False)
        return self._clip_encoder.encode_text(text)


store = Store()

# --- Auto-reindex: rebuild the index on the Mac shortly after uploads stop
# arriving, so the phone can fire-and-forget (no need to trigger/await indexing).
_dirty = {"flag": False, "last": 0.0}
_full = {"flag": False}    # True => next build is a full re-cluster (new people),
                           # else an incremental update (fast; known people only)
_REINDEX_DEBOUNCE = 45.0   # seconds of quiet after the last upload before indexing

# The auto-reindex loop is the SINGLE owner of build_index. We track the live
# subprocess handle here so nothing ever spawns a second concurrent build (two
# builds at once doubled Metal/unified-memory use and got OOM-killed). /api/reindex
# just requests a run via the dirty flag; it never launches a process itself.
_build_proc: dict = {"proc": None}
_MAX_RETRIES = 3           # give up after this many consecutive failed builds
_retries = {"n": 0}

# Metadata-only dirtiness: a dup upload refreshed an existing photo's capture
# date/GPS sidecar (the backfill). That needs only a fast photos.json patch, not
# a full rebuild — tracked separately so we don't trigger a 1.5 hr reindex.
_meta_dirty = {"flag": False, "last": 0.0}


def _mark_meta_dirty():
    _meta_dirty["flag"] = True
    _meta_dirty["last"] = time.time()


def _build_running() -> bool:
    p = _build_proc["proc"]
    return p is not None and p.returncode is None


def _mark_dirty():
    _dirty["flag"] = True
    _dirty["last"] = time.time()


async def _auto_reindex_loop():
    global store                           # rebound after a (re)build / meta refresh
    while True:
        await asyncio.sleep(5)
        if _build_running():
            continue                       # never run two builds at once
        if not _dirty["flag"]:
            # Recover a crashed/interrupted run: if the lock is stale (indexer
            # died and left "running" behind), pick the work back up.
            if _index_status().get("stale") and _retries["n"] < _MAX_RETRIES:
                print("auto-reindex: stale index lock detected — resuming build")
                _mark_dirty()
                continue
            # No full rebuild pending: apply any metadata-only backfill cheaply.
            if _meta_dirty["flag"] and time.time() - _meta_dirty["last"] >= _REINDEX_DEBOUNCE:
                _meta_dirty["flag"] = False
                try:
                    proc = await asyncio.create_subprocess_exec(
                        sys.executable, "build_index.py", "--meta-only", cwd=str(HERE))
                    await proc.wait()
                    store = Store()
                    print("metadata refresh applied:", len(store.photos), "photos")
                except Exception as exc:
                    print("metadata refresh failed:", exc)
                    _mark_meta_dirty()
            continue
        if time.time() - _dirty["last"] < _REINDEX_DEBOUNCE:
            continue
        # Respect a live build started outside this process (e.g. a manual
        # build_index run): if status.json says running and isn't stale, wait.
        st = _index_status()
        if st.get("running") and not st.get("stale"):
            continue
        _dirty["flag"] = False
        full = _full["flag"]
        _full["flag"] = False
        try:
            STATUS_PATH.parent.mkdir(exist_ok=True)
            STATUS_PATH.write_text(json.dumps({"running": True, "processed": 0, "total": 0, "done": False}))
            # New photos normally just get an incremental update (fast, assigns
            # faces to existing people). A full re-cluster (which can discover new
            # people) only runs on an explicit /api/reindex.
            args = ["build_index.py"] if full else ["build_index.py", "--incremental"]
            proc = await asyncio.create_subprocess_exec(sys.executable, *args, cwd=str(HERE))
            _build_proc["proc"] = proc
            await proc.wait()
            store = Store()                # load whatever got built
            if proc.returncode == 0 and _index_status().get("done"):
                _retries["n"] = 0
                print(f"auto-reindex complete ({'full' if full else 'incremental'}):",
                      len(store.photos), "photos")
            else:
                _retries["n"] += 1
                print(f"auto-reindex did not finish (rc={proc.returncode}); "
                      f"attempt {_retries['n']}/{_MAX_RETRIES}")
                if _retries["n"] < _MAX_RETRIES:
                    _mark_dirty()
                else:
                    print("auto-reindex giving up after repeated failures; "
                          "mark dirty (upload a photo) or POST /api/reindex to retry")
        except Exception as exc:
            print("auto-reindex failed:", exc)
        finally:
            _build_proc["proc"] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_auto_reindex_loop())
    yield
    task.cancel()


app = FastAPI(title="PhotoSearch", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)


# --------------------------------------------------------------------------
# People + naming
# --------------------------------------------------------------------------

class NameBody(BaseModel):
    name: str


def _person_payload(rec: dict) -> dict:
    pid = rec["id"]
    return {
        "id": pid,
        "count": rec["count"],
        "name": store.names.get(str(pid)),
        "face_url": f"/api/face/{pid}",
    }


@app.get("/api/people")
def get_people(min_count: int = 20, folder_id: str = Query(default="")):
    """All people who appear in at least `min_count` photos (most frequent first).

    Every cluster already has >= 3 faces (DBSCAN min_samples), so `min_count`
    filters out the long tail of incidental faces. Deleted (hidden) people are excluded.
    """
    people = [
        _person_payload(r) for r in store.people
        if r["count"] >= min_count and r["id"] not in store.hidden
    ]
    if folder_id.strip():
        folder_set = set(store.photo_folders.get(folder_id, []))
        people_in_folder: set[int] = set()
        for pid in folder_set:
            if 0 <= pid < len(store.photos):
                for person_id in store.photos[pid].get("person_ids", []):
                    people_in_folder.add(store.canonical(person_id))
        people = [p for p in people if p["id"] in people_in_folder]
    return people


@app.delete("/api/people/{person_id}")
def delete_person(person_id: int):
    """Hide a person from the People tab (persists) and drop any name they had."""
    store.hidden.add(person_id)
    store.save_hidden()
    if store.names.pop(str(person_id), None) is not None:
        store.save_names()
    return {"id": person_id, "deleted": True}


@app.post("/api/people/{person_id}/name")
def set_name(person_id: int, body: NameBody):
    if not any(r["id"] == person_id for r in store.people):
        raise HTTPException(404, "unknown person")
    name = body.name.strip()
    if name:
        store.names[str(person_id)] = name
    else:
        store.names.pop(str(person_id), None)
    store.save_names()
    return {"id": person_id, "name": store.names.get(str(person_id))}


@app.post("/api/people/{source_id}/merge/{target_id}")
def merge_people(source_id: int, target_id: int):
    """Merge `source_id` into `target_id` — they become one person (target wins).

    Use when one real person was split into multiple clusters (e.g. a child who
    looks different across years). Persisted as an alias; reversible by editing
    aliases.json and re-running, and preserved across rebuilds.
    """
    source = store.canonical(source_id)
    target = store.canonical(target_id)
    if source == target:
        return {"merged": False, "reason": "same person"}

    store.aliases[source] = target
    # The merged-away cluster keeps no separate name; hand its name to the target
    # if the target was unnamed, then drop it.
    src_name = store.names.pop(str(source), None)
    if src_name and not store.names.get(str(target)):
        store.names[str(target)] = src_name
    store.hidden.discard(source)
    store.save_aliases()
    store.save_names()
    store.save_hidden()
    store._recompute()
    return {"merged": True, "source": source, "target": target,
            "count": store.counts.get(target, 0)}


@app.get("/api/people/{person_id}/members")
def person_members(person_id: int):
    """The original face clusters that make up a person. More than one means
    they've been merged; `is_primary` marks the cluster others were merged into."""
    canonical = store.canonical(person_id)
    members = sorted(
        (o for o in store.all_person_ids if store.canonical(o) == canonical),
        key=lambda o: store.raw_counts.get(o, 0), reverse=True,
    )
    return [
        {
            "id": o,
            "face_url": f"/api/face/{o}",
            "count": store.raw_counts.get(o, 0),
            "is_primary": o == canonical,
        }
        for o in members
    ]


@app.post("/api/people/{member_id}/unmerge")
def unmerge_person(member_id: int):
    """Split a previously-merged cluster back out into its own person."""
    if member_id in store.aliases:
        del store.aliases[member_id]
        store.save_aliases()
        store._recompute()
        return {"unmerged": True, "id": member_id}
    return {"unmerged": False, "reason": "not a merged cluster"}


# --------------------------------------------------------------------------
# Search
# --------------------------------------------------------------------------

def _resolve_name_to_ids(name: str) -> list[int]:
    """All person ids whose assigned name matches (case-insensitive; exact, then substring)."""
    q = name.strip().lower()
    if not q:
        return []
    exact = [int(pid) for pid, nm in store.names.items() if nm.lower() == q]
    if exact:
        return exact
    return [int(pid) for pid, nm in store.names.items() if q in nm.lower()]


def _parse_query_time(s: str):
    """Parse a date/datetime and return (datetime, granularity) or None.

    Accepts 'YYYY', 'YYYY-MM', 'YYYY-MM-DD', or full ISO 'YYYY-MM-DDTHH:MM'.
    Granularity controls the match window: year / month / day / time(+-6h).
    """
    s = s.strip()
    fmts = [("%Y", "year"), ("%Y-%m", "month"), ("%Y-%m-%d", "day")]
    for fmt, gran in fmts:
        try:
            return datetime.strptime(s, fmt), gran
        except ValueError:
            pass
    try:
        return datetime.fromisoformat(s), "time"
    except ValueError:
        return None


def _empty(offset: int, limit: int) -> dict:
    return {"results": [], "count": 0, "total": 0, "offset": offset, "limit": limit}


def _time_match(dt, target, gran) -> bool:
    if dt is None:
        return False
    if gran == "year":
        return dt.year == target.year
    if gran == "month":
        return (dt.year, dt.month) == (target.year, target.month)
    if gran == "day":
        return dt.date() == target.date()
    return abs((dt - target).total_seconds()) <= 6 * 3600


# --- Natural-language query parsing ----------------------------------------
# Split one free-text query ("Mom at the beach in summer 2021") across the
# structured filters search already supports: people, content (CLIP caption),
# time, and place. Only tags what the library can actually match (known names +
# the index's place vocabulary); leftover words become the content caption.

_NL_STOP = {
    "a", "an", "the", "of", "in", "on", "at", "with", "and", "to", "from",
    "me", "my", "show", "find", "search", "for", "taken", "photo", "photos",
    "pic", "pics", "picture", "pictures", "image", "images", "all",
}
_MONTHS = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
    "july": 7, "august": 8, "september": 9, "october": 10, "november": 11,
    "december": 12, "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7,
    "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
}


def _place_vocab() -> set[str]:
    """Lowercased place phrases in the index (city/state names from the
    reverse-geocoded locations + user aliases). 2-letter country codes skipped."""
    vocab: set[str] = set()
    for p in store.photos:
        loc = p.get("location")
        if not loc:
            continue
        for part in loc.split(","):
            t = part.strip().lower()
            if len(t) > 2:
                vocab.add(t)
    for alias in store.location_aliases.values():
        if alias:
            vocab.add(alias.lower())
    return vocab


def _match_phrases(tokens: list[str], phrases: set[str], consumed: set[int]) -> list[str]:
    """Greedily tag known phrases (longest first) over `tokens`, skipping already
    -consumed positions. Mutates `consumed`; returns the matched phrases."""
    matched: list[str] = []
    for ph in sorted((p for p in phrases if p), key=lambda p: len(p.split()), reverse=True):
        w = ph.split()
        L = len(w)
        i = 0
        while i + L <= len(tokens):
            if all((i + k) not in consumed for k in range(L)) and tokens[i:i + L] == w:
                matched.append(ph)
                consumed.update(range(i, i + L))
                i += L
            else:
                i += 1
    return matched


def _parse_nl_query(q: str) -> dict:
    """Free text -> {names, caption, timestamp, location}."""
    tokens = re.findall(r"[a-z0-9]+", q.lower())
    consumed: set[int] = set()

    known = {n.lower(): n for n in store.names.values() if n}
    names = [known[m] for m in _match_phrases(tokens, set(known), consumed)]

    places = _match_phrases(tokens, _place_vocab(), consumed)
    location = places[0] if places else ""

    # Time: a year, optionally with a month. A month with no year stays in the
    # caption (it might be content, e.g. "may flowers").
    year = year_i = month = month_i = None
    for i, t in enumerate(tokens):
        if i in consumed:
            continue
        if year is None and re.fullmatch(r"(19|20)\d{2}", t):
            year, year_i = t, i
        elif month is None and t in _MONTHS:
            month, month_i = _MONTHS[t], i
    timestamp = ""
    if year:
        consumed.add(year_i)
        if month is not None:
            consumed.add(month_i)
            timestamp = f"{year}-{month:02d}"
        else:
            timestamp = year

    caption = " ".join(t for i, t in enumerate(tokens)
                       if i not in consumed and t not in _NL_STOP)
    return {"names": names, "caption": caption, "timestamp": timestamp, "location": location}


@app.get("/api/search")
def search(
    q: str = Query(default=""),
    name: list[str] = Query(default=[]),
    caption: str = Query(default=""),
    timestamp: str = Query(default=""),
    location: str = Query(default=""),
    device_id: str = Query(default=""),
    folder_id: str = Query(default=""),
    limit: int = DEFAULT_LIMIT,
    offset: int = 0,
):
    # Natural-language box: parse `q` into the structured filters below. Explicit
    # params still win if provided; the parsed reading is echoed back as
    # `interpreted` so the UI can show what it searched.
    interpreted = None
    if q.strip():
        interpreted = _parse_nl_query(q)
        name = name or interpreted["names"]
        caption = caption or interpreted["caption"]
        timestamp = timestamp or interpreted["timestamp"]
        location = location or interpreted["location"]
    # Candidate set starts as every (non-deleted) photo; each field narrows it.
    candidates = [i for i in range(len(store.photos)) if i not in store.deleted]

    # --- Device filter: Photos tab passes its UUID so only that device's photos show. ---
    if device_id.strip():
        candidates = [i for i in candidates
                      if store.photos[i].get("device_id", "") == device_id]

    # --- Folder filter: restrict to photos the user placed in a folder. ---
    if folder_id.strip():
        folder_set = set(store.photo_folders.get(folder_id, []))
        candidates = [i for i in candidates if i in folder_set]

    # --- Names (AND): photo must contain a person for every requested name. ---
    names = [n for n in name if n.strip()]
    if names:
        for nm in names:
            ids = set(_resolve_name_to_ids(nm))
            if not ids:
                return _empty(offset, limit)  # unknown name -> AND fails
            canon_ids = {store.canonical(pid) for pid in ids}
            candidates = [
                i for i in candidates
                if canon_ids & store.photo_people[i]
            ]
        if not candidates:
            return _empty(offset, limit)

    # --- Timestamp: keep photos inside the window. ---
    if timestamp.strip():
        parsed = _parse_query_time(timestamp)
        if parsed is None:
            raise HTTPException(400, f"could not parse timestamp '{timestamp}'")
        target, gran = parsed
        candidates = [i for i in candidates if _time_match(store._dates[i], target, gran)]
        if not candidates:
            return _empty(offset, limit)

    # --- Location: substring match against the reverse-geocoded place name. ---
    # (e.g. "hawaii" matches "Pukalani, Hawaii, US"). Photos with no GPS never match.
    if location.strip():
        q = location.strip().lower()

        def loc_matches(i: int) -> bool:
            loc = store.photos[i].get("location") or ""
            if q in loc.lower():
                return True
            alias = store.location_aliases.get(loc)
            return bool(alias) and q in alias.lower()

        candidates = [i for i in candidates if loc_matches(i)]
        if not candidates:
            return _empty(offset, limit)

    # --- Caption: rank by CLIP cosine similarity (and drop unrelated). ---
    scored: list[tuple[int, float]] = []
    if caption.strip():
        t_emb = store.encode_text(caption.strip())
        sims = store.clip[candidates] @ t_emb
        for i, s in zip(candidates, sims):
            if s >= CAPTION_FLOOR:
                scored.append((i, float(s)))
        scored.sort(key=lambda x: x[1], reverse=True)
    else:
        # No caption: sort by recency (newest first).
        scored = [(i, 0.0) for i in candidates]
        scored.sort(
            key=lambda x: store._dates[x[0]] or datetime.min, reverse=True
        )

    return _results_payload(scored, offset, limit, interpreted)


def _results_payload(scored: list[tuple[int, float]], offset: int, limit: int,
                     interpreted: dict | None = None, collapse: bool = True) -> dict:
    """Build the paged search-result response from ranked (photo_index, score) pairs.

    When `collapse` is set (the default for every browse/search view), near-
    identical photos are folded to a single representative — the first (best-
    ranked) one in each duplicate group — and each result carries `dup_count`
    (how many photos that representative stands for)."""
    if collapse:
        seen, deduped = set(), []
        for i, s in scored:
            rep = store.dup_rep[i] if i < len(store.dup_rep) else i
            if rep in seen:
                continue
            seen.add(rep)
            deduped.append((i, s))
        scored = deduped
    total = len(scored)
    results = []
    for i, s in scored[offset:offset + limit]:
        p = store.photos[i]
        people_names = sorted({
            store.names[str(pid)]
            for pid in store.photo_people[i]
            if str(pid) in store.names
        })
        results.append({
            "photo_id": p["photo_id"],
            "url": f"/api/photo/{p['photo_id']}",
            "thumb_url": f"/api/thumb/{p['photo_id']}",
            "timestamp": p["timestamp"],
            "location": p.get("location"),
            "score": round(s, 3),
            "people": people_names,
            "dup_count": store.dup_count(i),
        })
    payload = {"results": results, "count": len(results), "total": total,
               "offset": offset, "limit": limit}
    if interpreted is not None:
        payload["interpreted"] = interpreted
    return payload


@app.get("/api/locations")
def get_locations(min_count: int = 1, folder_id: str = Query(default="")):
    """Distinct tagged places (reverse-geocoded), most common first, with a
    representative thumbnail. Photos for a place come from /api/search?location=."""
    folder_set = set(store.photo_folders.get(folder_id, [])) if folder_id.strip() else None
    counts: dict[str, int] = {}
    rep: dict[str, int] = {}
    for i, p in enumerate(store.photos):
        loc = p.get("location")
        if not loc or i in store.deleted:
            continue
        if folder_set is not None and i not in folder_set:
            continue
        counts[loc] = counts.get(loc, 0) + 1
        rep.setdefault(loc, p["photo_id"])
    items = [
        {
            "location": loc,
            "alias": store.location_aliases.get(loc),
            "count": c,
            "thumb_url": f"/api/thumb/{rep[loc]}",
        }
        for loc, c in counts.items() if c >= min_count
    ]
    items.sort(key=lambda x: x["count"], reverse=True)
    return items


class LocationAliasBody(BaseModel):
    location: str
    alias: str


@app.post("/api/locations/alias")
def set_location_alias(body: LocationAliasBody):
    """Label a place (e.g. 'Grandma's house'). Searching the label or the real
    place name both return its photos."""
    alias = body.alias.strip()
    if alias:
        store.location_aliases[body.location] = alias
    else:
        store.location_aliases.pop(body.location, None)
    store.save_location_aliases()
    return {"location": body.location, "alias": store.location_aliases.get(body.location)}


@app.get("/api/people/{person_id}/photos")
def person_photos(person_id: int, folder_id: str = Query(default=""), limit: int = DEFAULT_LIMIT, offset: int = 0):
    """All photos containing a person (newest first), paged — even if unnamed."""
    target = store.canonical(person_id)
    folder_set = set(store.photo_folders.get(folder_id, [])) if folder_id.strip() else None
    idxs = [
        i for i in range(len(store.photos))
        if target in store.photo_people[i] and i not in store.deleted
        and (folder_set is None or i in folder_set)
    ]
    idxs.sort(key=lambda i: store._dates[i] or datetime.min, reverse=True)
    scored = [(i, 0.0) for i in idxs]
    return _results_payload(scored, offset, limit)


STATUS_PATH = INDEX_DIR / "status.json"


def _dhash(pil_img, hash_size: int = 8) -> int:
    """Perceptual hash (matches build_index.dhash) — light, no heavy model deps."""
    img = pil_img.convert("L").resize((hash_size + 1, hash_size), Image.Resampling.LANCZOS)
    px = np.asarray(img, dtype=np.int16)
    bits = 0
    for v in (px[:, 1:] > px[:, :-1]).flatten():
        bits = (bits << 1) | int(v)
    return bits


def _meta_from_headers(headers) -> dict:
    """Capture metadata the iOS app sends alongside each upload (from PhotoKit,
    which is authoritative — EXIF doesn't survive our JPEG re-encode)."""
    def _num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None
    meta: dict = {}
    aid = headers.get("x-asset-id")
    did = headers.get("x-device-id")
    created = headers.get("x-created")        # ISO-8601 capture date
    lat = _num(headers.get("x-lat"))
    lon = _num(headers.get("x-lon"))
    if aid:
        meta["asset_id"] = aid
    if did:
        meta["device_id"] = did
    if created:
        meta["created"] = created
    if lat is not None and lon is not None:
        meta["lat"] = lat
        meta["lon"] = lon
    return meta


def _write_sidecar(jpg_path: Path, meta: dict) -> None:
    """Persist capture metadata next to its image as <name>.json. build_index
    prefers this over EXIF. Per-file (not a shared index) so concurrent
    background uploads never race on it."""
    if not meta:
        return
    try:
        jpg_path.with_suffix(".json").write_text(json.dumps(meta))
    except Exception:
        pass


def _save_photo_if_new(data: bytes, meta: dict | None = None) -> str:
    """Save image bytes into test_images/uploads as JPEG, unless an equivalent
    photo is already indexed. Returns 'added', 'updated' (an already-indexed dup
    whose capture metadata we refreshed — the backfill path), or 'skipped'.
    Light — no model load."""
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except Exception:
        pass
    try:
        pil = Image.open(io.BytesIO(data)).convert("RGB")
    except Exception:
        return "skipped"
    phash = _dhash(pil)
    # Already indexed? Don't re-store the pixels — just (re)write its capture
    # metadata sidecar so the next reindex can backfill date/place.
    for p in store.photos:
        ph = p.get("phash")
        if ph is not None and (int(ph) ^ phash).bit_count() <= _DUP_HAMMING:
            if meta:
                _write_sidecar(IMAGES_ROOT / p["path"], meta)
                return "updated"
            return "skipped"
    uploads = IMAGES_ROOT / "uploads"
    uploads.mkdir(exist_ok=True)
    name = f"{uuid.uuid4().hex}.jpg"
    pil.save(uploads / name, format="JPEG", quality=90)
    _write_sidecar(uploads / name, meta or {})
    return "added"


@app.post("/api/photos/upload-raw")
async def upload_raw(files: list[UploadFile] = File(...)):
    """Save granted device photos (multipart). Auto-reindex runs once uploads stop."""
    added = 0
    skipped = 0
    for file in files:
        data = await file.read()
        if data and _save_photo_if_new(data) == "added":
            added += 1
        else:
            skipped += 1
    if added:
        _mark_dirty()
    return {"added": added, "skipped": skipped}


@app.post("/api/photos/upload-one")
async def upload_one(request: Request):
    """Save a single photo from a raw request body — used by the iOS background
    URLSession (which uploads from a file), so transfers continue when the app is
    backgrounded or the phone is locked. Capture date + GPS ride along as
    X-Created / X-Lat / X-Lon headers. Auto-reindex runs once uploads stop."""
    data = await request.body()
    meta = _meta_from_headers(request.headers)
    result = _save_photo_if_new(data, meta) if data else "skipped"
    if result == "added":
        _mark_dirty()            # new pixels -> full reindex (embeddings + faces)
    elif result == "updated":
        _mark_meta_dirty()       # only date/GPS changed -> fast metadata refresh
    return {
        "added": 1 if result == "added" else 0,
        "updated": 1 if result == "updated" else 0,
        "skipped": 1 if result == "skipped" else 0,
    }


@app.post("/api/photos/upload-device")
async def upload_device(request: Request):
    """Accept a photo whose CLIP + face embeddings were already computed on-device.

    The iOS app runs CLIP + SCRFD + ArcFace locally, then POSTs the thumbnail
    JPEG (base64) plus the pre-computed embeddings here. The backend stores
    everything and assigns faces to existing person clusters — no ML inference
    needed on the server side for these uploads.

    JSON body:
        thumbnail_b64  : str   — base64-encoded JPEG thumbnail
        clip_embedding : list  — 512 float32 values (L2-normalized)
        face_embeddings: list  — list of 512-float lists, one per detected face
        asset_id       : str   — PhotoKit localIdentifier
        created        : str   — ISO-8601 capture date (optional)
        lat, lon       : float — GPS (optional)
        device_id      : str   — UIDevice.identifierForVendor (optional)
    """
    import base64

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "invalid JSON")

    thumb_b64 = body.get("thumbnail_b64", "")
    clip_emb  = body.get("clip_embedding", [])
    face_embs = body.get("face_embeddings", [])

    if not thumb_b64 or len(clip_emb) != 512:
        raise HTTPException(400, "thumbnail_b64 and 512-dim clip_embedding required")

    try:
        thumb_bytes = base64.b64decode(thumb_b64)
        pil = Image.open(io.BytesIO(thumb_bytes)).convert("RGB")
    except Exception:
        raise HTTPException(400, "cannot decode thumbnail")

    phash = _dhash(pil)

    # Duplicate check
    for p in store.photos:
        ph = p.get("phash")
        if ph is not None and (int(ph) ^ phash).bit_count() <= _DUP_HAMMING:
            # Already indexed; update metadata sidecar if provided
            meta = _meta_from_body(body)
            if meta:
                _write_sidecar(IMAGES_ROOT / p["path"], meta)
            return {"added": 0, "skipped": 1, "photo_id": p["photo_id"]}

    # Save thumbnail
    uploads = IMAGES_ROOT / "uploads"
    uploads.mkdir(exist_ok=True)
    uid  = uuid.uuid4().hex
    dest = uploads / f"{uid}.jpg"
    pil.save(dest, format="JPEG", quality=90)
    _write_sidecar(dest, _meta_from_body(body))

    # Assign faces to existing person clusters (if prototypes exist)
    person_ids: list[int] = []
    MATCH_THRESHOLD = 0.3
    if face_embs and (INDEX_DIR / "prototypes.npy").exists():
        protos = np.load(INDEX_DIR / "prototypes.npy")
        if len(protos):
            for fe in face_embs:
                emb = np.asarray(fe, dtype=np.float32)
                if emb.shape == (512,):
                    sims = protos @ emb
                    best = int(sims.argmax())
                    if float(sims[best]) >= MATCH_THRESHOLD:
                        person_ids.append(best)

    # Build timestamp + location from body metadata
    meta = _meta_from_body(body)
    created  = meta.get("created", "")
    location = ""
    lat      = meta.get("lat")
    lon      = meta.get("lon")
    if lat is not None and lon is not None:
        try:
            import build_index as bi
            from geopy.geocoders import Nominatim
            geo = Nominatim(user_agent="photosearch")
            loc = geo.reverse(f"{lat},{lon}", language="en", timeout=5)
            location = loc.address if loc else ""
        except Exception:
            pass

    pid = len(store.photos)
    row = {
        "photo_id":   pid,
        "path":       str(dest.relative_to(IMAGES_ROOT)),
        "timestamp":  created or "",
        "location":   location,
        "lat":        lat,
        "lon":        lon,
        "person_ids": sorted(set(person_ids)),
        "phash":      phash,
        "asset_id":   meta.get("asset_id", ""),
        "device_id":  meta.get("device_id", ""),
    }
    store.photos.append(row)
    store._dates.append(store._parse_iso(created or ""))
    for o in set(person_ids):
        store.raw_counts[o] = store.raw_counts.get(o, 0) + 1
        store.all_person_ids.add(o)

    # Append CLIP embedding
    emb_arr = np.asarray(clip_emb, dtype=np.float32).reshape(1, 512)
    store.clip = np.vstack([store.clip, emb_arr])
    np.save(INDEX_DIR / "clip.npy", store.clip)
    (INDEX_DIR / "photos.json").write_text(json.dumps(store.photos))
    store._recompute()

    return {"added": 1, "skipped": 0, "photo_id": pid}


def _meta_from_body(body: dict) -> dict:
    """Extract capture metadata from a JSON body (device upload path)."""
    def _num(v):
        try:   return float(v)
        except Exception: return None
    meta: dict = {}
    for key in ("asset_id", "created", "device_id"):
        if body.get(key):
            meta[key] = body[key]
    lat = _num(body.get("lat"))
    lon = _num(body.get("lon"))
    if lat is not None and lon is not None:
        meta["lat"] = lat; meta["lon"] = lon
    return meta


@app.post("/api/reindex")
def reindex():
    """Request a rebuild that (re)clusters faces + embeds everything in
    test_images/. Clustering (People) only happens here, not in per-photo upload.

    This does NOT spawn build_index directly — it asks the single-owner
    auto-reindex loop to run one (bypassing the upload debounce), so there can
    never be two concurrent builds competing for memory."""
    if _build_running():
        return {"started": False, "reason": "already running"}
    _retries["n"] = 0          # explicit request: clear the give-up counter
    _full["flag"] = True       # explicit reindex = full re-cluster (finds new people)
    _dirty["flag"] = True
    _dirty["last"] = 0.0       # 0 => debounce already satisfied, runs next tick
    return {"started": True}


# If status.json says "running" but hasn't been touched in this long, the
# build_index process is dead (crash or Mac sleep) and left a stale lock.
# build_index updates the file every chunk (~15s); the only long quiet gap is
# the clustering step (well under a minute), so 10 min is a safe crash signal.
_STALE_AFTER = 600.0


def _index_status() -> dict:
    if STATUS_PATH.exists():
        try:
            st = json.loads(STATUS_PATH.read_text())
            # Self-heal: a "running" lock that has gone quiet means the indexer
            # died. Report it as not-running so reindex isn't deadlocked, and
            # flag it stale so the auto loop knows to resume.
            if st.get("running") and not st.get("done"):
                age = time.time() - STATUS_PATH.stat().st_mtime
                if age > _STALE_AFTER:
                    st["running"] = False
                    st["stale"] = True
            return st
        except Exception:
            pass
    return {"running": False, "processed": 0, "total": 0, "done": False}


@app.get("/api/index/status")
def index_status():
    return _index_status()


@app.post("/api/reload")
def reload_index():
    """Reload the in-memory index after a reindex completes."""
    global store
    store = Store()
    return {"reloaded": True, "photos": len(store.photos), "people": len(store.people)}


_ml: dict = {}


def _ensure_ml() -> dict:
    """Lazily load the face + CLIP models (and prototypes) for indexing uploads.
    The server normally avoids these heavy deps; only uploads need them."""
    if _ml:
        return _ml
    import build_index as bi          # importing this loads InsightFace (utils)
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()   # let PIL open HEIC uploads
    except Exception:
        pass
    protos = None
    if (INDEX_DIR / "prototypes.npy").exists():
        protos = np.load(INDEX_DIR / "prototypes.npy")
    _ml.update(bi=bi, clip=bi.ClipEncoder(want_image=True), protos=protos)
    return _ml


@app.post("/api/photos/upload")
async def upload_photos(files: list[UploadFile] = File(...)):
    """Index photos picked on the device: run faces + CLIP + EXIF on each and
    append to the index so they're immediately searchable. Faces are matched to
    existing people via saved prototypes (rebuild the index once to create them)."""
    import uuid
    ml = _ensure_ml()
    bi, clip, protos = ml["bi"], ml["clip"], ml["protos"]
    uploads = IMAGES_ROOT / "uploads"
    uploads.mkdir(exist_ok=True)

    DUP_HAMMING = 5
    new_ids: list[int] = []
    new_rows: list[np.ndarray] = []
    skipped = 0
    restored: list[int] = []
    for file in files:
        data = await file.read()
        if not data:
            continue
        uid = uuid.uuid4().hex
        ext = Path(file.filename or "").suffix.lower()
        if ext not in {".jpg", ".jpeg", ".png", ".heic"}:
            ext = ".jpg"
        tmp = uploads / f"{uid}{ext}"
        tmp.write_bytes(data)
        try:
            pil = Image.open(tmp).convert("RGB")     # HEIC ok (heif opener registered)
        except Exception:
            tmp.unlink(missing_ok=True)
            continue

        # --- Dedup: does this image already exist (perceptual hash match)? ---
        # Pick the CLOSEST match within threshold; on ties prefer a deleted one,
        # so re-adding a photo you deleted restores it rather than matching some
        # other near-duplicate that's still in the library.
        phash = bi.dhash(pil)
        best = None  # (sort_key, is_deleted, photo_id)
        for p in store.photos:
            ph = p.get("phash")
            if ph is None:
                continue
            dist = (int(ph) ^ phash).bit_count()
            if dist <= DUP_HAMMING:
                is_del = p["photo_id"] in store.deleted
                key = (dist, 0 if is_del else 1)     # closer first; deleted wins ties
                if best is None or key < best[0]:
                    best = (key, is_del, p["photo_id"])
        if best is not None:
            tmp.unlink(missing_ok=True)              # don't keep a copy
            _, is_del, match_id = best
            if is_del:
                store.deleted.discard(match_id)      # re-adding a deleted photo restores it
                restored.append(match_id)
            else:
                skipped += 1                         # already in the library
            continue

        timestamp, location, lat, lon = bi.read_exif_meta(tmp)

        # Store a re-encoded JPEG so /api/photo always serves a valid image,
        # regardless of the source format.
        dest = uploads / f"{uid}.jpg"
        pil.save(dest, format="JPEG", quality=90)
        if tmp != dest:
            tmp.unlink(missing_ok=True)

        # Faces -> nearest existing person (prototype), if confident enough.
        person_ids: list[int] = []
        if protos is not None and len(protos):
            bgr = np.asarray(pil)[:, :, ::-1].copy()    # RGB -> BGR for InsightFace
            for f in bi.get_faces(bgr):
                emb = np.asarray(f.normed_embedding, dtype=np.float32)
                sims = protos @ emb
                best = int(sims.argmax())
                if float(sims[best]) >= bi.MATCH_THRESHOLD:
                    person_ids.append(best)

        pid = len(store.photos)
        store.photos.append({
            "photo_id": pid,
            "path": str(dest.relative_to(IMAGES_ROOT)),
            "timestamp": timestamp, "location": location, "lat": lat, "lon": lon,
            "person_ids": sorted(set(person_ids)),
            "phash": phash,
        })
        store._dates.append(store._parse_iso(timestamp))
        new_rows.append(clip.encode_image(pil))
        for o in set(person_ids):
            store.raw_counts[o] = store.raw_counts.get(o, 0) + 1
            store.all_person_ids.add(o)
        new_ids.append(pid)

    if new_rows:
        store.clip = np.vstack([store.clip, np.array(new_rows, dtype=np.float32)])
        np.save(INDEX_DIR / "clip.npy", store.clip)
        (INDEX_DIR / "photos.json").write_text(json.dumps(store.photos))
    if restored:
        store.save_deleted()
    if new_rows or restored:
        store._recompute()
    return {"added": len(new_ids), "skipped": skipped,
            "restored": len(restored), "photo_ids": new_ids}


@app.delete("/api/photo/{photo_id}")
def delete_photo(photo_id: int):
    """Soft-delete a photo: hidden from search/people/places (file kept on disk)."""
    if not (0 <= photo_id < len(store.photos)):
        raise HTTPException(404, "unknown photo")
    store.deleted.add(photo_id)
    store.save_deleted()
    store._recompute()
    return {"photo_id": photo_id, "deleted": True}


@app.get("/api/photo/{photo_id}/duplicates")
def photo_duplicates(photo_id: int):
    """All non-deleted photos in this photo's duplicate group (the representative
    first), so the app can show every near-identical copy."""
    if not (0 <= photo_id < len(store.photos)):
        raise HTTPException(404, "unknown photo")
    rep = store.dup_rep[photo_id]
    members = [m for m in store.dup_members.get(rep, [photo_id]) if m not in store.deleted]
    scored = [(m, 0.0) for m in members]
    return _results_payload(scored, 0, len(scored), collapse=False)


class KeepBody(BaseModel):
    keep: list[int] = []


@app.post("/api/photo/{photo_id}/keep")
def keep_photo(photo_id: int, body: KeepBody | None = None):
    """Soft-delete every photo in this photo's duplicate group EXCEPT the ones in
    `body.keep`. With a body present, the keep list is honored literally — an
    empty list deletes the whole group ("delete all"). With no body, keep just
    {photo_id} (the original single-keep behavior)."""
    if not (0 <= photo_id < len(store.photos)):
        raise HTTPException(404, "unknown photo")
    rep = store.dup_rep[photo_id]
    members = store.dup_members.get(rep, [photo_id])
    member_set = set(members)
    keep = {k for k in body.keep if k in member_set} if body is not None else {photo_id}
    deleted = []
    for m in members:
        if m not in keep and m not in store.deleted:
            store.deleted.add(m)
            deleted.append(m)
    if deleted:
        store.save_deleted()
        store._recompute()
    return {"kept": sorted(keep), "deleted": deleted}


@app.post("/api/photos/merge")
def merge_photos(body: dict):
    """Manually merge two photos (and their existing groups) into one duplicate
    group regardless of phash.  Persisted in manual_dups.json so it survives
    reloads and rebuilds."""
    global store
    try:
        a, b = int(body["a"]), int(body["b"])
    except (KeyError, ValueError, TypeError):
        raise HTTPException(400, "body must be {a: int, b: int}")
    n = len(store.photos)
    if not (0 <= a < n and 0 <= b < n):
        raise HTTPException(404, "unknown photo id")
    if a == b:
        return {"merged": False, "reason": "same photo"}

    # Find existing manual groups that contain a or b.
    idx_a = next((i for i, g in enumerate(store.manual_dups) if a in g), None)
    idx_b = next((i for i, g in enumerate(store.manual_dups) if b in g), None)

    if idx_a is not None and idx_b is not None and idx_a == idx_b:
        return {"merged": False, "reason": "already in same manual group"}

    if idx_a is None and idx_b is None:
        store.manual_dups.append([a, b])
    elif idx_a is not None and idx_b is None:
        store.manual_dups[idx_a].append(b)
    elif idx_a is None and idx_b is not None:
        store.manual_dups[idx_b].append(a)
    else:
        # Absorb the smaller group into the larger one, remove the smaller.
        store.manual_dups[idx_a].extend(
            x for x in store.manual_dups[idx_b] if x not in store.manual_dups[idx_a]
        )
        store.manual_dups.pop(idx_b)

    store.save_manual_dups()
    # Remove both from ungrouped — manual merge overrides "not duplicates".
    store.ungrouped.discard(a)
    store.ungrouped.discard(b)
    store.save_ungrouped()
    store._compute_dups()
    return {"merged": True}


@app.post("/api/photos/backfill-device-id")
def backfill_device_id(body: dict):
    """Tag all photos that have no device_id with the supplied id.
    Called once on app launch so photos uploaded before device-id tracking
    was wired up still appear under the correct device."""
    did = (body.get("device_id") or "").strip()
    if not did:
        raise HTTPException(400, "device_id required")
    patched = 0
    for p in store.photos:
        if not p.get("device_id"):
            p["device_id"] = did
            patched += 1
    if patched:
        (INDEX_DIR / "photos.json").write_text(json.dumps(store.photos))
        # Backfill sidecar files too so future reindexes keep the tag.
        for p in store.photos:
            if p.get("device_id") != did:
                continue
            jpg = IMAGES_ROOT / p["path"]
            side = jpg.with_suffix(".json")
            try:
                meta = json.loads(side.read_text()) if side.exists() else {}
                if not meta.get("device_id"):
                    meta["device_id"] = did
                    side.write_text(json.dumps(meta))
            except Exception:
                pass
    return {"patched": patched}


@app.get("/api/folders")
def list_folders():
    return store.folders


@app.post("/api/folders")
def create_folder(body: dict):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name required")
    folder = {"id": uuid.uuid4().hex, "name": name}
    store.folders.append(folder)
    store.save_folders()
    return folder


@app.delete("/api/folders/{folder_id}")
def delete_folder(folder_id: str, delete_photos: bool = Query(default=False)):
    idx = next((i for i, f in enumerate(store.folders) if f["id"] == folder_id), None)
    if idx is None:
        raise HTTPException(404, "folder not found")
    store.folders.pop(idx)
    store.save_folders()
    photo_ids = store.photo_folders.pop(folder_id, [])
    store.save_photo_folders()
    if delete_photos:
        for pid in photo_ids:
            if 0 <= pid < len(store.photos) and pid not in store.deleted:
                store.deleted.add(pid)
        if photo_ids:
            store.save_deleted()
    return {"deleted": True, "photos_deleted": len(photo_ids) if delete_photos else 0}


@app.post("/api/folders/{folder_id}/photos")
def add_to_folder(folder_id: str, body: dict):
    if not any(f["id"] == folder_id for f in store.folders):
        raise HTTPException(404, "folder not found")
    photo_ids = [int(i) for i in body.get("photo_ids", [])]
    existing = set(store.photo_folders.get(folder_id, []))
    existing.update(photo_ids)
    store.photo_folders[folder_id] = list(existing)
    store.save_photo_folders()
    return {"added": len(photo_ids)}


@app.post("/api/folders/{folder_id}/remove")
def remove_from_folder(folder_id: str, body: dict):
    photo_ids = set(int(i) for i in body.get("photo_ids", []))
    current = set(store.photo_folders.get(folder_id, []))
    store.photo_folders[folder_id] = list(current - photo_ids)
    store.save_photo_folders()
    return {"removed": len(photo_ids)}


@app.post("/api/photo/{photo_id}/ungroup")
def ungroup_photo(photo_id: int):
    """Mark this photo's duplicate group as 'not duplicates' — its members are
    excluded from grouping from now on and shown individually. Persisted across
    rebuilds. Deletes nothing."""
    if not (0 <= photo_id < len(store.photos)):
        raise HTTPException(404, "unknown photo")
    rep = store.dup_rep[photo_id]
    members = store.dup_members.get(rep, [photo_id])
    store.ungrouped.update(members)
    store.save_ungrouped()
    store._compute_dups()          # recompute groups respecting the exclusion (~secs)
    return {"ungrouped": sorted(members)}


# --------------------------------------------------------------------------
# Image serving
# --------------------------------------------------------------------------

def _photo_path(photo_id: int) -> Path:
    if not (0 <= photo_id < len(store.photos)):
        raise HTTPException(404, "unknown photo")
    return IMAGES_ROOT / store.photos[photo_id]["path"]


@app.get("/api/photo/{photo_id}")
def get_photo(photo_id: int):
    path = _photo_path(photo_id)
    if not path.exists():
        raise HTTPException(404, "file missing")
    return Response(path.read_bytes(), media_type="image/jpeg")


@app.get("/api/thumb/{photo_id}")
def get_thumb(photo_id: int, size: int = 400):
    path = _photo_path(photo_id)
    if not path.exists():
        raise HTTPException(404, "file missing")

    # Serve from disk cache when present; otherwise render once and cache.
    # Without this, every scroll re-decodes the full-resolution JPEG — fine at
    # hundreds of photos, a real bottleneck at tens of thousands.
    cache_file = THUMB_CACHE_DIR / f"{photo_id}_{size}.jpg"
    if cache_file.exists():
        return Response(cache_file.read_bytes(), media_type="image/jpeg")

    img = Image.open(path).convert("RGB")
    img.thumbnail((size, size))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=82)
    data = buf.getvalue()
    THUMB_CACHE_DIR.mkdir(exist_ok=True)
    cache_file.write_bytes(data)
    return Response(data, media_type="image/jpeg")


@app.get("/api/face/{person_id}")
def get_face(person_id: int):
    path = FACES_DIR / f"{person_id}.jpg"
    if not path.exists():
        raise HTTPException(404, "no face crop")
    return Response(path.read_bytes(), media_type="image/jpeg")


@app.get("/api/photos/summary")
def photos_summary(device_id: str = Query(default=""), folder_id: str = Query(default="")):
    """Year and month buckets for the Photos tab Years/Months views.
    Each bucket includes a cover photo (most recent in the period) and count."""
    year_buckets: dict[int, list[int]] = {}
    month_buckets: dict[tuple, list[int]] = {}
    did = device_id.strip()
    folder_set = set(store.photo_folders.get(folder_id, [])) if folder_id.strip() else None

    for i, (p, dt) in enumerate(zip(store.photos, store._dates)):
        if i in store.deleted or i in store.hidden:
            continue
        if dt is None:
            continue
        if did and p.get("device_id", "") != did:
            continue
        if folder_set is not None and i not in folder_set:
            continue
        y, m = dt.year, dt.month
        year_buckets.setdefault(y, []).append(i)
        month_buckets.setdefault((y, m), []).append(i)

    def cover(indices: list[int]) -> dict:
        # Most recent timestamp wins.
        idx = max(indices, key=lambda i: store._dates[i] or datetime.min)
        p = store.photos[idx]
        return {
            "photo_id": idx,
            "thumb_url": f"/api/thumb/{idx}",
            "timestamp": p.get("timestamp", ""),
            "location": p.get("location") or "",
            "people": p.get("person_ids", []),
            "dup_count": store.dup_count(idx),
            "score": 1.0,
        }

    years = [
        {"year": y, "month": None, "count": len(year_buckets[y]), "cover": cover(year_buckets[y])}
        for y in sorted(year_buckets, reverse=True)
    ]
    months = [
        {"year": y, "month": m, "count": len(month_buckets[(y, m)]), "cover": cover(month_buckets[(y, m)])}
        for (y, m) in sorted(month_buckets, reverse=True)
    ]
    return {"years": years, "months": months}


@app.get("/")
def root():
    return {"photos": len(store.photos), "people": len(store.people)}
