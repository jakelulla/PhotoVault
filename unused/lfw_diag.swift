// lfw_diag.swift — fast diagnostic: 10 same + 10 different pairs, prints full debug
// swiftc -O -framework CoreML -framework ImageIO lfw_diag.swift -o lfw_diag && ./lfw_diag

import CoreML
import CoreGraphics
import ImageIO
import Foundation

let lfwDir    = NSHomeDirectory() + "/scikit_learn_data/lfw_home/lfw_funneled"
let pairsFile = NSHomeDirectory() + "/scikit_learn_data/lfw_home/pairs.txt"
let modelsDir = "/Users/jakelulla/Desktop/PhotoSearch/PhotoSearch/PhotoSearch/ML"

// ── Math ────────────────────────────────────────────────────────────────────

func floats(_ a: MLMultiArray) -> [Float] { (0..<a.count).map { a[$0].floatValue } }
func l2Norm(_ v: [Float]) -> [Float] {
    let n = sqrt(v.reduce(0) { $0+$1*$1 }) + 1e-10; return v.map { $0/n }
}
func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }

// ── Image ───────────────────────────────────────────────────────────────────

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgbaPixels(_ img: CGImage, toWidth w: Int, height h: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: w*h*4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // NOTE: no flip — a raw CGBitmapContext already stores row 0 = top of image
    ctx.draw(img, in: CGRect(x:0, y:0, width:w, height:h))
    return buf
}

// ── SCRFD ───────────────────────────────────────────────────────────────────

struct DetFace { var bbox: CGRect; var score: Float; var landmarks: [CGPoint] }

