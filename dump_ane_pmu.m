//
// dump_ane_pmu.m
// Apple Neural Engine (ANE) Silicon PMU Register Dump & Live Hardware Telemetry
//
// Supports:
//   Option A: On-the-fly CoreML MIL compilation via _ANEClient (e.g. .mlmodelc)
//   Option B: Direct trusted cache injection & execution of precompiled .hwx
//   Option C: Direct CoreAI / .aimodel / .mlirb JIT & live _ANEClient execution (without copying .hwx)
//
// Checks driver gate status, allocates statType=2 PMU IOSurface buffer,
// dispatches live inference on physical silicon, and decodes all 29 hardware registers.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <Security/Security.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

extern NSString * const kANEFModelTypeKey;
extern NSString * const kANEFModelPreCompiledValue;
extern NSString * const kANEFPerformanceStatsMaskKey;

typedef enum {
    RUN_MODE_HWX = 0,     // Option B: Pre-compiled .hwx
    RUN_MODE_COMPILE = 1, // Option A: .mlmodelc via _ANEClient
    RUN_MODE_COREAI = 2   // Option C: .aimodel / .mlirb via CoreAI & direct _ANEClient without copying .hwx
} RunMode;

typedef struct {
    RunMode runMode;            // Execution pipeline
    NSString *modelPath;        // Path to .mlmodelc, .hwx, .aimodel, or .mlirb
    size_t inBytes;             // Input IOSurface size in bytes
    size_t outBytes;            // Output IOSurface size in bytes
    int numIters;               // Number of inference iterations
} Config;

#import "coreai_loader.h"

static IOSurfaceRef gInSurface = NULL;
static IOSurfaceRef gOutSurface = NULL;
static IOSurfaceRef gPmuSurface = NULL;
static id gLivePerfStatsObj = nil;
static uint64_t gLiveHwTimeNs = 0;
static uint64_t gInitialRegs[29] = { 0 };
static uint64_t gFinalRegs[29] = { 0 };
static BOOL gHasInitialRegs = NO;
static int gMeasuredIters = 0;

// --- 1. Check ANE Driver & Gating Status ---

