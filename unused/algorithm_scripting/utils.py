"""Face detection, embedding, clustering, and visualization helpers.

Built on InsightFace's `buffalo_l` model, which detects faces and produces a
512-d L2-normalized recognition embedding per face. Cosine similarity between
two embeddings approximates whether they belong to the same person.

End-to-end pipeline (picture-centric storage):

    face_index        = extract_face_index(image_paths)     # {path: (k, 512)}
    embeddings, paths = flatten_face_index(face_index)      # flat form for clustering
    cluster_ids       = cluster_faces(embeddings, eps=0.45, min_samples=3)
    prototypes, keys  = build_prototypes(embeddings, cluster_ids)
    album             = photos_by_person(embeddings, paths, prototypes)

Queries on a built index:

    album[person_id]                                  # all photos containing a person
    assign_to_prototype(new_emb, prototypes)          # which person is this face?
"""

from typing import Iterable, Sequence

import cv2
import matplotlib.pyplot as plt
import numpy as np
import onnxruntime as ort
from insightface.app import FaceAnalysis
from sklearn.cluster import DBSCAN
from tqdm import tqdm


# ---------------------------------------------------------------------------
# Model setup
# ---------------------------------------------------------------------------

# Prefer CUDA when the onnxruntime-gpu build is installed and a CUDA device is
# visible; otherwise fall back to CPU. ctx_id=0 selects the first GPU, -1 CPU.
_available_providers = ort.get_available_providers()
_use_gpu = "CUDAExecutionProvider" in _available_providers
_providers = ["CUDAExecutionProvider", "CPUExecutionProvider"] if _use_gpu else ["CPUExecutionProvider"]
_ctx_id = 0 if _use_gpu else -1

# One shared FaceAnalysis instance. Notebooks can re-call `app.prepare(...)`
# with a different `det_size` if they need higher detection resolution.
app = FaceAnalysis(name="buffalo_l", providers=_providers)
app.prepare(ctx_id=_ctx_id, det_size=(640, 640))
print(f"insightface running on {'GPU (CUDA)' if _use_gpu else 'CPU'}")


# ---------------------------------------------------------------------------
# Image I/O and face detection
# ---------------------------------------------------------------------------

def load_image(path) -> np.ndarray | None:
    """Read an image from disk as a BGR numpy array, or None if unreadable."""
    return cv2.imread(str(path))


def get_faces(img: np.ndarray) -> list:
    """Detect faces in a BGR image and return InsightFace `Face` objects."""
    return app.get(img)


def get_embeddings(faces: Iterable) -> list[np.ndarray]:
    """Return the L2-normalized 512-d recognition embedding for each face."""
    return [face.normed_embedding for face in faces]


def main_face(faces: Sequence):
    """Pick the largest face by bbox area — usually the subject of the photo."""
    return max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))


# ---------------------------------------------------------------------------
# Batch extraction
# ---------------------------------------------------------------------------

def extract_embeddings(
    image_paths: Iterable,
    multi_face: bool = False,
    return_meta: bool = False,
    progress: bool = True,
) -> tuple:
    """Run detection + embedding on a list of image paths.

    `multi_face=False` keeps only the largest face per image (the photo's
    presumed subject). `multi_face=True` keeps every detected face — required
    for group photos and "click any face in a photo" queries.

    Returns parallel arrays:
        embeddings   : (M, 512) float32, L2-normalized
        source_paths : list of length M; source_paths[i] is the source image
                       for embeddings[i]. With multi_face the same path can
                       appear multiple times (once per detected face).
        face_meta    : (M, 3) float32, columns [det_score, bbox_min_side, |yaw|].
                       Returned only if `return_meta=True`. Useful for quality
                       filtering: a typical rule is det_score >= 0.65 AND
                       bbox_min_side >= 80 AND |yaw| <= 40 degrees.

    Images that fail to load or contain no faces are silently skipped.
    """
    paths = list(image_paths)
    iterator = tqdm(paths) if progress else paths

    embs: list[np.ndarray] = []
    src: list = []
    meta: list[tuple[float, float, float]] = []

    for path in iterator:
        img = load_image(path)
        if img is None:
            continue
        faces = get_faces(img)
        if not faces:
            continue

        chosen = faces if multi_face else [main_face(faces)]
        for f in chosen:
            embs.append(f.normed_embedding)
            src.append(path)
            if return_meta:
                x1, y1, x2, y2 = f.bbox
                pose = getattr(f, "pose", None)
                abs_yaw = float(abs(pose[1])) if pose is not None else 0.0
                meta.append((float(f.det_score), float(min(x2 - x1, y2 - y1)), abs_yaw))

    embeddings = np.stack(embs) if embs else np.empty((0, 512), dtype=np.float32)
    if return_meta:
        return embeddings, src, np.array(meta, dtype=np.float32)
    return embeddings, src


