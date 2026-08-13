// Tests C++ aligned faces through FaceEmbedder + inspects model spec
// swiftc -O -framework CoreML -framework ImageIO lfw_ref.swift -o lfw_ref && ./lfw_ref

import CoreML
import CoreGraphics
import ImageIO
import Foundation

let modelsDir = "/Users/jakelulla/Desktop/PhotoSearch/PhotoSearch/PhotoSearch/ML"
let refDir    = "/Users/jakelulla/Desktop/CoreML/build"

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgbaPixels(_ img: CGImage, toWidth w: Int, height h: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: w*h*4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x:0, y:0, width:w, height:h))
    return buf
}

func floats(_ a: MLMultiArray) -> [Float] { (0..<a.count).map { a[$0].floatValue } }
func l2Norm(_ v: [Float]) -> [Float] {
    let n = sqrt(v.reduce(0) { $0+$1*$1 }) + 1e-10; return v.map { $0/n }
}
func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }

func loadOrCompile(name: String, cfg: MLModelConfiguration) throws -> MLModel {
    let fm = FileManager.default
    let src   = URL(fileURLWithPath: "\(modelsDir)/\(name).mlpackage")
    let cache = URL(fileURLWithPath: "\(modelsDir)/\(name).mlmodelc")
    if !fm.fileExists(atPath: cache.path) {
        let tmp = try MLModel.compileModel(at: src); try fm.moveItem(at: tmp, to: cache)
    }
    return try MLModel(contentsOf: cache, configuration: cfg)
}

func embed(_ face: CGImage, model: MLModel, norm: String) throws -> [Float]? {
    let S = 112
    guard let buf = rgbaPixels(face, toWidth: S, height: S) else { return nil }
    let t = try MLMultiArray(shape: [1,3,S as NSNumber,S as NSNumber], dataType: .float32)
    let plane = S*S
    for y in 0..<S { for x in 0..<S {
        let off = (y*S+x)*4
        let r = Float(buf[off]), g = Float(buf[off+1]), b = Float(buf[off+2])
        let (rv, gv, bv): (Float,Float,Float)
        switch norm {
        case "127.5/127.5": (rv,gv,bv) = ((r-127.5)/127.5,(g-127.5)/127.5,(b-127.5)/127.5)
        case "127.5/128":   (rv,gv,bv) = ((r-127.5)/128.0,(g-127.5)/128.0,(b-127.5)/128.0)
        case "/255":        (rv,gv,bv) = (r/255,g/255,b/255)
        case "raw":         (rv,gv,bv) = (r,g,b)
        default:            (rv,gv,bv) = ((r-127.5)/127.5,(g-127.5)/127.5,(b-127.5)/127.5)
        }
        t[0*plane+y*S+x] = NSNumber(value: rv)
        t[1*plane+y*S+x] = NSNumber(value: gv)
        t[2*plane+y*S+x] = NSNumber(value: bv)
    }}
    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": t]))
    guard let name = out.featureNames.first(where: { (out.featureValue(for: $0)?.multiArrayValue?.count ?? 0) == 512 }),
          let arr = out.featureValue(for: name)?.multiArrayValue else { return nil }
    return l2Norm(floats(arr))
}

// Version that reads pixels WITHOUT rgbaPixels y-flip, directly from CGDataProvider
func embedDirect(_ face: CGImage, model: MLModel) throws -> [Float]? {
    let S = 112
    // Read raw pixel bytes directly from CGImage data provider
    guard let data = face.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data) else { return nil }
    let bpp = face.bitsPerPixel / 8
    let bpr = face.bytesPerRow
    let t = try MLMultiArray(shape: [1,3,S as NSNumber,S as NSNumber], dataType: .float32)
    let plane = S*S
    for y in 0..<S { for x in 0..<S {
        let off = y*bpr + x*bpp
        let r = Float(ptr[off]), g = Float(ptr[off+1]), b = Float(ptr[off+2])
        t[0*plane+y*S+x] = NSNumber(value: (r-127.5)/127.5)
        t[1*plane+y*S+x] = NSNumber(value: (g-127.5)/127.5)
        t[2*plane+y*S+x] = NSNumber(value: (b-127.5)/127.5)
    }}
    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": t]))
    guard let name = out.featureNames.first(where: { (out.featureValue(for: $0)?.multiArrayValue?.count ?? 0) == 512 }),
          let arr = out.featureValue(for: name)?.multiArrayValue else { return nil }
    return l2Norm(floats(arr))
}

// ─── Main ────────────────────────────────────────────────────────────────────

print("FaceEmbedder Reference Test")
print("===========================\n")

let cfg = MLModelConfiguration()
cfg.computeUnits = .cpuAndGPU
let emb = try loadOrCompile(name: "FaceEmbedder", cfg: cfg)

// Print model input description
print("Model input specs:")
for (name, desc) in emb.modelDescription.inputDescriptionsByName {
    print("  \(name): \(desc.type)  multiArray=\(desc.multiArrayConstraint?.shape ?? [])  dtype=\(desc.multiArrayConstraint?.dataType.rawValue ?? -1)")
}
print("Model output specs:")
for (name, desc) in emb.modelDescription.outputDescriptionsByName {
    print("  \(name): \(desc.type)  multiArray=\(desc.multiArrayConstraint?.shape ?? [])  dtype=\(desc.multiArrayConstraint?.dataType.rawValue ?? -1)")
}
print()

// Load reference C++ aligned faces
let refs = (0..<4).compactMap { i -> (Int, CGImage)? in
    guard let img = loadCG("\(refDir)/aligned_face_\(i).jpg") else { return nil }
    return (i, img)
}
print("Loaded \(refs.count) C++ reference faces (\(refDir))\n")

// Print center pixel of each reference face
for (i, img) in refs {
    guard let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { continue }
    let bpr = img.bytesPerRow, bpp = img.bitsPerPixel/8
    // center pixel
    let cy = 56, cx = 56, off = cy*bpr+cx*bpp
    print("ref_\(i): size=\(img.width)×\(img.height) bpr=\(bpr) bpp=\(bpp)  center_RGB=(\(ptr[off]),\(ptr[off+1]),\(ptr[off+2]))")
    // Show top-left 5 pixels to detect upside-down
    print("  top-left pixels: ", terminator:"")
    for x in 0..<5 {
        let o2 = 0*bpr+x*bpp
        print("(\(ptr[o2]),\(ptr[o2+1]),\(ptr[o2+2])) ", terminator:"")
    }
    print()
}
print()

// Embed all C++ faces with different methods
var embeddings: [(Int, String, [Float])] = []
for (i, img) in refs {
    for norm in ["127.5/127.5", "127.5/128"] {
        if let e = try embed(img, model: emb, norm: norm) {
            embeddings.append((i, "via_rgbaPixels[\(norm)]", e))
        }
    }
    if let e = try embedDirect(img, model: emb) {
        embeddings.append((i, "direct[127.5/127.5]", e))
    }
}

// Similarity matrix for same-method pairs
print("Similarities between C++ faces (same method):")
let methods = ["via_rgbaPixels[127.5/127.5]", "via_rgbaPixels[127.5/128]", "direct[127.5/127.5]"]
for method in methods {
    let group = embeddings.filter { $0.1 == method }
    print("  [\(method)]")
    for j in 0..<group.count { for k in (j+1)..<group.count {
        let sim = dot(group[j].2, group[k].2)
        print(String(format:"    ref_%d vs ref_%d: %.4f", group[j].0, group[k].0, sim))
    }}
}