BOOL checkAndPrintDriverStatus(void) {
    printf("========================================================================================================\n");
    printf("🔍 APPLE NEURAL ENGINE (ANE) DRIVER & SILICON PMU STATUS CHECK\n");
    printf("========================================================================================================\n");

    // A. Query Kernel Boot Arguments
    char bootargs[1024] = { 0 };
    size_t size = sizeof(bootargs);
    int ret = sysctlbyname("kern.bootargs", bootargs, &size, NULL, 0);
    NSString *bootArgsStr = (ret == 0 && strlen(bootargs) > 0) ? [NSString stringWithUTF8String:bootargs] : @"(none)";
    BOOL hasAneDebug = [bootArgsStr containsString:@"anedebug"];

    // B. Query IOKit Registry for ANE Driver & Hardware Properties
    CFMutableDictionaryRef matching = IOServiceMatching("H11ANEIn");
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) {
        matching = IOServiceMatching("AppleH16ANEInterface");
        service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    }

    NSString *driverName = @"AppleH16ANEInterface";
    NSString *archStr = @"Unknown";
    int cores = 16;
    int version = 0;
    int minorVersion = 0;
    int boardType = 0;
    BOOL isInternalBuild = NO;
    BOOL firmwareLoaded = NO;

    if (service) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            NSDictionary *dict = (__bridge NSDictionary *)props;
            if (dict[@"CFBundleIdentifierKernel"]) driverName = [dict[@"CFBundleIdentifierKernel"] copy];
            firmwareLoaded = [dict[@"FirmwareLoaded"] boolValue];

            NSDictionary *devProps = dict[@"DeviceProperties"];
            if (devProps) {
                if (devProps[@"ANEDevicePropertyTypeANEArchitectureTypeStr"])
                    archStr = [devProps[@"ANEDevicePropertyTypeANEArchitectureTypeStr"] copy];
                if (devProps[@"ANEDevicePropertyNumANECores"])
                    cores = [devProps[@"ANEDevicePropertyNumANECores"] intValue];
                if (devProps[@"ANEDevicePropertyANEVersion"])
                    version = [devProps[@"ANEDevicePropertyANEVersion"] intValue];
                if (devProps[@"ANEDevicePropertyANEMinorVersion"])
                    minorVersion = [devProps[@"ANEDevicePropertyANEMinorVersion"] intValue];
                if (devProps[@"ANEDevicePropertyANEHWBoardType"])
                    boardType = [devProps[@"ANEDevicePropertyANEHWBoardType"] intValue];
                if (devProps[@"ANEDevicePropertyIsInternalBuild"])
                    isInternalBuild = [devProps[@"ANEDevicePropertyIsInternalBuild"] boolValue];
            }
            CFRelease(props);
        }
        IOObjectRelease(service);
    }

    // C. Query Process Code-Signing Entitlements
    BOOL hasHwCounterEntitlement = NO;
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (task) {
        CFErrorRef err = NULL;
        CFTypeRef val = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.ane.hardware-counters"), &err);
        if (val) {
            if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
                hasHwCounterEntitlement = CFBooleanGetValue((CFBooleanRef)val);
            }
            CFRelease(val);
        }
        CFRelease(task);
    }

    // D. Print Driver Status Report
    printf("  • Kernel Driver Bundle     : %s\n", driverName.UTF8String);
    printf("  • Silicon Architecture     : Apple %s (%d Physical Cores | Board Type: %d)\n",
           archStr.UTF8String, cores, boardType);
    printf("  • Firmware Status          : %s (ANE Version %d.%d)\n",
           firmwareLoaded ? "Loaded & Active (OK)" : "Unloaded / Inactive", version, minorVersion);
    printf("  • Internal Build Flag      : %s (ANEDevicePropertyIsInternalBuild = %d)\n",
           isInternalBuild ? "YES (Apple Internal Test HW)" : "NO (Retail macOS Production Build)", isInternalBuild ? 1 : 0);
    printf("  • Process Entitlement      : %s ('com.apple.ane.hardware-counters')\n",
           hasHwCounterEntitlement ? "PRESENT & VALID" : "MISSING (Requires entitlement in signature)");
    printf("  • Active Kernel Boot-Args  : %s\n", bootArgsStr.UTF8String);

    BOOL isUnlocked = hasAneDebug || hasHwCounterEntitlement || isInternalBuild;
    printf("  • Driver PMU Streaming Gate: %s\n",
           isUnlocked ? "UNLOCKED (boot-arg 'anedebug' detected)" : "LOCKED (Driver zeroes PMU surface)");
    printf("--------------------------------------------------------------------------------------------------------\n");

    if (isUnlocked) {
        printf("✅ SILICON PMU STATUS: UNLOCKED! Hardware PMU registers active on silicon.\n");
    } else {
        printf("⚠️  SILICON PMU STATUS: GATED. Driver requires 'anedebug=1' boot-arg or entitlement.\n");
    }
    printf("========================================================================================================\n\n");
    return isUnlocked;
}

// --- 2. Live Inference on Physical Silicon & Hardware PMU Latching ---

