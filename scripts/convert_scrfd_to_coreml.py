"""Convert SCRFD face detector (det_10g.onnx) to CoreML using torch.jit.trace."""

from pathlib import Path
import torch
import onnx2torch
import coremltools as ct

BUFFALO = Path.home() / ".insightface/models/buffalo_l"
OUT = Path(__file__).parent / "coreml_models"
OUT.mkdir(exist_ok=True)
DST = OUT / "FaceDetector.mlpackage"

if DST.exists():
    print("FaceDetector.mlpackage already exists, skipping")
    raise SystemExit(0)

print("Loading SCRFD via onnx2torch...")
model = onnx2torch.convert(str(BUFFALO / "det_10g.onnx"))
model = model.eval()

# Use torch.jit.trace (not export) to avoid the dynamic-shape Gather issue
dummy = torch.zeros(1, 3, 640, 640)
print("Tracing SCRFD...")
with torch.no_grad():
    traced = torch.jit.trace(model, dummy)

print("Converting to CoreML...")
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 640, 640))],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)
mlmodel.save(str(DST))
size_mb = sum(f.stat().st_size for f in DST.rglob("*") if f.is_file()) / 1e6
print(f"Saved {DST} ({size_mb:.0f} MB)")
