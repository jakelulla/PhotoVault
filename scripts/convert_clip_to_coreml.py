"""Convert CLIP ViT-B/32 image encoder from PyTorch to CoreML mlpackage.

Run:
    KMP_DUPLICATE_LIB_OK=TRUE python scripts/convert_clip_to_coreml.py

Output: scripts/coreml_models/CLIPVisual.mlpackage (~170MB float16)
"""

from pathlib import Path
import torch
import open_clip
import coremltools as ct

OUT = Path(__file__).parent / "coreml_models"
OUT.mkdir(exist_ok=True)
DST = OUT / "CLIPVisual.mlpackage"

if DST.exists():
    print(f"{DST} already exists, skipping")
    raise SystemExit(0)

print("Loading CLIP ViT-B/32 openai weights...")
model, _, _ = open_clip.create_model_and_transforms("ViT-B-32", pretrained="openai")
model = model.eval().float()

class VisualEncoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.visual = m.visual

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        features = self.visual(x)
        # L2 normalize to unit sphere (same as open_clip encode_image)
        return features / features.norm(dim=-1, keepdim=True)

encoder = VisualEncoder(model).eval()

print("Exporting model (torch.export)...")
dummy = torch.zeros(1, 3, 224, 224)
# torch.export decomposes fused kernels (_native_multi_head_attention) into
# primitive ops that coremltools can convert, unlike torch.jit.trace.
with torch.no_grad():
    exported = torch.export.export(encoder, (dummy,)).run_decompositions({})

print("Converting to CoreML (float16, iOS 16+)...")
mlmodel = ct.convert(
    exported,
    inputs=[ct.TensorType(name="image", shape=(1, 3, 224, 224))],
    outputs=[ct.TensorType(name="image_features")],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)

mlmodel.short_description = "CLIP ViT-B/32 image encoder, L2-normalized 512-dim output"
mlmodel.save(str(DST))
print(f"Saved: {DST}")
import os
size_mb = sum(f.stat().st_size for f in DST.rglob("*") if f.is_file()) / 1e6
print(f"Size: {size_mb:.0f} MB")