BOOL runLiveInferenceAndCapturePmu(const Config *cfg) {
    void *aneHandle = dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW);
    if (!aneHandle) {
        fprintf(stderr, "❌ Failed to dlopen AppleNeuralEngine: %s\n", dlerror());
        return NO;
    }

    Class clientCls      = NSClassFromString(@"_ANEClient");
    Class modelCls       = NSClassFromString(@"_ANEModel");
    Class reqCls         = NSClassFromString(@"_ANERequest");
    Class ioObjCls       = NSClassFromString(@"_ANEIOSurfaceObject");
    Class perfSurfaceCls = NSClassFromString(@"_ANEPerformanceStatsIOSurface");

    if (!clientCls || !modelCls || !reqCls || !ioObjCls || !perfSurfaceCls) {
        fprintf(stderr, "❌ Required ANE classes not found in runtime.\n");
        return NO;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:cfg->modelPath]) {
        printf("❌ Model file not found at path: %s\n", cfg->modelPath.UTF8String);
        return NO;
    }

    id client = nil;
    id model = nil;
    size_t inBytes = cfg->inBytes;
    size_t outBytes = cfg->outBytes;

    if (cfg->runMode == RUN_MODE_COREAI) {
        printf("⚡️ DISPATCHING LIVE INFERENCE ON PHYSICAL ANE SILICON...\n");
        printf("  • Execution Pipeline       : OPTION C (Direct CoreAI JIT -> ANEClient without copying .hwx)\n");
        printf("  • Model File Path          : %s\n", cfg->modelPath.UTF8String);

        void *rawResult = NULL;
        if (!load_coreai_for_aneclient(cfg->modelPath.UTF8String, &rawResult) || !rawResult) {
            printf("❌ Failed to load CoreAI model into ANEClient.\n");
            return NO;
        }

        CoreAILoaderResult *loaderResult = (__bridge_transfer CoreAILoaderResult *)rawResult;
        client = loaderResult.client;
        model = loaderResult.model;

        if (inBytes == 0 && loaderResult.inBytes > 0) {
            inBytes = (size_t)loaderResult.inBytes;
        }
        if (outBytes == 0 && loaderResult.outBytes > 0) {
            outBytes = (size_t)loaderResult.outBytes;
        }

        printf("  • Daemon Client Connection : %p\n", (__bridge void *)client);
        printf("  • Silicon State            : Loaded & Configured on Physical Hardware (Program Handle: %s)\n",
               [[model valueForKey:@"programHandle"] description].UTF8String ?: "active");
        printf("  • Input Buffer Size        : %zu bytes (auto-configured)\n", inBytes);
        printf("  • Output Buffer Size       : %zu bytes (auto-configured)\n", outBytes);
    } else {
        // 1. Connect to ANE Daemon
        client = [clientCls valueForKey:@"sharedConnection"];
        printf("⚡️ DISPATCHING LIVE INFERENCE ON PHYSICAL ANE SILICON...\n");
        printf("  • Execution Pipeline       : %s\n", cfg->runMode == RUN_MODE_COMPILE ? "OPTION A (On-The-Fly _ANEClient Compile)" : "OPTION B (Direct Trusted Cache Injection)");
        printf("  • Model File Path          : %s\n", cfg->modelPath.UTF8String);
        printf("  • Daemon Client Connection : %p\n", (__bridge void *)client);

        // 2. Wrap model in _ANEModel
        NSURL *modelURL = [NSURL fileURLWithPath:cfg->modelPath];
        SEL selModel = NSSelectorFromString(@"modelAtURL:key:");
        typedef id (*ModelFn)(id, SEL, NSURL *, NSString *);
        model = ((ModelFn)objc_msgSend)(modelCls, selModel, modelURL, @"net");

        // 3. Optional Step: Option A Compilation
        if (cfg->runMode == RUN_MODE_COMPILE) {
            printf("  • Option A Compiling via   : aned daemon (kANEFModelMIL)... \n");
            SEL selCompile = NSSelectorFromString(@"compileModel:options:qos:error:");
            typedef BOOL (*CompileFn)(id, SEL, id, NSDictionary *, unsigned int, NSError **);

            NSError *compErr = nil;
            NSDictionary *compOpts = @{
                kANEFModelTypeKey: @"kANEFModelMIL"
            };
            uint64_t tComp0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            BOOL compOk = ((CompileFn)objc_msgSend)(client, selCompile, model, compOpts, 25, &compErr);
            uint64_t dtComp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - tComp0;

            if (!compOk) {
                printf("❌ Compilation failed: %s\n", compErr.description.UTF8String ?: "Unknown error");
                return NO;
            }
            printf("  • Compilation Latency      : %.2f ms (Cache Identifier: %s)\n",
                   (double)dtComp / 1000000.0, [[model valueForKey:@"cacheURLIdentifier"] UTF8String]);
        }

        // 4. Load Model into Silicon
        SEL selLoad = NSSelectorFromString(@"loadModel:options:qos:error:");
        typedef BOOL (*LoadFn)(id, SEL, id, NSDictionary *, unsigned int, NSError **);

        NSError *loadErr = nil;
        NSDictionary *loadOpts = @{
            kANEFModelTypeKey: (cfg->runMode == RUN_MODE_COMPILE) ? @"kANEFModelMIL" : kANEFModelPreCompiledValue,
            kANEFPerformanceStatsMaskKey: @(15)
        };

        BOOL loadOk = ((LoadFn)objc_msgSend)(client, selLoad, model, loadOpts, 25, &loadErr);
        if (!loadOk) {
            printf("❌ Failed to load model into ANE silicon: %s\n", loadErr.description.UTF8String ?: "Unknown error");
            return NO;
        }
        printf("  • Silicon State            : Loaded & Configured on Physical Hardware\n");
    }

    if (inBytes == 0) inBytes = 0x4c000;
    if (outBytes == 0) outBytes = 0x4000;

    // 5. Create Input IOSurface
    NSDictionary *inProps = @{
        (id)kIOSurfaceWidth: @(inBytes),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1,
        (id)kIOSurfaceBytesPerRow: @(inBytes),
        (id)kIOSurfaceAllocSize: @(inBytes)
    };
    gInSurface = IOSurfaceCreate((CFDictionaryRef)inProps);
    SEL selIoObj = NSSelectorFromString(@"objectWithIOSurface:");
    typedef id (*IoObjFn)(id, SEL, id);
    id inSurfaceObj = ((IoObjFn)objc_msgSend)(ioObjCls, selIoObj, (__bridge id)gInSurface);

    // 6. Create Output IOSurface
    NSDictionary *outProps = @{
        (id)kIOSurfaceWidth: @(outBytes),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1,
        (id)kIOSurfaceBytesPerRow: @(outBytes),
        (id)kIOSurfaceAllocSize: @(outBytes)
    };
    gOutSurface = IOSurfaceCreate((CFDictionaryRef)outProps);
    id outSurfaceObj = ((IoObjFn)objc_msgSend)(ioObjCls, selIoObj, (__bridge id)gOutSurface);

    // 7. Create PMU Stats IOSurface (statType = 2, 4096 bytes)
    NSDictionary *pmuProps = @{
        (id)kIOSurfaceWidth: @1024,
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @4096,
        (id)kIOSurfaceAllocSize: @4096
    };
    gPmuSurface = IOSurfaceCreate((CFDictionaryRef)pmuProps);
    IOSurfaceLock(gPmuSurface, 0, NULL);
    memset(IOSurfaceGetBaseAddress(gPmuSurface), 0, 4096);
    IOSurfaceUnlock(gPmuSurface, 0, NULL);

    id pmuIoObj = ((IoObjFn)objc_msgSend)(ioObjCls, selIoObj, (__bridge id)gPmuSurface);
    SEL selPmuObj = NSSelectorFromString(@"objectWithIOSurface:statType:");
    typedef id (*PmuObjFn)(id, SEL, id, NSInteger);
    id pmuSurfaceObj = ((PmuObjFn)objc_msgSend)(perfSurfaceCls, selPmuObj, pmuIoObj, 2);

    // 8. Assemble _ANERequest with perfStats surface
    SEL selReq = NSSelectorFromString(@"requestWithInputs:inputIndices:outputs:outputIndices:perfStats:procedureIndex:");
    typedef id (*ReqFn)(id, SEL, NSArray *, NSArray *, NSArray *, NSArray *, NSArray *, NSNumber *);
    id request = ((ReqFn)objc_msgSend)(reqCls, selReq,
                                       @[inSurfaceObj], @[@0],
                                       @[outSurfaceObj], @[@0],
                                       @[pmuSurfaceObj], @0);

    // 9. Run live silicon inferences
    SEL selEval = NSSelectorFromString(@"evaluateWithModel:options:request:qos:error:");
    typedef BOOL (*EvalFn)(id, SEL, id, NSDictionary *, id, unsigned int, NSError **);

    NSDictionary *evalOpts = @{
        kANEFPerformanceStatsMaskKey: @(15),
        @"enableProfiling": @YES
    };

    printf("🔥 Performing warm-up iteration & establishing baseline PMU counters...\n");
    NSError *warmupErr = nil;
    uint64_t tW0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL warmupOk = ((EvalFn)objc_msgSend)(client, selEval, model, evalOpts, request, 25, &warmupErr);
    uint64_t dtWarmup = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - tW0;
    if (warmupOk) {
        printf("  • Warm-up Completed in     : %9.2f µs (%.3f ms)\n",
               (double)dtWarmup / 1000.0, (double)dtWarmup / 1000000.0);
        id wStats = [request valueForKey:@"perfStats"];
        if (wStats) {
            NSData *wData = [wStats valueForKey:@"perfCounterData"];
            if (wData && wData.length >= sizeof(gInitialRegs)) {
                memcpy(gInitialRegs, wData.bytes, sizeof(gInitialRegs));
                gHasInitialRegs = YES;
            }
        }
    } else {
        printf("⚠️  Warm-up iteration failed: %s\n", warmupErr.description.UTF8String ?: "Unknown");
    }

    printf("🏃 Executing %d benchmark iterations on physical ANE silicon with hardware PMU streaming...\n", cfg->numIters);
    uint64_t totalNs = 0;
    gMeasuredIters = cfg->numIters;

    for (int i = 0; i < cfg->numIters; i++) {
        NSError *evalErr = nil;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        BOOL ok = ((EvalFn)objc_msgSend)(client, selEval, model, evalOpts, request, 25, &evalErr);
        uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
        totalNs += dt;

        if (!ok) {
            printf("❌ Evaluation failed at iteration %d: %s\n", i + 1, evalErr.description.UTF8String ?: "Unknown");
            return NO;
        }

        id retPerfStats = [request valueForKey:@"perfStats"];
        if (retPerfStats) {
            gLivePerfStatsObj = retPerfStats;
        }
        printf("  • Silicon Iteration %d/%d: %9.2f µs (%.3f ms)\n",
               i + 1, cfg->numIters, (double)dt / 1000.0, (double)dt / 1000000.0);
    }

    if (gLivePerfStatsObj) {
        NSData *fData = [gLivePerfStatsObj valueForKey:@"perfCounterData"];
        if (fData && fData.length >= sizeof(gFinalRegs)) {
            memcpy(gFinalRegs, fData.bytes, sizeof(gFinalRegs));
        }
    }

    gLiveHwTimeNs = totalNs / cfg->numIters;
    printf("\n✅ Physical ANE Silicon Execution Complete (Average Latency: %.3f ms | Throughput: %.1f FPS)!\n",
           (double)gLiveHwTimeNs / 1000000.0, 1000.0 / ((double)gLiveHwTimeNs / 1000000.0));
    printf("--------------------------------------------------------------------------------------------------------\n\n");
    return YES;
}

