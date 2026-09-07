//
// dump_ane_pmu.m
// Apple Neural Engine (ANE) Silicon PMU Register Dump & Live Hardware Telemetry
//
// Supports:
//   1. CoreML Models: .mlmodel, .mlpackage, and .mlmodelc (on-the-fly compilation & ANE loading)
//   2. MIL (Model Intermediate Language): .mil or directory containing model.mil
//   3. Espresso IR: model.espresso.net (with .shape / .weights)
//   4. ANECIR: compiler_options_*.plist + *.bc.mlir / net.plist user-space bundle
//   5. Standalone Pre-compiled .hwx binaries
//   6. CoreAI: .aimodel / .mlirb via host JIT & _ANEClient
//
// Features:
//   - Automatic format detection from file extension / directory contents
//   - Dynamic multi-tensor IOSurface allocation from NetworkStatusList (LiveInputList / LiveOutputList)
//   - Driver gate status check (boot-arg 'anedebug' / com.apple.ane.hardware-counters entitlement)
//   - PMU IOSurface buffer allocation (statType = 2, 4096 bytes)
//   - Warm-up & baseline PMU latching + multi-iteration benchmarking
//   - Full decode of all 29 hardware PMU registers & delta analysis
//

#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
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

#define kANEFModelTypeKey                     @"kANEFModelType"
#define kANEFModelMILValue                    @"kANEFModelMIL"
#define kANEFModelEspressoValue               @"kANEFModelEspresso"
#define kANEFModelANECIRValue                 @"kANEFModelANECIR"
#define kANEFModelCoreMLValue                 @"kANEFModelCoreML"
#define kANEFModelPreCompiledValue            @"kANEFModelPreCompiled"
#define kANEFPerformanceStatsMaskKey          @"kANEFPerformanceStatsMask"
#define kANEFNetPlistFilenameKey              @"kANEFNetPlistFilenameKey"
#define kANEFCompilerOptionsFilenameKey       @"kANEFCompilerOptionsFilenameKey"
#define kANEFRetainModelsWithoutSourceURLKey  @"kANEFRetainModelsWithoutSourceURLKey"
#define kANEFTargetArchitectureKey            @"kANEFTargetArchitectureKey"

typedef enum {
    RUN_MODE_AUTO = 0,
    RUN_MODE_COREML,     // .mlmodel, .mlpackage, .mlmodelc
    RUN_MODE_MIL,        // .mil or directory with model.mil
    RUN_MODE_ESPRESSO,   // model.espresso.net
    RUN_MODE_ANECIR,     // compiler_options_*.plist + *.bc.mlir / net.plist
    RUN_MODE_HWX,        // Standalone pre-compiled .hwx binary
    RUN_MODE_COREAI      // CoreAI .aimodel / .mlirb via host JIT & _ANEClient
} RunMode;

typedef struct {
    RunMode runMode;            // Execution pipeline
    NSString *modelPath;        // Path to input model / directory / file
    size_t inBytes;             // Manual input IOSurface size override (0 = auto)
    size_t outBytes;            // Manual output IOSurface size override (0 = auto)
    int numIters;               // Number of inference iterations
} Config;

#import "coreai_loader.h"

// Global state for PMU latching
static NSMutableArray *gAllocatedSurfaces = nil;
static _ANEPerformanceStats *gLivePerfStatsObj = nil;
static uint64_t gLiveHwTimeNs = 0;
static uint64_t gInitialRegs[29] = { 0 };
static uint64_t gFinalRegs[29] = { 0 };
static BOOL gHasInitialRegs = NO;
static int gMeasuredIters = 0;
static NSString *gTempCleanupDir = nil;

// --- Helper: Query System ANE Architecture ---

static NSString *querySystemANEArchitecture(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("H11ANEIn");
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) {
        matching = IOServiceMatching("AppleH16ANEInterface");
        service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    }
    NSString *archStr = @"h16g";
    if (service) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            NSDictionary *dict = (__bridge NSDictionary *)props;
            NSDictionary *devProps = dict[@"DeviceProperties"];
            if (devProps && devProps[@"ANEDevicePropertyTypeANEArchitectureTypeStr"]) {
                archStr = [devProps[@"ANEDevicePropertyTypeANEArchitectureTypeStr"] copy];
            }
            CFRelease(props);
        }
        IOObjectRelease(service);
    }
    return archStr;
}

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

// --- Helper: Format human-readable bytes ---
static NSString *formatByteSize(size_t bytes) {
    if (bytes >= 1024 * 1024) {
        return [NSString stringWithFormat:@"%.2f MB (%zu bytes)", (double)bytes / (1024.0 * 1024.0), bytes];
    } else if (bytes >= 1024) {
        return [NSString stringWithFormat:@"%.2f KB (%zu bytes)", (double)bytes / 1024.0, bytes];
    }
    return [NSString stringWithFormat:@"%zu bytes", bytes];
}

