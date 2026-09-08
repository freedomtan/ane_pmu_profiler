CC = clang
CFLAGS = -O2 -fobjc-arc -Wall
FRAMEWORKS = -framework Foundation -framework IOKit -framework Security
ENTITLEMENTS = entitlements.plist

ANE_FRAMEWORKS = -F /System/Library/PrivateFrameworks -framework AppleNeuralEngine -framework IOSurface $(FRAMEWORKS) -framework Metal -framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph -framework CoreML

# Private CoreAI framework interfaces (optional, generated via https://github.com/freedomtan/swift_interface_gen/)
LOCAL_FRAMEWORKS ?= $(HOME)/work/swift_interface_gen/LocalFrameworks

# Auto-detect Swift CoreAI compiler support if swift_interface_gen LocalFrameworks exists
ifeq ($(ENABLE_SWIFT),)
    ifeq ($(wildcard $(LOCAL_FRAMEWORKS)/CoreAICompiler.framework),)
        ENABLE_SWIFT = 0
    else
        ENABLE_SWIFT = 1
    endif
endif

ifeq ($(ENABLE_SWIFT),1)
    $(info [build] Swift CoreAI compiler support ENABLED (using $(LOCAL_FRAMEWORKS)))
    XCODE_TOOLCHAIN ?= $(shell xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx
    CFLAGS += -DENABLE_SWIFT_COMPILER=1
    SWIFT_LIBS = -L$(XCODE_TOOLCHAIN) -rpath $(XCODE_TOOLCHAIN) -F $(LOCAL_FRAMEWORKS) -framework CoreAICompiler -framework CoreAIDelegates
    SWIFT_OBJS = model_compiler_bridge.o
    TARGETS = dump_ane_pmu_objc coreai_loader model_compiler_objc
else
    $(info [build] Swift CoreAI compiler support DISABLED (pure Objective-C build; no swift_interface_gen needed))
    CFLAGS += -DENABLE_SWIFT_COMPILER=0
    SWIFT_LIBS =
    SWIFT_OBJS =
    TARGETS = dump_ane_pmu_objc coreai_loader
endif

all: $(TARGETS)

model_compiler_bridge.o: model_compiler_bridge.swift
	swiftc -O -parse-as-library -emit-object model_compiler_bridge.swift -F $(LOCAL_FRAMEWORKS) -o model_compiler_bridge.o

model_compiler_objc: model_compiler.m model_compiler_bridge.o
	$(CC) $(CFLAGS) model_compiler.m model_compiler_bridge.o $(FRAMEWORKS) $(SWIFT_LIBS) -o model_compiler_objc

dump_ane_pmu_objc: dump_ane_pmu.m coreai_loader.m $(SWIFT_OBJS) $(ENTITLEMENTS)
	$(CC) $(CFLAGS) dump_ane_pmu.m coreai_loader.m $(SWIFT_OBJS) $(ANE_FRAMEWORKS) $(SWIFT_LIBS) -o dump_ane_pmu_objc
	codesign -s - --entitlements $(ENTITLEMENTS) --force dump_ane_pmu_objc

coreai_loader: coreai_loader.m $(SWIFT_OBJS) $(ENTITLEMENTS)
	$(CC) $(CFLAGS) -DCOREAI_LOADER_MAIN coreai_loader.m $(SWIFT_OBJS) $(ANE_FRAMEWORKS) $(SWIFT_LIBS) -o coreai_loader
	codesign -s - --entitlements $(ENTITLEMENTS) --force coreai_loader

clean:
	rm -f dump_ane_pmu_objc coreai_loader model_compiler_objc model_compiler_bridge.o
