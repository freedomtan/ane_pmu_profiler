#!/usr/bin/env python3
"""
benchmark_quantized_models.py
Automated benchmark runner for CoreML quantized model variants using dump_ane_pmu_objc.
Collects hardware PMU telemetry across FP16, Weight-Only INT8, and W8A8 models on Apple Neural Engine.
"""

import os
import sys
import argparse
import subprocess
import re
import json

MODELS = [
    {
        "family": "MobileNetV2",
        "variant": "FP16",
        "package_name": "MobileNetV2Alpha1.mlpackage",
    },
    {
        "family": "MobileNetV2",
        "variant": "Weight-Only INT8",
        "package_name": "MobileNetV2Alpha1WeightOnlySymmetricQuantized.mlpackage",
    },
    {
        "family": "MobileNetV2",
        "variant": "W8A8 Quantized",
        "package_name": "MobileNetV2Alpha1SymmetricPerChannel.mlpackage",
    },
    {
        "family": "ResNet50",
        "variant": "FP16",
        "package_name": "ResNet50.mlpackage",
    },
    {
        "family": "ResNet50",
        "variant": "Weight-Only INT8",
        "package_name": "ResNet50WeightOnlySymmetricQuantized.mlpackage",
    },
    {
        "family": "ResNet50",
        "variant": "W8A8 Quantized",
        "package_name": "ResNet50SymmetricPerChannel.mlpackage",
    },
    {
        "family": "MobileViTv2",
        "variant": "FP16",
        "package_name": "MobileViTV2Alpha1.mlpackage",
    },
    {
        "family": "MobileViTv2",
        "variant": "Weight-Only INT8",
        "package_name": "MobileViTV2Alpha1WeightOnlySymmetricQuantized.mlpackage",
    },
    {
        "family": "MobileViTv2",
        "variant": "W8A8 Quantized",
        "package_name": "MobileViTV2Alpha1SymmetricPerChannel.mlpackage",
    },
]


def run_model_benchmark(bin_path, model_path, iters=5, qos=1):
    cmd = [bin_path, model_path, str(iters), str(qos)]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        return proc.returncode, proc.stdout
    except Exception as e:
        return -1, str(e)


def parse_telemetry(output):
    metrics = {}
    
    # Latency & FPS
    lat_match = re.search(r"Average Latency:\s*([\d\.]+)\s*ms\s*\|\s*Throughput:\s*([\d\.]+)\s*FPS", output)
    if lat_match:
        metrics["latency_ms"] = float(lat_match.group(1))
        metrics["fps"] = float(lat_match.group(2))
    else:
        metrics["latency_ms"] = None
        metrics["fps"] = None

    # CoreML & ANE Compilation times
    coreml_comp = re.search(r"CoreML Compilation Time\s*:\s*([\d\.]+)\s*ms", output)
    metrics["coreml_comp_ms"] = float(coreml_comp.group(1)) if coreml_comp else None

    ane_comp = re.search(r"ANE Compilation Latency\s*:\s*([\d\.]+)\s*ms", output)
    metrics["ane_comp_ms"] = float(ane_comp.group(1)) if ane_comp else None

    # PMU Delta Highlights
    ne_comp = re.search(r"Neural Engine Compute Cycles\s*:\s*([\d,]+)\s*cycles/iter", output)
    metrics["ne_compute_cycles"] = int(ne_comp.group(1).replace(",", "")) if ne_comp else 0

    l2pe_comp = re.search(r"L2PE Compute Cycles\s*:\s*([\d,]+)\s*cycles/iter", output)
    metrics["l2pe_compute_cycles"] = int(l2pe_comp.group(1).replace(",", "")) if l2pe_comp else 0

    ne_nom = re.search(r"Neural Engine Nominal Cycles\s*:\s*([\d,]+)\s*cycles/iter", output)
    metrics["ne_nominal_cycles"] = int(ne_nom.group(1).replace(",", "")) if ne_nom else 0

    dma_rw = re.search(r"Unified Memory Read/Write\s*:\s*([\d,]+)\s*bytes/iter", output)
    metrics["dma_rw_bytes"] = int(dma_rw.group(1).replace(",", "")) if dma_rw else 0

    dma_r = re.search(r"Unified Memory DMA Read\s*:\s*([\d,]+)\s*bytes/iter", output)
    metrics["dma_r_bytes"] = int(dma_r.group(1).replace(",", "")) if dma_r else 0

    eff_clk = re.search(r"Effective Silicon Clock\s*:\s*([\d\.]+)\s*GHz per core", output)
    metrics["clock_ghz"] = float(eff_clk.group(1)) if eff_clk else 0.0

    # Specific Register Deltas from Table
    input_stall = re.search(r"kANE_NE_INPUT_STALL_CYCLES\s*\|\s*([\d,]+)", output)
    metrics["ne_input_stall"] = int(input_stall.group(1).replace(",", "")) if input_stall else 0

    output_stall = re.search(r"kANE_NE_OUTPUT_STALL_CYCLES\s*\|\s*([\d,]+)", output)
    metrics["ne_output_stall"] = int(output_stall.group(1).replace(",", "")) if output_stall else 0

    dpe_energy = re.search(r"kANE_DPE_ENERGY\s*\|\s*([\d,]+)", output)
    metrics["dpe_energy"] = int(dpe_energy.group(1).replace(",", "")) if dpe_energy else 0

    l2_throttle = re.search(r"kANE_L2_THROTTLE_CYCLES\s*\|\s*([\d,]+)", output)
    metrics["l2_throttle"] = int(l2_throttle.group(1).replace(",", "")) if l2_throttle else 0

    return metrics


