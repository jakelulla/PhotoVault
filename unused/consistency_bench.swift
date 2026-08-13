// consistency_bench.swift — verifies the OPTIMIZED app pipeline produces
// embeddings consistent with the original Python/ONNX reference.
//
// Mirrors OnDeviceMLEngine.swift exactly as of the perf optimizations:
//   - rgbaPixels with NO y-flip, pointer kept valid via withUnsafeMutableBytes
//   - scrfdTensor: direct Float16 writes + memset zero padding
//   - decodeSCRFD: bulk float reads (no NSNumber boxing)
//   - arcfaceTensor / clipPreprocess: direct Float32 writes
//   - computeUnits = .all (Neural Engine)
//
// Output: /tmp/swift_embeddings.json  {image: {face: [512], clip: [512]}}
// Compare with: python3 consistency_ref.py  (writes /tmp/python_embeddings.json)
//
// Build: swiftc -O -framework CoreML -framework ImageIO consistency_bench.swift -o consistency_bench

import CoreML
import CoreGraphics
import ImageIO
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let modelsDir = "/Users/jakelulla/Desktop/PhotoSearch/PhotoSearch/PhotoSearch/ML"
let lfwDir    = NSHomeDirectory() + "/scikit_learn_data/lfw_home/lfw_funneled"

let testImages = [
    "\(lfwDir)/Angela_Bassett/Angela_Bassett_0001.jpg",
    "\(lfwDir)/Abel_Pacheco/Abel_Pacheco_0001.jpg",
    "\(lfwDir)/George_W_Bush/George_W_Bush_0001.jpg",
]

// MARK: - Image helpers (identical to app)

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgbaPixels(_ cgImage: CGImage, toWidth w: Int, height h: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Bool in
        guard let ctx = CGContext(
            data: ptr.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        // NOTE: no flip — raw CGBitmapContext already stores row 0 = top.
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? buf : nil
}

// MARK: - Math (identical to app)

func floats(_ arr: MLMultiArray) -> [Float] {
    let n      = arr.count
    let shape  = arr.shape.map { $0.intValue }
    let stride = arr.strides.map { $0.intValue }

    var packed = true
    var expected = 1
    for d in Swift.stride(from: shape.count - 1, through: 0, by: -1) {
        if stride[d] != expected { packed = false; break }
        expected *= shape[d]
    }

    func gather(_ offset: (Int) -> Int) -> [Float] {
        switch arr.dataType {
        case .float16:
            let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: offset(n - 1) + 1)
            return (0..<n).map { Float(p[offset($0)]) }
        case .float32:
            let p = arr.dataPointer.bindMemory(to: Float.self, capacity: offset(n - 1) + 1)
            return (0..<n).map { p[offset($0)] }
        default:
            return (0..<n).map { arr[$0].floatValue }
        }
    }

    if packed { return gather { $0 } }
    if shape.count == 2 {
        let cols = shape[1]
        return gather { i in (i / cols) * stride[0] + (i % cols) * stride[1] }
    }
    return (0..<n).map { arr[$0].floatValue }
}

func l2Normalize(_ v: [Float]) -> [Float] {
    let norm = (v.reduce(0) { $0 + $1*$1 }).squareRoot() + 1e-10
    return v.map { $0 / norm }
}

// MARK: - Models

func loadModel(_ name: String, cfg: MLModelConfiguration) throws -> MLModel {
    let fm = FileManager.default
    let cache = URL(fileURLWithPath: "\(modelsDir)/\(name).mlmodelc")
    if !fm.fileExists(atPath: cache.path) {
        let tmp = try MLModel.compileModel(at: URL(fileURLWithPath: "\(modelsDir)/\(name).mlpackage"))
        try fm.moveItem(at: tmp, to: cache)
    }
    return try MLModel(contentsOf: cache, configuration: cfg)
}

// MARK: - CLIP (identical preprocessing to app)

