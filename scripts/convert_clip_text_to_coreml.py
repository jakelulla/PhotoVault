"""Convert CLIP ViT-B/32 text encoder from PyTorch to CoreML mlpackage.

Run:
    KMP_DUPLICATE_LIB_OK=TRUE python3.12 scripts/convert_clip_text_to_coreml.py

Output: scripts/coreml_models/CLIPText.mlpackage (~60MB float16)
"""

from pathlib import Path
import torch
import open_clip
import coremltools as ct

OUT = Path(__file__).parent / "coreml_models"
OUT.mkdir(exist_ok=True)
DST = OUT / "CLIPText.mlpackage"

if DST.exists():
    print(f"{DST} already exists, skipping")
    raise SystemExit(0)

print("Loading CLIP ViT-B/32 openai weights...")
model, _, _ = open_clip.create_model_and_transforms("ViT-B-32", pretrained="openai")
model = model.eval().float()

class TextEncoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.token_embedding = m.token_embedding
        self.positional_embedding = m.positional_embedding
        self.transformer = m.transformer
        self.ln_final = m.ln_final
        self.text_projection = m.text_projection
        self.register_buffer("attn_mask", m.attn_mask)

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        # tokens: (1, 77) int32
        x = self.token_embedding(tokens)
        x = x + self.positional_embedding
        x = self.transformer(x, attn_mask=self.attn_mask)
        x = self.ln_final(x)
        # take features at the EOT token (highest token id in sequence)
        eot = tokens.argmax(dim=-1)
        x = x[torch.arange(x.shape[0]), eot] @ self.text_projection
        return x / x.norm(dim=-1, keepdim=True)

encoder = TextEncoder(model).eval()

# Sanity check vs open_clip reference
tokenizer = open_clip.get_tokenizer("ViT-B-32")
toks = tokenizer(["a dog on the beach"])
with torch.no_grad():
    ours = encoder(toks)
    ref = model.encode_text(toks)
    ref = ref / ref.norm(dim=-1, keepdim=True)
sim = (ours * ref).sum().item()
print(f"Sanity: cosine(ours, open_clip reference) = {sim:.6f}")
assert sim > 0.999, "text encoder mismatch"

print("Exporting model (torch.export)...")
with torch.no_grad():
    exported = torch.export.export(encoder, (toks.to(torch.int32),)).run_decompositions({})

print("Converting to CoreML (float16, iOS 16+)...")
mlmodel = ct.convert(
    exported,
    inputs=[ct.TensorType(name="tokens", shape=(1, 77), dtype=int)],
    outputs=[ct.TensorType(name="text_features")],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)
mlmodel.save(str(DST))
size_mb = sum(f.stat().st_size for f in DST.rglob("*") if f.is_file()) / 1e6
print(f"Saved: {DST} ({size_mb:.0f} MB)")
