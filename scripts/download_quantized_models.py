#!/usr/bin/env python3
"""
download_quantized_models.py
Download MobileNetV2, ResNet50, and MobileViTv2 quantized and uncompressed CoreML variants
from Apple coremltools performance benchmark docs to a local directory (default: /tmp/coreml_models/).

Reference:
https://apple.github.io/coremltools/docs-guides/source/opt-quantization-perf.html
"""

import os
import sys
import argparse
import urllib.request
import zipfile
import shutil

MODELS = [
    # MobileNetv2-1.0
    {
        "family": "MobileNetV2",
        "variant": "Float16 (Uncompressed)",
        "package_name": "MobileNetV2Alpha1.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/uncompressed/MobileNetV2Alpha1.mlpackage.zip",
        "yaml_url": None,
        "compression": "None (FP16)",
        "accuracy": "71.86%",
    },
    {
        "family": "MobileNetV2",
        "variant": "Weight-Only Symmetric Quantized",
        "package_name": "MobileNetV2Alpha1WeightOnlySymmetricQuantized.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/post_training_compressed/quantized/MobileNetV2Alpha1WeightOnlySymmetricQuantized.mlpackage.zip",
        "yaml_url": None,
        "compression": "Post-Training (INT8 Weight)",
        "accuracy": "71.78%",
    },
    {
        "family": "MobileNetV2",
        "variant": "Weight & Activation Symmetric Per-Channel (W8A8)",
        "package_name": "MobileNetV2Alpha1SymmetricPerChannel.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/training_time_compressed/quantized/MobileNetV2Alpha1SymmetricPerChannel.mlpackage.zip",
        "yaml_url": "https://ml-assets.apple.com/coreml/quantized_models/training_time_compressed/quantized/MobileNetV2Alpha1SymmetricPerChannel.yaml",
        "compression": "Training-Time (W8A8)",
        "accuracy": "71.66%",
    },

    # ResNet50
    {
        "family": "ResNet50",
        "variant": "Float16 (Uncompressed)",
        "package_name": "ResNet50.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/uncompressed/ResNet50.mlpackage.zip",
        "yaml_url": None,
        "compression": "None (FP16)",
        "accuracy": "76.14%",
    },
    {
        "family": "ResNet50",
        "variant": "Weight-Only Symmetric Quantized",
        "package_name": "ResNet50WeightOnlySymmetricQuantized.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/post_training_compressed/quantized/ResNet50WeightOnlySymmetricQuantized.mlpackage.zip",
        "yaml_url": None,
        "compression": "Post-Training (INT8 Weight)",
        "accuracy": "76.10%",
    },
    {
        "family": "ResNet50",
        "variant": "Weight & Activation Symmetric Per-Channel (W8A8)",
        "package_name": "ResNet50SymmetricPerChannel.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/training_time_compressed/quantized/ResNet50SymmetricPerChannel.mlpackage.zip",
        "yaml_url": "https://ml-assets.apple.com/coreml/quantized_models/training_time_compressed/quantized/ResNet50SymmetricPerChannel.yaml",
        "compression": "Training-Time (W8A8)",
        "accuracy": "76.80%",
    },

    # MobileViTv2-1.0
    {
        "family": "MobileViTv2",
        "variant": "Float16 (Uncompressed)",
        "package_name": "MobileViTV2Alpha1.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/uncompressed/MobileViTV2Alpha1.mlpackage.zip",
        "yaml_url": None,
        "compression": "None (FP16)",
        "accuracy": "78.09%",
    },
    {
        "family": "MobileViTv2",
        "variant": "Weight-Only Symmetric Quantized",
        "package_name": "MobileViTV2Alpha1WeightOnlySymmetricQuantized.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/post_training_compressed/quantized/MobileViTV2Alpha1WeightOnlySymmetricQuantized.mlpackage.zip",
        "yaml_url": None,
        "compression": "Post-Training (INT8 Weight)",
        "accuracy": "77.66%",
    },
    {
        "family": "MobileViTv2",
        "variant": "Weight & Activation Symmetric Per-Channel (W8A8)",
        "package_name": "MobileViTV2Alpha1SymmetricPerChannel.mlpackage",
        "url": "https://ml-assets.apple.com/coreml/quantized_models/training_time_compressed/quantized/MobileViTV2Alpha1SymmetricPerChannel.mlpackage.zip",
        "yaml_url": "https://ml-assets.apple.com/coreml/quantized_models/training_time_compressed/quantized/MobileViTV2Alpha1SymmetricPerChannel.yaml",
        "compression": "Training-Time (W8A8)",
        "accuracy": "76.89%",
    },
]