func clipEmbed(_ cgImage: CGImage, model: MLModel) throws -> [Float]? {
    let S = 224
    let srcW = cgImage.width, srcH = cgImage.height
    let scale: CGFloat = srcW < srcH ? CGFloat(S) / CGFloat(srcW) : CGFloat(S) / CGFloat(srcH)
    let newW = Int((CGFloat(srcW) * scale).rounded())
    let newH = Int((CGFloat(srcH) * scale).rounded())
    let cropX = (newW - S) / 2, cropY = (newH - S) / 2
    guard let buf = rgbaPixels(cgImage, toWidth: newW, height: newH) else { return nil }

    let mean: [Float] = [0.48145466, 0.4578275,  0.40821073]
    let std:  [Float] = [0.26862954, 0.26130258, 0.27577711]
    let tensor = try MLMultiArray(shape: [1, 3, S as NSNumber, S as NSNumber], dataType: .float32)
    let plane = S * S, rowStride = newW * 4
    let p = tensor.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
    for y in 0..<S {
        for x in 0..<S {
            let off = (y + cropY) * rowStride + (x + cropX) * 4
            p[0 * plane + y * S + x] = (Float(buf[off    ]) / 255.0 - mean[0]) / std[0]
            p[1 * plane + y * S + x] = (Float(buf[off + 1]) / 255.0 - mean[1]) / std[1]
            p[2 * plane + y * S + x] = (Float(buf[off + 2]) / 255.0 - mean[2]) / std[2]
        }
    }
    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": tensor]))
    guard let arr = out.featureValue(for: "image_features")?.multiArrayValue else { return nil }
    return l2Normalize(floats(arr))
}

// MARK: - SCRFD (identical to app: optimized tensor fill + bulk reads)

struct DetFace { var score: Float; var landmarks: [CGPoint] }

