#!/usr/bin/env python3.12
"""Palettize CLIP CoreML models to 6-bit (kmeans) for smaller app payload.

Run:
    KMP_DUPLICATE_LIB_OK=TRUE python3.12 scripts/palettize_clip.py
"""

import os
import shutil
import subprocess

import coremltools as ct
from coremltools.optimize.coreml import (
    OpPalettizerConfig,
    OptimizationConfig,
    palettize_weights,
)

SRC_DIR = "/Users/jakelulla/Desktop/PhotoSearch/scripts/coreml_models"
OUT_DIR = os.path.join(SRC_DIR, "palettized")

MODELS = ["CLIPVisual.mlpackage", "CLIPText.mlpackage"]


def dir_size_mb(path: str) -> float:
    out = subprocess.run(["du", "-sk", path], capture_output=True, text=True)
    kb = int(out.stdout.split()[0])
    return kb / 1024.0


def load_model(path: str) -> ct.models.MLModel:
    try:
        return ct.models.MLModel(path)
    except Exception as exc:  # fall back to weights-only load
        print(f"  plain load failed ({exc}); retrying with skip_model_load=True")
        return ct.models.MLModel(path, skip_model_load=True)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    # weight_threshold=10000 skips small consts — in particular CLIPText's
    # 77x77 causal attention mask (contains -inf, which crashes kmeans).
    # All real weight matrices are >= 512x512 = 262144 elements.
    op_config = OpPalettizerConfig(nbits=6, mode="kmeans", weight_threshold=10000)
    config = OptimizationConfig(global_config=op_config)

    for name in MODELS:
        src = os.path.join(SRC_DIR, name)
        dst = os.path.join(OUT_DIR, name)
        print(f"== {name} ==")
        before = dir_size_mb(src)

        model = load_model(src)
        compressed = palettize_weights(model, config=config)

        if os.path.exists(dst):
            shutil.rmtree(dst)
        compressed.save(dst)

        after = dir_size_mb(dst)
        print(f"  before: {before:8.1f} MB  ->  after: {after:8.1f} MB "
              f"({after / before * 100:.1f}% of original)")

    print("done.")


if __name__ == "__main__":
    main()
