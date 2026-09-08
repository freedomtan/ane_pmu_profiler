//
// coreai_loader.m
// Clean Objective-C Loader for CoreAI, MPSGraph, and AppleNeuralEngine
//

#import "coreai_loader.h"
#import <mach/mach_time.h>
#import <spawn.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>

@implementation CoreAILoaderResult
@end

static NSString *getSystemANEArchitecture(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("H11ANEIn");
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) {
        matching = IOServiceMatching("AppleH16ANEInterface");
        service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    }
    NSString *archStr = nil;
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
    return archStr ?: @"h13g";
}

static size_t bytesPerElementForMPSDataType(MPSDataType dataType) {
    switch (dataType) {
        case MPSDataTypeFloat32:
        case MPSDataTypeInt32:
        case MPSDataTypeUInt32:
            return 4;
        case MPSDataTypeFloat16:
        case MPSDataTypeBFloat16:
        case MPSDataTypeInt16:
        case MPSDataTypeUInt16:
            return 2;
        case MPSDataTypeInt8:
        case MPSDataTypeUInt8:
        case MPSDataTypeBool:
            return 1;
        case MPSDataTypeInt64:
        case MPSDataTypeUInt64:
        case MPSDataTypeComplexFloat32:
            return 8;
        default:
            if ((dataType & 0xFF) >= 8) {
                return (dataType & 0xFF) / 8;
            }
            return 2;
    }
}

// Inspect tensor dimensions directly using MPSGraphExecutable
static BOOL inspectModelTensorsViaMPSGraph(NSString *mlirbPath, uint64_t *outInBytes, uint64_t *outOutBytes) {
    NSData *bytecode = [NSData dataWithContentsOfFile:mlirbPath];
    if (!bytecode) return NO;

    MPSGraphExecutableDescriptor *desc = [[MPSGraphExecutableDescriptor alloc] init];
    desc.isAICodeBytecode = YES;

    MPSGraphCompilationDescriptor *compDesc = [[MPSGraphCompilationDescriptor alloc] init];
    compDesc.preferredDevice = 2; // MPSGraphDeviceTypeANE
    desc.compilationDescriptor = compDesc;

    MPSGraphExecutable *exec = [[MPSGraphExecutable alloc] initWithMLIRBytecode:bytecode executableDescriptor:desc];
    if (!exec) return NO;

    uint64_t detectedIn = 0;
    uint64_t detectedOut = 0;

    NSArray<MPSGraphShapedType *> *inShapes = [exec getInputShapesForFunction:@"main"];
    for (MPSGraphShapedType *st in inShapes) {
        NSArray<NSNumber *> *shape = st.shape;
        uint64_t count = 1;
        for (NSNumber *n in shape) count *= [n unsignedLongLongValue];
        size_t bpe = bytesPerElementForMPSDataType(st.dataType);
        uint64_t sz = count * bpe;
        if (sz > detectedIn) detectedIn = sz;
    }

    NSArray<MPSGraphShapedType *> *outShapes = [exec getOutputShapesForFunction:@"main"];
    for (MPSGraphShapedType *st in outShapes) {
        NSArray<NSNumber *> *shape = st.shape;
        uint64_t count = 1;
        for (NSNumber *n in shape) count *= [n unsignedLongLongValue];
        size_t bpe = bytesPerElementForMPSDataType(st.dataType);
        uint64_t sz = count * bpe;
        if (sz > detectedOut) detectedOut = sz;
    }

    detectedIn = (detectedIn + 0xFFF) & ~0xFFF;
    detectedOut = (detectedOut + 0xFFF) & ~0xFFF;
    if (detectedOut < 0x4000) detectedOut = 0x4000;

    *outInBytes = detectedIn;
    *outOutBytes = detectedOut;
    return YES;
}

// Extract the deterministic ANERegionsHash from manifest.plist
static NSString *extractANERegionHashFromManifest(NSString *manifestPath) {
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    if (!manifest) return nil;

    NSDictionary *versionDict = manifest[@"Package Version"];
    for (NSString *ver in versionDict) {
        NSDictionary *pkg = versionDict[ver];
        NSDictionary *regions = pkg[@"ANERegionsHash"];
        for (NSString *arch in regions) {
            return regions[arch];
        }
    }
    return nil;
}

