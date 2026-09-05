//
// odiec_pipeline.h
// Pure C Interface & Declarations for libODIECompiler pass pipeline
//

#ifndef ODIEC_PIPELINE_H
#define ODIEC_PIPELINE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handles for libODIECompiler objects
typedef uintptr_t odiec_context_t;
typedef uintptr_t odiec_bytecode_blob_t;
typedef uintptr_t odiec_bytecode_metadata_t;
typedef uintptr_t odiec_module_t;
typedef uintptr_t odiec_external_rewriter_t;
typedef uintptr_t odiec_external_rewriter_payload_t;
typedef uintptr_t odiec_global_options_t;
typedef uintptr_t odiec_pass_t;

/// Table of 62 C function pointers populated by odiec_initialize
typedef struct {
    // 00-06: bytecodeBlobApi
    odiec_bytecode_blob_t (*create_bytecode_blob)(void);
    void (*destroy_bytecode_blob)(odiec_bytecode_blob_t);
    void (*set_buffer)(odiec_bytecode_blob_t blob, const void *buf, long long size);
    void (*get_buffer)(odiec_bytecode_blob_t blob, const void **buf, long long *size);
    void (*set_buffer_deleter)(odiec_bytecode_blob_t blob, void *ctx, void (*deleter)(void *));
    void (*read_metadata)(odiec_context_t ctx, odiec_bytecode_blob_t blob, odiec_bytecode_metadata_t outMeta);
    void (*read_detailed_metadata)(odiec_context_t ctx, odiec_bytecode_blob_t blob, odiec_bytecode_metadata_t outMeta);

    // 07-27: bytecodeMetadataApi
    odiec_bytecode_metadata_t (*create_bytecode_metadata)(void);
    void (*destroy_bytecode_metadata)(odiec_bytecode_metadata_t meta);
    int (*get_version)(odiec_bytecode_metadata_t meta);
    int (*get_latest_version)(void);
    long long (*get_graph_count)(odiec_bytecode_metadata_t meta);
    void (*get_name)(odiec_bytecode_metadata_t meta, long long idx, void *ctx, void (*cb)(void *, const char *, long long));
    long long (*get_input_count)(odiec_bytecode_metadata_t meta, long long graphIdx);
    void (*get_input_name)(odiec_bytecode_metadata_t meta, long long graphIdx, long long inIdx, void *ctx, void (*cb)(void *, const char *, long long));
    void (*get_input_type)(odiec_bytecode_metadata_t meta, long long graphIdx, long long inIdx, void *ctx, void (*cb)(void *, const char *, long long));
    long long (*get_output_count)(odiec_bytecode_metadata_t meta, long long graphIdx);
    void (*get_output_name)(odiec_bytecode_metadata_t meta, long long graphIdx, long long outIdx, void *ctx, void (*cb)(void *, const char *, long long));
    void (*get_output_type)(odiec_bytecode_metadata_t meta, long long graphIdx, long long outIdx, void *ctx, void (*cb)(void *, const char *, long long));
    long long (*get_state_count)(odiec_bytecode_metadata_t meta, long long graphIdx);
    void (*get_state_name)(odiec_bytecode_metadata_t meta, long long graphIdx, long long stateIdx, void *ctx, void (*cb)(void *, const char *, long long));
    void (*get_state_type)(odiec_bytecode_metadata_t meta, long long graphIdx, long long stateIdx, void *ctx, void (*cb)(void *, const char *, long long));
    long long (*get_storage_type_count)(odiec_bytecode_metadata_t meta);
    void (*get_storage_type)(odiec_bytecode_metadata_t meta, long long idx, void *ctx, void (*cb)(void *, const char *, long long, long long));
    long long (*get_compute_type_count)(odiec_bytecode_metadata_t meta);
    void (*get_compute_type)(odiec_bytecode_metadata_t meta, long long idx, void *ctx, void (*cb)(void *, const char *, long long));
    long long (*get_operation_count)(odiec_bytecode_metadata_t meta);
    void (*get_operation)(odiec_bytecode_metadata_t meta, long long idx, void *ctx, void (*cb)(void *, const char *, long long, long long));

    // 28-32: rewriterPayloadApi
    odiec_bytecode_blob_t (*get_bytecode_blob)(odiec_external_rewriter_payload_t payload);
    void (*get_resource)(odiec_external_rewriter_payload_t payload, const char *name, long long len, const void **buf, long long *size);
    void (*get_input_directory)(odiec_external_rewriter_payload_t payload, const char **path, long long *len);
    void (*get_binary_directory)(odiec_external_rewriter_payload_t payload, const char **path, long long *len);
    void (*report_error)(odiec_external_rewriter_payload_t payload, const char *err, long long len);

    // 33-37: externalRewriterApi
    odiec_external_rewriter_t (*create_external_rewriter)(void);
    void (*destroy_external_rewriter)(odiec_external_rewriter_t rewriter);
    void (*set_ir_properties)(odiec_external_rewriter_t rewriter, unsigned long long bcVer, unsigned long long dialectVer, long long encoding, bool supportsPartial);
    void (*set_op_version)(odiec_external_rewriter_t rewriter, const char *name, unsigned long long nameLen, unsigned long long ver);
    void (*set_callback)(odiec_external_rewriter_t rewriter, void *ctx, odiec_bytecode_blob_t (*cb)(void *ctx, odiec_external_rewriter_payload_t payload));

    // 38-45: globalOptionsApi
    odiec_global_options_t (*create_global_options)(void);
    void (*destroy_global_options)(odiec_global_options_t opts);
    void (*set_output_directory)(odiec_global_options_t opts, const char *path, long long len);
    void (*set_input_directory)(odiec_global_options_t opts, const char *path, long long len);
    void (*add_external_rewriter)(odiec_global_options_t opts, const char *name, long long len, odiec_external_rewriter_t rewriter);
    void (*set_debug_printer)(odiec_global_options_t opts, void *ctx, void (*cb)(void *ctx, const char *msg, long long len));
    void (*set_debug_option)(odiec_global_options_t opts, int opt);
    void (*enable_debuginfo)(odiec_global_options_t opts, bool enable);

    // 46-56: moduleApi
    odiec_module_t (*create_module_from_bytecode)(odiec_context_t ctx, odiec_bytecode_blob_t *blob, bool verify);
    odiec_module_t (*create_module_from_asm)(odiec_context_t ctx, const char *str, long long len);
    odiec_module_t (*clone_module)(odiec_module_t mod);
    void (*destroy_module)(odiec_module_t mod);
    odiec_module_t (*combine_modules)(odiec_module_t *mods, long long count);
    void (*print_module)(odiec_module_t mod);
    int (*serialize_module)(odiec_module_t mod, int fmt, int ver, const char *path, long long len);
    odiec_bytecode_blob_t (*serialize_to_bytecode_blob)(odiec_module_t mod, const unsigned long long *ver);
    void (*serialize_debug_info)(odiec_module_t mod, const char *p1, long long l1, const char *p2, long long l2);
    void (*dump_mlir_asm)(odiec_module_t mod, const char *p, long long l, bool b1, bool b2);
    void (*dump_mlir_bytecode)(odiec_module_t mod, int v, const char *p, long long l, bool b);

    // 57-58: passApi
    odiec_pass_t (*create_pass_descriptor)(const char *name, long long nameLen, const char *args, long long argLen, const char *desc, long long descLen);
    void (*destroy_pass_descriptor)(odiec_pass_t pass);

    // 59-61: compilerApi
    odiec_context_t (*create_context)(void);
    void (*destroy_context)(odiec_context_t ctx);
    int (*invoke)(odiec_module_t mod, odiec_pass_t *passes, long long passCount, odiec_global_options_t opts);
} odiec_api_t;

/// Loads and initializes libODIECompiler C-API. Returns true on success.
bool odiec_pipeline_init(odiec_api_t *outApi);

/// Executes the pure C MLIR pass pipeline over bytecode data
int odiec_pipeline_execute(const void *mlirbBytes, size_t mlirbSize, const char *outputDirectory);

#ifdef __cplusplus
}
#endif

#endif /* ODIEC_PIPELINE_H */
