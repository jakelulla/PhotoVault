# unused/

Retired code and data, kept for reference. **Nothing in here is built,
imported, or run by the app.**

| Item | What it was |
|---|---|
| `backend/` | The original Python backend (CLIP + face search server). Fully replaced by on-device CoreML on 2026-06-11; its tuned thresholds and algorithms were ported into the app. `venv/`, `index/`, `uploads/` are untracked local data. |
| `algorithm_scripting/` | Early algorithm-exploration notebooks (VGGFace2, toy face-finder tests). |
| `lfw_*.swift`, `lfw_onnx.py`, `lfw_data/` | The LFW face-verification benchmark harness that validated the on-device pipeline at 98.6% and caught the CoreML image-flip bug. Rebuild any binary with `swiftc -O <name>.swift`. |
| `consistency_bench.swift` / `consistency_ref.py` | Swift↔Python embedding-parity check (healthy ≥ 0.97 cosine). Still the tool to reach for after any model regeneration — run it before trusting new .mlmodelc bundles. |
| `testbench.swift` | Scratch bench from the flip-bug hunt. |
| `go.sh` | Old "start backend + build + run" launcher; the backend half is retired (use `build.sh` / `run.sh`). |
| `test_images/`, `test_images_wiped_*/` | Upload artifacts and bulk test data from the backend era (the wiped set is ~4.9 GB, untracked). Safe to delete outright if disk space matters. |
| `removed-dead-code.md` | Small in-app functions deleted during cleanup, archived verbatim. |
