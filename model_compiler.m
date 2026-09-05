//
// model_compiler.m
// Objective-C CLI tool for CoreAI Host-Specialized JIT Compilation
//

#import <Foundation/Foundation.h>
#import "model_compiler.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            printf("Usage: %s <input.mlirb> [outputDir]\n", argv[0]);
            return 1;
        }

        const char *inputPath = argv[1];
        const char *outputPath = (argc > 2) ? argv[2] : "output_host_jit";

        printf("========================================================================================================\n");
        printf("🚀 CoreAI Host-Specialized JIT Compiler (Objective-C)\n");
        printf("========================================================================================================\n");
        printf("  • Target SOC           : this (Host Architecture)\n");
        printf("  • Input Bytecode       : %s\n", inputPath);
        printf("  • Output Package       : %s\n", outputPath);
        printf("  • Preferred Device     : Apple Neural Engine (ANE)\n");

        int ret = compile_model_for_host(inputPath, outputPath);
        if (ret != 0) {
            fprintf(stderr, "❌ Model compilation failed (error: %d)\n", ret);
            return 1;
        }

        printf("✅ Model compilation finished successfully!\n");
        NSString *manifest = [NSString stringWithFormat:@"%s/main-this-delegates/MPSGraph/mpsExecutable.mpsgraphpackage/manifest.plist", outputPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:manifest]) {
            NSDictionary *manifestDict = [NSDictionary dictionaryWithContentsOfFile:manifest];
            NSDictionary *versionDict = manifestDict[@"Package Version"];
            for (NSString *ver in versionDict) {
                NSDictionary *pkg = versionDict[ver];
                NSDictionary *regions = pkg[@"ANERegionsHash"];
                for (NSString *arch in regions) {
                    printf("  • Target Architecture  : %s\n", [arch UTF8String]);
                    printf("  • ANERegionsHash       : %s\n", [regions[arch] UTF8String]);
                }
            }
        }
        printf("========================================================================================================\n");
        return 0;
    }
}
