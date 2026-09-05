//
// coreai_loader.m
// Clean Objective-C Loader for CoreAI, MPSGraph, and AppleNeuralEngine
//

#import "coreai_loader.h"
#import <mach/mach_time.h>
#import <spawn.h>

@implementation CoreAILoaderResult
@end

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
        unsigned int dt = (unsigned int)st.dataType;
        uint64_t count = 1;
        for (NSNumber *n in shape) count *= [n unsignedLongLongValue];
        // 0x10000020: Float32 (4 bytes), 0x10000008/0x20000008: Int8/UInt8 (1 byte), 0x10000010: Float16 (2 bytes)
        uint64_t bpe = (dt == 0x10000020) ? 4 : ((dt == 0x10000008 || dt == 0x20000008) ? 1 : 2);
        uint64_t sz = count * bpe;
        if (sz > detectedIn) detectedIn = sz;
    }

    NSArray<MPSGraphShapedType *> *outShapes = [exec getOutputShapesForFunction:@"main"];
    for (MPSGraphShapedType *st in outShapes) {
        NSArray<NSNumber *> *shape = st.shape;
        unsigned int dt = (unsigned int)st.dataType;
        uint64_t count = 1;
        for (NSNumber *n in shape) count *= [n unsignedLongLongValue];
        uint64_t bpe = (dt == 0x10000020) ? 4 : ((dt == 0x10000008 || dt == 0x20000008) ? 1 : 2);
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
static NSString *locateCompiledHWXForHash(NSString *regionHash) {
    if (!regionHash) return nil;
    NSArray *parts = [regionHash componentsSeparatedByString:@"_"];
    if ([parts count] != 2) return nil;

    NSString *hash1 = parts[0];
    NSString *hash2 = parts[1];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *anedCacheRoot = @"/Library/Caches/com.apple.aned/26A5425a/ModelAssetsCache";
    NSArray *subdirs = [fm contentsOfDirectoryAtPath:anedCacheRoot error:nil];
    for (NSString *sub in subdirs) {
        NSString *candidate = [NSString stringWithFormat:@"%@/%@/%@/%@/model.hwx", anedCacheRoot, sub, hash1, hash2];
        if ([fm fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
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

            if ([fm fileExistsAtPath:manifestPath]) {
                regionHash = extractANERegionHashFromManifest(manifestPath);
            }
        }

        if (!regionHash) {
            fprintf(stderr, "❌ Failed to obtain ANERegionsHash from manifest: %s\n", [manifestPath UTF8String]);
            return NO;
        }

        // 4. Locate compiled .hwx binary in aned cache
        NSString *foundHWX = locateCompiledHWXForHash(regionHash);

        if (!foundHWX) {
            fprintf(stderr, "❌ Could not locate compiled model.hwx for region hash: %s\n", [regionHash UTF8String]);
            return NO;
        }

        NSDictionary *hwxAttrs = [fm attributesOfItemAtPath:foundHWX error:nil];
        uint64_t hwxSize = [hwxAttrs[NSFileSize] unsignedLongLongValue];
        if (dtComp > 0) {
            printf("  • Compilation Latency      : %.2f ms\n", (double)dtComp / 1000000.0);
        } else {
            printf("  • Compilation Cache Status : HIT (Zero compilation latency)\n");
        }
        printf("  • Host JIT Region Hash     : %s\n", [regionHash UTF8String]);
        printf("  • Compiled Hardware Binary : %s (%llu bytes)\n", [foundHWX UTF8String], hwxSize);

        // 5. Connect to _ANEClient and load model directly
        _ANEClient *client = [_ANEClient sharedConnection];
        if (!client) {
            fprintf(stderr, "❌ Failed to get _ANEClient sharedConnection\n");
            return NO;
        }

        NSURL *hwxURL = [NSURL fileURLWithPath:foundHWX];
        _ANEModel *model = [_ANEModel modelAtURL:hwxURL key:@"net"];
        if (!model) {
            fprintf(stderr, "❌ Failed to create _ANEModel\n");
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

        CoreAILoaderResult *result = [[CoreAILoaderResult alloc] init];
        result.client = client;
        result.model = model;
        result.inBytes = detectedInBytes;
        result.outBytes = detectedOutBytes;
        result.hwxPath = foundHWX;

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
