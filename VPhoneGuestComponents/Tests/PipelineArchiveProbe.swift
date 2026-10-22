// On-device integration test for the shipped PipelineArchive component.
// Build/run instructions are in Research/Guest/coreanimation_precompiled_pipelines.md.
import Foundation
import Metal
import QuartzCore
import CryptoKit
import Darwin

let mode = CommandLine.arguments.dropFirst().first ?? "reuse"
let root = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/var/mobile/Library/VPhonePipelineIntegration"
let dylib = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "/var/tmp/libvphonepipelinearchive.dylib"
typealias Install = @convention(c) (UnsafePointer<CChar>?) -> Int32
typealias Action = @convention(c) () -> Void
typealias Statistics = @convention(c) () -> UnsafeMutablePointer<CChar>?
func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _: T.Type) throws -> T {
    guard let pointer = dlsym(handle, name) else { throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(name)"]) }
    return unsafeBitCast(pointer, to: T.self)
}
func scene(_ index: Int) -> CALayer {
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
    root.backgroundColor = CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    let child = CALayer()
    child.frame = CGRect(x: 12, y: 14, width: 64, height: 60)
    child.backgroundColor = CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1)
    root.addSublayer(child)
    if index >= 1 {
        child.cornerRadius = 12
        child.opacity = 0.7
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 30, y: 40, width: 55, height: 45)
        gradient.colors = [CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
        root.addSublayer(gradient)
    }
    if index >= 2 {
        child.shadowColor = CGColor(gray: 0, alpha: 1)
        child.shadowOpacity = 0.8
        child.shadowRadius = 5
        child.shadowOffset = CGSize(width: 3, height: 4)
        child.transform = CATransform3DMakeRotation(0.2, 0, 0, 1)
    }
    if index >= 3 {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.7, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 1, alpha: 0.7))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        child.contents = context.makeImage()
        child.contentsGravity = .resize
        child.borderWidth = 2
        child.borderColor = CGColor(gray: 1, alpha: 1)
    }
    return root
}
var report: [String: Any] = ["mode": mode, "pid": getpid()]
var result: Int32 = 0
func run() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let handle = dlopen(dylib, RTLD_NOW | RTLD_LOCAL) else {
        throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: dlerror().map { String(cString: $0) } ?? "No device"])
    }
    let install = try symbol(handle, "vphone_pipeline_archive_install", Install.self)
    let flush = try symbol(handle, "vphone_pipeline_archive_flush", Action.self)
    let prewarm = try symbol(handle, "vphone_pipeline_archive_prewarm", Action.self)
    let statistics = try symbol(handle, "vphone_pipeline_archive_copy_statistics", Statistics.self)
    func stats() throws -> [String: Any] {
        guard let json = statistics() else { return [:] }
        defer { free(json) }
        return try JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as! [String: Any]
    }
    if mode != "baseline" {
        guard root.withCString({ install($0) }) == 1 else { throw NSError(domain: "Probe", code: 3) }
    }
    report["device"] = device.name
    report["architecture"] = device.architecture.name
    if mode == "prewarm" { prewarm(); flush(); report["afterPrewarm"] = try stats() }
    var scenes: [[String: Any]] = []
    for index in 0..<4 {
        try autoreleasepool {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 96, height: 96, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw NSError(domain: "Probe", code: 4) }
            let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
            renderer.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
            renderer.layer = scene(index)
            CATransaction.flush()
            let start = CACurrentMediaTime()
            renderer.beginFrame(atTime: start, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            let barrier = queue.makeCommandBuffer()!
            barrier.commit()
            barrier.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: 96 * 96 * 4)
            texture.getBytes(&bytes, bytesPerRow: 96 * 4, from: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0)
            scenes.append(["index": index, "pixelSHA256": SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(),
                           "gpuStatus": barrier.status.rawValue, "gpuError": barrier.error?.localizedDescription ?? "", "milliseconds": (CACurrentMediaTime() - start) * 1000])
            if barrier.status != .completed { result = 5 }
            renderer.layer = nil
        }
    }
    report["scenes"] = scenes
    let libraryURL = Bundle(for: CALayer.self).url(forResource: "default", withExtension: "metallib")!
    let library = try device.makeLibrary(URL: libraryURL)
    let names = ["compute_clear", "compute_sum_luma", "compute_average_luma", "compute_apl", "compute_apl_fast", "rgb_to_420f", "variable_blur_downsample_compute", "variable_blur_downsample_compute_agx2", "variable_blur_copy_base_mip_compute", "read_write_surf_compute"]
    var controls: [[String: Any]] = []
    let empty = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
    for name in names {
        let functionDescriptor = MTLFunctionDescriptor()
        functionDescriptor.name = name
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = try library.makeFunction(descriptor: functionDescriptor)
        descriptor.label = "com.apple.coreanimation.\(name)"
        _ = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        // A non-CoreAnimation request must retain the caller's archive policy.
        descriptor.label = "vphone.integration.negative-control"
        descriptor.binaryArchives = [empty]
        do {
            _ = try device.makeComputePipelineState(descriptor: descriptor, options: .failOnBinaryArchiveMiss, reflection: nil)
            controls.append(["name": name, "emptyArchiveMiss": false]); result = 6
        } catch { controls.append(["name": name, "emptyArchiveMiss": true]) }
    }
    report["negativeControls"] = controls
    flush()
    report["statistics"] = try stats()
    if let path = (report["statistics"] as? [String: Any])?["archivePath"] as? String,
       let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        report["archiveSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        report["archiveBytes"] = data.count
    }
}
do { try run() } catch { report["fatalError"] = String(describing: error); result = 7 }
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
FileHandle.standardOutput.write(Data([10]))
exit(result)
