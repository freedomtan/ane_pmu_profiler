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
        "macs": 300_000_000,
    },
    {
        "family": "MobileNetV2",
        "variant": "Weight-Only INT8",
        "package_name": "MobileNetV2Alpha1WeightOnlySymmetricQuantized.mlpackage",
        "macs": 300_000_000,
    },
    {
        "family": "MobileNetV2",
        "variant": "W8A8 Quantized",
        "package_name": "MobileNetV2Alpha1SymmetricPerChannel.mlpackage",
        "macs": 300_000_000,
    },
    {
        "family": "ResNet50",
        "variant": "FP16",
        "package_name": "ResNet50.mlpackage",
        "macs": 4_120_000_000,
    },
    {
        "family": "ResNet50",
        "variant": "Weight-Only INT8",
        "package_name": "ResNet50WeightOnlySymmetricQuantized.mlpackage",
        "macs": 4_120_000_000,
    },
    {
        "family": "ResNet50",
        "variant": "W8A8 Quantized",
        "package_name": "ResNet50SymmetricPerChannel.mlpackage",
        "macs": 4_120_000_000,
    },
    {
        "family": "MobileViTv2",
        "variant": "FP16",
        "package_name": "MobileViTV2Alpha1.mlpackage",
        "macs": 1_840_000_000,
    },
    {
        "family": "MobileViTv2",
        "variant": "Weight-Only INT8",
        "package_name": "MobileViTV2Alpha1WeightOnlySymmetricQuantized.mlpackage",
        "macs": 1_840_000_000,
    },
    {
        "family": "MobileViTv2",
        "variant": "W8A8 Quantized",
        "package_name": "MobileViTV2Alpha1SymmetricPerChannel.mlpackage",
        "macs": 1_840_000_000,
    },
]


def run_model_benchmark(bin_path, model_path, iters=5, qos=1, macs=0):
    cmd = [bin_path, model_path, "--iters", str(iters)]
    if macs > 0:
        cmd += ["--macs", str(macs)]
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

    # Throughput & TOPS Highlights
    tops_match = re.search(r"Realized Compute Speed\s*:\s*([\d\.]+)\s*TOPS", output)
    metrics["tops"] = float(tops_match.group(1)) if tops_match else None

    tp_core = re.search(r"Silicon Throughput / Core\s*:\s*([\d\.]+)\s*MACs / cycle / core", output)
    metrics["macs_per_core_cycle"] = float(tp_core.group(1)) if tp_core else None

    tp_chip = re.search(r"Total Chip Throughput \(16x\)\s*:\s*([\d\.]+)\s*MACs / cycle", output)
    metrics["chip_macs_per_cycle"] = float(tp_chip.group(1)) if tp_chip else None

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
        help="Quality of Service class (1: UserInteractive, 2: Default)",
    )
    parser.add_argument(
        "--family",
        "-f",
        default="all",
        help="Model family to benchmark (MobileNetV2, ResNet50, MobileViTv2, or all)",
    )
    parser.add_argument(
        "--output-json",
        "-o",
        default="reports/quantization_telemetry.json",
        help="Output JSON file for benchmark telemetry (default: reports/quantization_telemetry.json)",
    )

    args = parser.parse_args()

    models_dir = os.path.abspath(args.models_dir)
    profiler_bin = os.path.abspath(args.bin)

    if not os.path.exists(profiler_bin):
        print(f"❌ Error: profiler binary not found at {profiler_bin}")
        print("Please build it first using `make dump_ane_pmu_objc`")
        sys.exit(1)

    if not os.path.exists(models_dir):
        print(f"❌ Error: models directory not found at {models_dir}")
        print("Please download models first using `scripts/download_quantized_models.py`")
        sys.exit(1)

    print("=" * 125)
    print("🔬 ANE PHYSICAL SILICON PMU PROFILING: QUANTIZED COREML VARIANTS")
    print(f"📂 Models Directory : {models_dir}")
    print(f"🛠️  Profiler Binary  : {profiler_bin}")
    print(f"🔁 Iterations       : {args.iters} | QoS: {args.qos}")
    print(f"🎯 Family Filter    : {args.family}")
    print("=" * 125)

    selected_models = []
    for m in MODELS:
        if args.family == "all" or m["family"].lower() == args.family.lower():
            selected_models.append(m)

    results = []
    for item in selected_models:
        family = item["family"]
        variant = item["variant"]
        macs = item.get("macs", 0)
        path = os.path.join(models_dir, item["package_name"])
        
        if not os.path.exists(path):
            print(f"⚠️  Model file not found: {path}")
            continue

        print(f"\n🏃 Profiling [{family}] - {variant}...")
        code, out = run_model_benchmark(profiler_bin, path, iters=args.iters, qos=args.qos, macs=macs)
        if code != 0:
            print(f"❌ Execution failed (code {code}):\n{out[-500:]}")
            continue

        metrics = parse_telemetry(out)
        metrics["family"] = family
        metrics["variant"] = variant
        metrics["workload_macs"] = macs

        if macs > 0 and metrics.get("latency_ms"):
            if metrics.get("tops") is None:
                metrics["tops"] = round((2.0 * macs) / (metrics["latency_ms"] * 1e6 * 1000.0), 2)
            if metrics.get("macs_per_core_cycle") is None and metrics.get("ne_nominal_cycles"):
                metrics["macs_per_core_cycle"] = round(macs / metrics["ne_nominal_cycles"], 1)
                metrics["chip_macs_per_cycle"] = round(metrics["macs_per_core_cycle"] * 16.0, 1)

        results.append(metrics)
        tops_str = f" | TOPS = {metrics['tops']:.2f}" if metrics.get("tops") else ""
        tp_str = f" | Throughput = {metrics['macs_per_core_cycle']:.1f} MACs/cyc/core" if metrics.get("macs_per_core_cycle") else ""
        print(f"   Done: Latency = {metrics['latency_ms']:.3f} ms{tops_str}{tp_str} | DMA = {metrics['dma_rw_bytes']:,} B")

    # Print Markdown Summary Table
    print("\n\n" + "=" * 125)
    print("📊 PHYSICAL TELEMETRY SUMMARY MATRIX")
    print("=" * 125)
    header = f"{'Model Family':<12} | {'Variant':<18} | {'Latency (ms)':<12} | {'TOPS':<7} | {'MACs/cyc/core':<14} | {'Chip MACs/cyc':<14} | {'DMA RW (MB)':<11} | {'DPE Energy':<10}"
    print(header)
    print("-" * len(header))
    for r in results:
        lat = f"{r['latency_ms']:.3f}" if r['latency_ms'] else "N/A"
        tops = f"{r['tops']:.2f}" if r.get('tops') else "—"
        tp_core = f"{r['macs_per_core_cycle']:.1f}" if r.get('macs_per_core_cycle') else "—"
        tp_chip = f"{r['chip_macs_per_cycle']:.1f}" if r.get('chip_macs_per_cycle') else "—"
        dma_mb = f"{r['dma_rw_bytes'] / (1024*1024):.2f}"
        energy = f"{r['dpe_energy']:,}"
        print(f"{r['family']:<12} | {r['variant']:<18} | {lat:<12} | {tops:<7} | {tp_core:<14} | {tp_chip:<14} | {dma_mb:<11} | {energy:<10}")

    # Output JSON
    out_json = os.path.abspath(args.output_json)
    with open(out_json, "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