// Locate compiled hardware binary .hwx using deterministic region hash
static NSString *locateCompiledHWXForHash(NSString *regionHash, NSString *modelDir) {
    if (!regionHash) return nil;
    NSArray *parts = [regionHash componentsSeparatedByString:@"_"];
    if ([parts count] != 2) return nil;

    NSString *hash1 = parts[0];
    NSString *hash2 = parts[1];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Check ANE_HWX_PATH environment variable
    const char *envHwx = getenv("ANE_HWX_PATH");
    if (envHwx && strlen(envHwx) > 0) {
        NSString *envPath = [NSString stringWithUTF8String:envHwx];
        if ([fm fileExistsAtPath:envPath]) return envPath;
    }

    // 2. Check local model directory and working directory for standalone .hwx
    if (modelDir) {
        NSArray *localCandidates = @[
            [modelDir stringByAppendingPathComponent:@"model.hwx"],
            [modelDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.hwx", hash1]],
            [modelDir stringByAppendingPathComponent:@"output_host_jit/model.hwx"],
            @"model.hwx"
        ];
        for (NSString *cand in localCandidates) {
            if ([fm fileExistsAtPath:cand]) {
                return cand;
            }
        }
    }

    // 3. Check system /Library/Caches/com.apple.aned (only if readable)
    NSString *anedBase = @"/Library/Caches/com.apple.aned";
    if ([fm fileExistsAtPath:anedBase] && access([anedBase UTF8String], R_OK | X_OK) == 0) {
        NSArray *osBuilds = [fm contentsOfDirectoryAtPath:anedBase error:nil];
        for (NSString *build in osBuilds) {
            NSString *assetsCache = [NSString stringWithFormat:@"%@/%@/ModelAssetsCache", anedBase, build];
            if (![fm fileExistsAtPath:assetsCache]) continue;

            NSArray *subdirs = [fm contentsOfDirectoryAtPath:assetsCache error:nil];
            for (NSString *sub in subdirs) {
                NSString *candidate = [NSString stringWithFormat:@"%@/%@/%@/%@/model.hwx", assetsCache, sub, hash1, hash2];
                if ([fm fileExistsAtPath:candidate]) {
                    return candidate;
                }
            }
        }
    }
    return nil;
}

// Locate or generate user-space ANE bundle (.bc.mlir + compiler_options.plist) for direct unprivileged loading
static BOOL locateOrPrepareANEBundle(NSString *modelDir, NSString *mlirbFile, NSString *regionHash, NSString **outBundleDir, NSString **outRegionKey) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = @[
        [modelDir stringByAppendingPathComponent:@"output_host_jit/ane_bundle"],
        [modelDir stringByAppendingPathComponent:@"ane_bundle"]
    ];

    for (NSString *cand in candidates) {
        if ([fm fileExistsAtPath:cand]) {
            NSArray *files = [fm contentsOfDirectoryAtPath:cand error:nil];
            for (NSString *f in files) {
                if ([f hasSuffix:@".bc.mlir"]) {
                    NSString *key = [f substringToIndex:(f.length - @".bc.mlir".length)];
                    NSString *plistName = [NSString stringWithFormat:@"compiler_options_%@.plist", key];
                    if ([fm fileExistsAtPath:[cand stringByAppendingPathComponent:plistName]]) {
                        *outBundleDir = cand;
                        *outRegionKey = key;
                        return YES;
                    }
                }
            }
        }
    }

    // If not cached, trigger user-space specialization pass via MPSGraphExecutable
    NSData *bytecode = [NSData dataWithContentsOfFile:mlirbFile];
    if (!bytecode) return NO;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return NO;
    id<MTLCommandQueue> queue = [device newCommandQueue];

    MPSGraphExecutableDescriptor *desc = [[MPSGraphExecutableDescriptor alloc] init];
    desc.isAICodeBytecode = YES;
    MPSGraphCompilationDescriptor *compDesc = [[MPSGraphCompilationDescriptor alloc] init];
    compDesc.preferredDevice = 2; // MPSGraphDeviceTypeANE
    desc.compilationDescriptor = compDesc;

    MPSGraphExecutable *exec = [[MPSGraphExecutable alloc] initWithMLIRBytecode:bytecode executableDescriptor:desc];
    if (!exec) return NO;

    NSArray<MPSGraphShapedType *> *inShapes = [exec getInputShapesForFunction:@"main"];
    NSMutableArray *inputs = [NSMutableArray array];
    for (MPSGraphShapedType *st in inShapes) {
        uint64_t count = 1;
        for (NSNumber *n in st.shape) count *= [n unsignedLongLongValue];
        size_t bpe = bytesPerElementForMPSDataType(st.dataType);
        size_t bytes = (size_t)(count * bpe);
        if (bytes == 0) bytes = 0x1000;
        id<MTLBuffer> buf = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        MPSGraphTensorData *td = [[MPSGraphTensorData alloc] initWithMTLBuffer:buf shape:st.shape dataType:st.dataType];
        [inputs addObject:td];
    }

    // Run 1 warm-up dispatch to trigger MPSGraph ANE region serialization
    [exec runAsyncWithMTLCommandQueue:queue inputsArray:inputs resultsArray:nil executionDescriptor:nil];

    // Search for the generated mpsgraph-<pid>-* directory in temporary directory
    NSString *tmpBase = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.apple.MetalPerformanceShadersGraph"];
    NSString *pidPrefix = [NSString stringWithFormat:@"mpsgraph-%d-", getpid()];
    NSArray *dirs = [fm contentsOfDirectoryAtPath:tmpBase error:nil];
    NSString *foundTmpDir = nil;
    for (NSString *d in [dirs reverseObjectEnumerator]) {
        if ([d hasPrefix:pidPrefix]) {
            foundTmpDir = [tmpBase stringByAppendingPathComponent:d];
            break;
        }
    }

    if (!foundTmpDir) return NO;

    // Cache the bundle into output_host_jit/ane_bundle
    NSString *destBundle = [modelDir stringByAppendingPathComponent:@"output_host_jit/ane_bundle"];
    [fm removeItemAtPath:destBundle error:nil];
    [fm createDirectoryAtPath:destBundle withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray *tmpFiles = [fm contentsOfDirectoryAtPath:foundTmpDir error:nil];
    NSString *foundKey = nil;
    for (NSString *f in tmpFiles) {
        NSString *src = [foundTmpDir stringByAppendingPathComponent:f];
        NSString *dst = [destBundle stringByAppendingPathComponent:f];
        [fm copyItemAtPath:src toPath:dst error:nil];
        if ([f hasSuffix:@".bc.mlir"]) {
            foundKey = [f substringToIndex:(f.length - @".bc.mlir".length)];
        }
    }

    if (foundKey) {
        *outBundleDir = destBundle;
        *outRegionKey = foundKey;
        return YES;
    }

    return NO;
}

BOOL load_coreai_for_aneclient(const char *modelPath, void **outResult) {
    @autoreleasepool {
        setenv("MPSGRAPH_RUN_F32_TO_F16_PASS", "1", 1);

        NSString *pathStr = [NSString stringWithUTF8String:modelPath];
        NSURL *inputURL = [NSURL fileURLWithPath:pathStr];
        NSFileManager *fm = [NSFileManager defaultManager];

        // 1. Resolve .mlirb path
        NSString *mlirbFile = nil;
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:inputURL.path isDirectory:&isDir] && isDir) {
            NSString *candidate = [inputURL.path stringByAppendingPathComponent:@"main.mlirb"];
            if ([fm fileExistsAtPath:candidate]) {
                mlirbFile = candidate;
            }
        } else if ([[inputURL pathExtension] isEqualToString:@"mlirb"]) {
            mlirbFile = inputURL.path;
        }

        if (!mlirbFile || ![fm fileExistsAtPath:mlirbFile]) {
            fprintf(stderr, "❌ Could not find valid MLIR bytecode for: %s\n", modelPath);
            return NO;
        }

        // 2. Inspect input/output shapes directly via MPSGraphExecutable
        uint64_t detectedInBytes = 0;
        uint64_t detectedOutBytes = 0;
        if (!inspectModelTensorsViaMPSGraph(mlirbFile, &detectedInBytes, &detectedOutBytes)) {
            detectedInBytes = 0x4A000;
            detectedOutBytes = 0x4000;
        }

        // 3. Resolve host JIT package manifest directly from deterministic location
        NSString *modelDir = isDir ? inputURL.path : [inputURL.path stringByDeletingLastPathComponent];
        NSString *manifestPath = [modelDir stringByAppendingPathComponent:@"output_host_jit/main-this-delegates/MPSGraph/mpsExecutable.mpsgraphpackage/manifest.plist"];
        
        NSString *regionHash = nil;
        if ([fm fileExistsAtPath:manifestPath]) {
            regionHash = extractANERegionHashFromManifest(manifestPath);
        }

        uint64_t dtComp = 0;
        // If not found or not compiled, trigger host JIT compilation
        if (!regionHash) {
#if defined(ENABLE_SWIFT_COMPILER) && ENABLE_SWIFT_COMPILER
            uint64_t tComp0 = mach_absolute_time();
            NSString *outDir = [modelDir stringByAppendingPathComponent:@"output_host_jit"];
            [fm removeItemAtPath:outDir error:nil];

            int compRet = compile_model_for_host([mlirbFile UTF8String], [outDir UTF8String]);
            if (compRet != 0) {
                fprintf(stderr, "❌ Host JIT compilation failed (code: %d)\n", compRet);
                return NO;
            }

            mach_timebase_info_data_t tb;
            mach_timebase_info(&tb);
            dtComp = (mach_absolute_time() - tComp0) * tb.numer / tb.denom;
#else
            fprintf(stderr, "❌ CoreAI package is not pre-compiled (missing manifest.plist in output_host_jit).\n");
            fprintf(stderr, "   In-process JIT compilation is disabled in this build (built without Swift support).\n");
            fprintf(stderr, "   To enable on-the-fly CoreAI compilation, rebuild with ENABLE_SWIFT=1 (requires swift_interface_gen).\n");
            fprintf(stderr, "   Or pre-compile the model using `model_compiler_objc`.\n");
            return NO;
#endif

            if ([fm fileExistsAtPath:manifestPath]) {
                regionHash = extractANERegionHashFromManifest(manifestPath);
            }
        }

        if (!regionHash) {
            fprintf(stderr, "❌ Failed to obtain ANERegionsHash from manifest: %s\n", [manifestPath UTF8String]);
            return NO;
        }

        if (dtComp > 0) {
            printf("  • Compilation Latency      : %.2f ms\n", (double)dtComp / 1000000.0);
        } else {
            printf("  • Compilation Cache Status : HIT (Zero compilation latency)\n");
        }

        // 4. Resolve Model Execution Binary / Bundle:
        // Priority 1: Standalone .hwx (local or via environment/cache) unless FORCE_USER_SPACE_ANE_BUNDLE is set
        // Priority 2: Direct User-Space ANE Bundle (unprivileged kANEFModelANECIR)
        BOOL forceBundle = (getenv("FORCE_USER_SPACE_ANE_BUNDLE") != NULL);
        NSString *foundHWX = forceBundle ? nil : locateCompiledHWXForHash(regionHash, modelDir);
        _ANEClient *client = [_ANEClient sharedConnection];
        if (!client) {
            fprintf(stderr, "❌ Failed to get _ANEClient sharedConnection\n");
            return NO;
        }

        _ANEModel *model = nil;
        NSString *activeBundlePath = nil;

        if (foundHWX) {
            NSDictionary *hwxAttrs = [fm attributesOfItemAtPath:foundHWX error:nil];
            uint64_t hwxSize = [hwxAttrs[NSFileSize] unsignedLongLongValue];
            printf("  • Execution Mode           : Pre-Compiled Hardware Binary (.hwx)\n");
            printf("  • Host JIT Region Hash     : %s\n", [regionHash UTF8String]);
            printf("  • Compiled Hardware Binary : %s (%llu bytes)\n", [foundHWX UTF8String], hwxSize);

            NSURL *hwxURL = [NSURL fileURLWithPath:foundHWX];
            model = [_ANEModel modelAtURL:hwxURL key:@"net"];
            if (!model) {
                fprintf(stderr, "❌ Failed to create _ANEModel for .hwx\n");
                return NO;
            }

            NSError *loadErr = nil;
            NSDictionary *loadOpts = @{
                @"kANEFModelType": @"kANEFModelPreCompiled",
                @"kANEFPerformanceStatsMask": @(15)
            };

            BOOL loadOk = [client loadModel:model options:loadOpts qos:25 error:&loadErr];
            if (!loadOk) {
                fprintf(stderr, "❌ Failed to load model into ANE silicon: %s\n",
                        loadErr ? [[loadErr localizedDescription] UTF8String] : "Unknown error");
                return NO;
            }
        } else {
            NSString *bundleDir = nil;
            NSString *regionKey = nil;
            if (!locateOrPrepareANEBundle(modelDir, mlirbFile, regionHash, &bundleDir, &regionKey)) {
                fprintf(stderr, "❌ Failed to prepare user-space ANE bundle for direct loading\n");
                return NO;
            }

            printf("  • Execution Mode           : Direct Unprivileged User-Space ANE Bundle (kANEFModelANECIR)\n");
            printf("  • User-Space ANE Bundle    : %s\n", [bundleDir UTF8String]);
            printf("  • Region Key               : %s\n", [regionKey UTF8String]);
            printf("  • Host JIT Region Hash     : %s\n", [regionHash UTF8String]);

            NSURL *bundleURL = [NSURL fileURLWithPath:bundleDir];
            model = [_ANEModel modelAtURL:bundleURL key:regionKey mpsConstants:regionHash];
            if (!model) {
                fprintf(stderr, "❌ Failed to create _ANEModel for bundle\n");
                return NO;
            }

            NSString *targetArch = nil;
            NSString *plistPath = [bundleDir stringByAppendingPathComponent:[NSString stringWithFormat:@"compiler_options_%@.plist", regionKey]];
            NSDictionary *compilerOptsDict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (compilerOptsDict && compilerOptsDict.count > 0) {
                NSString *firstKey = compilerOptsDict.allKeys.firstObject;
                NSDictionary *archDict = compilerOptsDict[firstKey];
                if ([archDict isKindOfClass:[NSDictionary class]] && archDict[@"TargetArchitecture"]) {
                    targetArch = archDict[@"TargetArchitecture"];
                } else {
                    targetArch = firstKey;
                }
            }
            if (!targetArch) {
                targetArch = getSystemANEArchitecture();
            }

            NSDictionary *loadOpts = @{
                @"kANEFModelType": @"kANEFModelANECIR",
                @"kANEFCompilerOptionsFilenameKey": [NSString stringWithFormat:@"compiler_options_%@.plist", regionKey],
                @"kANEFNetPlistFilenameKey": [NSString stringWithFormat:@"%@.bc.mlir", regionKey],
                @"kANEFTargetArchitectureKey": targetArch,
                @"kANEFPerformanceStatsMask": @(15)
            };

            NSError *loadErr = nil;
            BOOL loadOk = [client loadModel:model options:loadOpts qos:25 error:&loadErr];
            if (!loadOk) {
                fprintf(stderr, "❌ Failed to load ANECIR model into ANE silicon: %s\n",
                        loadErr ? [[loadErr localizedDescription] UTF8String] : "Unknown error");
                return NO;
            }
            activeBundlePath = bundleDir;
        }

        CoreAILoaderResult *result = [[CoreAILoaderResult alloc] init];
        result.client = client;
        result.model = model;
        result.inBytes = detectedInBytes;
        result.outBytes = detectedOutBytes;
        result.hwxPath = foundHWX;
        result.bundlePath = activeBundlePath;

        *outResult = (__bridge_retained void *)result;
        return YES;
    }
}

#ifdef COREAI_LOADER_MAIN
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            printf("Usage: %s <model.aimodel | model.mlirb>\n", argv[0]);
            return 1;
        }

        printf("========================================================================================================\n");
        printf("🚀 CoreAI / MPSGraph Objective-C Standalone Loader\n");
        printf("========================================================================================================\n");

        void *resultPtr = NULL;
        BOOL ok = load_coreai_for_aneclient(argv[1], &resultPtr);
        if (!ok || !resultPtr) {
            printf("❌ Failed to load model.\n");
            return 1;
        }

        CoreAILoaderResult *res = (__bridge_transfer CoreAILoaderResult *)resultPtr;
        printf("✅ Model successfully loaded into Apple Neural Engine silicon!\n");
        printf("  • Client instance : %p\n", (__bridge void *)res.client);
        printf("  • Model instance  : %p (Program Handle: %llu)\n", (__bridge void *)res.model, res.model.programHandle);
        printf("  • Input Buffer    : %llu bytes\n", res.inBytes);
        printf("  • Output Buffer   : %llu bytes\n", res.outBytes);
        printf("========================================================================================================\n");
        return 0;
    }
}
#endif