# ---------------------------------------------------------------------------
# Picture-centric storage
# ---------------------------------------------------------------------------

def extract_face_index(
    image_paths: Iterable,
    return_meta: bool = False,
    progress: bool = True,
) -> dict:
    """Run detection + embedding, return a picture-centric mapping.

    Each detectable image maps to its (k, 512) array of L2-normalized face
    embeddings — one row per face detected in that photo. Images that fail
    to load or contain no faces are absent from the result.

    If `return_meta=True`, returns a second dict mapping each path to a
    (k, 3) float32 array with columns [det_score, bbox_min_side, |yaw|].

    Use `flatten_face_index` to convert to the flat (embeddings, source_paths)
    form required by `cluster_faces`.
    """
    paths = list(image_paths)
    iterator = tqdm(paths) if progress else paths

    face_index: dict = {}
    meta_index: dict = {}

    for path in iterator:
        img = load_image(path)
        if img is None:
            continue
        faces = get_faces(img)
        if not faces:
            continue

        face_index[path] = np.stack([f.normed_embedding for f in faces])
        if return_meta:
            rows = []
            for f in faces:
                x1, y1, x2, y2 = f.bbox
                pose = getattr(f, "pose", None)
                abs_yaw = float(abs(pose[1])) if pose is not None else 0.0
                rows.append((float(f.det_score), float(min(x2 - x1, y2 - y1)), abs_yaw))
            meta_index[path] = np.array(rows, dtype=np.float32)

    if return_meta:
        return face_index, meta_index
    return face_index


def flatten_face_index(face_index: dict) -> tuple[np.ndarray, list]:
    """Flatten {path: (k, 512)} into (embeddings (M, 512), source_paths length M).

    DBSCAN clustering and prototype-matching helpers operate on the flat form;
    this is the inverse of building a picture-centric index. The output path
    list repeats each photo path once per face detected in it.
    """
    if not face_index:
        return np.empty((0, 512), dtype=np.float32), []
    arrays: list[np.ndarray] = []
    paths_repeated: list = []
    for path, embs in face_index.items():
        arrays.append(embs)
        paths_repeated.extend([path] * len(embs))
    return np.concatenate(arrays), paths_repeated


# ---------------------------------------------------------------------------
# Similarity and pairwise matching
# ---------------------------------------------------------------------------