func detectFaces(_ img: CGImage, model: MLModel) throws -> [DetFace] {
    let W = img.width, H = img.height, pad = 640
    let scale = Float(min(Float(pad)/Float(W), Float(pad)/Float(H)))
    let nW = Int((Float(W)*scale).rounded()), nH = Int((Float(H)*scale).rounded())
    guard let buf = rgbaPixels(img, toWidth: nW, height: nH) else { return [] }

    let t = try MLMultiArray(shape: [1,3,pad as NSNumber,pad as NSNumber], dataType: .float16)
    let plane = pad*pad, row = nW*4
    for y in 0..<pad { for x in 0..<pad {
        let r,g,b: Float
        if y<nH && x<nW { let o=y*row+x*4; r=(Float(buf[o])-127.5)/128; g=(Float(buf[o+1])-127.5)/128; b=(Float(buf[o+2])-127.5)/128 }
        else { r=0; g=0; b=0 }
        t[0*plane+y*pad+x]=NSNumber(value:r); t[1*plane+y*pad+x]=NSNumber(value:g); t[2*plane+y*pad+x]=NSNumber(value:b)
    }}

    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": t]))
    var byCol: [Int:[(String,Int)]] = [:]
    for name in out.featureNames {
        guard let arr = out.featureValue(for:name)?.multiArrayValue else { continue }
        let sh = arr.shape.map{$0.intValue}; guard sh.count==2 else { continue }
        byCol[sh[1], default:[]].append((name,sh[0]))
    }
    for k in byCol.keys { byCol[k]!.sort{$0.1>$1.1} }
    guard let sn=byCol[1], let bn=byCol[4], let kn=byCol[10],
          sn.count==3, bn.count==3, kn.count==3 else { return [] }

    let strides=[8,16,32]; var allS=[Float](); var allB=[[Float]](); var allK=[[Float]]()
    for s in 0..<3 {
        let stride=strides[s], fH=pad/stride, fW=pad/stride, nPos=fH*fW*2
        guard let sArr=out.featureValue(for:sn[s].0)?.multiArrayValue,
              let bArr=out.featureValue(for:bn[s].0)?.multiArrayValue,
              let kArr=out.featureValue(for:kn[s].0)?.multiArrayValue else { continue }
        let sp=(0..<nPos).map{sArr[$0].floatValue}
        let bp=(0..<nPos*4).map{bArr[$0].floatValue}
        let kp=(0..<nPos*10).map{kArr[$0].floatValue}
        var ai=0
        for y in 0..<fH { for x in 0..<fW {
            let cx=Float(x*stride),cy=Float(y*stride),st=Float(stride)
            for _ in 0..<2 {
                if sp[ai]>=0.3 {
                    allB.append([cx-bp[ai*4]*st,cy-bp[ai*4+1]*st,cx+bp[ai*4+2]*st,cy+bp[ai*4+3]*st])
                    allS.append(sp[ai])
                    allK.append((0..<5).flatMap{k->[Float] in [cx+kp[ai*10+k*2]*st, cy+kp[ai*10+k*2+1]*st]})
                }
                ai+=1
            }
        }}
    }
    guard !allS.isEmpty else { return [] }

    let inv=1/scale, mX=Float(W-1), mY=Float(H-1)
    var order=(0..<allS.count).sorted{allS[$0]>allS[$1]}
    var supp=[Bool](repeating:false,count:allS.count); var keep=[Int]()
    for i in 0..<order.count {
        let ii=order[i]; if supp[ii] { continue }; keep.append(ii)
        for j in (i+1)..<order.count {
            let jj=order[j]; if supp[jj] { continue }
            let a=allB[ii],b=allB[jj]
            let inter=max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
            if inter/((a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-inter+1e-7)>0.4 { supp[jj]=true }
        }
    }
    return keep.map { i in
        let b=allB[i]
        return DetFace(
            bbox: CGRect(x:CGFloat(max(0,min(b[0]*inv,mX))), y:CGFloat(max(0,min(b[1]*inv,mY))),
                         width:CGFloat(max(0,min(b[2]*inv,mX))-max(0,min(b[0]*inv,mX))),
                         height:CGFloat(max(0,min(b[3]*inv,mY))-max(0,min(b[1]*inv,mY)))),
            score: allS[i],
            landmarks: (0..<5).map{k in CGPoint(x:CGFloat(max(0,min(allK[i][k*2]*inv,mX))),
                                                 y:CGFloat(max(0,min(allK[i][k*2+1]*inv,mY))))}
        )
    }
}

// ── Alignment ───────────────────────────────────────────────────────────────

let arcDst: [CGPoint] = [
    CGPoint(x:38.2946,y:51.6963), CGPoint(x:73.5318,y:51.5014),
    CGPoint(x:56.0252,y:71.7366), CGPoint(x:41.5493,y:92.3655),
    CGPoint(x:70.7299,y:92.2041),
]

func similarityTransform(_ src: [CGPoint], _ dst: [CGPoint]) -> CGAffineTransform {
    var sXX:CGFloat=0,sX:CGFloat=0,sY:CGFloat=0,sUX:CGFloat=0,sVX:CGFloat=0,sU:CGFloat=0,sV:CGFloat=0
    for i in 0..<src.count {
        let (x,y,u,v)=(src[i].x,src[i].y,dst[i].x,dst[i].y)
        sXX+=x*x+y*y;sX+=x;sY+=y;sUX+=u*x+v*y;sVX+=u*y-v*x;sU+=u;sV+=v
    }
    let n=CGFloat(src.count),D=sXX*n-(sX*sX+sY*sY); guard abs(D)>1e-10 else { return .identity }
    let a=(sUX*n-sX*sU-sY*sV)/D, b=(-sVX*n+sY*sU-sX*sV)/D
    let c=(sU-a*sX+b*sY)/n, d=(sV-b*sX-a*sY)/n
    return CGAffineTransform(a:a,b:b,c:-b,d:a,tx:c,ty:d)
}

func alignFace(_ img: CGImage, landmarks: [CGPoint]) -> CGImage? {
    let S=112, W=img.width, H=img.height
    guard let srcBuf=rgbaPixels(img, toWidth:W, height:H) else { return nil }
    let Tinv=similarityTransform(landmarks, arcDst).inverted()
    var out=[UInt8](repeating:0, count:S*S*4)
    for oy in 0..<S { for ox in 0..<S {
        let sp=CGPoint(x:CGFloat(ox),y:CGFloat(oy)).applying(Tinv)
        let sx=Int(sp.x.rounded()),sy=Int(sp.y.rounded())
        guard sx>=0&&sx<W&&sy>=0&&sy<H else { continue }
        let di=(oy*S+ox)*4, si=(sy*W+sx)*4
        out[di]=srcBuf[si];out[di+1]=srcBuf[si+1];out[di+2]=srcBuf[si+2];out[di+3]=srcBuf[si+3]
    }}
    let info=CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let prov=CGDataProvider(data:NSData(bytes:out,length:out.count) as CFData) else { return nil }
    return CGImage(width:S,height:S,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:S*4,
                   space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info,provider:prov,
                   decode:nil,shouldInterpolate:true,intent:.defaultIntent)
}

// ── ArcFace embedding ───────────────────────────────────────────────────────

func embed(_ face: CGImage, model: MLModel) throws -> [Float]? {
    let S=112
    guard let buf=rgbaPixels(face, toWidth:S, height:S) else { return nil }
    let t=try MLMultiArray(shape:[1,3,S as NSNumber,S as NSNumber], dataType:.float32)
    let plane=S*S
    for y in 0..<S { for x in 0..<S {
        let off=(y*S+x)*4
        t[0*plane+y*S+x]=NSNumber(value:(Float(buf[off    ])-127.5)/127.5)
        t[1*plane+y*S+x]=NSNumber(value:(Float(buf[off + 1])-127.5)/127.5)
        t[2*plane+y*S+x]=NSNumber(value:(Float(buf[off + 2])-127.5)/127.5)
    }}
    let out=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["input":t]))
    guard let name=out.featureNames.first(where:{(out.featureValue(for:$0)?.multiArrayValue?.count ?? 0)==512}),
          let arr=out.featureValue(for:name)?.multiArrayValue else { return nil }
    return l2Norm(floats(arr))
}

