"""Shared OpenCLIP loader — used by both the index builder (image embeddings)
and the server (text embeddings for caption search).

Mirrors the notebook: ViT-B/32, OpenAI weights, 512-d L2-normalized vectors,
so image and text embeddings live in the same cosine space.
"""

import numpy as np
import torch
import open_clip

MODEL_NAME = "ViT-B-32"
PRETRAINED = "openai"


def _pick_device() -> str:
    if torch.cuda.is_available():
        return "cuda"
    # MPS works for CLIP on Apple Silicon and is much faster than CPU.
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


class ClipEncoder:
    def __init__(self, want_image: bool = False):
        self.device = _pick_device()
        model, _, preprocess = open_clip.create_model_and_transforms(
            MODEL_NAME, pretrained=PRETRAINED
        )
        self.model = model.to(self.device).eval()
        self.tokenizer = open_clip.get_tokenizer(MODEL_NAME)
        self.preprocess = preprocess if want_image else None
        print(f"CLIP {MODEL_NAME}/{PRETRAINED} running on {self.device}")

    @torch.no_grad()
    def encode_text(self, text: str) -> np.ndarray:
        tokens = self.tokenizer([text]).to(self.device)
        emb = self.model.encode_text(tokens)
        emb = emb / emb.norm(dim=-1, keepdim=True)
        return emb.cpu().numpy().squeeze(0).astype(np.float32)

    @torch.no_grad()
    def encode_image(self, pil_img) -> np.ndarray:
        return self.encode_images([pil_img])[0]

    @torch.no_grad()
    def encode_images(self, pil_imgs: list) -> np.ndarray:
        """Batch-encode images -> (N, 512). Batching the GPU/MPS forward pass is
        far faster than one image at a time when indexing a large library.

        We explicitly drop the device tensors and empty the allocator cache after
        each batch. Without this the MPS (Metal) allocator holds onto freed
        buffers and RSS grows ~6 GB per 64-image chunk, OOM-killing a long index
        build partway through.
        """
        batch = torch.stack([self.preprocess(im) for im in pil_imgs]).to(self.device)
        emb = self.model.encode_image(batch)
        emb = emb / emb.norm(dim=-1, keepdim=True)
        out = emb.cpu().numpy().astype(np.float32)
        del batch, emb
        if self.device == "mps":
            torch.mps.empty_cache()
        elif self.device == "cuda":
            torch.cuda.empty_cache()
        return out
