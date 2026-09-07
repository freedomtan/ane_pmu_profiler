//
// coreai_loader.h
// Objective-C Declarations for CoreAI, MPSGraph, and AppleNeuralEngine
//

#ifndef COREAI_LOADER_H
#define COREAI_LOADER_H

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#import "model_compiler.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - AppleNeuralEngine Private Declarations

@class _ANEModel;
@class _ANEIOSurfaceObject;
@class _ANEPerformanceStats;
@class _ANEPerformanceStatsIOSurface;
@class _ANERequest;

@interface _ANEPerformanceStats : NSObject
@property (nonatomic, readonly) NSData *perfCounterData;
@property (nonatomic, readonly) unsigned long long hwExecutionTime;
@property (nonatomic, readonly) NSData *pStatsRawData;
- (NSDictionary *)performanceCounters;
- (NSString *)stringForPerfCounter:(int32_t)counter;
@end

@interface _ANEModel : NSObject
@property (nonatomic, assign) unsigned long long programHandle;
@property (nonatomic, copy, nullable) NSString *cacheURLIdentifier;
@property (nonatomic, readonly) NSURL *modelURL;
+ (nullable instancetype)modelAtURL:(NSURL *)url key:(NSString *)key;
+ (nullable instancetype)modelAtURL:(NSURL *)url key:(NSString *)key mpsConstants:(nullable NSString *)mpsConstants;
@end

@interface _ANEIOSurfaceObject : NSObject
@property (nonatomic, readonly) IOSurfaceRef ioSurface;
@property (nonatomic, readonly, nullable) NSNumber *startOffset;
+ (instancetype)objectWithIOSurface:(IOSurfaceRef)ioSurface;
+ (instancetype)objectWithIOSurface:(IOSurfaceRef)ioSurface startOffset:(nullable NSNumber *)startOffset;
@end

@interface _ANEPerformanceStatsIOSurface : NSObject
@property (nonatomic, readonly) _ANEIOSurfaceObject *stats;
@property (nonatomic, readonly) NSInteger statType;
+ (instancetype)objectWithIOSurface:(_ANEIOSurfaceObject *)surface statType:(NSInteger)statType;
- (instancetype)initWithIOSurface:(_ANEIOSurfaceObject *)surface statType:(NSInteger)statType;
@end

@interface _ANERequest : NSObject
@property (nonatomic, readonly) NSArray<_ANEIOSurfaceObject *> *inputArray;
@property (nonatomic, readonly) NSArray<NSNumber *> *inputIndexArray;
@property (nonatomic, readonly) NSArray<_ANEIOSurfaceObject *> *outputArray;
@property (nonatomic, readonly) NSArray<NSNumber *> *outputIndexArray;
@property (nonatomic, readonly) NSArray<_ANEPerformanceStatsIOSurface *> *perfStatsArray;
@property (nonatomic, readonly) NSNumber *procedureIndex;
@property (nonatomic, strong, nullable) _ANEPerformanceStats *perfStats;
+ (instancetype)requestWithInputs:(NSArray<_ANEIOSurfaceObject *> *)inputs
                     inputIndices:(NSArray<NSNumber *> *)inputIndices
                          outputs:(NSArray<_ANEIOSurfaceObject *> *)outputs
                    outputIndices:(NSArray<NSNumber *> *)outputIndices
                        perfStats:(nullable NSArray<_ANEPerformanceStatsIOSurface *> *)perfStats
                   procedureIndex:(NSNumber *)procedureIndex;
- (BOOL)validate;
@end

@interface _ANEClient : NSObject
+ (instancetype)sharedConnection;
- (BOOL)compileModel:(_ANEModel *)model
             options:(NSDictionary *)options
                 qos:(unsigned int)qos
               error:(NSError **)error;
- (BOOL)loadModel:(_ANEModel *)model
          options:(NSDictionary *)options
              qos:(unsigned int)qos
            error:(NSError **)error;
- (BOOL)unloadModel:(_ANEModel *)model
            options:(NSDictionary *)options
                qos:(unsigned int)qos
              error:(NSError **)error;
- (BOOL)evaluateWithModel:(_ANEModel *)model
                  options:(NSDictionary *)options
                  request:(_ANERequest *)request
                      qos:(unsigned int)qos
                    error:(NSError **)error;
@end

#pragma mark - MetalPerformanceShadersGraph Private Declarations

@interface MPSGraphCompilationDescriptor (PrivateANE)
@property (readwrite, nonatomic) unsigned long long preferredDevice;
@end

@interface MPSGraphExecutableDescriptor : NSObject
@property (readwrite, nonatomic) BOOL isAICodeBytecode;
@property (readwrite, nonatomic) BOOL includeDebugInfo;
@property (readwrite, nonatomic) unsigned long long compilerOptions;
@property (strong, nonatomic, nullable) MPSGraphCompilationDescriptor *compilationDescriptor;
@end

@interface MPSGraphExecutable (PrivateMLIR)
- (nullable instancetype)initWithMLIRBytecode:(NSData *)bytecode
                         executableDescriptor:(MPSGraphExecutableDescriptor *)descriptor;
- (NSArray<MPSGraphShapedType *> *)getInputShapesForFunction:(NSString *)functionName;
- (NSArray<MPSGraphShapedType *> *)getOutputShapesForFunction:(NSString *)functionName;
@end

#pragma mark - Loader Result Interface

@interface CoreAILoaderResult : NSObject
@property (nonatomic, strong) _ANEClient *client;
@property (nonatomic, strong) _ANEModel *model;
@property (nonatomic, assign) uint64_t inBytes;
@property (nonatomic, assign) uint64_t outBytes;
@property (nonatomic, copy, nullable) NSString *hwxPath;
@property (nonatomic, copy, nullable) NSString *bundlePath;
@end

#pragma mark - C Function Declarations

#ifdef __cplusplus
extern "C" {
#endif

BOOL load_coreai_for_aneclient(const char *modelPath, void * _Nullable * _Nonnull outResult);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* COREAI_LOADER_H */