func detectFaces(_ cgImage: CGImage, model: MLModel) throws -> [DetFace] {
    let W = cgImage.width, H = cgImage.height, inputSize = 640
    let scale = Float(min(Float(inputSize) / Float(W), Float(inputSize) / Float(H)))
    let newW = Int((Float(W) * scale).rounded())
    let newH = Int((Float(H) * scale).rounded())
    guard let buf = rgbaPixels(cgImage, toWidth: newW, height: newH) else { return [] }

    // scrfdTensor — direct Float16 writes + memset padding
    let tensor = try MLMultiArray(shape: [1, 3, inputSize as NSNumber, inputSize as NSNumber],
                                  dataType: .float16)
    let plane = inputSize * inputSize, rowStride = newW * 4
    let tp = tensor.dataPointer.bindMemory(to: Float16.self, capacity: 3 * plane)
    memset(tensor.dataPointer, 0, 3 * plane * MemoryLayout<Float16>.size)
    for y in 0..<min(newH, inputSize) {
        for x in 0..<min(newW, inputSize) {
            let off = y * rowStride + x * 4
            tp[0 * plane + y * inputSize + x] = Float16((Float(buf[off    ]) - 127.5) / 128.0)
            tp[1 * plane + y * inputSize + x] = Float16((Float(buf[off + 1]) - 127.5) / 128.0)
            tp[2 * plane + y * inputSize + x] = Float16((Float(buf[off + 2]) - 127.5) / 128.0)
        }
    }

    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": tensor]))

    // Group outputs by column count, sort by row count desc → strides 8/16/32
    var byCol: [Int: [(String, Int)]] = [:]
    for name in out.featureNames {
        guard let arr = out.featureValue(for: name)?.multiArrayValue else { continue }
        let sh = arr.shape.map { $0.intValue }
        guard sh.count == 2 else { continue }
        byCol[sh[1], default: []].append((name, sh[0]))
    }
    for k in byCol.keys { byCol[k]!.sort { $0.1 > $1.1 } }
    guard let sn = byCol[1], let bn = byCol[4], let kn = byCol[10],
          sn.count == 3, bn.count == 3, kn.count == 3 else { return [] }

    let strides = [8, 16, 32]
    let detThresh: Float = 0.5
    var allS = [Float](), allB = [[Float]](), allK = [[Float]]()
    for s in 0..<3 {
        let stride = strides[s], fH = inputSize / stride, fW = inputSize / stride
        guard let sArr = out.featureValue(for: sn[s].0)?.multiArrayValue,
              let bArr = out.featureValue(for: bn[s].0)?.multiArrayValue,
              let kArr = out.featureValue(for: kn[s].0)?.multiArrayValue else { continue }
        let sp = floats(sArr), bp = floats(bArr), kp = floats(kArr)
        var ai = 0
        for y in 0..<fH {
            for x in 0..<fW {
                let cx = Float(x * stride), cy = Float(y * stride), st = Float(stride)
                for _ in 0..<2 {
                    if sp[ai] >= detThresh {
                        allB.append([cx - bp[ai*4]*st, cy - bp[ai*4+1]*st,
                                     cx + bp[ai*4+2]*st, cy + bp[ai*4+3]*st])
                        allS.append(sp[ai])
                        allK.append((0..<5).flatMap { k -> [Float] in
                            [cx + kp[ai*10 + k*2]*st, cy + kp[ai*10 + k*2 + 1]*st] })
                    }
                    ai += 1
                }
            }
        }
    }
    guard !allS.isEmpty else { return [] }

    // NMS
    let order = (0..<allS.count).sorted { allS[$0] > allS[$1] }
    var supp = [Bool](repeating: false, count: allS.count); var keep = [Int]()
    for i in 0..<order.count {
        let ii = order[i]; if supp[ii] { continue }; keep.append(ii)
        for j in (i+1)..<order.count {
            let jj = order[j]; if supp[jj] { continue }
            let a = allB[ii], b = allB[jj]
            let inter = max(0, min(a[2],b[2]) - max(a[0],b[0])) * max(0, min(a[3],b[3]) - max(a[1],b[1]))
            let union = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter + 1e-7
            if inter/union > 0.4 { supp[jj] = true }
        }
    }
    let inv = 1/scale, mX = Float(W-1), mY = Float(H-1)
    return keep.map { i in
        DetFace(score: allS[i],
                landmarks: (0..<5).map { k in
                    CGPoint(x: CGFloat(max(0, min(allK[i][k*2]   * inv, mX))),
                            y: CGFloat(max(0, min(allK[i][k*2+1] * inv, mY))))
                })
    }
}

// MARK: - Alignment (identical to app: explicit inverse mapping)

let arcDst: [CGPoint] = [
    CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
    CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
    CGPoint(x: 70.7299, y: 92.2041),
]

func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
    var sXX: CGFloat = 0, sX: CGFloat = 0, sY: CGFloat = 0
    var sUX: CGFloat = 0, sVX: CGFloat = 0, sU: CGFloat = 0, sV: CGFloat = 0
    for i in 0..<src.count {
        let (x, y, u, v) = (src[i].x, src[i].y, dst[i].x, dst[i].y)
        sXX += x*x + y*y; sX += x; sY += y
        sUX += u*x + v*y; sVX += u*y - v*x; sU += u; sV += v
    }
    let n = CGFloat(src.count), D = sXX*n - (sX*sX + sY*sY)
    guard abs(D) > 1e-10 else { return .identity }
    let a = (sUX*n - sX*sU - sY*sV) / D
    let b = (-sVX*n + sY*sU - sX*sV) / D
    let c = (sU - a*sX + b*sY) / n
    let d = (sV - b*sX - a*sY) / n
    return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: c, ty: d)
}

