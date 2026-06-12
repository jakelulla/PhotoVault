// PhotoSearch Inference Test Bench
// Compile & run:
//   swiftc -framework CoreML -framework ImageIO testbench.swift -o testbench && ./testbench

import CoreML
import CoreGraphics
import ImageIO
import Foundation

// MARK: - Paths

let uploadsDir = "/Users/jakelulla/Desktop/PhotoSearch/test_images_wiped_1780536107/uploads"
let modelsDir  = "/Users/jakelulla/Desktop/PhotoSearch/PhotoSearch/PhotoSearch/ML"

// MARK: - Math helpers

func floats(_ arr: MLMultiArray) -> [Float] {
    (0..<arr.count).map { arr[$0].floatValue }
}

func l2Normalize(_ v: [Float]) -> [Float] {
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 }) + 1e-10
    return v.map { $0 / norm }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

// MARK: - Image loading / resizing (pure CoreGraphics, no UIKit)

func cgImageFrom(path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgbaPixels(_ cgImage: CGImage, toWidth w: Int, height h: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &buf, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    // NOTE: no flip — raw CGBitmapContext already stores row 0 = top of image
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

// MARK: - CLIP preprocessing  (224×224, OpenAI normalization)

func clipTensor(_ cgImage: CGImage) throws -> MLMultiArray {
    let S = 224
    let srcW = cgImage.width, srcH = cgImage.height
    let scale: CGFloat = srcW < srcH ? CGFloat(S) / CGFloat(srcW) : CGFloat(S) / CGFloat(srcH)
    let newW = Int((CGFloat(srcW) * scale).rounded())
    let newH = Int((CGFloat(srcH) * scale).rounded())
    let cropX = (newW - S) / 2, cropY = (newH - S) / 2
    guard let buf = rgbaPixels(cgImage, toWidth: newW, height: newH) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let mean: [Float] = [0.48145466, 0.4578275,  0.40821073]
    let std:  [Float] = [0.26862954, 0.26130258, 0.27577711]
    let t = try MLMultiArray(shape: [1, 3, S as NSNumber, S as NSNumber], dataType: .float32)
    let plane = S * S, row = newW * 4
    for y in 0..<S { for x in 0..<S {
        let off = (y + cropY) * row + (x + cropX) * 4
        t[0 * plane + y * S + x] = NSNumber(value: (Float(buf[off    ]) / 255 - mean[0]) / std[0])
        t[1 * plane + y * S + x] = NSNumber(value: (Float(buf[off + 1]) / 255 - mean[1]) / std[1])
        t[2 * plane + y * S + x] = NSNumber(value: (Float(buf[off + 2]) / 255 - mean[2]) / std[2])
    }}
    return t
}

// MARK: - SCRFD face detection

struct DetFace { var bbox: CGRect; var landmarks: [CGPoint] }

func scrfdTensor(_ buf: [UInt8], drawnW: Int, drawnH: Int, pad: Int) throws -> MLMultiArray {
    // Model expects Float16 — use Float16 to avoid silent byte-reinterpretation bugs.
    let t = try MLMultiArray(shape: [1, 3, pad as NSNumber, pad as NSNumber], dataType: .float16)
    let plane = pad * pad, row = drawnW * 4
    for y in 0..<pad { for x in 0..<pad {
        let r, g, b: Float
        if y < drawnH && x < drawnW {
            let off = y * row + x * 4
            r = (Float(buf[off    ]) - 127.5) / 128
            g = (Float(buf[off + 1]) - 127.5) / 128
            b = (Float(buf[off + 2]) - 127.5) / 128
        } else { r = 0; g = 0; b = 0 }
        t[0 * plane + y * pad + x] = NSNumber(value: r)
        t[1 * plane + y * pad + x] = NSNumber(value: g)
        t[2 * plane + y * pad + x] = NSNumber(value: b)
    }}
    return t
}

func nms(_ scores: [Float], _ boxes: [[Float]], thresh: Float) -> [Int] {
    var order = (0..<scores.count).sorted { scores[$0] > scores[$1] }
    var suppressed = [Bool](repeating: false, count: scores.count)
    var keep: [Int] = []
    for i in 0..<order.count {
        let ii = order[i]; if suppressed[ii] { continue }
        keep.append(ii)
        for j in (i+1)..<order.count {
            let jj = order[j]; if suppressed[jj] { continue }
            let a = boxes[ii], b = boxes[jj]
            let inter = max(0, min(a[2],b[2])-max(a[0],b[0])) * max(0, min(a[3],b[3])-max(a[1],b[1]))
            if inter / ((a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter + 1e-7) > thresh {
                suppressed[jj] = true
            }
        }
    }
    return keep
}

func decodeSCRFD(_ out: MLFeatureProvider, scale: Float, W: Int, H: Int) -> [DetFace] {
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

    let strides = [8, 16, 32]; let anch = 2; let inputSize = 640
    var allS: [Float] = []; var allB: [[Float]] = []; var allK: [[Float]] = []

    for s in 0..<3 {
        let stride = strides[s], fH = inputSize/stride, fW = inputSize/stride, nPos = fH*fW*anch
        guard let sArr = out.featureValue(for: sn[s].0)?.multiArrayValue,
              let bArr = out.featureValue(for: bn[s].0)?.multiArrayValue,
              let kArr = out.featureValue(for: kn[s].0)?.multiArrayValue else { continue }
        let sp = (0..<nPos).map      { sArr[$0].floatValue }
        let bp = (0..<nPos * 4).map  { bArr[$0].floatValue }
        let kp = (0..<nPos * 10).map { kArr[$0].floatValue }
        var ai = 0
        for y in 0..<fH { for x in 0..<fW {
            let cx = Float(x*stride), cy = Float(y*stride), st = Float(stride)
            for _ in 0..<anch {
                if sp[ai] >= 0.5 {
                    allB.append([cx-bp[ai*4]*st, cy-bp[ai*4+1]*st, cx+bp[ai*4+2]*st, cy+bp[ai*4+3]*st])
                    allS.append(sp[ai])
                    allK.append((0..<5).flatMap { k -> [Float] in
                        [cx + kp[ai*10+k*2]*st, cy + kp[ai*10+k*2+1]*st]
                    })
                }
                ai += 1
            }
        }}
    }
    guard !allS.isEmpty else { return [] }
    let inv = 1/scale, mX = Float(W-1), mY = Float(H-1)
    return nms(allS, allB, thresh: 0.4).map { i in
        let b = allB[i]
        let bbox = CGRect(
            x:      CGFloat(max(0, min(b[0]*inv, mX))),
            y:      CGFloat(max(0, min(b[1]*inv, mY))),
            width:  CGFloat(max(0, min(b[2]*inv, mX)) - max(0, min(b[0]*inv, mX))),
            height: CGFloat(max(0, min(b[3]*inv, mY)) - max(0, min(b[1]*inv, mY)))
        )
        let pts = (0..<5).map { k -> CGPoint in
            CGPoint(x: CGFloat(max(0, min(allK[i][k*2]*inv, mX))),
                    y: CGFloat(max(0, min(allK[i][k*2+1]*inv, mY))))
        }
        return DetFace(bbox: bbox, landmarks: pts)
    }
}

// MARK: - Face alignment  (ArcFace 112×112 reference)

let arcDst: [CGPoint] = [
    CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
    CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
    CGPoint(x: 70.7299, y: 92.2041),
]

func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
    var sXX: CGFloat=0, sX: CGFloat=0, sY: CGFloat=0
    var sUX: CGFloat=0, sVX: CGFloat=0, sU: CGFloat=0, sV: CGFloat=0
    for i in 0..<src.count {
        let (x,y,u,v) = (src[i].x, src[i].y, dst[i].x, dst[i].y)
        sXX += x*x+y*y; sX += x; sY += y; sUX += u*x+v*y; sVX += u*y-v*x; sU += u; sV += v
    }
    let n = CGFloat(src.count), D = sXX*n - (sX*sX+sY*sY)
    guard abs(D) > 1e-10 else { return .identity }
    let a = (sUX*n - sX*sU - sY*sV) / D
    let b = (-sVX*n + sY*sU - sX*sV) / D
    let c = (sU - a*sX + b*sY) / n
    let d = (sV - b*sX - a*sY) / n
    return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: c, ty: d)
}

func alignFace(_ img: CGImage, face: DetFace) -> CGImage? {
    let S = 112, W = img.width, H = img.height
    guard let srcBuf = rgbaPixels(img, toWidth: W, height: H) else { return nil }
    let Tinv = similarityTransform(from: face.landmarks, to: arcDst as [CGPoint]).inverted()
    var outBuf = [UInt8](repeating: 0, count: S*S*4)
    for oy in 0..<S { for ox in 0..<S {
        let sp = CGPoint(x: CGFloat(ox), y: CGFloat(oy)).applying(Tinv)
        let sx = Int(sp.x.rounded()), sy = Int(sp.y.rounded())
        guard sx >= 0 && sx < W && sy >= 0 && sy < H else { continue }
        let di = (oy*S + ox)*4, si = (sy*W + sx)*4
        outBuf[di] = srcBuf[si]; outBuf[di+1] = srcBuf[si+1]
        outBuf[di+2] = srcBuf[si+2]; outBuf[di+3] = srcBuf[si+3]
    }}
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let prov = CGDataProvider(data: NSData(bytes: outBuf, length: outBuf.count) as CFData)
    else { return nil }
    return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: S*4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: info, provider: prov,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

func arcfaceTensor(_ img: CGImage) throws -> MLMultiArray {
    let S = 112
    guard let buf = rgbaPixels(img, toWidth: S, height: S) else { throw CocoaError(.fileReadCorruptFile) }
    let t = try MLMultiArray(shape: [1, 3, S as NSNumber, S as NSNumber], dataType: .float32)
    let plane = S*S
    for y in 0..<S { for x in 0..<S {
        let off = (y*S+x)*4
        t[0*plane+y*S+x] = NSNumber(value: (Float(buf[off    ])-127.5)/127.5)
        t[1*plane+y*S+x] = NSNumber(value: (Float(buf[off + 1])-127.5)/127.5)
        t[2*plane+y*S+x] = NSNumber(value: (Float(buf[off + 2])-127.5)/127.5)
    }}
    return t
}

// MARK: - Face clustering  (same algorithm as PhotoStore)

struct Cluster { var prototype: [Float]; var photos: [String] }

func assignFace(emb: [Float], photo: String, clusters: inout [Cluster]) {
    var bestIdx = -1, bestSim: Float = 0.70
    for (i, c) in clusters.enumerated() {
        let s = cosine(emb, c.prototype)
        if s > bestSim { bestSim = s; bestIdx = i }
    }
    if bestIdx >= 0 {
        let n = Float(clusters[bestIdx].photos.count)
        clusters[bestIdx].prototype = l2Normalize(zip(clusters[bestIdx].prototype, emb).map { $0.0*n + $0.1 })
        if !clusters[bestIdx].photos.contains(photo) { clusters[bestIdx].photos.append(photo) }
    } else {
        clusters.append(Cluster(prototype: l2Normalize(emb), photos: [photo]))
    }
}

// MARK: - Main

print("PhotoSearch Inference Test Bench")
print(String(repeating: "=", count: 50))

let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU

// Compile a .mlpackage to .mlmodelc on first run; reuse the cached .mlmodelc after.
func loadModel(name: String, cfg: MLModelConfiguration) throws -> MLModel {
    let fm        = FileManager.default
    let srcURL    = URL(fileURLWithPath: "\(modelsDir)/\(name).mlpackage")
    let cacheURL  = URL(fileURLWithPath: "\(modelsDir)/\(name).mlmodelc")

    if !fm.fileExists(atPath: cacheURL.path) {
        print("  Compiling \(name) (one-time, may take a minute)…")
        let tmp = try MLModel.compileModel(at: srcURL)
        try fm.moveItem(at: tmp, to: cacheURL)
    }
    return try MLModel(contentsOf: cacheURL, configuration: cfg)
}

print("Loading models...")
let clipModel, detModel, embModel: MLModel
do {
    clipModel = try loadModel(name: "CLIPVisual",   cfg: cfg); print("  ✓ CLIPVisual")
    detModel  = try loadModel(name: "FaceDetector", cfg: cfg); print("  ✓ FaceDetector")
    embModel  = try loadModel(name: "FaceEmbedder", cfg: cfg); print("  ✓ FaceEmbedder")
} catch {
    fputs("ERROR loading models: \(error)\n", stderr); exit(1)
}

// ── Model diagnostics ────────────────────────────────────────────────────────
print("\nFaceDetector input spec:")
for (name, desc) in detModel.modelDescription.inputDescriptionsByName {
    print("  '\(name)'  type=\(desc.type.rawValue)  constraint=\(String(describing: desc.multiArrayConstraint))")
}
print("FaceDetector output spec:")
for (name, desc) in detModel.modelDescription.outputDescriptionsByName {
    let shape = desc.multiArrayConstraint?.shape ?? []
    print("  '\(name)'  shape=\(shape)")
}

let jpgs = (try! FileManager.default.contentsOfDirectory(atPath: uploadsDir))
    .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
    .sorted()

// Run detector on first image and print raw output to check score range
if let firstJpg = jpgs.first, let img = cgImageFrom(path: "\(uploadsDir)/\(firstJpg)") {
    let W = img.width, H = img.height
    let pad = 640
    let scale = Float(min(Float(pad)/Float(W), Float(pad)/Float(H)))
    let newW = Int((Float(W)*scale).rounded()), newH = Int((Float(H)*scale).rounded())
    if let buf = rgbaPixels(img, toWidth: newW, height: newH),
       let dTen = try? scrfdTensor(buf, drawnW: newW, drawnH: newH, pad: pad),
       let dIn  = try? MLDictionaryFeatureProvider(dictionary: ["input": dTen]),
       let dOut = try? detModel.prediction(from: dIn) {
        print("\nDetector raw outputs for '\(firstJpg)':")
        for name in dOut.featureNames.sorted() {
            if let arr = dOut.featureValue(for: name)?.multiArrayValue {
                let sh = arr.shape.map { $0.intValue }
                let count = min(arr.count, 100000)
                let vals = (0..<count).map { arr[$0].floatValue }
                let maxV = vals.max() ?? 0
                let minV = vals.min() ?? 0
                let above3 = vals.filter { $0 > 0.3 }.count
                let above5 = vals.filter { $0 > 0.5 }.count
                print("  '\(name)' shape=\(sh)  min=\(String(format:"%.4f",minV))  max=\(String(format:"%.4f",maxV))  >0.3: \(above3)  >0.5: \(above5)")
            }
        }
    }
}
print()

print("Processing \(jpgs.count) images...\n")

var clusters:     [Cluster] = []
var clipEmbs:     [(name: String, emb: [Float])] = []
var totalFaces    = 0
var imgsWithFaces = 0
var failures      = 0
let t0 = Date()

for (i, fname) in jpgs.enumerated() {
    let path = "\(uploadsDir)/\(fname)"
    guard let img = cgImageFrom(path: path) else { failures += 1; continue }
    let W = img.width, H = img.height

    // CLIP embedding
    if let tensor = try? clipTensor(img),
       let inp    = try? MLDictionaryFeatureProvider(dictionary: ["image": tensor]),
       let out    = try? clipModel.prediction(from: inp),
       let arr    = out.featureValue(for: "image_features")?.multiArrayValue {
        clipEmbs.append((fname, l2Normalize(floats(arr))))
    }

    // Face detection
    let pad   = 640
    let scale = Float(min(Float(pad)/Float(W), Float(pad)/Float(H)))
    let newW  = Int((Float(W)*scale).rounded())
    let newH  = Int((Float(H)*scale).rounded())

    if let buf    = rgbaPixels(img, toWidth: newW, height: newH),
       let dTen   = try? scrfdTensor(buf, drawnW: newW, drawnH: newH, pad: pad),
       let dIn    = try? MLDictionaryFeatureProvider(dictionary: ["input": dTen]),
       let dOut   = try? detModel.prediction(from: dIn) {

        let faces = decodeSCRFD(dOut, scale: scale, W: W, H: H)
        if !faces.isEmpty { imgsWithFaces += 1 }
        totalFaces += faces.count

        for face in faces {
            guard let aligned = alignFace(img, face: face),
                  let eTen   = try? arcfaceTensor(aligned),
                  let eIn    = try? MLDictionaryFeatureProvider(dictionary: ["input": eTen]),
                  let eOut   = try? embModel.prediction(from: eIn),
                  let eName  = eOut.featureNames.first(where: { (eOut.featureValue(for: $0)?.multiArrayValue?.count ?? 0) == 512 }),
                  let eArr   = eOut.featureValue(for: eName)?.multiArrayValue
            else { continue }
            assignFace(emb: l2Normalize(floats(eArr)), photo: fname, clusters: &clusters)
        }
    }

    if (i+1) % 100 == 0 || i == jpgs.count-1 {
        let s = Date().timeIntervalSince(t0)
        print(String(format: "  [%4d/%d]  faces: %d  clusters: %d  %.1f img/s",
                     i+1, jpgs.count, totalFaces, clusters.count, Double(i+1)/s))
    }
}

let elapsed = Date().timeIntervalSince(t0)

// ── Report ──────────────────────────────────────────────────────────────────

print("\n" + String(repeating: "=", count: 50))
print("RESULTS")
print(String(repeating: "=", count: 50))
print(String(format: "Images processed     %d / %d", jpgs.count - failures, jpgs.count))
print(String(format: "Images with faces    %d (%.0f%%)", imgsWithFaces, 100.0*Double(imgsWithFaces)/Double(max(jpgs.count,1))))
print(String(format: "Total faces          %d", totalFaces))
print(String(format: "Avg faces / image    %.2f", Double(totalFaces)/Double(max(jpgs.count,1))))
print(String(format: "Person clusters      %d", clusters.count))
print(String(format: "Elapsed              %.1fs  (%.2f img/s)", elapsed, Double(jpgs.count)/elapsed))

print("\nTop 20 clusters by photo count:")
let sorted = clusters.sorted { $0.photos.count > $1.photos.count }
for (rank, c) in sorted.prefix(20).enumerated() {
    let bar = String(repeating: "█", count: min(c.photos.count, 40))
    print(String(format: "  %2d. %3d photo(s)  %@", rank+1, c.photos.count, bar))
}
if sorted.count > 20 {
    let rest = sorted.dropFirst(20)
    print(String(format: "  ... %d more clusters (sizes: %@%@)",
                 rest.count,
                 rest.prefix(10).map { "\($0.photos.count)" }.joined(separator: ", "),
                 rest.count > 10 ? ", ..." : ""))
}

print("\nCluster size distribution:")
let dist = Dictionary(grouping: clusters, by: { $0.photos.count })
    .mapValues { $0.count }.sorted { $0.key > $1.key }
for (size, cnt) in dist {
    print(String(format: "  %3d photo(s) → %d cluster(s)", size, cnt))
}

print("\nDuplicate pairs (CLIP cosine > 0.97):")
var dupCount = 0, shown = 0
for i in 0..<clipEmbs.count {
    for j in (i+1)..<clipEmbs.count {
        if cosine(clipEmbs[i].emb, clipEmbs[j].emb) > 0.97 {
            dupCount += 1
            if shown < 5 { print("  \(clipEmbs[i].name)  ↔  \(clipEmbs[j].name)"); shown += 1 }
        }
    }
}
if dupCount > 5 { print("  ... and \(dupCount - 5) more pairs") }
if dupCount == 0 { print("  None found") }
print()
