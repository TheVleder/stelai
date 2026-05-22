#!/usr/bin/env python3
"""
Convert the FASHN Human Parser (SegFormer-B4, 18 fashion classes) to a CoreML
.mlpackage suitable for `StyleAI/Core/HumanParserService.swift`.

Output:
    StyleAI/MLAssets/HumanParser.mlpackage

⚠️  LICENSE: the upstream model uses the NVIDIA Source Code License for
SegFormer — **non-commercial use only**. This is fine for personal sideload
builds. For App Store distribution you need a different parser.

Usage (run on macOS — `coremltools` ANE optimization paths need it):
    pip install -r scripts/requirements_human_parser.txt
    python scripts/prepare_human_parser.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import torch
import coremltools as ct
from coremltools.optimize.coreml import OpPalettizerConfig, OptimizationConfig, palettize_weights
from transformers import SegformerForSemanticSegmentation


REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = REPO_ROOT / "StyleAI" / "MLAssets"
TARGET = ASSETS_DIR / "HumanParser.mlpackage"
MODEL_ID = "fashn-ai/fashn-human-parser"

INPUT_W, INPUT_H = 384, 576  # documented model resolution
NUM_CLASSES = 18

# ImageNet normalization that SegFormer expects.
MEAN = [0.485, 0.456, 0.406]
STD  = [0.229, 0.224, 0.225]


class ParserWrapper(torch.nn.Module):
    """Wrapper that returns full-resolution logits in NCHW order."""

    def __init__(self, model: SegformerForSemanticSegmentation):
        super().__init__()
        self.model = model

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        logits = self.model(pixel_values=x).logits  # (1, 18, H/4, W/4)
        return torch.nn.functional.interpolate(
            logits, size=(INPUT_H, INPUT_W), mode="bilinear", align_corners=False
        )


def main() -> None:
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"⬇️  Loading {MODEL_ID} …")
    base = SegformerForSemanticSegmentation.from_pretrained(MODEL_ID)
    base.eval()
    if base.config.num_labels != NUM_CLASSES:
        print(f"❌ Expected {NUM_CLASSES} classes, got {base.config.num_labels}", file=sys.stderr)
        sys.exit(1)

    wrapped = ParserWrapper(base).eval()
    example = torch.randn(1, 3, INPUT_H, INPUT_W)

    print("🧠 Tracing …")
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    print("📦 Converting to CoreML …")
    # CoreML wants the image input declared so the on-device preprocessing
    # absorbs the per-channel normalization automatically. Bias is subtracted
    # BEFORE scaling — that matches ImageNet's (x/255 - mean)/std formula.
    scale = 1.0 / 255.0
    bias = [-MEAN[i] / STD[i] for i in range(3)]
    bias_scaled = [b / s for b, s in zip(bias, STD)]  # absorb /std into the bias

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, INPUT_H, INPUT_W),
                scale=scale,
                bias=bias_scaled,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="logits")],
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )

    print("🗜  Palettizing weights to 6-bit (≈4× smaller, marginal quality loss) …")
    config = OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=6))
    mlmodel = palettize_weights(mlmodel, config)

    if TARGET.exists():
        import shutil
        shutil.rmtree(TARGET)
    mlmodel.save(str(TARGET))
    print(f"✅ Wrote {TARGET.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
