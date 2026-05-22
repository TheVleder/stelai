#!/usr/bin/env python3
"""
Prepare the fashion classifier assets that StyleAI/Core/FashionClassifier.swift
reads at runtime:

    StyleAI/MLAssets/FashionClassifier.mlpackage      (MobileCLIP-S0 image encoder)
    StyleAI/MLAssets/garment_label_embeddings.json    (precomputed text embeddings)

Runs on any platform with Python and PyTorch — no CoreML / macOS dependency.
The CoreML image encoder is just downloaded from Hugging Face as a .mlpackage
bundle; we never load it from Python.

Usage:
    pip install -r scripts/requirements.txt
    python scripts/prepare_fashion_classifier.py
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import torch
from huggingface_hub import snapshot_download
import mobileclip


REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = REPO_ROOT / "StyleAI" / "MLAssets"
COREML_REPO = "apple/coreml-mobileclip"
COREML_IMAGE_FILE = "mobileclip_s0_image.mlpackage"
TARGET_MLPACKAGE = ASSETS_DIR / "FashionClassifier.mlpackage"
TARGET_EMBEDDINGS = ASSETS_DIR / "garment_label_embeddings.json"
PYTORCH_CHECKPOINT_URL = "https://docs-assets.developer.apple.com/ml-research/datasets/mobileclip/mobileclip_s0.pt"
CHECKPOINT_PATH = REPO_ROOT / "scripts" / "_cache" / "mobileclip_s0.pt"


# A single record describes one garment the scanner can recognise. `prompt` is
# the English description fed to the CLIP text encoder; the result becomes the
# `embedding` field that ships with the app. Keep prompts short and use the
# exact CLIP convention ("a photo of a …").
LABELS: list[dict] = [
    # --- Tops ---
    {"name": "Camiseta blanca",        "type": "top",       "thermalIndex": 0.70, "tags": ["Casual"],            "prompt": "a photo of a plain white t-shirt"},
    {"name": "Camiseta negra",         "type": "top",       "thermalIndex": 0.70, "tags": ["Casual"],            "prompt": "a photo of a plain black t-shirt"},
    {"name": "Camiseta de manga larga","type": "top",       "thermalIndex": 0.50, "tags": ["Casual"],            "prompt": "a photo of a long sleeve t-shirt"},
    {"name": "Polo",                   "type": "top",       "thermalIndex": 0.55, "tags": ["Casual"],            "prompt": "a photo of a polo shirt"},
    {"name": "Camisa",                 "type": "top",       "thermalIndex": 0.55, "tags": ["Formal"],            "prompt": "a photo of a button-up dress shirt"},
    {"name": "Blusa",                  "type": "top",       "thermalIndex": 0.60, "tags": ["Elegante"],          "prompt": "a photo of a women's blouse"},
    {"name": "Sudadera",               "type": "top",       "thermalIndex": 0.30, "tags": ["Casual", "Deportivo"], "prompt": "a photo of a sweatshirt"},
    {"name": "Sudadera con capucha",   "type": "top",       "thermalIndex": 0.25, "tags": ["Casual"],            "prompt": "a photo of a hoodie"},
    {"name": "Jersey",                 "type": "top",       "thermalIndex": 0.20, "tags": ["Casual"],            "prompt": "a photo of a knitted sweater"},
    {"name": "Cárdigan",               "type": "top",       "thermalIndex": 0.30, "tags": ["Elegante"],          "prompt": "a photo of a cardigan"},
    {"name": "Top de tirantes",        "type": "top",       "thermalIndex": 0.85, "tags": ["Casual"],            "prompt": "a photo of a tank top"},
    # --- Outerwear ---
    {"name": "Chaqueta vaquera",       "type": "outerwear", "thermalIndex": 0.40, "tags": ["Casual"],            "prompt": "a photo of a denim jacket"},
    {"name": "Chaqueta de cuero",      "type": "outerwear", "thermalIndex": 0.35, "tags": ["Casual"],            "prompt": "a photo of a leather jacket"},
    {"name": "Bomber",                 "type": "outerwear", "thermalIndex": 0.35, "tags": ["Casual"],            "prompt": "a photo of a bomber jacket"},
    {"name": "Blazer",                 "type": "outerwear", "thermalIndex": 0.45, "tags": ["Formal"],            "prompt": "a photo of a tailored blazer"},
    {"name": "Abrigo",                 "type": "outerwear", "thermalIndex": 0.10, "tags": ["Elegante"],          "prompt": "a photo of a long winter coat"},
    {"name": "Parka",                  "type": "outerwear", "thermalIndex": 0.05, "tags": ["Casual"],            "prompt": "a photo of a parka with hood"},
    {"name": "Cortavientos",           "type": "outerwear", "thermalIndex": 0.50, "tags": ["Deportivo"],         "prompt": "a photo of a windbreaker jacket"},
    {"name": "Plumífero",              "type": "outerwear", "thermalIndex": 0.10, "tags": ["Casual"],            "prompt": "a photo of a puffer down jacket"},
    # --- Bottoms ---
    {"name": "Pantalón vaquero",       "type": "bottom",    "thermalIndex": 0.50, "tags": ["Casual"],            "prompt": "a photo of blue jeans"},
    {"name": "Pantalón chino",         "type": "bottom",    "thermalIndex": 0.55, "tags": ["Casual", "Formal"],  "prompt": "a photo of chino pants"},
    {"name": "Pantalón de vestir",     "type": "bottom",    "thermalIndex": 0.55, "tags": ["Formal"],            "prompt": "a photo of dress trousers"},
    {"name": "Pantalón de chándal",    "type": "bottom",    "thermalIndex": 0.45, "tags": ["Deportivo"],         "prompt": "a photo of sweatpants"},
    {"name": "Leggings",               "type": "bottom",    "thermalIndex": 0.55, "tags": ["Deportivo"],         "prompt": "a photo of leggings"},
    {"name": "Pantalón corto",         "type": "bottom",    "thermalIndex": 0.85, "tags": ["Casual"],            "prompt": "a photo of shorts"},
    {"name": "Falda",                  "type": "bottom",    "thermalIndex": 0.70, "tags": ["Elegante"],          "prompt": "a photo of a skirt"},
    {"name": "Falda larga",            "type": "bottom",    "thermalIndex": 0.55, "tags": ["Elegante"],          "prompt": "a photo of a long maxi skirt"},
    # --- Full body ---
    {"name": "Vestido casual",         "type": "full_body", "thermalIndex": 0.70, "tags": ["Casual"],            "prompt": "a photo of a casual summer dress"},
    {"name": "Vestido elegante",       "type": "full_body", "thermalIndex": 0.65, "tags": ["Elegante", "Formal"],"prompt": "a photo of an elegant evening dress"},
    {"name": "Mono",                   "type": "full_body", "thermalIndex": 0.60, "tags": ["Casual"],            "prompt": "a photo of a jumpsuit"},
    {"name": "Traje",                  "type": "full_body", "thermalIndex": 0.50, "tags": ["Formal"],            "prompt": "a photo of a two-piece business suit"},
    # --- Shoes ---
    {"name": "Zapatillas",             "type": "shoes",     "thermalIndex": 0.60, "tags": ["Casual"],            "prompt": "a photo of casual sneakers"},
    {"name": "Zapatillas deportivas",  "type": "shoes",     "thermalIndex": 0.65, "tags": ["Deportivo"],         "prompt": "a photo of athletic running shoes"},
    {"name": "Zapatos de vestir",      "type": "shoes",     "thermalIndex": 0.55, "tags": ["Formal"],            "prompt": "a photo of formal leather dress shoes"},
    {"name": "Botas",                  "type": "shoes",     "thermalIndex": 0.25, "tags": ["Casual"],            "prompt": "a photo of leather boots"},
    {"name": "Botines",                "type": "shoes",     "thermalIndex": 0.40, "tags": ["Casual"],            "prompt": "a photo of ankle boots"},
    {"name": "Sandalias",              "type": "shoes",     "thermalIndex": 0.95, "tags": ["Casual"],            "prompt": "a photo of summer sandals"},
    # --- Accessories ---
    {"name": "Gorra",                  "type": "accessory", "thermalIndex": 0.55, "tags": ["Casual"],            "prompt": "a photo of a baseball cap"},
    {"name": "Bufanda",                "type": "accessory", "thermalIndex": 0.10, "tags": ["Casual"],            "prompt": "a photo of a winter scarf"},
    {"name": "Cinturón",               "type": "accessory", "thermalIndex": 0.50, "tags": ["Formal"],            "prompt": "a photo of a leather belt"},
    {"name": "Bolso",                  "type": "accessory", "thermalIndex": 0.50, "tags": ["Elegante"],          "prompt": "a photo of a handbag"},
    {"name": "Gafas de sol",           "type": "accessory", "thermalIndex": 0.95, "tags": ["Casual"],            "prompt": "a photo of sunglasses"},
]


def download_coreml_image_encoder() -> None:
    """Pull just the S0 image encoder .mlpackage from apple/coreml-mobileclip."""
    print(f"⬇️  Downloading {COREML_IMAGE_FILE} from {COREML_REPO} …")
    local = snapshot_download(
        repo_id=COREML_REPO,
        allow_patterns=[f"{COREML_IMAGE_FILE}/**"],
    )
    src = Path(local) / COREML_IMAGE_FILE
    if not src.exists():
        print(f"❌ Expected file not found: {src}", file=sys.stderr)
        sys.exit(1)

    if TARGET_MLPACKAGE.exists():
        shutil.rmtree(TARGET_MLPACKAGE)
    shutil.copytree(src, TARGET_MLPACKAGE)
    print(f"✅ Wrote {TARGET_MLPACKAGE.relative_to(REPO_ROOT)}")


def download_pytorch_checkpoint() -> None:
    """The text encoder needs the PyTorch checkpoint to run offline encoding."""
    if CHECKPOINT_PATH.exists():
        print(f"♻️  Reusing cached checkpoint at {CHECKPOINT_PATH.relative_to(REPO_ROOT)}")
        return
    CHECKPOINT_PATH.parent.mkdir(parents=True, exist_ok=True)
    print(f"⬇️  Downloading PyTorch checkpoint …")
    subprocess.run(
        ["curl", "-fL", "-o", str(CHECKPOINT_PATH), PYTORCH_CHECKPOINT_URL],
        check=True,
    )
    print(f"✅ Saved to {CHECKPOINT_PATH.relative_to(REPO_ROOT)}")


def compute_text_embeddings() -> None:
    print("🧠 Loading MobileCLIP-S0 (PyTorch) for text encoding …")
    model, _, _ = mobileclip.create_model_and_transforms(
        "mobileclip_s0", pretrained=str(CHECKPOINT_PATH)
    )
    model.eval()
    tokenizer = mobileclip.get_tokenizer("mobileclip_s0")

    enriched: list[dict] = []
    with torch.no_grad():
        for label in LABELS:
            tokens = tokenizer([label["prompt"]])
            embedding = model.encode_text(tokens)
            embedding = embedding / embedding.norm(dim=-1, keepdim=True)
            vec = embedding.squeeze(0).tolist()
            enriched.append({
                "name": label["name"],
                "type": label["type"],
                "thermalIndex": label["thermalIndex"],
                "tags": label["tags"],
                "embedding": [float(x) for x in vec],
            })

    payload = {
        "modelId": COREML_REPO,
        "variant": "MobileCLIP-S0",
        "embeddingDim": len(enriched[0]["embedding"]),
        "labels": enriched,
    }
    TARGET_EMBEDDINGS.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"✅ Wrote {TARGET_EMBEDDINGS.relative_to(REPO_ROOT)} ({len(enriched)} labels, dim {payload['embeddingDim']})")


def main() -> None:
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    download_coreml_image_encoder()
    download_pytorch_checkpoint()
    compute_text_embeddings()
    print("\n🎉 Fashion classifier assets ready.")


if __name__ == "__main__":
    main()