func alignFace(_ cgImage: CGImage, landmarks: [CGPoint]) -> CGImage? {
    let S = 112, W = cgImage.width, H = cgImage.height
    guard let srcBuf = rgbaPixels(cgImage, toWidth: W, height: H) else { return nil }
    let Tinv = similarityTransform(from: landmarks, to: arcDst).inverted()
    var outBuf = [UInt8](repeating: 0, count: S * S * 4)
    for oy in 0..<S {
        for ox in 0..<S {
            let sp = CGPoint(x: CGFloat(ox), y: CGFloat(oy)).applying(Tinv)
            let sx = Int(sp.x.rounded()), sy = Int(sp.y.rounded())
            guard sx >= 0 && sx < W && sy >= 0 && sy < H else { continue }
            let di = (oy*S + ox)*4, si = (sy*W + sx)*4
            outBuf[di] = srcBuf[si]; outBuf[di+1] = srcBuf[si+1]
            outBuf[di+2] = srcBuf[si+2]; outBuf[di+3] = srcBuf[si+3]
        }
    }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let prov = CGDataProvider(data: NSData(bytes: outBuf, length: outBuf.count) as CFData)
    else { return nil }
    return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: S*4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: info, provider: prov,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// MARK: - ArcFace (identical to app: direct Float32 writes)

func faceEmbed(_ aligned: CGImage, model: MLModel) throws -> [Float]? {
    let S = 112
    guard let buf = rgbaPixels(aligned, toWidth: S, height: S) else { return nil }
    let tensor = try MLMultiArray(shape: [1, 3, S as NSNumber, S as NSNumber], dataType: .float32)
    let plane = S * S
    let p = tensor.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
    for y in 0..<S {
        for x in 0..<S {
            let off = (y * S + x) * 4
            p[0 * plane + y * S + x] = (Float(buf[off    ]) - 127.5) / 127.5
            p[1 * plane + y * S + x] = (Float(buf[off + 1]) - 127.5) / 127.5
            p[2 * plane + y * S + x] = (Float(buf[off + 2]) - 127.5) / 127.5
        }
    }
    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": tensor]))
    guard let name = out.featureNames.first(where: {
        (out.featureValue(for: $0)?.multiArrayValue?.count ?? 0) == 512
    }), let arr = out.featureValue(for: name)?.multiArrayValue else { return nil }
    return l2Normalize(floats(arr))
}

// MARK: - Main

print("Consistency Bench — optimized Swift pipeline (computeUnits = .all)")
print(String(repeating: "=", count: 66))

let cfg = MLModelConfiguration()
cfg.computeUnits = .all
let det  = try loadModel("FaceDetector", cfg: cfg)
let emb  = try loadModel("FaceEmbedder", cfg: cfg)
let clip = try loadModel("CLIPVisual",   cfg: cfg)
print("Models loaded (FaceDetector, FaceEmbedder, CLIPVisual)\n")

var results: [String: [String: [Float]]] = [:]

for path in testImages {
    let name = URL(fileURLWithPath: path).lastPathComponent
    guard let img = loadCG(path) else { print("\(name): cannot load"); continue }

    var entry: [String: [Float]] = [:]

    let faces = try detectFaces(img, model: det)
    if let best = faces.first {
        let lm = best.landmarks.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) }.joined(separator: " ")
        print("\(name)")
        print("  det score=\(String(format: "%.4f", best.score))  landmarks=\(lm)")
        if let aligned = alignFace(img, landmarks: best.landmarks),
           let fe = try faceEmbed(aligned, model: emb) {
            entry["face"] = fe
            print("  face[0..8]: [\(fe.prefix(8).map { String(format: "%+.4f", $0) }.joined(separator: ", "))]")
        }
    } else {
        print("\(name): no face detected")
    }

    if let ce = try clipEmbed(img, model: clip) {
        entry["clip"] = ce
        print("  clip[0..8]: [\(ce.prefix(8).map { String(format: "%+.4f", $0) }.joined(separator: ", "))]")
    }
    print("")
    results[name] = entry
}

let json = try JSONEncoder().encode(results)
try json.write(to: URL(fileURLWithPath: "/tmp/swift_embeddings.json"))
print("Wrote /tmp/swift_embeddings.json")
