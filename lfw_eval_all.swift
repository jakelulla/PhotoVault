// LFW Face Verification Benchmark — CoreML pipeline
// Tests ArcFace accuracy on the standard LFW pairs protocol (10-fold, 6000 pairs).
//
// Compile & run:
//   swiftc -O -framework CoreML -framework ImageIO lfw_eval.swift -o lfw_eval && ./lfw_eval

import CoreML
import CoreGraphics
import ImageIO
import Foundation

// Line-buffer stdout even when piped, so progress is visible and a crash
// doesn't swallow all prior output.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Config

let lfwDir    = NSHomeDirectory() + "/scikit_learn_data/lfw_home/lfw_funneled"
let pairsFile = NSHomeDirectory() + "/scikit_learn_data/lfw_home/pairs.txt"
let modelsDir = "/Users/jakelulla/Desktop/PhotoSearch/PhotoSearch/PhotoSearch/ML"

let detThresh: Float = 0.3   // lower than testbench since LFW images are face-centered

// MARK: - Shared math helpers

func floats(_ arr: MLMultiArray) -> [Float] { (0..<arr.count).map { arr[$0].floatValue } }

func l2Norm(_ v: [Float]) -> [Float] {
    let n = sqrt(v.reduce(0.0) { $0 + $1*$1 }) + 1e-10
    return v.map { $0 / n }
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
}

