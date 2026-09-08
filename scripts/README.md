# Automated Quantization Profiling & Benchmarking Suite

This directory contains automated Python automation scripts for downloading official Apple CoreML quantized model suites, executing hardware PMU telemetry benchmarks via `dump_ane_pmu_objc`, and analyzing physical execution metrics across Apple Neural Engine (ANE) hardware.

---

## 1. Scripts Overview

| Script | Purpose |
| :--- | :--- |
| [`download_quantized_models.py`](file:///Users/freedom/work/ios-hacking/ane_pmu_profiler/scripts/download_quantized_models.py) | Downloads the 9 canonical Apple CoreML models (MobileNetV2, ResNet-50, MobileViTv2 across FP16, Weight-Only INT8, and W8A8) from Apple's official CDN. |
| [`benchmark_quantized_models.py`](file:///Users/freedom/work/ios-hacking/ane_pmu_profiler/scripts/benchmark_quantized_models.py) | Automates end-to-end benchmarking using `dump_ane_pmu_objc`, extracts all 29 PMU registers, formats a summary table, and exports raw metrics to JSON. |

---

## 2. Prerequisites

1. **Physical Apple Silicon Hardware** with `boot-args="amfi_get_out_of_my_way=0x1 anedebug=1"`.
2. **Compiled Profiler Binary**:
   ```bash
   make dump_ane_pmu_objc
   ```
3. **Python 3.8+** (Standard library only; no third-party `pip` dependencies required).

---

## 3. Workflow: End-to-End Profiling

### Step 1: Download the Model Suite
Run `download_quantized_models.py` to fetch official CoreML `.mlpackage` archives from Apple CDN:

```bash
# Download all 9 models into /tmp/coreml_models/ (default)
python3 scripts/download_quantized_models.py

# Download only MobileNetV2 models into a custom directory
python3 scripts/download_quantized_models.py --family mobilenetv2 -o ~/models/coreml

# Force re-download and keep raw zip archives
python3 scripts/download_quantized_models.py --force --keep-zips
```

#### Supported Model Families:
- **`mobilenetv2`**: `MobileNetV2Alpha1`, `MobileNetV2Alpha1WeightOnlySymmetricQuantized`, `MobileNetV2Alpha1SymmetricPerChannel`
- **`resnet50`**: `ResNet50`, `ResNet50WeightOnlySymmetricQuantized`, `ResNet50SymmetricPerChannel`
- **`mobilevitv2`**: `MobileViTV2Alpha1`, `MobileViTV2Alpha1WeightOnlySymmetricQuantized`, `MobileViTV2Alpha1SymmetricPerChannel`
- **`all`** (Default): All 9 models above.

---

### Step 2: Run Automated Silicon PMU Telemetry
Execute `benchmark_quantized_models.py` to run batches through `dump_ane_pmu_objc`:

```bash
# Run benchmark on all downloaded models with default settings (5 iterations per model)
python3 scripts/benchmark_quantized_models.py

# Benchmark with custom models directory and profiler binary
python3 scripts/benchmark_quantized_models.py \
    --models-dir /tmp/coreml_models \
    --bin ./dump_ane_pmu_objc \
    --iters 10 \
    --qos 1 \
    --output-json /tmp/m4_pmu_benchmarks.json

# Benchmark only ResNet-50 variants
python3 scripts/benchmark_quantized_models.py --family resnet50
```

---

## 4. Telemetry Extraction & Metrics

`benchmark_quantized_models.py` automatically parses and extracts:
- **Execution Latency & Throughput**: Average inference time (`ms`) and `FPS`.
- **Compile Latency**: CoreML compilation time and `_ANEClient` ANE compilation latency.
- **Compute Cycles**:
  - `kANE_NE_COMPUTE_CYCLES` (`[13]`): Active convolution MAC array cycles.
  - `kANE_L2PE_COMPUTE_CYCLES` (`[21]`): Active Planar Engine vector cycles.
  - `kANE_NE_NOMINAL_CYCLES` (`[10]`): Reference clock cycles.
- **Pipeline Stalls**:
  - `kANE_NE_INPUT_STALL_CYCLES` (`[14]`): Memory starvation cycles waiting on input operands.
  - `kANE_NE_OUTPUT_STALL_CYCLES` (`[15]`): Output backpressure stalls waiting for DRAM writeback.
  - `kANE_L2_THROTTLE_CYCLES` (`[12]`): L2 SRAM bus throttling.
- **Bandwidth & Energy**:
  - `kANE_DMA_READWRITE_BYTES` (`[17]`): Total Unified Memory DRAM read/write traffic.
  - `kANE_DPE_ENERGY` (`[19]`): Dedicated Processing Engine energy accumulator units.

---

## 5. Sample Benchmark Console Output

```text
===================================================================================================================
🔬 ANE PHYSICAL SILICON PMU PROFILING: QUANTIZED COREML VARIANTS
📂 Models Directory : /tmp/coreml_models
🛠️  Profiler Binary  : /Users/freedom/work/ios-hacking/ane_pmu_profiler/dump_ane_pmu_objc
🔁 Iterations       : 5 | QoS: 1
🎯 Family Filter    : all
===================================================================================================================

🏃 Profiling [MobileNetV2] - FP16...
   Done: Latency = 2.923 ms | FPS = 342.1 | MAC Cycles = 48,139,618 | DMA = 5,337,292 B

🏃 Profiling [MobileNetV2] - Weight-Only INT8...
   Done: Latency = 2.799 ms | FPS = 357.2 | MAC Cycles = 47,006,286 | DMA = 5,106,560 B

🏃 Profiling [MobileNetV2] - W8A8 Quantized...
   Done: Latency = 1.171 ms | FPS = 854.2 | MAC Cycles = 12,339,213 | DMA = 2,149,580 B
...

===================================================================================================================
📊 PHYSICAL TELEMETRY SUMMARY MATRIX
===================================================================================================================
Model Family   | Variant            | Latency (ms) | FPS      | MAC Cycles   | Input Stalls  | DMA RW (MB) | DPE Energy
-------------------------------------------------------------------------------------------------------------------
MobileNetV2    | FP16               | 2.923        | 342.1    | 48.14M       | 23.41M        | 5.09        | 419,979   
MobileNetV2    | Weight-Only INT8   | 2.799        | 357.2    | 47.01M       | 21.22M        | 4.87        | 369,772   
MobileNetV2    | W8A8 Quantized     | 1.171        | 854.2    | 12.34M       | 4,768         | 2.05        | 91,750    
ResNet50       | FP16               | 8.765        | 114.1    | 98.13M       | 22.91M        | 15.21       | 1,415,683 
ResNet50       | Weight-Only INT8   | 8.173        | 122.4    | 93.58M       | 23.42M        | 14.42       | 1,417,674 
ResNet50       | W8A8 Quantized     | 5.090        | 196.5    | 38.89M       | 3.18M         | 8.17        | 249,170   
MobileViTv2    | FP16               | 7.952        | 125.8    | 167.36M      | 37.35M        | 13.77       | 967,898   
MobileViTv2    | Weight-Only INT8   | 8.064        | 124.0    | 173.36M      | 37.01M        | 13.98       | 953,569   
MobileViTv2    | W8A8 Quantized     | 5.483        | 182.4    | 129.41M      | 13.09M        | 9.50        | 754,326   

Saved raw telemetry metrics to /tmp/quantized_benchmarks.json
```

---

## 6. Related Documentation

- For the full theoretical and microarchitectural interpretation of these benchmark results, see:
  [`reports/ANE_Quantization_Performance_Analysis_Report.md`](file:///Users/freedom/work/ios-hacking/ane_pmu_profiler/reports/ANE_Quantization_Performance_Analysis_Report.md).