// Fallback: center-crop without SCRFD
func embedCrop(_ img: CGImage, model: MLModel) throws -> [Float]? {
    let W=img.width, H=img.height
    let crop=CGRect(x:(W-200)/2, y:(H-200)/2, width:200, height:200)
    guard let cropped=img.cropping(to:crop) else { return nil }
    return try embed(cropped, model:model)
}

// ── Full pipeline for one image ─────────────────────────────────────────────

func processImage(path: String, detector: MLModel, embedder: MLModel) throws -> (emb: [Float], method: String, landmarks: [CGPoint]?) {
    guard let img = loadCG(path) else {
        throw NSError(domain:"diag", code:1, userInfo:[NSLocalizedDescriptionKey:"cannot load \(path)"])
    }
    let faces = try detectFaces(img, model: detector)
    if let best = faces.first, let aligned = alignFace(img, landmarks: best.landmarks),
       let emb = try embed(aligned, model: embedder) {
        return (emb, String(format:"SCRFD(score=%.3f)", best.score), best.landmarks)
    }
    if let emb = try embedCrop(img, model: embedder) {
        return (emb, "crop", nil)
    }
    throw NSError(domain:"diag", code:2, userInfo:[NSLocalizedDescriptionKey:"no embedding"])
}

// ── Model loading ────────────────────────────────────────────────────────────

func loadOrCompile(name: String, cfg: MLModelConfiguration) throws -> MLModel {
    let fm=FileManager.default
    let src=URL(fileURLWithPath:"\(modelsDir)/\(name).mlpackage")
    let cache=URL(fileURLWithPath:"\(modelsDir)/\(name).mlmodelc")
    if !fm.fileExists(atPath:cache.path) {
        let tmp=try MLModel.compileModel(at:src); try fm.moveItem(at:tmp, to:cache)
    }
    return try MLModel(contentsOf:cache, configuration:cfg)
}

// ── Parse pairs ─────────────────────────────────────────────────────────────

func imgPath(_ name: String, _ num: Int) -> String {
    "\(lfwDir)/\(name)/\(name)_\(String(format:"%04d",num)).jpg"
}

struct Pair { let p1,p2: String; let same: Bool }