// --- Helper: Compute allocation size from tensor dict ---
static size_t computeTensorAllocSize(NSDictionary *d, size_t overrideSize) {
    if (overrideSize > 0) return overrideSize;
    size_t allocSize = 0;
    if (d[@"BatchStride"] && d[@"Batches"]) {
        size_t bs = [d[@"BatchStride"] unsignedLongLongValue];
        size_t b = [d[@"Batches"] unsignedLongLongValue];
        if (b == 0) b = 1;
        allocSize = bs * b;
    } else if (d[@"PlaneStride"] && d[@"PlaneCount"]) {
        size_t ps = [d[@"PlaneStride"] unsignedLongLongValue];
        size_t p = [d[@"PlaneCount"] unsignedLongLongValue];
        if (p == 0) p = 1;
        allocSize = ps * p;
    } else if (d[@"RowStride"] && d[@"Height"]) {
        size_t rs = [d[@"RowStride"] unsignedLongLongValue];
        size_t h = [d[@"Height"] unsignedLongLongValue];
        if (h == 0) h = 1;
        allocSize = rs * h;
    }
    return (allocSize > 0) ? allocSize : 0x4000;
}

// --- Helper: Create IOSurface with given size ---
static IOSurfaceRef createIOSurfaceWithSize(size_t allocSize) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(allocSize),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1,
        (id)kIOSurfaceBytesPerRow: @(allocSize),
        (id)kIOSurfaceAllocSize: @(allocSize)
    };
    return IOSurfaceCreate((CFDictionaryRef)props);
}

// --- Auto-Detect Model Format ---

static RunMode detectModelFormat(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return RUN_MODE_AUTO;
    }

    if (isDir) {
        if ([path hasSuffix:@".mlpackage"]) {
            return RUN_MODE_COREML;
        }
        if ([path hasSuffix:@".aimodel"] || [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"main.mlirb"]]) {
            return RUN_MODE_COREAI;
        }
        if ([path hasSuffix:@".mlmodelc"]) {
            if ([fm fileExistsAtPath:[path stringByAppendingPathComponent:@"model.espresso.net"]]) {
                return RUN_MODE_ESPRESSO;
            }
            return RUN_MODE_COREML;
        }
        // Check contents of arbitrary directory
        NSArray *items = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *item in items) {
            if ([item hasPrefix:@"compiler_options_"] && [item hasSuffix:@".plist"]) {
                return RUN_MODE_ANECIR;
            }
            if ([item isEqualToString:@"model.espresso.net"]) {
                return RUN_MODE_ESPRESSO;
            }
            if ([item isEqualToString:@"model.mil"]) {
                return RUN_MODE_MIL;
            }
            if ([item isEqualToString:@"model.hwx"]) {
                return RUN_MODE_HWX;
            }
        }
        return RUN_MODE_COREML;
    } else {
        // Single file
        if ([path hasSuffix:@".mlmodel"]) {
            return RUN_MODE_COREML;
        }
        if ([path hasSuffix:@".hwx"]) {
            return RUN_MODE_HWX;
        }
        if ([path hasSuffix:@".mil"]) {
            return RUN_MODE_MIL;
        }
        if ([path hasSuffix:@".espresso.net"] || [path hasSuffix:@".net"]) {
            return RUN_MODE_ESPRESSO;
        }
        if ([path hasSuffix:@".mlirb"]) {
            return RUN_MODE_COREAI;
        }
        if ([path hasSuffix:@".plist"]) {
            return RUN_MODE_ANECIR;
        }
    }
    return RUN_MODE_COREML;
}

// --- 2. Live Inference on Physical Silicon & Hardware PMU Latching ---

