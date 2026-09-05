//
// odiec_pipeline.c
// Pure C Implementation of the libODIECompiler Pass Pipeline
//

#include "odiec_pipeline.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

static odiec_api_t g_odiec;
static bool g_initialized = false;

bool odiec_pipeline_init(odiec_api_t *outApi) {
    if (g_initialized) {
        if (outApi) *outApi = g_odiec;
        return true;
    }

    void *h = dlopen("/System/Library/PrivateFrameworks/ODIE.framework/Versions/A/Frameworks/libODIECompiler.dylib", RTLD_NOW);
    if (!h) {
        h = dlopen("/System/Library/SubFrameworks/CoreAICompiler.framework/Versions/A/Frameworks/libODIECompiler.dylib", RTLD_NOW);
    }
    if (!h) {
        fprintf(stderr, "❌ Failed to dlopen libODIECompiler.dylib\n");
        return false;
    }

    typedef odiec_api_t (*init_fn_t)(void);
    init_fn_t init_fn = (init_fn_t)dlsym(h, "odiec_initialize");
    if (!init_fn) {
        fprintf(stderr, "❌ Failed to find odiec_initialize in libODIECompiler\n");
        return false;
    }

    g_odiec = init_fn();
    g_initialized = true;
    if (outApi) *outApi = g_odiec;
    return true;
}

int odiec_pipeline_execute(const void *mlirbBytes, size_t mlirbSize, const char *outputDirectory) {
    if (!g_initialized && !odiec_pipeline_init(NULL)) {
        return -1;
    }

    // 1. Create context
    odiec_context_t ctx = g_odiec.create_context();
    if (!ctx) return -1;

    // 2. Wrap MLIR bytecode into odiec_bytecode_blob
    odiec_bytecode_blob_t blob = g_odiec.create_bytecode_blob();
    g_odiec.set_buffer(blob, mlirbBytes, (long long)mlirbSize);

    // 3. Construct module from bytecode
    odiec_module_t mod = g_odiec.create_module_from_bytecode(ctx, &blob, false);
    if (!mod) {
        g_odiec.destroy_context(ctx);
        return -2;
    }

    // 4. Create global compilation options
    odiec_global_options_t opts = g_odiec.create_global_options();
    if (outputDirectory) {
        g_odiec.set_output_directory(opts, outputDirectory, (long long)strlen(outputDirectory));
    }

    // 5. Setup Pass Pipeline:
    // CoreAI Host JIT pass pipeline sequence:
    // 1. "convert-from-versioned"
    // 2. "insert-target-spec"
    // 3. "run-online-frontend"
    // 4. "run-default-segmenter"
    // 5. "core-to-odix"
    const char *passNames[] = {
        "convert-from-versioned",
        "insert-target-spec",
        "run-online-frontend",
        "run-default-segmenter",
        "core-to-odix"
    };
    int numPasses = sizeof(passNames) / sizeof(passNames[0]);
    odiec_pass_t passes[5];
    for (int i = 0; i < numPasses; i++) {
        passes[i] = g_odiec.create_pass_descriptor(passNames[i], (long long)strlen(passNames[i]), "", 0, "", 0);
    }

    // 6. Invoke pipeline
    int invokeRet = g_odiec.invoke(mod, passes, numPasses, opts);

    // 7. Cleanup
    for (int i = 0; i < numPasses; i++) {
        g_odiec.destroy_pass_descriptor(passes[i]);
    }
    g_odiec.destroy_global_options(opts);
    g_odiec.destroy_module(mod);
    g_odiec.destroy_context(ctx);

    return (invokeRet == 1) ? 0 : -3;
}
