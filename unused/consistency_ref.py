"""Reference embeddings from the ORIGINAL Python pipeline:
- Face: insightface ONNX (det_10g SCRFD + w600k_r50 ArcFace), as the backend used
- CLIP: open_clip ViT-B/32 openai, full reference preprocessing

Writes /tmp/python_embeddings.json {image: {face: [512], clip: [512]}}
Then compares against /tmp/swift_embeddings.json if present.

Run (two stages — onnxruntime and torch crash when sharing a process):
    KMP_DUPLICATE_LIB_OK=TRUE python3   consistency_ref.py face
    KMP_DUPLICATE_LIB_OK=TRUE python3.12 consistency_ref.py clip
"""
import json
import os
import sys

import numpy as np
from PIL import Image

STAGE = sys.argv[1] if len(sys.argv) > 1 else "face"
if STAGE == "face":
    import onnxruntime as ort

LFW = os.path.expanduser("~/scikit_learn_data/lfw_home/lfw_funneled")
MODELS = os.path.expanduser("~/.insightface/models/buffalo_l")

TEST_IMAGES = [
    f"{LFW}/Angela_Bassett/Angela_Bassett_0001.jpg",
    f"{LFW}/Abel_Pacheco/Abel_Pacheco_0001.jpg",
    f"{LFW}/George_W_Bush/George_W_Bush_0001.jpg",
]

ARC_DST = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
                    [41.5493, 92.3655], [70.7299, 92.2041]], dtype=np.float32)

if STAGE == "face":
    det_sess = ort.InferenceSession(f"{MODELS}/det_10g.onnx", providers=["CPUExecutionProvider"])
    emb_sess = ort.InferenceSession(f"{MODELS}/w600k_r50.onnx", providers=["CPUExecutionProvider"])


# ── SCRFD ────────────────────────────────────────────────────────────────────

def detect(img_rgb, thresh=0.5):
    PAD = 640
    H, W = img_rgb.shape[:2]
    scale = min(PAD / W, PAD / H)
    nW, nH = int(round(W * scale)), int(round(H * scale))
    resized = np.array(Image.fromarray(img_rgb).resize((nW, nH), Image.BILINEAR))
    padded = np.zeros((PAD, PAD, 3), dtype=np.uint8)
    padded[:nH, :nW] = resized
    x = ((padded.astype(np.float32) - 127.5) / 128.0).transpose(2, 0, 1)[None]

    outputs = det_sess.run(None, {det_sess.get_inputs()[0].name: x})
    by_col = {}
    for arr in outputs:
        by_col.setdefault(arr.shape[-1], []).append(arr)
    for k in by_col:
        by_col[k].sort(key=lambda a: a.size, reverse=True)

    strides = [8, 16, 32]
    allS, allB, allK = [], [], []
    for s, stride in enumerate(strides):
        fH = fW = PAD // stride
        sp = by_col[1][s].flatten()
        bp = by_col[4][s]
        kp = by_col[10][s]
        ai = 0
        for y in range(fH):
            for x_ in range(fW):
                cx, cy = float(x_ * stride), float(y * stride)
                for _ in range(2):
                    if sp[ai] >= thresh:
                        b = bp[ai]
                        allB.append([cx - b[0]*stride, cy - b[1]*stride,
                                     cx + b[2]*stride, cy + b[3]*stride])
                        allS.append(float(sp[ai]))
                        k = kp[ai]
                        allK.append([[cx + k[i*2]*stride, cy + k[i*2+1]*stride] for i in range(5)])
                    ai += 1
    if not allS:
        return []

    order = np.argsort(allS)[::-1]
    supp = np.zeros(len(allS), bool)
    keep = []
    for i in range(len(order)):
        ii = order[i]
        if supp[ii]:
            continue
        keep.append(ii)
        for j in range(i + 1, len(order)):
            jj = order[j]
            if supp[jj]:
                continue
            a, b = allB[ii], allB[jj]
            inter = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
            union = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter + 1e-7
            if inter / union > 0.4:
                supp[jj] = True

    inv = 1.0 / scale
    return [
        (allS[i], [[np.clip(allK[i][k][0]*inv, 0, W-1), np.clip(allK[i][k][1]*inv, 0, H-1)]
                   for k in range(5)])
        for i in keep
    ]


# ── Alignment + ArcFace ──────────────────────────────────────────────────────

