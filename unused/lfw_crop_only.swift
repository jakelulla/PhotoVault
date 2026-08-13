// Benchmark using center-crop only (no SCRFD) to isolate embedding quality
// swiftc -O -framework CoreML -framework ImageIO lfw_crop_only.swift -o lfw_crop_only && ./lfw_crop_only

import CoreML
import CoreGraphics
import ImageIO
import Foundation

let lfwDir    = NSHomeDirectory() + "/scikit_learn_data/lfw_home/lfw_funneled"
let pairsFile = NSHomeDirectory() + "/scikit_learn_data/lfw_home/pairs.txt"
let modelsDir = "/Users/jakelulla/Desktop/PhotoSearch/PhotoSearch/PhotoSearch/ML"

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL, nil) else { return nil }
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

// Center-crop 112×112 from a 250×250 LFW image
// Standard ArcFace center crop: take central 112×112
func embedCenterCrop(_ img: CGImage, model: MLModel) throws -> [Float]? {
    let W = img.width, H = img.height
    // For 250×250, center crop gives 69 offset each side
    let cropSize = 200
    let ox = (W - cropSize)/2, oy = (H - cropSize)/2
    let crop = CGRect(x: ox, y: oy, width: cropSize, height: cropSize)
    guard let cropped = img.cropping(to: crop) else { return nil }
    let S = 112
    guard let buf = rgbaPixels(cropped, toWidth: S, height: S) else { return nil }
    let t = try MLMultiArray(shape: [1,3,S as NSNumber,S as NSNumber], dataType: .float32)
    let plane = S*S
    for y in 0..<S { for x in 0..<S {
        let off = (y*S+x)*4
        t[0*plane+y*S+x] = NSNumber(value: (Float(buf[off  ])-127.5)/127.5)
        t[1*plane+y*S+x] = NSNumber(value: (Float(buf[off+1])-127.5)/127.5)
        t[2*plane+y*S+x] = NSNumber(value: (Float(buf[off+2])-127.5)/127.5)
    }}
    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": t]))
    guard let nm = out.featureNames.first(where: { (out.featureValue(for:$0)?.multiArrayValue?.count ?? 0) == 512 }),
          let arr = out.featureValue(for: nm)?.multiArrayValue else { return nil }
    return l2Norm(floats(arr))
}

struct Pair { let p1, p2: String; let same: Bool }

func imgPath(_ name: String, _ num: Int) -> String {
    "\(lfwDir)/\(name)/\(name)_\(String(format:"%04d",num)).jpg"
}

func readPairs() -> [Pair] {
    guard let raw = try? String(contentsOfFile: pairsFile, encoding: .utf8) else { return [] }
    var lines = raw.split(separator:"\n",omittingEmptySubsequences:true).map{String($0)}
    let h = lines.removeFirst().split(separator:"\t").map{Int($0)!}
    let perFold = h[1]; var out = [Pair]()
    for line in lines.prefix(perFold*h[0]) {
        let c = line.split(separator:"\t").map{String($0)}
        guard c.count==3, let n1=Int(c[1]), let n2=Int(c[2]) else { continue }
        out.append(Pair(p1:imgPath(c[0],n1), p2:imgPath(c[0],n2), same:true))
    }
    for line in lines.dropFirst(perFold*h[0]) {
        let c = line.split(separator:"\t").map{String($0)}
        guard c.count==4, let n1=Int(c[1]), let n2=Int(c[3]) else { continue }
        out.append(Pair(p1:imgPath(c[0],n1), p2:imgPath(c[2],n2), same:false))
    }
    return out
}

// ── Main ───────────────────────────────────────────────────────────────────

print("LFW Center-Crop Benchmark (no face detection)")
print(String(repeating:"=",count:50))

let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
let embedder = try loadOrCompile(name:"FaceEmbedder", cfg:cfg)

let pairs = readPairs()
print("  \(pairs.count) pairs  (\(pairs.filter{$0.same}.count) same, \(pairs.filter{!$0.same}.count) diff)")

var embeddings = [String:[Float]]()
let imgs = Array(Set(pairs.flatMap{[$0.p1,$0.p2]}))
let t0 = Date()
for (i,path) in imgs.enumerated() {
    if let img=loadCG(path), let e=try embedCenterCrop(img, model:embedder) {
        embeddings[path]=e
    }
    if (i+1)%500==0 {
        let dt=Date().timeIntervalSince(t0)
        print(String(format:"  [%4d/%4d]  %.1f img/s", i+1, imgs.count, Double(i+1)/dt))
    }
}
print(String(format:"  Done: %d embeddings in %.1fs\n", embeddings.count, Date().timeIntervalSince(t0)))

// Coverage
let covered = pairs.filter { embeddings[$0.p1] != nil && embeddings[$0.p2] != nil }
print("  \(covered.count)/\(pairs.count) pairs covered")

// 10-fold CV
let foldSize = covered.count / 10
var accs = [Float]()
for fold in 0..<10 {
    let testPairs  = Array(covered[(fold*foldSize)..<((fold+1)*foldSize)])
    let trainPairs = covered.filter { p in !testPairs.contains(where: { $0.p1==p.p1 && $0.p2==p.p2 }) }

    var bestT: Float = 0.5, bestAcc: Float = 0
    for ti in stride(from: Float(-0.5), through: Float(1.0), by: 0.01) {
        var correct = 0
        for p in trainPairs {
            guard let e1=embeddings[p.p1], let e2=embeddings[p.p2] else { continue }
            let pred = dot(e1,e2) > ti
            if pred == p.same { correct += 1 }
        }
        let acc = Float(correct)/Float(trainPairs.count)
        if acc > bestAcc { bestAcc=acc; bestT=ti }
    }
    var tc = 0
    for p in testPairs {
        guard let e1=embeddings[p.p1], let e2=embeddings[p.p2] else { continue }
        if (dot(e1,e2)>bestT)==p.same { tc += 1 }
    }
    let ta = Float(tc)/Float(testPairs.count)
    accs.append(ta)
    print(String(format:"  Fold %2d: thresh=%.2f  test=%.2f%%", fold+1, bestT, ta*100))
}

let mean = accs.reduce(0,+)/Float(accs.count)
let std  = sqrt(accs.map{($0-mean)*($0-mean)}.reduce(0,+)/Float(accs.count))
print(String(repeating:"=",count:50))
print(String(format:"LFW Accuracy (center crop): %.2f%% ± %.2f%%", mean*100, std*100))
print(String(repeating:"=",count:50))
