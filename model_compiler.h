//
// model_compiler.h
// CoreAI Host-Specialized Model Compiler C Interface
//

#ifndef MODEL_COMPILER_H
#define MODEL_COMPILER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Compiles input MLIR bytecode (.mlirb) targeting host Apple Neural Engine (targetSOC: "this")
/// and outputs an MPSGraphPackage.
///
/// @param inputPath Path to input .mlirb bytecode
/// @param outputPath Destination directory path for compiled package
/// @return 0 on success, non-zero on error.
int compile_model_for_host(const char *inputPath, const char *outputPath);

#ifdef __cplusplus
}
#endif

#endif /* MODEL_COMPILER_H */