def download_file(url: str, dest_path: str):
    """Download a file with progress reporting."""
    print(f"  ⬇️  Downloading from: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Macintosh; Apple Silicon)"})
    with urllib.request.urlopen(req) as response, open(dest_path, "wb") as out_file:
        total_size = int(response.info().get("Content-Length", 0))
        downloaded = 0
        chunk_size = 1024 * 512  # 512 KB chunks
        while True:
            chunk = response.read(chunk_size)
            if not chunk:
                break
            out_file.write(chunk)
            downloaded += len(chunk)
            if total_size > 0:
                percent = (downloaded / total_size) * 100
                mb_down = downloaded / (1024 * 1024)
                mb_tot = total_size / (1024 * 1024)
                sys.stdout.write(f"\r     Progress: {mb_down:6.1f} MB / {mb_tot:6.1f} MB ({percent:5.1f}%)")
                sys.stdout.flush()
            else:
                mb_down = downloaded / (1024 * 1024)
                sys.stdout.write(f"\r     Progress: {mb_down:6.1f} MB")
                sys.stdout.flush()
        sys.stdout.write("\n")


def extract_zip(zip_path: str, extract_dir: str):
    """Extract zip file into target directory."""
    print(f"  📦 Extracting archive: {os.path.basename(zip_path)}")
    with zipfile.ZipFile(zip_path, "r") as zip_ref:
        zip_ref.extractall(extract_dir)


def main():
    parser = argparse.ArgumentParser(
        description="Download Apple coremltools MobileNetV2, ResNet50, and MobileViTv2 quantized variants."
    )
    parser.add_argument(
        "--output-dir",
        "-o",
        default="/tmp/coreml_models",
        help="Target directory to store extracted .mlpackage models (default: /tmp/coreml_models)",
    )
    parser.add_argument(
        "--family",
        "-f",
        choices=["all", "mobilenetv2", "resnet50", "mobilevitv2"],
        default="all",
        help="Filter model family to download (default: all)",
    )
    parser.add_argument(
        "--keep-zips",
        action="store_true",
        help="Do not delete downloaded .zip archives after extraction",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing extracted .mlpackage bundles",
    )

    args = parser.parse_args()
    dest_dir = os.path.abspath(args.output_dir)
    os.makedirs(dest_dir, exist_ok=True)

    print("=" * 80)
    print("🚀 Apple CoreML Quantized Models Downloader")
    print(f"📂 Destination Directory : {dest_dir}")
    print(f"🎯 Model Family Filter   : {args.family}")
    print("=" * 80)

    selected_models = []
    for m in MODELS:
        if args.family == "all" or m["family"].lower() == args.family.lower():
            selected_models.append(m)

    downloaded_packages = []

    for idx, model_info in enumerate(selected_models, 1):
        pkg_name = model_info["package_name"]
        final_pkg_path = os.path.join(dest_dir, pkg_name)
        zip_name = os.path.basename(model_info["url"])
        zip_path = os.path.join(dest_dir, zip_name)

        print(f"\n[{idx}/{len(selected_models)}] {model_info['family']} - {model_info['variant']}")
        print(f"  • Optimization : {model_info['compression']}")
        print(f"  • Top-1 Acc    : {model_info['accuracy']}")

        if os.path.exists(final_pkg_path) and not args.force:
            print(f"  ✅ Package already exists: {final_pkg_path} (Skipping, use --force to overwrite)")
            downloaded_packages.append(final_pkg_path)
            continue

        # Download zip
        try:
            download_file(model_info["url"], zip_path)
            extract_zip(zip_path, dest_dir)
            if not args.keep_zips and os.path.exists(zip_path):
                os.remove(zip_path)
            downloaded_packages.append(final_pkg_path)

            # Also download YAML config if present
            if model_info["yaml_url"]:
                yaml_name = os.path.basename(model_info["yaml_url"])
                yaml_path = os.path.join(dest_dir, yaml_name)
                download_file(model_info["yaml_url"], yaml_path)

            print(f"  ✨ Successfully prepared: {final_pkg_path}")
        except Exception as e:
            print(f"  ❌ Error downloading {pkg_name}: {e}")

    print("\n" + "=" * 80)
    print("🎉 All Models Downloaded & Ready for Profiling!")
    print("=" * 80)
    print(f"Models directory: {dest_dir}\n")
    print("Run profiling with ane_pmu_profiler:")
    for pkg in downloaded_packages:
        print(f"  ./dump_ane_pmu_objc {pkg}")
    print("=" * 80)


if __name__ == "__main__":
    main()