// MARK: - Image helpers

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgbaPixels(_ img: CGImage, toWidth w: Int, height h: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    // Keep the buffer pointer valid for the context's whole lifetime —
    // passing &buf directly to CGContext(data:) is UB once the call returns.
    let ok = buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Bool in
        guard let ctx = CGContext(
            data: ptr.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        // NOTE: no flip — raw CGBitmapContext already stores row 0 = top of image
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? buf : nil
}

// MARK: - SCRFD

struct DetFace { var bbox: CGRect; var score: Float; var landmarks: [CGPoint] }

func scrfdTensor(_ buf: [UInt8], drawnW: Int, drawnH: Int, pad: Int) throws -> MLMultiArray {
    let t = try MLMultiArray(shape: [1, 3, pad as NSNumber, pad as NSNumber], dataType: .float16)
    let plane = pad*pad, row = drawnW*4
    for y in 0..<pad { for x in 0..<pad {
        let r, g, b: Float
        if y < drawnH && x < drawnW {
            let off = y*row + x*4
            r = (Float(buf[off    ])-127.5)/128; g = (Float(buf[off+1])-127.5)/128; b = (Float(buf[off+2])-127.5)/128
        } else { r = 0; g = 0; b = 0 }
        t[0*plane + y*pad + x] = NSNumber(value: r)
        t[1*plane + y*pad + x] = NSNumber(value: g)
        t[2*plane + y*pad + x] = NSNumber(value: b)
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
            let inter = max(0,min(a[2],b[2])-max(a[0],b[0])) * max(0,min(a[3],b[3])-max(a[1],b[1]))
            if inter / ((a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-inter+1e-7) > thresh {
                suppressed[jj] = true
            }
        }
    }
    return keep
}

func detectFaces(_ img: CGImage, model: MLModel) throws -> [DetFace] {
    let W = img.width, H = img.height
    let pad = 640
    let scale = Float(min(Float(pad)/Float(W), Float(pad)/Float(H)))
    let nW = Int((Float(W)*scale).rounded()), nH = Int((Float(H)*scale).rounded())
    guard let buf = rgbaPixels(img, toWidth: nW, height: nH) else { return [] }
    let t = try scrfdTensor(buf, drawnW: nW, drawnH: nH, pad: pad)
    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": t]))

    var byCol: [Int: [(String, Int)]] = [:]
    for name in out.featureNames {
        guard let arr = out.featureValue(for: name)?.multiArrayValue else { continue }
        let sh = arr.shape.map { $0.intValue }; guard sh.count == 2 else { continue }
        byCol[sh[1], default: []].append((name, sh[0]))
    }
    for k in byCol.keys { byCol[k]!.sort { $0.1 > $1.1 } }
    guard let sn = byCol[1], let bn = byCol[4], let kn = byCol[10],
          sn.count == 3, bn.count == 3, kn.count == 3 else { return [] }

    let strides = [8,16,32]; let anch = 2
    var allS: [Float] = []; var allB: [[Float]] = []; var allK: [[Float]] = []

    for s in 0..<3 {
        let stride = strides[s], fH = pad/stride, fW = pad/stride, nPos = fH*fW*anch
        guard let sArr = out.featureValue(for: sn[s].0)?.multiArrayValue,
              let bArr = out.featureValue(for: bn[s].0)?.multiArrayValue,
              let kArr = out.featureValue(for: kn[s].0)?.multiArrayValue else { continue }
        let sp = (0..<nPos).map      { sArr[$0].floatValue }
        let bp = (0..<nPos*4).map    { bArr[$0].floatValue }
        let kp = (0..<nPos*10).map   { kArr[$0].floatValue }
        var ai = 0
        for y in 0..<fH { for x in 0..<fW {
            let cx = Float(x*stride), cy = Float(y*stride), st = Float(stride)
            for _ in 0..<anch {
                if sp[ai] >= detThresh {
                    allB.append([cx-bp[ai*4]*st, cy-bp[ai*4+1]*st, cx+bp[ai*4+2]*st, cy+bp[ai*4+3]*st])
                    allS.append(sp[ai])
                    allK.append((0..<5).flatMap { k -> [Float] in [cx+kp[ai*10+k*2]*st, cy+kp[ai*10+k*2+1]*st] })
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
            x: CGFloat(max(0,min(b[0]*inv,mX))), y: CGFloat(max(0,min(b[1]*inv,mY))),
            width:  CGFloat(max(0,min(b[2]*inv,mX))-max(0,min(b[0]*inv,mX))),
            height: CGFloat(max(0,min(b[3]*inv,mY))-max(0,min(b[1]*inv,mY)))
        )
        let pts = (0..<5).map { k in CGPoint(x: CGFloat(max(0,min(allK[i][k*2]*inv,mX))),
                                              y: CGFloat(max(0,min(allK[i][k*2+1]*inv,mY)))) }
        return DetFace(bbox: bbox, score: allS[i], landmarks: pts)
    }
}

// MARK: - Face alignment

let arcDst: [CGPoint] = [
    CGPoint(x:38.2946, y:51.6963), CGPoint(x:73.5318, y:51.5014),
    CGPoint(x:56.0252, y:71.7366), CGPoint(x:41.5493, y:92.3655),
    CGPoint(x:70.7299, y:92.2041),
]

func similarityTransform(_ src: [CGPoint], _ dst: [CGPoint]) -> CGAffineTransform {
    var sXX: CGFloat=0,sX: CGFloat=0,sY: CGFloat=0,sUX: CGFloat=0,sVX: CGFloat=0,sU: CGFloat=0,sV: CGFloat=0
    for i in 0..<src.count {
        let (x,y,u,v) = (src[i].x,src[i].y,dst[i].x,dst[i].y)
        sXX+=x*x+y*y; sX+=x; sY+=y; sUX+=u*x+v*y; sVX+=u*y-v*x; sU+=u; sV+=v
    }
    let n=CGFloat(src.count), D=sXX*n-(sX*sX+sY*sY); guard abs(D)>1e-10 else { return .identity }
    let a=(sUX*n-sX*sU-sY*sV)/D, b=(-sVX*n+sY*sU-sX*sV)/D
    let c=(sU-a*sX+b*sY)/n, d=(sV-b*sX-a*sY)/n
    return CGAffineTransform(a:a, b:b, c:-b, d:a, tx:c, ty:d)
}

func alignFace(_ img: CGImage, face: DetFace) -> CGImage? {
    let S = 112, W = img.width, H = img.height
    // Get source pixels in y-down format (row 0 = top)
    guard let srcBuf = rgbaPixels(img, toWidth: W, height: H) else { return nil }
    // Inverse-map each output pixel to source (matches OpenCV warpAffine semantics)
    let Tinv = similarityTransform(face.landmarks, arcDst).inverted()
    var outBuf = [UInt8](repeating: 0, count: S*S*4)
    for oy in 0..<S { for ox in 0..<S {
        let sp  = CGPoint(x: CGFloat(ox), y: CGFloat(oy)).applying(Tinv)
        let sx  = Int(sp.x.rounded()), sy = Int(sp.y.rounded())
        guard sx >= 0 && sx < W && sy >= 0 && sy < H else { continue }
        let di = (oy*S + ox)*4, si = (sy*W + sx)*4
        outBuf[di] = srcBuf[si]; outBuf[di+1] = srcBuf[si+1]
        outBuf[di+2] = srcBuf[si+2]; outBuf[di+3] = srcBuf[si+3]
    }}
    // Create CGImage treating outBuf row 0 as the top of the image
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let prov = CGDataProvider(data: NSData(bytes: outBuf, length: outBuf.count) as CFData)
    else { return nil }
    return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: S*4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: info, provider: prov,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// MARK: - ArcFace embedding

func embedFace(_ img: CGImage, model: MLModel) throws -> [Float]? {
    let S = 112
    guard let buf = rgbaPixels(img, toWidth: S, height: S) else { return nil }
    let t = try MLMultiArray(shape: [1,3,S as NSNumber,S as NSNumber], dataType: .float32)
    let plane = S*S
    for y in 0..<S { for x in 0..<S {
        let off=(y*S+x)*4
        t[0*plane+y*S+x] = NSNumber(value: (Float(buf[off    ])-127.5)/127.5)
        t[1*plane+y*S+x] = NSNumber(value: (Float(buf[off + 1])-127.5)/127.5)
        t[2*plane+y*S+x] = NSNumber(value: (Float(buf[off + 2])-127.5)/127.5)
    }}
    let inp = try MLDictionaryFeatureProvider(dictionary: ["input": t])
    let out = try model.prediction(from: inp)
    guard let name = out.featureNames.first(where: { (out.featureValue(for: $0)?.multiArrayValue?.count ?? 0) == 512 }),
          let arr = out.featureValue(for: name)?.multiArrayValue else { return nil }
    return l2Norm(floats(arr))
}

// MARK: - Full-image fallback embedding (center-crop the 250×250 LFW image as if it's the face)

func fallbackEmbed(_ img: CGImage, embedder: MLModel) throws -> [Float]? {
    // LFW funneled images are already face-centered — use the central 200×200 region
    let S = 112, W = img.width, H = img.height
    let crop = CGRect(x: (W-200)/2, y: (H-200)/2, width: 200, height: 200)
    guard let cropped = img.cropping(to: crop) else { return nil }
    return try embedFace(cropped, model: embedder)
}

// MARK: - Model loading

func loadOrCompile(name: String, cfg: MLModelConfiguration) throws -> MLModel {
    let fm = FileManager.default
    let src   = URL(fileURLWithPath: "\(modelsDir)/\(name).mlpackage")
    let cache = URL(fileURLWithPath: "\(modelsDir)/\(name).mlmodelc")
    if !fm.fileExists(atPath: cache.path) {
        print("  Compiling \(name)…")
        let tmp = try MLModel.compileModel(at: src)
        try fm.moveItem(at: tmp, to: cache)
    }
    return try MLModel(contentsOf: cache, configuration: cfg)
}

// MARK: - Pair parsing

struct Pair { let path1: String; let path2: String; let sameLabel: Bool; let fold: Int }

func imagePath(name: String, num: Int) -> String {
    "\(lfwDir)/\(name)/\(name)_\(String(format: "%04d", num)).jpg"
}

func parsePairs() -> [Pair] {
    guard let raw = try? String(contentsOfFile: pairsFile, encoding: .utf8) else {
        fputs("Cannot read pairs.txt\n", stderr); exit(1)
    }
    var lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
    let header = lines.removeFirst().split(separator: "\t").map { Int($0)! }
    let (nFolds, perFold) = (header[0], header[1])

    var pairs: [Pair] = []
    // Same-person pairs
    for (idx, line) in lines.prefix(nFolds*perFold).enumerated() {
        let cols = line.split(separator: "\t").map { String($0) }
        guard cols.count == 3, let n1 = Int(cols[1]), let n2 = Int(cols[2]) else { continue }
        let fold = idx / perFold
        pairs.append(Pair(path1: imagePath(name: cols[0], num: n1),
                          path2: imagePath(name: cols[0], num: n2),
                          sameLabel: true, fold: fold))
    }
    // Different-person pairs
    for (idx, line) in lines.dropFirst(nFolds*perFold).prefix(nFolds*perFold).enumerated() {
        let cols = line.split(separator: "\t").map { String($0) }
        guard cols.count == 4, let n1 = Int(cols[1]), let n2 = Int(cols[3]) else { continue }
        let fold = idx / perFold
        pairs.append(Pair(path1: imagePath(name: cols[0], num: n1),
                          path2: imagePath(name: cols[2], num: n2),
                          sameLabel: false, fold: fold))
    }
    return pairs
}

// MARK: - 10-fold cross-validation accuracy

func accuracy(pairs: [Pair], embeddings: [String: [Float]], thresh: Float) -> (correct: Int, total: Int) {
    var correct = 0, total = 0
    for p in pairs {
        guard let e1 = embeddings[p.path1], let e2 = embeddings[p.path2] else { continue }
        let predicted = dot(e1, e2) >= thresh
        if predicted == p.sameLabel { correct += 1 }
        total += 1
    }
    return (correct, total)
}

func crossValAccuracy(pairs: [Pair], embeddings: [String: [Float]]) -> (mean: Double, std: Double, perFold: [Double]) {
    let nFolds = 10
    var foldAccuracies: [Double] = []

    for testFold in 0..<nFolds {
        let trainPairs = pairs.filter { $0.fold != testFold }
        let testPairs  = pairs.filter { $0.fold == testFold }

        // Sweep threshold on train set
        var bestThresh: Float = 0.4
        var bestTrainAcc = 0.0
        for ti in stride(from: Float(0.1), through: Float(0.9), by: Float(0.01)) {
            let (c, t) = accuracy(pairs: trainPairs, embeddings: embeddings, thresh: ti)
            let a = t > 0 ? Double(c)/Double(t) : 0
            if a > bestTrainAcc { bestTrainAcc = a; bestThresh = ti }
        }

        let (c, t) = accuracy(pairs: testPairs, embeddings: embeddings, thresh: bestThresh)
        let foldAcc = t > 0 ? Double(c)/Double(t) : 0
        foldAccuracies.append(foldAcc)
        print(String(format: "  Fold %2d: thresh=%.2f  train=%.2f%%  test=%.2f%%  (%d/%d)",
                     testFold+1, bestThresh, bestTrainAcc*100, foldAcc*100, c, t))
    }

    let mean = foldAccuracies.reduce(0, +) / Double(nFolds)
    let variance = foldAccuracies.map { ($0 - mean)*($0 - mean) }.reduce(0, +) / Double(nFolds)
    return (mean, sqrt(variance), foldAccuracies)
}

// MARK: - AUC (trapezoidal)

func auc(pairs: [Pair], embeddings: [String: [Float]]) -> Double {
    var scored: [(sim: Float, label: Bool)] = []
    for p in pairs {
        guard let e1 = embeddings[p.path1], let e2 = embeddings[p.path2] else { continue }
        scored.append((dot(e1, e2), p.sameLabel))
    }
    scored.sort { $0.sim > $1.sim }
    let pos = Double(scored.filter { $0.label }.count)
    let neg = Double(scored.filter { !$0.label }.count)
    var tp = 0.0, fp = 0.0, prevFpr = 0.0, prevTpr = 0.0, area = 0.0
    for s in scored {
        if s.label { tp += 1 } else { fp += 1 }
        let tpr = tp/pos, fpr = fp/neg
        area += (fpr - prevFpr) * (tpr + prevTpr) / 2
        prevFpr = fpr; prevTpr = tpr
    }
    return area
}

// MARK: - Main

print("LFW Face Verification Benchmark")
print(String(repeating: "=", count: 50))

let cfg = MLModelConfiguration()
cfg.computeUnits = .all  // ANE validation run

print("Loading models…")
let detModel: MLModel
let embModel: MLModel
do {
    detModel = try loadOrCompile(name: "FaceDetector", cfg: cfg); print("  ✓ FaceDetector")
    embModel = try loadOrCompile(name: "FaceEmbedder", cfg: cfg); print("  ✓ FaceEmbedder")
} catch {
    fputs("ERROR: \(error)\n", stderr); exit(1)
}

print("\nParsing pairs…")
let pairs = parsePairs()
print("  \(pairs.count) pairs (\(pairs.filter{$0.sameLabel}.count) same, \(pairs.filter{!$0.sameLabel}.count) different)")

// Collect unique image paths
var uniquePaths = Set<String>()
for p in pairs { uniquePaths.insert(p.path1); uniquePaths.insert(p.path2) }
let sortedPaths = uniquePaths.sorted()
print("  \(sortedPaths.count) unique images")

print("\nRunning inference…")
var embeddings: [String: [Float]] = [:]
var detected = 0, fallback = 0, failed = 0
let t0 = Date()

for (i, path) in sortedPaths.enumerated() {
    // Drain autoreleased CG/CoreML objects each iteration — without this a
    // long CLI loop accumulates them and eventually crashes.
    autoreleasepool {
        guard let img = loadCGImage(path) else { failed += 1; return }

        do {
            let faces = try detectFaces(img, model: detModel)
            // Pick highest-score face (faces are NMS-sorted by score, highest first)
            if let best = faces.first, let aligned = alignFace(img, face: best),
               let emb = try embedFace(aligned, model: embModel) {
                embeddings[path] = emb
                detected += 1
            } else {
                // Fallback: use center crop (LFW images are face-centered)
                if let emb = try fallbackEmbed(img, embedder: embModel) {
                    embeddings[path] = emb
                    fallback += 1
                } else {
                    failed += 1
                }
            }
        } catch {
            failed += 1
        }
    }

    if (i+1) % 500 == 0 || i == sortedPaths.count-1 {
        let s = Date().timeIntervalSince(t0)
        print(String(format: "  [%4d/%d]  det: %d  fallback: %d  fail: %d  %.1f img/s",
                     i+1, sortedPaths.count, detected, fallback, failed, Double(i+1)/s))
    }
}

let elapsed = Date().timeIntervalSince(t0)
print(String(format: "\nEmbedding stats:"))
print(String(format: "  Detected (SCRFD)  %d / %d  (%.1f%%)",
             detected, sortedPaths.count, 100.0*Double(detected)/Double(sortedPaths.count)))
print(String(format: "  Fallback (crop)   %d  (%.1f%%)",
             fallback, 100.0*Double(fallback)/Double(sortedPaths.count)))
print(String(format: "  Failed            %d",  failed))
print(String(format: "  Time              %.1fs  (%.1f img/s)", elapsed, Double(sortedPaths.count)/elapsed))

// How many pairs have both embeddings available
let coverablePairs = pairs.filter { embeddings[$0.path1] != nil && embeddings[$0.path2] != nil }
print(String(format: "\n%d / %d pairs have both embeddings (%.1f%%)",
             coverablePairs.count, pairs.count, 100.0*Double(coverablePairs.count)/Double(pairs.count)))

// MARK: - Similarity distribution diagnostic
print("\nSimilarity distributions:")
var sameSims: [Float] = [], diffSims: [Float] = []
for p in coverablePairs {
    guard let e1 = embeddings[p.path1], let e2 = embeddings[p.path2] else { continue }
    let s = dot(e1, e2)
    if p.sameLabel { sameSims.append(s) } else { diffSims.append(s) }
}
func stats(_ v: [Float]) -> (mean: Float, std: Float, min: Float, max: Float) {
    let n = Float(v.count), m = v.reduce(0,+)/n
    let s = sqrt(v.map{($0-m)*($0-m)}.reduce(0,+)/n)
    return (m, s, v.min()!, v.max()!)
}
let ss = stats(sameSims), ds = stats(diffSims)
print(String(format: "  Same-person   n=%d  mean=%.4f  std=%.4f  [%.4f, %.4f]",
             sameSims.count, ss.mean, ss.std, ss.min, ss.max))
print(String(format: "  Diff-person   n=%d  mean=%.4f  std=%.4f  [%.4f, %.4f]",
             diffSims.count, ds.mean, ds.std, ds.min, ds.max))
// Text histogram
let bins = 20
let lo: Float = -0.2, hi: Float = 0.8, bw = (hi-lo)/Float(bins)
var sameHist = [Int](repeating: 0, count: bins), diffHist = [Int](repeating: 0, count: bins)
for s in sameSims { let b = min(bins-1, max(0, Int((s-lo)/bw))); sameHist[b] += 1 }
for s in diffSims  { let b = min(bins-1, max(0, Int((s-lo)/bw))); diffHist[b] += 1 }
let maxH = max(sameHist.max()!, diffHist.max()!)
print("\nSimilarity histogram  (S=same, D=different):")
// NOTE: %s with Swift String is UB (strlen on garbage) — use interpolation
print("    sim    #S  S" + String(repeating: " ", count: 23) + "  #D  D")
for i in 0..<bins {
    let simLo = lo + Float(i)*bw
    let sBar = String(repeating: "S", count: sameHist[i]*24/max(maxH,1))
    let dBar = String(repeating: "D", count: diffHist[i]*24/max(maxH,1))
    let sBarPad = sBar.padding(toLength: 24, withPad: " ", startingAt: 0)
    print(String(format: "  %+.2f  %4d  ", simLo, sameHist[i]) + sBarPad
          + String(format: "  %4d  ", diffHist[i]) + dBar)
}

print("\n" + String(repeating: "=", count: 50))
print("10-FOLD CROSS-VALIDATION")
print(String(repeating: "=", count: 50))
let (mean, std, _) = crossValAccuracy(pairs: coverablePairs, embeddings: embeddings)

print(String(repeating: "=", count: 50))
print(String(format: "LFW Accuracy:  %.4f ± %.4f  (%.2f%% ± %.2f%%)",
             mean, std, mean*100, std*100))

let aucScore = auc(pairs: coverablePairs, embeddings: embeddings)
print(String(format: "AUC:           %.4f", aucScore))
print(String(repeating: "=", count: 50))

print("""

Reference numbers (from papers):
  ArcFace (R100, ONNX Float32):  99.77%
  ArcFace (R50,  ONNX Float32):  99.50%
  Typical on-device (MobileNet): 97–98%
  Random baseline:               50.00%
""")
