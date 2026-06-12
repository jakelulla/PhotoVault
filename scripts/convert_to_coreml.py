"""Convert ONNX models to CoreML .mlpackage format for iOS deployment.

Usage:
    python scripts/convert_to_coreml.py

Outputs in scripts/coreml_models/:
    CLIPVisual.mlpackage   - CLIP ViT-B/32 image encoder (input: image [1,3,224,224])
    FaceDetector.mlpackage - SCRFD face detector (input: [1,3,640,640])
    FaceEmbedder.mlpackage - ArcFace face recognizer (input: [1,3,112,112])
"""

from pathlib import Path

import coremltools as ct

HERE = Path(__file__).resolve().parent
OUT = HERE / "coreml_models"
OUT.mkdir(exist_ok=True)

CLIP_VISUAL = HERE.parent.parent / "CoreML/build/clip_visual.onnx"
SCRFD = Path.home() / ".insightface/models/buffalo_l/det_10g.onnx"
ARCFACE = Path.home() / ".insightface/models/buffalo_l/w600k_r50.onnx"


def convert_clip_visual():
    dst = OUT / "CLIPVisual.mlpackage"
    if dst.exists():
        print("CLIPVisual.mlpackage already exists, skipping")
        return
    print("Converting CLIP visual encoder (~1-2 min)...")
    m = ct.convert(
        str(CLIP_VISUAL),
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="image", shape=(1, 3, 224, 224))],
        outputs=[ct.TensorType(name="image_features")],
        convert_to="mlprogram",
    )
    m.save(str(dst))
    print(f"  -> {dst}")


def convert_scrfd():
    dst = OUT / "FaceDetector.mlpackage"
    if dst.exists():
        print("FaceDetector.mlpackage already exists, skipping")
        return
    print("Converting SCRFD face detector (~30s)...")
    m = ct.convert(
        str(SCRFD),
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="input.1", shape=(1, 3, 640, 640))],
        convert_to="mlprogram",
    )
    m.save(str(dst))
    print(f"  -> {dst}")


def convert_arcface():
    dst = OUT / "FaceEmbedder.mlpackage"
    if dst.exists():
        print("FaceEmbedder.mlpackage already exists, skipping")
        return
    print("Converting ArcFace recognizer (~1 min)...")
    m = ct.convert(
        str(ARCFACE),
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="input.1", shape=(1, 3, 112, 112))],
        outputs=[ct.TensorType(name="683")],
        convert_to="mlprogram",
    )
    m.save(str(dst))
    print(f"  -> {dst}")


if __name__ == "__main__":
    print(f"Output: {OUT}\n")
    convert_clip_visual()
    convert_scrfd()
    convert_arcface()
    print("\nAll done. Add the .mlpackage bundles to the Xcode project (drag into the project navigator).")
