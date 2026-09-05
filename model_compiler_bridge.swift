import Foundation
import CoreAICompiler
import CoreAIDelegates

@_cdecl("compile_model_for_host")
public func compile_model_for_host(inputPath: UnsafePointer<CChar>, outputPath: UnsafePointer<CChar>) -> Int32 {
    let inPathStr = String(cString: inputPath)
    let outPathStr = String(cString: outputPath)
    
    let inputURL = URL(fileURLWithPath: inPathStr)
    let outputURL = URL(fileURLWithPath: outPathStr)
    
    do {
        let data = try Data(contentsOf: inputURL)
        let module = CoreAICompiler.Compiler.Module.bytecode(data)
        
        var options = try CoreAICompiler.Compiler.Options.defaultOptions(
            for: "this",
            delegates: CompilationDelegates.mpsGraph,
            aneOptionsURL: nil
        )
        options.targetSpecification?.targetDelegateOptions = "\"{streaming=\"preferredDevice=NeuralEngine\"}\""
        
        try? FileManager.default.removeItem(at: outputURL)
        
        try CoreAICompiler.Compiler.compileSync(
            module: module,
            intermediateResult: nil,
            to: outputURL,
            using: options
        )
        return 0
    } catch {
        print("❌ Model compilation failed: \(error)")
        return -1
    }
}
