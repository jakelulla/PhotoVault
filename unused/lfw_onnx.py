"""
LFW benchmark using original ONNX models via onnxruntime.
Mirrors Swift pipeline exactly to find the divergence point.
"""
import numpy as np
import onnxruntime as ort
from PIL import Image
import os, time

LFW_DIR    = os.path.expanduser("~/scikit_learn_data/lfw_home/lfw_funneled")
PAIRS_FILE = os.path.expanduser("~/scikit_learn_data/lfw_home/pairs.txt")
MODELS_DIR = os.path.expanduser("~/.insightface/models/buffalo_l")

DET_MODEL  = os.path.join(MODELS_DIR, "det_10g.onnx")
EMB_MODEL  = os.path.join(MODELS_DIR, "w600k_r50.onnx")

# ── ArcFace standard 5-point alignment targets ───────────────────────────────
ARC_DST = np.array([
    [38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
    [41.5493, 92.3655], [70.7299, 92.2041]], dtype=np.float32)

# ── ONNX sessions ─────────────────────────────────────────────────────────────
print("Loading models...")
det_sess = ort.InferenceSession(DET_MODEL,  providers=["CPUExecutionProvider"])
emb_sess = ort.InferenceSession(EMB_MODEL, providers=["CPUExecutionProvider"])
print("  det input:", [(i.name, i.shape) for i in det_sess.get_inputs()])
print("  det outputs:", [o.name for o in det_sess.get_outputs()])
print("  emb input:", [(i.name, i.shape) for i in emb_sess.get_inputs()])
print("  emb outputs:", [o.name for o in emb_sess.get_outputs()])
print()

# ── Preprocessing ─────────────────────────────────────────────────────────────

def preprocess_detect(img_rgb: np.ndarray, pad=640):
    H, W = img_rgb.shape[:2]
    scale = min(pad/W, pad/H)
    nW, nH = int(round(W*scale)), int(round(H*scale))
    from PIL import Image as PILImage
    resized = np.array(PILImage.fromarray(img_rgb).resize((nW, nH), PILImage.BILINEAR))
    padded = np.zeros((pad, pad, 3), dtype=np.uint8)
    padded[:nH, :nW] = resized
    x = (padded.astype(np.float32) - 127.5) / 128.0
    return x.transpose(2,0,1)[None], scale  # NCHW

def decode_scrfd(outputs, scale, img_w, img_h, thresh=0.3, nms_thresh=0.4):
    """Decode SCRFD-10GF outputs. Returns list of (score, bbox, kps)."""
    # SCRFD-10GF has 9 outputs: 3 score, 3 bbox, 3 kps at strides 8,16,32
    # Output names depend on the model; we group by shape
    PAD = 640
    strides = [8, 16, 32]
    
    # Map outputs by size
    by_size = {}
    for name, arr in zip([o.name for o in det_sess.get_outputs()], outputs):
        by_size.setdefault(arr.shape[-1], []).append((name, arr))
    
    # Sort each group by total elements descending
    for k in by_size:
        by_size[k].sort(key=lambda x: x[1].size, reverse=True)
    
    # Get score/bbox/kps groups
    # Scores: 2D [npos,1]; bbox: [npos,4]; kps: [npos,10]
    score_arrs = [arr for _, arr in by_size.get(1, []) if arr.ndim==2]
    bbox_arrs  = [arr for _, arr in by_size.get(4, []) if arr.ndim==2]
    kps_arrs   = [arr for _, arr in by_size.get(10,[]) if arr.ndim==2]
    
    # Try flat shape too (some ONNX models reshape differently)
    if not score_arrs:
        # Maybe all outputs are 3D: [1, npos, k]
        score_arrs, bbox_arrs, kps_arrs = [], [], []
        for name, arr in zip([o.name for o in det_sess.get_outputs()], outputs):
            arr = arr.squeeze(0) if arr.ndim==3 else arr
            if arr.shape[-1]==1:  score_arrs.append(arr)
            elif arr.shape[-1]==4: bbox_arrs.append(arr)
            elif arr.shape[-1]==10: kps_arrs.append(arr)
        score_arrs.sort(key=lambda x:x.size, reverse=True)
        bbox_arrs.sort(key=lambda x:x.size, reverse=True)
        kps_arrs.sort(key=lambda x:x.size, reverse=True)
    
    if len(score_arrs)<3 or len(bbox_arrs)<3 or len(kps_arrs)<3:
        print(f"  WARNING: unexpected SCRFD output structure. scores:{len(score_arrs)} bbox:{len(bbox_arrs)} kps:{len(kps_arrs)}")
        return []
    
    all_scores, all_boxes, all_kps = [], [], []
    for s_idx, stride in enumerate(strides):
        fH = PAD//stride; fW = PAD//stride; nPos = fH*fW*2
        scores = score_arrs[s_idx].flatten()
        boxes  = bbox_arrs[s_idx]
        kps    = kps_arrs[s_idx]
        ai = 0
        for y in range(fH):
            for x in range(fW):
                cx, cy = float(x*stride), float(y*stride)
                for _ in range(2):
                    sc = float(scores[ai]) if ai < len(scores) else 0
                    if sc >= thresh:
                        b = boxes[ai]
                        box = [cx-b[0]*stride, cy-b[1]*stride, cx+b[2]*stride, cy+b[3]*stride]
                        k = kps[ai]
                        kp = [[cx+k[i*2]*stride, cy+k[i*2+1]*stride] for i in range(5)]
                        all_scores.append(sc)
                        all_boxes.append(box)
                        all_kps.append(kp)
                    ai += 1
    
    if not all_scores:
        return []
    
    # NMS
    scores_arr = np.array(all_scores)
    order = np.argsort(scores_arr)[::-1]
    suppressed = np.zeros(len(all_scores), bool)
    keep = []
    for i in range(len(order)):
        ii = order[i]
        if suppressed[ii]: continue
        keep.append(ii)
        for j in range(i+1, len(order)):
            jj = order[j]
            if suppressed[jj]: continue
            a, b = all_boxes[ii], all_boxes[jj]
            inter = max(0,min(a[2],b[2])-max(a[0],b[0])) * max(0,min(a[3],b[3])-max(a[1],b[1]))
            union = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter + 1e-7
            if inter/union > nms_thresh:
                suppressed[jj] = True
    
    inv = 1.0/scale
    results = []
    for i in keep:
        sc = all_scores[i]
        b  = all_boxes[i]
        kp = all_kps[i]
        box = [np.clip(v*inv, 0, img_w-1 if j%2==0 else img_h-1) for j,v in enumerate(b)]
        lm  = [[np.clip(kp[k][0]*inv,0,img_w-1), np.clip(kp[k][1]*inv,0,img_h-1)] for k in range(5)]
        results.append((sc, box, lm))
    return results

# ── Similarity transform (same math as Swift) ─────────────────────────────────

def similarity_transform(src: np.ndarray, dst: np.ndarray) -> np.ndarray:
    """Least-squares similarity transform from src→dst. Returns 2×3 affine matrix."""
    n = len(src)
    sXX = np.sum(src[:,0]**2 + src[:,1]**2)
    sX, sY = np.sum(src[:,0]), np.sum(src[:,1])
    sUX = np.sum(dst[:,0]*src[:,0] + dst[:,1]*src[:,1])
    sVX = np.sum(dst[:,0]*src[:,1] - dst[:,1]*src[:,0])
    sU, sV = np.sum(dst[:,0]), np.sum(dst[:,1])
    D = sXX*n - (sX**2+sY**2)
    if abs(D) < 1e-10:
        return np.array([[1,0,0],[0,1,0]], dtype=np.float32)
    a = (sUX*n - sX*sU - sY*sV) / D
    b = (-sVX*n + sY*sU - sX*sV) / D
    c = (sU - a*sX + b*sY) / n
    d = (sV - b*sX - a*sY) / n
    return np.array([[a,-b,c],[b,a,d]], dtype=np.float32)

def align_face(img_rgb: np.ndarray, landmarks: list, out_size=112) -> np.ndarray:
    """Align face to ARC_DST template using inverse mapping."""
    from PIL import Image as PILImage
    import cv2
    src = np.array(landmarks, dtype=np.float32)
    M = similarity_transform(src, ARC_DST)   # 2×3 forward transform
    # warpAffine with M = forward transform (opencv handles inverse internally)
    aligned = cv2.warpAffine(img_rgb, M, (out_size, out_size), flags=cv2.INTER_LINEAR)
    return aligned

def embed_face(aligned_rgb: np.ndarray) -> np.ndarray:
    """ArcFace embedding: normalize, NCHW, run, L2 normalize."""
    x = (aligned_rgb.astype(np.float32) - 127.5) / 127.5
    x = x.transpose(2,0,1)[None]  # NCHW
    out = emb_sess.run(None, {emb_sess.get_inputs()[0].name: x})[0]
    emb = out.flatten()
    return emb / (np.linalg.norm(emb) + 1e-10)

def embed_crop(img_rgb: np.ndarray) -> np.ndarray:
    """Center crop 200×200 from 250×250, resize to 112×112, embed."""
    H, W = img_rgb.shape[:2]
    ox, oy = (W-200)//2, (H-200)//2
    crop = img_rgb[oy:oy+200, ox:ox+200]
    from PIL import Image as PILImage
    resized = np.array(PILImage.fromarray(crop).resize((112,112), PILImage.BILINEAR))
    return embed_face(resized)

def process_image(path):
    try:
        img = np.array(Image.open(path).convert("RGB"))
        inp, scale = preprocess_detect(img)
        outputs = det_sess.run(None, {det_sess.get_inputs()[0].name: inp})
        faces = decode_scrfd(outputs, scale, img.shape[1], img.shape[0])
        if faces:
            best = max(faces, key=lambda f: f[0])
            aligned = align_face(img, best[2])
            return embed_face(aligned), "det", best[0], best[2]
        return embed_crop(img), "crop", 0.0, None
    except Exception as e:
        return None, f"error:{e}", 0.0, None

# ── Pairs ─────────────────────────────────────────────────────────────────────

def img_path(name, num):
    return os.path.join(LFW_DIR, name, f"{name}_{num:04d}.jpg")

def read_pairs():
    with open(PAIRS_FILE) as f:
        lines = f.read().strip().split("\n")
    h = list(map(int, lines[0].split("\t")))
    per_fold = h[1]
    pairs = []
    for line in lines[1:1+per_fold*h[0]]:
        c = line.split("\t")
        if len(c)==3:
            pairs.append((img_path(c[0],int(c[1])), img_path(c[0],int(c[2])), True))
    for line in lines[1+per_fold*h[0]:]:
        c = line.split("\t")
        if len(c)==4:
            pairs.append((img_path(c[0],int(c[1])), img_path(c[2],int(c[3])), False))
    return pairs

# ── Main ──────────────────────────────────────────────────────────────────────

pairs = read_pairs()
print(f"Pairs: {len(pairs)} ({sum(p[2] for p in pairs)} same, {sum(not p[2] for p in pairs)} diff)\n")

embeddings = {}
imgs = list(set(p for pair in pairs for p in pair[:2]))
n_det = n_crop = n_fail = 0
t0 = time.time()

for i, path in enumerate(imgs):
    emb, method, score, lms = process_image(path)
    if emb is not None:
        embeddings[path] = emb
        if method == "det": n_det += 1
        else: n_crop += 1
    else:
        n_fail += 1
    
    if (i+1) % 500 == 0:
        dt = time.time()-t0
        print(f"  [{i+1:4d}/{len(imgs)}]  det:{n_det}  crop:{n_crop}  fail:{n_fail}  {(i+1)/dt:.1f} img/s")
        # Print sample landmarks for last detected image
        if lms and i < 10:
            print(f"    sample landmarks: {[[f'{v:.1f}' for v in lm] for lm in lms]}")

print(f"\n  Done: det={n_det} crop={n_crop} fail={n_fail} in {time.time()-t0:.1f}s\n")

covered = [(p1,p2,same) for p1,p2,same in pairs if p1 in embeddings and p2 in embeddings]
print(f"  {len(covered)}/{len(pairs)} pairs covered\n")

# Show some sample similarities
same_sims = [np.dot(embeddings[p1],embeddings[p2]) for p1,p2,same in covered[:100] if same]
diff_sims = [np.dot(embeddings[p1],embeddings[p2]) for p1,p2,same in covered[1500:1600] if not same]
print(f"Sample sims (first 100 same pairs): mean={np.mean(same_sims):.4f} std={np.std(same_sims):.4f} min={np.min(same_sims):.4f} max={np.max(same_sims):.4f}")
if diff_sims:
    print(f"Sample sims (diff pairs 1500-1600): mean={np.mean(diff_sims):.4f} std={np.std(diff_sims):.4f}")

# 10-fold CV
fold_size = len(covered)//10
accs = []
for fold in range(10):
    test  = covered[fold*fold_size:(fold+1)*fold_size]
    train = [p for p in covered if p not in test]
    
    best_t, best_acc = 0.5, 0.0
    for t in np.arange(-0.5, 1.01, 0.01):
        correct = sum((np.dot(embeddings[p1],embeddings[p2])>t)==same for p1,p2,same in train)
        acc = correct/len(train)
        if acc > best_acc: best_acc, best_t = acc, t
    
    tc = sum((np.dot(embeddings[p1],embeddings[p2])>best_t)==same for p1,p2,same in test)
    accs.append(tc/len(test))
    print(f"  Fold {fold+1:2d}: thresh={best_t:.2f}  test={accs[-1]*100:.2f}%")

print("="*50)
print(f"LFW Accuracy (ONNX): {np.mean(accs)*100:.2f}% ± {np.std(accs)*100:.2f}%")
print("="*50)