def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Cosine similarity between two embedding vectors (any norm)."""
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def is_match(score: float, threshold: float = 0.5) -> bool:
    """True if a similarity score meets or exceeds the threshold.

    A fixed threshold gives base-rate-dependent precision. For a real photo
    library prefer `assign_to_prototype` after clustering.
    """
    return score >= threshold


# ---------------------------------------------------------------------------
# Clustering and prototypes
# ---------------------------------------------------------------------------

def cluster_faces(
    embeddings: np.ndarray,
    eps: float = 0.45,
    min_samples: int = 3,
) -> np.ndarray:
    """Group face embeddings into identity clusters via cosine-distance DBSCAN.

    Returns an integer label per embedding; -1 marks noise (unclustered).
    `min_samples > 1` requires a face to be close to several others before it
    joins a cluster — the consensus check that kills false positives.
    """
    db = DBSCAN(eps=eps, min_samples=min_samples, metric="cosine", n_jobs=-1)
    return db.fit_predict(embeddings)


def build_prototypes(
    embeddings: np.ndarray,
    cluster_ids: np.ndarray,
) -> tuple[np.ndarray, list[int]]:
    """Build one L2-normalized centroid embedding per non-noise cluster.

    Returns (prototypes, cluster_keys) where prototypes[i] corresponds to
    cluster_keys[i]. Averaging multiple shots of the same person cancels
    per-image noise, so matching against prototypes is more precise than
    matching against any single embedding.
    """
    keys = sorted(c for c in set(cluster_ids.tolist()) if c != -1)
    protos = np.stack([embeddings[cluster_ids == c].mean(0) for c in keys])
    protos /= np.linalg.norm(protos, axis=1, keepdims=True)
    return protos, keys


def assign_to_prototype(
    embedding: np.ndarray,
    prototypes: np.ndarray,
    threshold: float = 0.30,
) -> tuple[int, float]:
    """Match an embedding to its nearest prototype.

    Returns (prototype_index, similarity). If similarity < threshold the
    returned index is -1 ("unknown person"), matching the DBSCAN noise label.
    """
    sims = prototypes @ embedding
    best = int(np.argmax(sims))
    score = float(sims[best])
    return (best if score >= threshold else -1), score


def photos_by_person(
    embeddings: np.ndarray,
    source_paths: Sequence,
    prototypes: np.ndarray,
    threshold: float = 0.30,
) -> dict[int, list]:
    """Build a person-id → photo-paths index by assigning each embedding to a prototype.

    Powers the "click a face, see all their photos" query:

        album = photos_by_person(...)
        album[person_id]   # → list of paths containing that person

    Each photo appears at most once per person even if multiple faces in it
    matched the same prototype. Faces that don't meet `threshold` are bucketed
    under key -1 ("unknown people" — Apple Photos' "Unnamed" section).
    """
    sims = embeddings @ prototypes.T
    nearest = sims.argmax(axis=1)
    scores = sims.max(axis=1)

    # Use sets while building to dedup, then convert to lists for ergonomics.
    buckets: dict[int, set] = {}
    for i, path in enumerate(source_paths):
        pid = int(nearest[i]) if scores[i] >= threshold else -1
        buckets.setdefault(pid, set()).add(path)
    return {pid: sorted(paths) for pid, paths in buckets.items()}


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------

def show_image(img: np.ndarray, title: str = "", figsize: tuple = (8, 8)) -> None:
    """Display a BGR image (as returned by `load_image`) with matplotlib."""
    plt.figure(figsize=figsize)
    plt.imshow(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    if title:
        plt.title(title)
    plt.axis("off")
    plt.show()


def show_faces(img: np.ndarray, faces: Sequence, title: str = "") -> None:
    """Plot a row of cropped face tiles labeled with index and detection score."""
    n = len(faces)
    fig, axes = plt.subplots(1, n, figsize=(3 * n, 3))
    if n == 1:
        axes = [axes]
    for ax, (i, face) in zip(axes, enumerate(faces)):
        x1, y1, x2, y2 = face.bbox.astype(int)
        crop = img[max(0, y1):y2, max(0, x1):x2]
        ax.imshow(cv2.cvtColor(crop, cv2.COLOR_BGR2RGB))
        ax.set_title(f"{i} score={face.det_score:.2f}")
        ax.axis("off")
    fig.suptitle(title)
    plt.show()


def show_with_boxes(img: np.ndarray, faces: Sequence, title: str = "") -> None:
    """Plot the full image with each detection drawn as a green bbox + index."""
    vis = img.copy()
    for i, f in enumerate(faces):
        x1, y1, x2, y2 = f.bbox.astype(int)
        cv2.rectangle(vis, (x1, y1), (x2, y2), (0, 255, 0), 2)
        cv2.putText(vis, str(i), (x1, max(0, y1 - 5)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
    plt.figure(figsize=(8, 8))
    plt.imshow(cv2.cvtColor(vis, cv2.COLOR_BGR2RGB))
    plt.title(f"{title}  ({len(faces)} faces, img={img.shape[:2]})")
    plt.axis("off")
    plt.show()
