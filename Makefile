CC = clang
CFLAGS = -O2 -fobjc-arc -Wall
FRAMEWORKS = -framework Foundation -framework IOKit -framework Security
ENTITLEMENTS = entitlements.plist

ANE_FRAMEWORKS = -F /System/Library/PrivateFrameworks -framework AppleNeuralEngine -framework IOSurface $(FRAMEWORKS) -framework Metal -framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph

LOCAL_FRAMEWORKS = $(HOME)/work/swift_interface_gen/LocalFrameworks

SWIFT_LIBS = -L/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx -rpath /Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx -F $(LOCAL_FRAMEWORKS) -framework CoreAICompiler -framework CoreAIDelegates

all: dump_ane_pmu_objc coreai_loader model_compiler_objc

model_compiler_bridge.o: model_compiler_bridge.swift
	swiftc -O -parse-as-library -emit-object model_compiler_bridge.swift -F $(LOCAL_FRAMEWORKS) -o model_compiler_bridge.o

model_compiler_objc: model_compiler.m model_compiler_bridge.o
	$(CC) $(CFLAGS) model_compiler.m model_compiler_bridge.o $(FRAMEWORKS) $(SWIFT_LIBS) -o model_compiler_objc

dump_ane_pmu_objc: dump_ane_pmu.m coreai_loader.m model_compiler_bridge.o $(ENTITLEMENTS)
	$(CC) $(CFLAGS) dump_ane_pmu.m coreai_loader.m model_compiler_bridge.o $(ANE_FRAMEWORKS) $(SWIFT_LIBS) -o dump_ane_pmu_objc
	codesign -s - --entitlements $(ENTITLEMENTS) --force dump_ane_pmu_objc

coreai_loader: coreai_loader.m model_compiler_bridge.o $(ENTITLEMENTS)
	$(CC) $(CFLAGS) -DCOREAI_LOADER_MAIN coreai_loader.m model_compiler_bridge.o $(ANE_FRAMEWORKS) $(SWIFT_LIBS) -o coreai_loader
	codesign -s - --entitlements $(ENTITLEMENTS) --force coreai_loader

clean:
	rm -f dump_ane_pmu_objc coreai_loader model_compiler_objc model_compiler_bridge.o