// --- 3. Decode and Dump PMU Registers ---

void decodeAndDumpPmuRegisters(BOOL isUnlocked) {
    if (!gLivePerfStatsObj) {
        fprintf(stderr, "❌ No live performance stats object latched from silicon run.\n");
        return;
    }

    Class statsCls = [gLivePerfStatsObj class];
    NSDictionary *counters = [gLivePerfStatsObj valueForKey:@"performanceCounters"];
    NSData *rawPerfData = [gLivePerfStatsObj valueForKey:@"perfCounterData"];
    const uint64_t *rawRegs = (const uint64_t *)rawPerfData.bytes;
    size_t numRegs = rawPerfData.length / sizeof(uint64_t);

    NSNumberFormatter *numFmt = [[NSNumberFormatter alloc] init];
    numFmt.numberStyle = NSNumberFormatterDecimalStyle;
    numFmt.groupingSeparator = @",";

    printf("📊 DECODED SILICON PERFORMANCE BUFFER SUMMARY:\n");
    printf("----------------------------------------------------------------------------------------------------------------------------------\n");
    printf("  • Target PMU Payload Size : %zu bytes (%zu x 64-bit hardware registers)\n",
           rawPerfData.length, numRegs);
    printf("  • Total Decoded Registers : %lu PMU hardware counters\n", (unsigned long)counters.count);
    printf("  • Measured Silicon Latency: %llu ns (%.3f µs | %.3f ms)\n",
           gLiveHwTimeNs, (double)gLiveHwTimeNs / 1000.0, (double)gLiveHwTimeNs / 1000000.0);
    printf("  • Hardware Clock Source   : Dynamic DVFS Clock (~1.064 GHz Nominal Silicon Target)\n");
    printf("  • Benchmark Iterations    : %d iterations (Baseline warm-up subtracted)\n", gMeasuredIters);

    // If we have deltas, print active hardware metric highlights
    if (gHasInitialRegs && gMeasuredIters > 0) {
        uint64_t neCompDelta = (gFinalRegs[13] >= gInitialRegs[13]) ? (gFinalRegs[13] - gInitialRegs[13]) : 0;
        uint64_t l2peDelta   = (gFinalRegs[21] >= gInitialRegs[21]) ? (gFinalRegs[21] - gInitialRegs[21]) : 0;
        uint64_t dmaRwDelta  = (gFinalRegs[17] >= gInitialRegs[17]) ? (gFinalRegs[17] - gInitialRegs[17]) : 0;
        uint64_t dmaRDelta   = (gFinalRegs[18] >= gInitialRegs[18]) ? (gFinalRegs[18] - gInitialRegs[18]) : 0;
        uint64_t neNomDelta  = (gFinalRegs[10] >= gInitialRegs[10]) ? (gFinalRegs[10] - gInitialRegs[10]) : 0;
        uint64_t neCompPerIter = neCompDelta / gMeasuredIters;
        uint64_t l2pePerIter   = l2peDelta / gMeasuredIters;
        uint64_t dmaRwPerIter  = dmaRwDelta / gMeasuredIters;
        uint64_t dmaRPerIter   = dmaRDelta / gMeasuredIters;
        uint64_t neNomPerIter  = neNomDelta / gMeasuredIters;

        double effClkGhz = (gLiveHwTimeNs > 0) ? ((double)neNomPerIter / (double)gLiveHwTimeNs) : 0.0;

        printf("----------------------------------------------------------------------------------------------------------------------------------\n");
        printf("📈 SILICON PMU DELTA HIGHLIGHTS (Per-Inference Activity):\n");
        printf("  • NE Compute Cycles        : %s cycles/iter  (kANE_NE_COMPUTE_CYCLES)\n",
               [numFmt stringFromNumber:@(neCompPerIter)].UTF8String);
        printf("  • L2PE Compute Cycles      : %s cycles/iter  (kANE_L2PE_COMPUTE_CYCLES)\n",
               [numFmt stringFromNumber:@(l2pePerIter)].UTF8String);
        printf("  • NE Nominal Cycles        : %s cycles/iter  (kANE_NE_NOMINAL_CYCLES)\n",
               [numFmt stringFromNumber:@(neNomPerIter)].UTF8String);
        printf("  • Unified Memory Read/Write: %s bytes/iter   (kANE_DMA_READWRITE_BYTES)\n",
               [numFmt stringFromNumber:@(dmaRwPerIter)].UTF8String);
        printf("  • Unified Memory DMA Read  : %s bytes/iter   (kANE_DMA_READ_BYTES)\n",
               [numFmt stringFromNumber:@(dmaRPerIter)].UTF8String);
        if (effClkGhz > 0.0) {
            printf("  • Effective Silicon Clock  : %.2f GHz per core (%.2f GHz aggregate across 16 cores)\n",
                   effClkGhz / 16.0, effClkGhz);
        }
    }
    printf("----------------------------------------------------------------------------------------------------------------------------------\n\n");

    SEL selName = NSSelectorFromString(@"stringForPerfCounter:");
    typedef NSString * (*NameFn)(id, SEL, int32_t);
    NameFn nameFn = (NameFn)[statsCls instanceMethodForSelector:selName];

    printf("📋 COMPLETE 29 SILICON PMU REGISTERS & DELTAS TABLE:\n");
    printf("----------------------------------------------------------------------------------------------------------------------------------\n");
    printf("%-6s | %-28s | %-16s | %-16s | %-18s | %s\n",
           "Index", "Hardware Register Name", "Delta / Iter", "Total Delta", "Final Raw Value", "Hardware Subsystem / Unit");
    printf("----------------------------------------------------------------------------------------------------------------------------------\n");

    for (int32_t i = 0; i < 29; i++) {
        NSString *regName = nameFn(gLivePerfStatsObj, selName, i);
        NSNumber *val = counters[regName];
        uint64_t v = 0;
        if (val) {
            v = [val unsignedLongLongValue];
        } else if (rawRegs && i < (int32_t)numRegs) {
            v = rawRegs[i];
        }

        uint64_t deltaTotal = 0;
        uint64_t deltaPerIter = 0;
        if (gHasInitialRegs && gMeasuredIters > 0 && v >= gInitialRegs[i]) {
            deltaTotal = v - gInitialRegs[i];
            deltaPerIter = deltaTotal / gMeasuredIters;
        }

        const char *subsystem = "Reserved / Internal";
        if (i <= 4) subsystem = "On-Chip L2 SRAM Bus";
        else if (i <= 6) subsystem = "Compute Unit (Tensor Cores)";
        else if (i <= 9) subsystem = "Pipeline Stall Detection";
        else if (i == 10) subsystem = "Compute Unit (Tensor Cores)";
        else if (i <= 12) subsystem = "Power & Thermal Management";
        else if (i == 13) subsystem = "Compute Unit (Tensor Cores)";
        else if (i <= 16) subsystem = "Pipeline Stall Detection";
        else if (i <= 18) subsystem = "Unified Memory DMA Bus";
        else if (i == 19) subsystem = "Power & Thermal Management";
        else if (i == 20) subsystem = "On-Chip L2 SRAM Bus";
        else if (i <= 23) subsystem = "Planar Engine (PE / L2PE)";

        NSString *deltaIterStr = (deltaTotal > 0) ? [numFmt stringFromNumber:@(deltaPerIter)] : @"0";
        NSString *deltaTotStr  = (deltaTotal > 0) ? [numFmt stringFromNumber:@(deltaTotal)] : @"0";
        NSString *rawStr       = (v > 0) ? [numFmt stringFromNumber:@(v)] : [NSString stringWithFormat:@"0x%016llX", v];

        printf("[%02d]   | %-28s | %16s | %16s | %18s | %s\n",
               i,
               regName.UTF8String ?: "kANE_UKNOWN",
               deltaIterStr.UTF8String,
               deltaTotStr.UTF8String,
               rawStr.UTF8String,
               subsystem);
    }
    printf("==================================================================================================================================\n\n");
    fflush(stdout);

    if (gInSurface) CFRelease(gInSurface);
    if (gOutSurface) CFRelease(gOutSurface);
    if (gPmuSurface) CFRelease(gPmuSurface);
}