def similarity_transform(src, dst):
    src = np.asarray(src, dtype=np.float64)
    n = len(src)
    sXX = np.sum(src[:, 0]**2 + src[:, 1]**2)
    sX, sY = src[:, 0].sum(), src[:, 1].sum()
    sUX = np.sum(dst[:, 0]*src[:, 0] + dst[:, 1]*src[:, 1])
    sVX = np.sum(dst[:, 0]*src[:, 1] - dst[:, 1]*src[:, 0])
    sU, sV = dst[:, 0].sum(), dst[:, 1].sum()
    D = sXX*n - (sX**2 + sY**2)
    a = (sUX*n - sX*sU - sY*sV) / D
    b = (-sVX*n + sY*sU - sX*sV) / D
    c = (sU - a*sX + b*sY) / n
    d = (sV - b*sX - a*sY) / n
    return np.array([[a, -b, c], [b, a, d]], dtype=np.float64)


def align_nearest(img_rgb, landmarks, S=112):
    """Inverse-map with nearest-neighbor sampling — matches the Swift code."""
    M = similarity_transform(landmarks, ARC_DST)
    A = np.vstack([M, [0, 0, 1]])
    Ainv = np.linalg.inv(A)
    H, W = img_rgb.shape[:2]
    out = np.zeros((S, S, 3), dtype=np.uint8)
    for oy in range(S):
        for ox in range(S):
            sx, sy, _ = Ainv @ np.array([ox, oy, 1.0])
            sxi, syi = int(round(sx)), int(round(sy))
            if 0 <= sxi < W and 0 <= syi < H:
                out[oy, ox] = img_rgb[syi, sxi]
    return out


def face_embed(aligned_rgb):
    x = ((aligned_rgb.astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None]
    e = emb_sess.run(None, {emb_sess.get_inputs()[0].name: x})[0].flatten()
    return (e / (np.linalg.norm(e) + 1e-10)).tolist()


# ── CLIP ─────────────────────────────────────────────────────────────────────

if STAGE == "clip":
    import open_clip
    import torch
    clip_model, _, clip_preprocess = open_clip.create_model_and_transforms("ViT-B-32", pretrained="openai")
    clip_model = clip_model.eval().float()


def clip_embed(pil_img):
    with torch.no_grad():
        x = clip_preprocess(pil_img).unsqueeze(0)
        f = clip_model.encode_image(x)
        f = f / f.norm(dim=-1, keepdim=True)
    return f[0].tolist()


# ── Main ─────────────────────────────────────────────────────────────────────

OUT = "/tmp/python_embeddings.json"
results = json.load(open(OUT)) if os.path.exists(OUT) else {}
for path in TEST_IMAGES:
    name = os.path.basename(path)
    pil = Image.open(path).convert("RGB")
    img = np.array(pil)
    entry = results.get(name, {})

    if STAGE == "face":
        faces = detect(img)
        if faces:
            score, lm = max(faces, key=lambda f: f[0])
            lm_str = " ".join(f"({p[0]:.1f},{p[1]:.1f})" for p in lm)
            print(f"{name}")
            print(f"  det score={score:.4f}  landmarks={lm_str}")
            aligned = align_nearest(img, lm)
            fe = face_embed(aligned)
            entry["face"] = fe
            print("  face[0..8]: [" + ", ".join(f"{v:+.4f}" for v in fe[:8]) + "]")
        else:
            print(f"{name}: no face detected")
    else:
        ce = clip_embed(pil)
        entry["clip"] = ce
        print(f"{name}")
        print("  clip[0..8]: [" + ", ".join(f"{v:+.4f}" for v in ce[:8]) + "]")
    print()
    results[name] = entry

json.dump(results, open(OUT, "w"))
print("Wrote /tmp/python_embeddings.json")

# ── Compare if the Swift run exists ──────────────────────────────────────────

swift_path = "/tmp/swift_embeddings.json"
if os.path.exists(swift_path):
    swift = json.load(open(swift_path))
    print()
    print("=" * 66)
    print("CONSISTENCY: cosine(Swift CoreML optimized, Python reference)")
    print("=" * 66)
    for name, entry in results.items():
        s = swift.get(name, {})
        for kind in ("face", "clip"):
            if kind in entry and kind in s:
                a, b = np.array(entry[kind]), np.array(s[kind])
                print(f"  {name:32s} {kind}: {float(a @ b):.5f}")
            else:
                print(f"  {name:32s} {kind}: MISSING ({'py' if kind not in entry else 'swift'})")