BOOL runLiveInferenceAndCapturePmu(Config *cfg) {
    void *aneHandle = dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW);
    if (!aneHandle) {
        fprintf(stderr, "❌ Failed to dlopen AppleNeuralEngine: %s\n", dlerror());
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cfg->modelPath]) {
        printf("❌ Model file not found at path: %s\n", cfg->modelPath.UTF8String);
        return NO;
    }

    // Auto-detect format if set to AUTO
    if (cfg->runMode == RUN_MODE_AUTO) {
        cfg->runMode = detectModelFormat(cfg->modelPath);
    }

    _ANEClient *client = nil;
    _ANEModel *model = nil;
    gAllocatedSurfaces = [NSMutableArray array];

    printf("⚡️ PREPARING MODEL FOR PHYSICAL ANE SILICON EXECUTION...\n");
    printf("  • Target Path              : %s\n", cfg->modelPath.UTF8String);

    if (cfg->runMode == RUN_MODE_COREAI) {
        printf("  • Execution Pipeline       : CoreAI Host JIT -> Direct _ANEClient Execution\n");
        void *rawResult = NULL;
        if (!load_coreai_for_aneclient(cfg->modelPath.UTF8String, &rawResult) || !rawResult) {
            printf("❌ Failed to load CoreAI model into ANEClient.\n");
            return NO;
        }

        CoreAILoaderResult *loaderResult = (__bridge_transfer CoreAILoaderResult *)rawResult;
        client = loaderResult.client;
        model = loaderResult.model;

        if (cfg->inBytes == 0 && loaderResult.inBytes > 0) {
            cfg->inBytes = (size_t)loaderResult.inBytes;
        }
        if (cfg->outBytes == 0 && loaderResult.outBytes > 0) {
            cfg->outBytes = (size_t)loaderResult.outBytes;
        }
    } else if (cfg->runMode == RUN_MODE_HWX) {
        printf("  • Execution Pipeline       : Pre-Compiled Hardware Binary (.hwx)\n");
        client = [_ANEClient sharedConnection];
        NSURL *hwxURL = [NSURL fileURLWithPath:cfg->modelPath];
        model = [_ANEModel modelAtURL:hwxURL key:@"net"];
        if (!model) {
            printf("❌ Failed to instantiate _ANEModel for %s\n", cfg->modelPath.UTF8String);
            return NO;
        }

        NSError *loadErr = nil;
        NSDictionary *loadOpts = @{
            kANEFModelTypeKey: kANEFModelPreCompiledValue,
            kANEFPerformanceStatsMaskKey: @(15)
        };
        BOOL loadOk = [client loadModel:model options:loadOpts qos:25 error:&loadErr];
        if (!loadOk) {
            printf("❌ Failed to load .hwx into ANE silicon: %s\n", loadErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
    } else if (cfg->runMode == RUN_MODE_COREML) {
        client = [_ANEClient sharedConnection];
        NSString *modelcDir = cfg->modelPath;

        // If .mlmodel or .mlpackage, compile via CoreML to temporary .mlmodelc
        if ([cfg->modelPath hasSuffix:@".mlmodel"] || [cfg->modelPath hasSuffix:@".mlpackage"]) {
            printf("  • CoreML Compilation      : On-the-fly compiling via MLModel...\n");
            uint64_t tComp0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            NSError *compErr = nil;
            NSURL *compiledURL = [MLModel compileModelAtURL:[NSURL fileURLWithPath:cfg->modelPath] error:&compErr];
            uint64_t dtComp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - tComp0;

            if (!compiledURL) {
                printf("❌ CoreML compilation failed: %s\n", compErr.localizedDescription.UTF8String ?: "Unknown");
                return NO;
            }
            printf("  • CoreML Compilation Time : %.2f ms -> %s\n",
                   (double)dtComp / 1000000.0, compiledURL.path.UTF8String);
            modelcDir = compiledURL.path;
            gTempCleanupDir = modelcDir;
        }

        // Check format inside .mlmodelc
        NSString *modelType = kANEFModelMILValue;
        if ([fm fileExistsAtPath:[modelcDir stringByAppendingPathComponent:@"model.espresso.net"]]) {
            modelType = kANEFModelEspressoValue;
        }
        printf("  • Model Format Detected    : %s inside %s\n", modelType.UTF8String, modelcDir.lastPathComponent.UTF8String);

        model = [_ANEModel modelAtURL:[NSURL fileURLWithPath:modelcDir] key:@"net"];
        if (!model) {
            printf("❌ Failed to create _ANEModel at %s\n", modelcDir.UTF8String);
            return NO;
        }

        printf("  • ANE Compiler Service     : Compiling via aned daemon (%s)...\n", modelType.UTF8String);
        uint64_t tAne0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSError *aneCompErr = nil;
        NSDictionary *compOpts = @{ kANEFModelTypeKey: modelType };
        BOOL compOk = [client compileModel:model options:compOpts qos:25 error:&aneCompErr];
        uint64_t dtAne = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - tAne0;
        if (!compOk) {
            printf("❌ ANE compilation failed: %s\n", aneCompErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
        printf("  • ANE Compilation Latency  : %.2f ms\n", (double)dtAne / 1000000.0);

        NSError *loadErr = nil;
        NSDictionary *loadOpts = @{
            kANEFModelTypeKey: modelType,
            kANEFPerformanceStatsMaskKey: @(15)
        };
        BOOL loadOk = [client loadModel:model options:loadOpts qos:25 error:&loadErr];
        if (!loadOk) {
            printf("❌ Failed to load compiled model into ANE silicon: %s\n", loadErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
    } else if (cfg->runMode == RUN_MODE_MIL) {
        printf("  • Execution Pipeline       : Model Intermediate Language (MIL)\n");
        client = [_ANEClient sharedConnection];
        NSString *modelDir = cfg->modelPath;
        BOOL isDir = NO;
        [fm fileExistsAtPath:cfg->modelPath isDirectory:&isDir];

        if (!isDir) {
            // Standalone .mil file
            if ([cfg->modelPath.lastPathComponent isEqualToString:@"model.mil"]) {
                modelDir = [cfg->modelPath stringByDeletingLastPathComponent];
            } else {
                // Stage into temp directory as model.mil
                char tempTemplate[] = "/tmp/ane_mil_staging_XXXXXX";
                char *tempPath = mkdtemp(tempTemplate);
                if (!tempPath) {
                    printf("❌ Failed to create temporary staging directory for MIL\n");
                    return NO;
                }
                NSString *stageDir = [NSString stringWithUTF8String:tempPath];
                NSString *stagedMil = [stageDir stringByAppendingPathComponent:@"model.mil"];
                NSError *copyErr = nil;
                [fm copyItemAtPath:cfg->modelPath toPath:stagedMil error:&copyErr];
                modelDir = stageDir;
                gTempCleanupDir = stageDir;
                printf("  • Staged MIL Model         : %s -> %s\n", cfg->modelPath.UTF8String, stagedMil.UTF8String);
            }
        }

        model = [_ANEModel modelAtURL:[NSURL fileURLWithPath:modelDir] key:@"net"];
        if (!model) {
            printf("❌ Failed to create _ANEModel for MIL directory: %s\n", modelDir.UTF8String);
            return NO;
        }

        printf("  • ANE Compiler Service     : Compiling MIL via aned daemon...\n");
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSError *compErr = nil;
        NSDictionary *compOpts = @{ kANEFModelTypeKey: kANEFModelMILValue };
        BOOL compOk = [client compileModel:model options:compOpts qos:25 error:&compErr];
        uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
        if (!compOk) {
            printf("❌ MIL compilation failed: %s\n", compErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
        printf("  • MIL Compilation Latency  : %.2f ms\n", (double)dt / 1000000.0);

        NSError *loadErr = nil;
        NSDictionary *loadOpts = @{
            kANEFModelTypeKey: kANEFModelMILValue,
            kANEFPerformanceStatsMaskKey: @(15)
        };
        BOOL loadOk = [client loadModel:model options:loadOpts qos:25 error:&loadErr];
        if (!loadOk) {
            printf("❌ Failed to load MIL model into ANE silicon: %s\n", loadErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
    } else if (cfg->runMode == RUN_MODE_ESPRESSO) {
        printf("  • Execution Pipeline       : Espresso IR (model.espresso.net)\n");
        client = [_ANEClient sharedConnection];
        NSString *modelDir = cfg->modelPath;
        BOOL isDir = NO;
        [fm fileExistsAtPath:cfg->modelPath isDirectory:&isDir];
        if (!isDir) {
            modelDir = [cfg->modelPath stringByDeletingLastPathComponent];
        }

        model = [_ANEModel modelAtURL:[NSURL fileURLWithPath:modelDir] key:@"net"];
        if (!model) {
            printf("❌ Failed to create _ANEModel for Espresso directory: %s\n", modelDir.UTF8String);
            return NO;
        }

        printf("  • ANE Compiler Service     : Compiling Espresso IR via aned daemon...\n");
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSError *compErr = nil;
        NSDictionary *compOpts = @{ kANEFModelTypeKey: kANEFModelEspressoValue };
        BOOL compOk = [client compileModel:model options:compOpts qos:25 error:&compErr];
        uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
        if (!compOk) {
            printf("❌ Espresso compilation failed: %s\n", compErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
        printf("  • Espresso Comp Latency    : %.2f ms\n", (double)dt / 1000000.0);

        NSError *loadErr = nil;
        NSDictionary *loadOpts = @{
            kANEFModelTypeKey: kANEFModelEspressoValue,
            kANEFPerformanceStatsMaskKey: @(15)
        };
        BOOL loadOk = [client loadModel:model options:loadOpts qos:25 error:&loadErr];
        if (!loadOk) {
            printf("❌ Failed to load Espresso model into ANE silicon: %s\n", loadErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
    } else if (cfg->runMode == RUN_MODE_ANECIR) {
        printf("  • Execution Pipeline       : Direct Unprivileged ANECIR Bundle (kANEFModelANECIR)\n");
        client = [_ANEClient sharedConnection];
        NSString *bundleDir = cfg->modelPath;
        BOOL isDir = NO;
        [fm fileExistsAtPath:cfg->modelPath isDirectory:&isDir];
        if (!isDir) {
            bundleDir = [cfg->modelPath stringByDeletingLastPathComponent];
        }

        // Discover compiler_options_*.plist and net file
        NSString *regionKey = @"net";
        NSString *compilerOptionsFile = nil;
        NSString *netFile = nil;

        NSArray *entries = [fm contentsOfDirectoryAtPath:bundleDir error:nil];
        for (NSString *entry in entries) {
            if ([entry hasPrefix:@"compiler_options_"] && [entry hasSuffix:@".plist"]) {
                compilerOptionsFile = entry;
                NSString *sub = [entry substringFromIndex:17]; // strip "compiler_options_"
                regionKey = [sub substringToIndex:sub.length - 6]; // strip ".plist"
            }
        }

        if (compilerOptionsFile) {
            NSString *candidateMlir = [NSString stringWithFormat:@"%@.bc.mlir", regionKey];
            NSString *candidatePlist = [NSString stringWithFormat:@"%@.plist", regionKey];
            if ([entries containsObject:candidateMlir]) {
                netFile = candidateMlir;
            } else if ([entries containsObject:candidatePlist]) {
                netFile = candidatePlist;
            }
        }

        if (!netFile) {
            if ([entries containsObject:@"net.plist"]) netFile = @"net.plist";
            else if ([entries containsObject:@"model.plist"]) netFile = @"model.plist";
        }

        if (!compilerOptionsFile || !netFile) {
            printf("❌ Could not locate matching compiler_options_*.plist and net file in %s\n", bundleDir.UTF8String);
            return NO;
        }

        printf("  • ANECIR Bundle Directory  : %s\n", bundleDir.UTF8String);
        printf("  • Region Key               : %s\n", regionKey.UTF8String);
        printf("  • Compiler Options File    : %s\n", compilerOptionsFile.UTF8String);
        printf("  • Net Representation File  : %s\n", netFile.UTF8String);

        // Prioritize actual physical host silicon architecture for ANECIR
        NSString *targetArch = querySystemANEArchitecture();
        if (!targetArch || targetArch.length == 0) {
            targetArch = @"h16g";
        }
        printf("  • Target Architecture      : %s\n", targetArch.UTF8String);

        NSURL *bundleURL = [NSURL fileURLWithPath:bundleDir];
        model = [_ANEModel modelAtURL:bundleURL key:regionKey mpsConstants:@"constants"];
        if (!model) {
            printf("❌ Failed to create _ANEModel for ANECIR bundle: %s\n", bundleDir.UTF8String);
            return NO;
        }

        NSDictionary *loadOpts = @{
            kANEFModelTypeKey: kANEFModelANECIRValue,
            kANEFCompilerOptionsFilenameKey: compilerOptionsFile,
            kANEFNetPlistFilenameKey: netFile,
            kANEFTargetArchitectureKey: targetArch,
            kANEFPerformanceStatsMaskKey: @(15),
            kANEFRetainModelsWithoutSourceURLKey: @1
        };

        NSError *loadErr = nil;
        BOOL loadOk = [client loadModel:model options:loadOpts qos:25 error:&loadErr];
        if (!loadOk) {
            printf("❌ Failed to load ANECIR model into ANE silicon: %s\n", loadErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }
    }

    printf("  • Daemon Client Connection : %p\n", (__bridge void *)client);
    printf("  • Silicon State            : Loaded & Configured on Physical Hardware\n");

    // --- 3. Dynamic Tensor Shape Extraction & Multi-Surface Allocation ---

    NSMutableArray *inSurfaceObjs = [NSMutableArray array];
    NSMutableArray *inIndices = [NSMutableArray array];
    NSMutableArray *outSurfaceObjs = [NSMutableArray array];
    NSMutableArray *outIndices = [NSMutableArray array];

    NSDictionary *attrs = model.modelAttributes;
    NSArray *netStatusList = attrs[@"NetworkStatusList"];
    NSArray *liveInputs = (netStatusList.count > 0) ? netStatusList[0][@"LiveInputList"] : nil;
    NSArray *liveOutputs = (netStatusList.count > 0) ? netStatusList[0][@"LiveOutputList"] : nil;

    printf("\n📐 HARDWARE TENSOR SURFACE CONFIGURATION:\n");
    printf("--------------------------------------------------------------------------------------------------------\n");

    if (liveInputs && liveInputs.count > 0) {
        for (NSUInteger i = 0; i < liveInputs.count; i++) {
            NSDictionary *d = liveInputs[i];
            size_t allocSize = computeTensorAllocSize(d, (liveInputs.count == 1) ? cfg->inBytes : 0);
            IOSurfaceRef s = createIOSurfaceWithSize(allocSize);
            [gAllocatedSurfaces addObject:(__bridge id)s];
            [inSurfaceObjs addObject:[_ANEIOSurfaceObject objectWithIOSurface:s]];
            [inIndices addObject:@(i)];

            NSString *name = d[@"Name"] ?: d[@"Symbol"] ?: [NSString stringWithFormat:@"input_%lu", i];
            NSString *type = d[@"Type"] ?: @"Float16";
            NSNumber *b = d[@"Batches"] ?: @1;
            NSNumber *c = d[@"Channels"] ?: @1;
            NSNumber *h = d[@"Height"] ?: @1;
            NSNumber *w = d[@"Width"] ?: @1;
            printf("  • Input  #%lu : %-26s | Shape: [%s, %s, %s, %s] | Type: %-7s | %s\n",
                   i, name.UTF8String, b.stringValue.UTF8String, c.stringValue.UTF8String,
                   h.stringValue.UTF8String, w.stringValue.UTF8String, type.UTF8String,
                   formatByteSize(allocSize).UTF8String);
        }
    } else {
        // Fallback for models without NetworkStatusList (e.g. bare .hwx)
        size_t allocSize = (cfg->inBytes > 0) ? cfg->inBytes : 0x4c000;
        IOSurfaceRef s = createIOSurfaceWithSize(allocSize);
        [gAllocatedSurfaces addObject:(__bridge id)s];
        [inSurfaceObjs addObject:[_ANEIOSurfaceObject objectWithIOSurface:s]];
        [inIndices addObject:@0];
        printf("  • Input  #0 : default_input              | Shape: [Auto / Raw]            | Type: Raw     | %s\n",
               formatByteSize(allocSize).UTF8String);
    }

    if (liveOutputs && liveOutputs.count > 0) {
        for (NSUInteger i = 0; i < liveOutputs.count; i++) {
            NSDictionary *d = liveOutputs[i];
            size_t allocSize = computeTensorAllocSize(d, (liveOutputs.count == 1) ? cfg->outBytes : 0);
            IOSurfaceRef s = createIOSurfaceWithSize(allocSize);
            [gAllocatedSurfaces addObject:(__bridge id)s];
            [outSurfaceObjs addObject:[_ANEIOSurfaceObject objectWithIOSurface:s]];
            [outIndices addObject:@(i)];

            NSString *name = d[@"Name"] ?: d[@"Symbol"] ?: [NSString stringWithFormat:@"output_%lu", i];
            NSString *type = d[@"Type"] ?: @"Float16";
            NSNumber *b = d[@"Batches"] ?: @1;
            NSNumber *c = d[@"Channels"] ?: @1;
            NSNumber *h = d[@"Height"] ?: @1;
            NSNumber *w = d[@"Width"] ?: @1;
            printf("  • Output #%lu : %-26s | Shape: [%s, %s, %s, %s] | Type: %-7s | %s\n",
                   i, name.UTF8String, b.stringValue.UTF8String, c.stringValue.UTF8String,
                   h.stringValue.UTF8String, w.stringValue.UTF8String, type.UTF8String,
                   formatByteSize(allocSize).UTF8String);
        }
    } else {
        size_t allocSize = (cfg->outBytes > 0) ? cfg->outBytes : 0x4000;
        IOSurfaceRef s = createIOSurfaceWithSize(allocSize);
        [gAllocatedSurfaces addObject:(__bridge id)s];
        [outSurfaceObjs addObject:[_ANEIOSurfaceObject objectWithIOSurface:s]];
        [outIndices addObject:@0];
        printf("  • Output #0 : default_output             | Shape: [Auto / Raw]            | Type: Raw     | %s\n",
               formatByteSize(allocSize).UTF8String);
    }
    printf("--------------------------------------------------------------------------------------------------------\n\n");

    // --- 4. Create PMU Stats IOSurface (statType = 2, 4096 bytes) ---
    IOSurfaceRef pmuSurface = createIOSurfaceWithSize(4096);
    [gAllocatedSurfaces addObject:(__bridge id)pmuSurface];
    IOSurfaceLock(pmuSurface, 0, NULL);
    memset(IOSurfaceGetBaseAddress(pmuSurface), 0, 4096);
    IOSurfaceUnlock(pmuSurface, 0, NULL);

    _ANEIOSurfaceObject *pmuIoObj = [_ANEIOSurfaceObject objectWithIOSurface:pmuSurface];
    _ANEPerformanceStatsIOSurface *pmuSurfaceObj = [_ANEPerformanceStatsIOSurface objectWithIOSurface:pmuIoObj statType:2];

    // --- 5. Assemble _ANERequest ---
    _ANERequest *request = [_ANERequest requestWithInputs:inSurfaceObjs
                                             inputIndices:inIndices
                                                  outputs:outSurfaceObjs
                                            outputIndices:outIndices
                                                perfStats:@[pmuSurfaceObj]
                                           procedureIndex:@0];

    // --- 6. Warm-up & Baseline PMU Latching ---
    NSDictionary *evalOpts = @{
        kANEFPerformanceStatsMaskKey: @(15),
        @"enableProfiling": @YES
    };

    printf("🔥 Performing warm-up iteration & establishing baseline PMU counters...\n");
    NSError *warmupErr = nil;
    uint64_t tW0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL warmupOk = [client evaluateWithModel:model options:evalOpts request:request qos:25 error:&warmupErr];
    uint64_t dtWarmup = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - tW0;

    if (warmupOk) {
        printf("  • Warm-up Completed in     : %9.2f µs (%.3f ms)\n",
               (double)dtWarmup / 1000.0, (double)dtWarmup / 1000000.0);
        _ANEPerformanceStats *wStats = request.perfStats;
        if (wStats) {
            NSData *wData = wStats.perfCounterData;
            if (wData && wData.length >= sizeof(gInitialRegs)) {
                memcpy(gInitialRegs, wData.bytes, sizeof(gInitialRegs));
                gHasInitialRegs = YES;
            }
        }
    } else {
        printf("⚠️  Warm-up iteration failed: %s\n", warmupErr.localizedDescription.UTF8String ?: "Unknown");
    }

    // --- 7. Benchmark Iterations with Live PMU Streaming ---
    printf("🏃 Executing %d benchmark iterations on physical ANE silicon with hardware PMU streaming...\n", cfg->numIters);
    uint64_t totalNs = 0;
    gMeasuredIters = cfg->numIters;

    for (int i = 0; i < cfg->numIters; i++) {
        NSError *evalErr = nil;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        BOOL ok = [client evaluateWithModel:model options:evalOpts request:request qos:25 error:&evalErr];
        uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
        totalNs += dt;

        if (!ok) {
            printf("❌ Evaluation failed at iteration %d: %s\n", i + 1, evalErr.localizedDescription.UTF8String ?: "Unknown");
            return NO;
        }

        _ANEPerformanceStats *retPerfStats = request.perfStats;
        if (retPerfStats) {
            gLivePerfStatsObj = retPerfStats;
        }
        printf("  • Silicon Iteration %d/%d: %9.2f µs (%.3f ms)\n",
               i + 1, cfg->numIters, (double)dt / 1000.0, (double)dt / 1000000.0);
    }

    if (gLivePerfStatsObj) {
        NSData *fData = gLivePerfStatsObj.perfCounterData;
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

    NSDictionary *counters = gLivePerfStatsObj.performanceCounters;
    NSData *rawPerfData = gLivePerfStatsObj.perfCounterData;
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

    // Delta Highlights
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
        printf("  • Neural Engine Compute Cycles : %s cycles/iter  (kANE_NE_COMPUTE_CYCLES)\n",
               [numFmt stringFromNumber:@(neCompPerIter)].UTF8String);
        printf("  • L2PE Compute Cycles          : %s cycles/iter  (kANE_L2PE_COMPUTE_CYCLES)\n",
               [numFmt stringFromNumber:@(l2pePerIter)].UTF8String);
        printf("  • Neural Engine Nominal Cycles : %s cycles/iter  (kANE_NE_NOMINAL_CYCLES)\n",
               [numFmt stringFromNumber:@(neNomPerIter)].UTF8String);
        printf("  • Unified Memory Read/Write    : %s bytes/iter   (kANE_DMA_READWRITE_BYTES)\n",
               [numFmt stringFromNumber:@(dmaRwPerIter)].UTF8String);
        printf("  • Unified Memory DMA Read      : %s bytes/iter   (kANE_DMA_READ_BYTES)\n",
               [numFmt stringFromNumber:@(dmaRPerIter)].UTF8String);
        if (effClkGhz > 0.0) {
            printf("  • Effective Silicon Clock      : %.2f GHz per core (%.2f GHz aggregate across 16 cores)\n",
                   effClkGhz / 16.0, effClkGhz);
        }
    }
    printf("----------------------------------------------------------------------------------------------------------------------------------\n\n");

    printf("📋 COMPLETE 29 SILICON PMU REGISTERS & DELTAS TABLE:\n");
    printf("----------------------------------------------------------------------------------------------------------------------------------\n");
    printf("%-6s | %-28s | %-16s | %-16s | %-18s | %s\n",
           "Index", "Hardware Register Name", "Delta / Iter", "Total Delta", "Final Raw Value", "Hardware Subsystem / Unit");
    printf("----------------------------------------------------------------------------------------------------------------------------------\n");

    for (int32_t i = 0; i < 29; i++) {
        NSString *regName = [gLivePerfStatsObj stringForPerfCounter:i];
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
        else if (i <= 6) subsystem = "Neural Engine (Convolution Engine)";
        else if (i <= 9) subsystem = "Pipeline Stall Detection";
        else if (i == 10) subsystem = "Neural Engine (Clock / Baseline)";
        else if (i <= 12) subsystem = "Power & Thermal Management";
        else if (i == 13) subsystem = "Neural Engine (Convolution Engine)";
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

    // Clean up allocated surfaces
    for (id obj in gAllocatedSurfaces) {
        CFRelease((__bridge CFTypeRef)obj);
    }
    [gAllocatedSurfaces removeAllObjects];

    // Clean up temporary compilation directory if created
    if (gTempCleanupDir) {
        [[NSFileManager defaultManager] removeItemAtPath:gTempCleanupDir error:nil];
        gTempCleanupDir = nil;
    }
}

void printUsage(const char *progName) {
    printf("========================================================================================================\n");
    printf("ANE SILICON PMU PROFILER & TELEMETRY TOOL\n");
    printf("========================================================================================================\n");
    printf("Usage: %s [options] <model_path>\n\n", progName);
    printf("Supported Model Input Formats (Auto-detected or via flags):\n");
    printf("  1. CoreML Models       : .mlmodel, .mlpackage, .mlmodelc\n");
    printf("  2. MIL Models          : .mil, or directory containing model.mil\n");
    printf("  3. Espresso IR         : model.espresso.net (with .shape / .weights), or .mlmodelc\n");
    printf("  4. ANECIR Bundles      : compiler_options_*.plist + *.bc.mlir / net.plist\n");
    printf("  5. Pre-compiled HWX    : standalone .hwx binary\n");
    printf("  6. CoreAI Graphs       : .aimodel package or .mlirb graph\n\n");
    printf("Options:\n");
    printf("  --coreml <path>        Profile CoreML model (.mlmodel, .mlpackage, or .mlmodelc)\n");
    printf("  --mil <path>           Profile MIL model (.mil file or directory containing model.mil)\n");
    printf("  --espresso <path>      Profile Espresso IR (model.espresso.net or directory)\n");
    printf("  --anecir <path>        Profile unprivileged user-space ANECIR bundle directory\n");
    printf("  --hwx <path>           Profile pre-compiled hardware binary (.hwx)\n");
    printf("  --coreai <path>        Profile CoreAI package (.aimodel) or MLIR bytecode (.mlirb)\n");
    printf("  --compile <path>       Compile and load model via _ANEClient and profile\n");
    printf("  --in-size <bytes>      Override input IOSurface size (hex e.g. 0x24c000, or decimal)\n");
    printf("  --out-size <bytes>     Override output IOSurface size (hex e.g. 0x4000, or decimal)\n");
    printf("  --iters <count>        Number of benchmark iterations (default: 5)\n");
    printf("  -h, --help             Display this help guide\n\n");
    printf("Examples:\n");
    printf("  %s ResNet50_fp16.mlmodelc\n", progName);
    printf("  %s MobilenetV4_Large.mlpackage\n", progName);
    printf("  %s MobileDet.mlmodel\n", progName);
    printf("  %s /path/to/model.mil\n", progName);
    printf("  %s MobileNetV2.mlmodelc/model.espresso.net\n", progName);
    printf("  %s --anecir resnet50_fp16.aimodel/output_host_jit/ane_bundle\n", progName);
    printf("  %s --hwx model.hwx\n", progName);
    printf("  %s --coreai resnet50_fp16.aimodel\n\n", progName);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        Config cfg;
        cfg.runMode = RUN_MODE_AUTO;
        cfg.modelPath = nil;
        cfg.inBytes = 0;
        cfg.outBytes = 0;
        cfg.numIters = 5;

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--coreml"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_COREML;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--mil"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_MIL;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--espresso"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_ESPRESSO;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--anecir"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_ANECIR;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--coreai"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_COREAI;
                cfg.modelPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--compile"] && i + 1 < argc) {
                cfg.runMode = RUN_MODE_COREML;
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
            } else if (![arg hasPrefix:@"-"] && !cfg.modelPath) {
                cfg.modelPath = arg;
            }
        }

        // Auto-detect default if not specified
        if (!cfg.modelPath) {
            NSString *defCoreAI = @"resnet50_fp16.aimodel";
            NSString *defHwx = @"model.hwx";
            NSString *defMil = @"ResNet50_fp16.mlmodelc";

            if ([[NSFileManager defaultManager] fileExistsAtPath:defCoreAI]) {
                cfg.runMode = RUN_MODE_COREAI;
                cfg.modelPath = defCoreAI;
            } else if ([[NSFileManager defaultManager] fileExistsAtPath:defHwx]) {
                cfg.runMode = RUN_MODE_HWX;
                cfg.modelPath = defHwx;
            } else if ([[NSFileManager defaultManager] fileExistsAtPath:defMil]) {
                cfg.runMode = RUN_MODE_COREML;
                cfg.modelPath = defMil;
            } else {
                fprintf(stderr, "❌ No model path specified.\n\n");
                printUsage(argv[0]);
                return 1;
            }
        }

        if (cfg.runMode == RUN_MODE_AUTO) {
            cfg.runMode = detectModelFormat(cfg.modelPath);
        }

        BOOL isUnlocked = checkAndPrintDriverStatus();
        if (runLiveInferenceAndCapturePmu(&cfg)) {
            decodeAndDumpPmuRegisters(isUnlocked);
        }
    }
    return 0;
}