def main():
    parser = argparse.ArgumentParser(
        description="Automated benchmark runner for CoreML quantized model variants using dump_ane_pmu_objc."
    )
    parser.add_argument(
        "--models-dir",
        "-d",
        default="/tmp/coreml_models",
        help="Directory containing downloaded .mlpackage models (default: /tmp/coreml_models)",
    )
    parser.add_argument(
        "--bin",
        "-b",
        default="./dump_ane_pmu_objc",
        help="Path to dump_ane_pmu_objc profiler binary (default: ./dump_ane_pmu_objc)",
    )
    parser.add_argument(
        "--iters",
        "-i",
        type=int,
        default=5,
        help="Number of benchmark iterations per model (default: 5)",
    )
    parser.add_argument(
        "--qos",
        "-q",
        type=int,
        default=1,
        help="Quality of Service tier (default: 1)",
    )
    parser.add_argument(
        "--family",
        "-f",
        choices=["all", "mobilenetv2", "resnet50", "mobilevitv2"],
        default="all",
        help="Filter model family to benchmark (default: all)",
    )
    parser.add_argument(
        "--output-json",
        "-o",
        default="/tmp/quantized_benchmarks.json",
        help="Path to save benchmark results JSON (default: /tmp/quantized_benchmarks.json)",
    )

    args = parser.parse_args()

    profiler_bin = os.path.abspath(args.bin)
    if not os.path.exists(profiler_bin):
        print(f"❌ Error: profiler binary not found at {profiler_bin}")
        print("Please build it first: `make dump_ane_pmu_objc`")
        sys.exit(1)

    models_dir = os.path.abspath(args.models_dir)
    if not os.path.exists(models_dir):
        print(f"❌ Error: models directory not found at {models_dir}")
        print("Please download models first using `scripts/download_quantized_models.py`")
        sys.exit(1)

    print("=" * 115)
    print("🔬 ANE PHYSICAL SILICON PMU PROFILING: QUANTIZED COREML VARIANTS")
    print(f"📂 Models Directory : {models_dir}")
    print(f"🛠️  Profiler Binary  : {profiler_bin}")
    print(f"🔁 Iterations       : {args.iters} | QoS: {args.qos}")
    print(f"🎯 Family Filter    : {args.family}")
    print("=" * 115)

    selected_models = []
    for m in MODELS:
        if args.family == "all" or m["family"].lower() == args.family.lower():
            selected_models.append(m)

    results = []
    for item in selected_models:
        family = item["family"]
        variant = item["variant"]
        path = os.path.join(models_dir, item["package_name"])
        
        if not os.path.exists(path):
            print(f"⚠️  Model file not found: {path}")
            continue

        print(f"\n🏃 Profiling [{family}] - {variant}...")
        code, out = run_model_benchmark(profiler_bin, path, iters=args.iters, qos=args.qos)
        if code != 0:
            print(f"❌ Execution failed (code {code}):\n{out[-500:]}")
            continue

        metrics = parse_telemetry(out)
        metrics["family"] = family
        metrics["variant"] = variant
        results.append(metrics)
        print(f"   Done: Latency = {metrics['latency_ms']:.3f} ms | FPS = {metrics['fps']:.1f} | MAC Cycles = {metrics['ne_compute_cycles']:,} | DMA = {metrics['dma_rw_bytes']:,} B")

    # Print Markdown Summary Table
    print("\n\n" + "=" * 115)
    print("📊 PHYSICAL TELEMETRY SUMMARY MATRIX")
    print("=" * 115)
    header = f"{'Model Family':<14} | {'Variant':<18} | {'Latency (ms)':<12} | {'FPS':<8} | {'MAC Cycles':<12} | {'Input Stalls':<13} | {'DMA RW (MB)':<11} | {'DPE Energy':<10}"
    print(header)
    print("-" * len(header))
    for r in results:
        lat = f"{r['latency_ms']:.3f}" if r['latency_ms'] else "N/A"
        fps = f"{r['fps']:.1f}" if r['fps'] else "N/A"
        mac = f"{r['ne_compute_cycles'] / 1e6:.2f}M"
        stalls = f"{r['ne_input_stall'] / 1e6:.2f}M" if r['ne_input_stall'] > 1e5 else f"{r['ne_input_stall']:,}"
        dma_mb = f"{r['dma_rw_bytes'] / (1024*1024):.2f}"
        energy = f"{r['dpe_energy']:,}"
        print(f"{r['family']:<14} | {r['variant']:<18} | {lat:<12} | {fps:<8} | {mac:<12} | {stalls:<13} | {dma_mb:<11} | {energy:<10}")

    # Output JSON
    out_json = os.path.abspath(args.output_json)
    with open(out_json, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nSaved raw telemetry metrics to {out_json}")


if __name__ == "__main__":
    main()
