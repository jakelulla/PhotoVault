"""Convert InsightFace ONNX models to CoreML .mlpackage.

Run:
    KMP_DUPLICATE_LIB_OK=TRUE python3.12 scripts/convert_insightface_to_coreml.py

Outputs in scripts/coreml_models/:
    FaceDetector.mlpackage  - SCRFD face detector
    FaceEmbedder.mlpackage  - ArcFace face recognizer
"""

from pathlib import Path
import torch
import onnx2torch
import coremltools as ct

BUFFALO = Path.home() / ".insightface/models/buffalo_l"
OUT = Path(__file__).parent / "coreml_models"
OUT.mkdir(exist_ok=True)


def convert_arcface():
    dst = OUT / "FaceEmbedder.mlpackage"
    if dst.exists():
        print("FaceEmbedder.mlpackage already exists, skipping")
        return

    print("Converting ArcFace (w600k_r50.onnx)...")
    model = onnx2torch.convert(str(BUFFALO / "w600k_r50.onnx"))
    model = model.eval()

    dummy = torch.zeros(1, 3, 112, 112)
    with torch.no_grad():
        exported = torch.export.export(model, (dummy,)).run_decompositions({})

    print("  Converting to CoreML...")
    mlmodel = ct.convert(
        exported,
        inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112))],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.save(str(dst))
    size_mb = sum(f.stat().st_size for f in dst.rglob("*") if f.is_file()) / 1e6
    print(f"  -> {dst} ({size_mb:.0f} MB)")


def convert_scrfd():
    dst = OUT / "FaceDetector.mlpackage"
    if dst.exists():
        print("FaceDetector.mlpackage already exists, skipping")
        return

    print("Converting SCRFD (det_10g.onnx)...")
    model = onnx2torch.convert(str(BUFFALO / "det_10g.onnx"))
    model = model.eval()

    dummy = torch.zeros(1, 3, 640, 640)
    with torch.no_grad():
        exported = torch.export.export(model, (dummy,)).run_decompositions({})

    print("  Converting to CoreML...")
    mlmodel = ct.convert(
        exported,
        inputs=[ct.TensorType(name="input", shape=(1, 3, 640, 640))],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.save(str(dst))
    size_mb = sum(f.stat().st_size for f in dst.rglob("*") if f.is_file()) / 1e6
    print(f"  -> {dst} ({size_mb:.0f} MB)")


if __name__ == "__main__":
    convert_arcface()
    convert_scrfd()
    print("\nDone.")