func readPairs(nSame: Int, nDiff: Int) -> [Pair] {
    guard let raw=try? String(contentsOfFile:pairsFile, encoding:.utf8) else { return [] }
    var lines=raw.split(separator:"\n",omittingEmptySubsequences:true).map{String($0)}
    let h=lines.removeFirst().split(separator:"\t").map{Int($0)!}
    let perFold=h[1]
    var out=[Pair]()
    for line in Array(lines.prefix(perFold*h[0])).prefix(nSame) {
        let c=line.split(separator:"\t").map{String($0)}
        guard c.count==3, let n1=Int(c[1]),let n2=Int(c[2]) else { continue }
        out.append(Pair(p1:imgPath(c[0],n1), p2:imgPath(c[0],n2), same:true))
    }
    for line in lines.dropFirst(perFold*h[0]).prefix(nDiff) {
        let c=line.split(separator:"\t").map{String($0)}
        guard c.count==4, let n1=Int(c[1]),let n2=Int(c[3]) else { continue }
        out.append(Pair(p1:imgPath(c[0],n1), p2:imgPath(c[2],n2), same:false))
    }
    return out
}

// ── Main ─────────────────────────────────────────────────────────────────────

print("LFW Diagnostic")
print(String(repeating:"=",count:60))

let cfg=MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
let det = try loadOrCompile(name:"FaceDetector", cfg:cfg)
let emb = try loadOrCompile(name:"FaceEmbedder", cfg:cfg)
print("Models loaded.\n")

let pairs = readPairs(nSame:15, nDiff:15)
print("Testing \(pairs.count) pairs (15 same + 15 different)\n")

var sameSims=[Float](), diffSims=[Float]()
var cache=[String:[Float]]()

for (i,pair) in pairs.enumerated() {
    let label = pair.same ? "SAME" : "DIFF"

    func getEmb(_ path: String) throws -> [Float] {
        if let e=cache[path] { return e }
        let (e,method,lm)=try processImage(path:path, detector:det, embedder:emb)
        cache[path]=e
        let fname=URL(fileURLWithPath:path).lastPathComponent
        var lmStr=""
        if let lm=lm {
            lmStr = " landmarks=[\(lm.map{String(format:"(%.0f,%.0f)",$0.x,$0.y)}.joined(separator:","))]"
        }
        print("  \(fname)  method=\(method)\(lmStr)")
        print("  emb[:8]=[\(e.prefix(8).map{String(format:"%.4f",$0)}.joined(separator:","))]")
        return e
    }

    print("[\(i+1)/\(pairs.count)] \(label)")
    let e1=try getEmb(pair.p1)
    let e2=try getEmb(pair.p2)
    let sim=dot(e1,e2)
    print("  → cosine similarity = \(String(format:"%.4f",sim))\n")
    if pair.same { sameSims.append(sim) } else { diffSims.append(sim) }
}

func stats(_ v:[Float]) -> String {
    let n=Float(v.count), m=v.reduce(0,+)/n
    let s=sqrt(v.map{($0-m)*($0-m)}.reduce(0,+)/n)
    return String(format:"mean=%.4f std=%.4f min=%.4f max=%.4f",m,s,v.min()!,v.max()!)
}

print(String(repeating:"=",count:60))
print("SAME pairs (\(sameSims.count)): \(stats(sameSims))")
print("DIFF pairs (\(diffSims.count)): \(stats(diffSims))")
print(String(repeating:"=",count:60))

// Also test: what if we normalise differently?
print("\nNormalization check — first SAME pair, trying alt norms on the aligned face:")
if let pair=pairs.first(where:{$0.same}), let img=loadCG(pair.p1) {
    let faces = try detectFaces(img, model:det)
    if let best=faces.first, let aligned=alignFace(img, landmarks:best.landmarks),
       let buf=rgbaPixels(aligned, toWidth:112, height:112) {
        // Sample pixels from center of face
        let cx=56, cy=56, off=(cy*112+cx)*4
        let r=Float(buf[off]),g=Float(buf[off+1]),b=Float(buf[off+2])
        print(String(format:"  Center pixel (56,56): R=%.0f G=%.0f B=%.0f",r,g,b))
        print(String(format:"  norm1=(x-127.5)/127.5: R=%.4f G=%.4f B=%.4f",(r-127.5)/127.5,(g-127.5)/127.5,(b-127.5)/127.5))
        print(String(format:"  norm2=x/255:           R=%.4f G=%.4f B=%.4f",r/255,g/255,b/255))
        print(String(format:"  norm3=(x-127.5)/128:   R=%.4f G=%.4f B=%.4f",(r-127.5)/128,(g-127.5)/128,(b-127.5)/128))
    }
}