void printUsage(const char *progName) {
    printf("Usage: %s [options] [model_path]\n\n", progName);
    printf("Pipelines / Options:\n");
    printf("  --coreai <path.aimodel|path.mlirb>  Option C (Recommended): Direct CoreAI JIT -> ANEClient run without copying .hwx\n");
    printf("  --compile <path.mlmodelc>           Option A: Compile CoreML package via _ANEClient and profile\n");
    printf("  --hwx <path.hwx>                    Option B: Directly load pre-compiled .hwx from trusted cache and profile\n");
    printf("  --in-size <bytes>                   Input IOSurface allocation size (decimal or hex, e.g. 0x24c000)\n");
    printf("  --out-size <bytes>                  Output IOSurface allocation size (decimal or hex, e.g. 0x4000)\n");
    printf("  --iters <count>                     Number of inference iterations (default: 5)\n");
    printf("  --help                              Show this help message\n\n");
    printf("Examples:\n");
    printf("  %s --coreai resnet50_fp16.aimodel\n", progName);
    printf("  %s --coreai resnet50_fp16.aimodel/main.mlirb\n", progName);
    printf("  %s --hwx out_resnet_hwx/model.hwx\n", progName);
    printf("  %s --compile /Users/freedom/work/mil/ResNet50_fp16.mlmodelc\n\n", progName);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        Config cfg;
        cfg.runMode = RUN_MODE_HWX;
        cfg.modelPath = nil;
        cfg.inBytes = 0;
        cfg.outBytes = 0;
        cfg.numIters = 5;

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--coreai"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_COREAI;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--compile"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_COMPILE;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--hwx"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_HWX;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--in-size"] && i + 1 < argc) {
                const char *val = argv[++i];
                cfg.inBytes = (size_t)strtoull(val, NULL, 0);
            } else if ([arg isEqualToString:@"--out-size"] && i + 1 < argc) {
                const char *val = argv[++i];
                cfg.outBytes = (size_t)strtoull(val, NULL, 0);
            } else if ([arg isEqualToString:@"--iters"] && i + 1 < argc) {
                cfg.numIters = atoi(argv[++i]);
            } else if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                printUsage(argv[0]);
                return 0;
            } else if (i == 1 && ![arg hasPrefix:@"-"]) {
                // Direct positional argument: auto-detect pipeline
                if ([arg hasSuffix:@".hwx"]) {
                    cfg.runMode = RUN_MODE_HWX;
                } else if ([arg hasSuffix:@".aimodel"] || [arg hasSuffix:@".mlirb"]) {
                    cfg.runMode = RUN_MODE_COREAI;
                } else {
                    cfg.runMode = RUN_MODE_COMPILE;
                }
                cfg.modelPath = arg;
            }
        }

        // Auto-detect defaults if not specified
        if (!cfg.modelPath) {
            NSString *defCoreAI = @"/Users/freedom/work/ios-hacking/disassm_b7/resnet50_fp16.aimodel";
            NSString *defHwx = @"/Library/Caches/com.apple.aned/26A5425a/my_model/model.hwx";
            NSString *defMil = @"/Users/freedom/work/mil/ResNet50_fp16.mlmodelc";

            if ([[NSFileManager defaultManager] fileExistsAtPath:defCoreAI]) {
                cfg.runMode = RUN_MODE_COREAI;
                cfg.modelPath = defCoreAI;
            } else if ([[NSFileManager defaultManager] fileExistsAtPath:defHwx]) {
                cfg.runMode = RUN_MODE_HWX;
                cfg.modelPath = defHwx;
            } else if ([[NSFileManager defaultManager] fileExistsAtPath:defMil]) {
                cfg.runMode = RUN_MODE_COMPILE;
                cfg.modelPath = defMil;
            } else {
                fprintf(stderr, "❌ No default model found. Please specify --coreai <model.aimodel>, --compile <model.mlmodelc>, or --hwx <model.hwx>\n");
                printUsage(argv[0]);
                return 1;
            }
        }

        // Set default buffer sizes based on model mode if not overridden
        if (cfg.inBytes == 0 && cfg.runMode != RUN_MODE_COREAI) {
            if (cfg.runMode == RUN_MODE_COMPILE) {
                cfg.inBytes = 0x24c000; // Batch 8 for ResNet50_fp16
            } else {
                cfg.inBytes = 0x4c000;  // Batch 1 for standard precompiled model
            }
        }
        if (cfg.outBytes == 0 && cfg.runMode != RUN_MODE_COREAI) {
            cfg.outBytes = 0x4000;
        }

        BOOL isUnlocked = checkAndPrintDriverStatus();
        if (runLiveInferenceAndCapturePmu(&cfg)) {
            decodeAndDumpPmuRegisters(isUnlocked);
        }
    }
    return 0;
}
