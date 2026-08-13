// Tests SCRFD with scale ≤ 1 (don't upscale LFW images)
// swiftc -O -framework CoreML -framework ImageIO lfw_scale1.swift -o lfw_scale1 && ./lfw_scale1

import CoreML
import CoreGraphics
import ImageIO
import Foundation

let lfwDir    = NSHomeDirectory() + "/scikit_learn_data/lfw_home/lfw_funneled"
let pairsFile = NSHomeDirectory() + "/scikit_learn_data/lfw_home/pairs.txt"
let modelsDir = "/Users/jakelulla/Desktop/PhotoSearch/PhotoSearch/PhotoSearch/ML"

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
    let n = sqrt(v.reduce(0){$0+$1*$1})+1e-10; return v.map{$0/n}
}
func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).reduce(0){$0+$1.0*$1.1} }

func loadOrCompile(name: String, cfg: MLModelConfiguration) throws -> MLModel {
    let fm = FileManager.default
    let src   = URL(fileURLWithPath: "\(modelsDir)/\(name).mlpackage")
    let cache = URL(fileURLWithPath: "\(modelsDir)/\(name).mlmodelc")
    if !fm.fileExists(atPath: cache.path) {
        let tmp = try MLModel.compileModel(at: src); try fm.moveItem(at: tmp, to: cache)
    }
    return try MLModel(contentsOf: cache, configuration: cfg)
}

struct DetFace { var bbox: CGRect; var score: Float; var landmarks: [CGPoint] }

// SCRFD with scale ≤ 1.0 (never upscale)
func detectFaces(_ img: CGImage, model: MLModel, maxScale: Float = 1.0) throws -> [DetFace] {
    let W = img.width, H = img.height, pad = 640
    var scale = Float(min(Float(pad)/Float(W), Float(pad)/Float(H)))
    scale = min(scale, maxScale)  // ← KEY CHANGE
    let nW = Int((Float(W)*scale).rounded()), nH = Int((Float(H)*scale).rounded())
    guard let buf = rgbaPixels(img, toWidth: nW, height: nH) else { return [] }

    let t = try MLMultiArray(shape: [1,3,pad as NSNumber,pad as NSNumber], dataType: .float16)
    let plane = pad*pad, row = nW*4
    for y in 0..<pad { for x in 0..<pad {
        let r,g,b: Float
        if y<nH && x<nW { let o=y*row+x*4; r=(Float(buf[o])-127.5)/128; g=(Float(buf[o+1])-127.5)/128; b=(Float(buf[o+2])-127.5)/128 }
        else { r=0;g=0;b=0 }
        t[0*plane+y*pad+x]=NSNumber(value:r);t[1*plane+y*pad+x]=NSNumber(value:g);t[2*plane+y*pad+x]=NSNumber(value:b)
    }}

    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": t]))
    var byCol: [Int:[(String,Int)]] = [:]
    for name in out.featureNames {
        guard let arr=out.featureValue(for:name)?.multiArrayValue else { continue }
        let sh=arr.shape.map{$0.intValue}; guard sh.count==2 else { continue }
        byCol[sh[1],default:[]].append((name,sh[0]))
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
    let order=(0..<allS.count).sorted{allS[$0]>allS[$1]}
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
        DetFace(bbox: CGRect(x:CGFloat(max(0,min(allB[i][0]*inv,mX))),y:CGFloat(max(0,min(allB[i][1]*inv,mY))),
                             width:CGFloat(max(0,min(allB[i][2]*inv,mX))-max(0,min(allB[i][0]*inv,mX))),
                             height:CGFloat(max(0,min(allB[i][3]*inv,mY))-max(0,min(allB[i][1]*inv,mY)))),
                score: allS[i],
                landmarks: (0..<5).map{k in CGPoint(x:CGFloat(max(0,min(allK[i][k*2]*inv,mX))),
                                                     y:CGFloat(max(0,min(allK[i][k*2+1]*inv,mY))))})
    }
}

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
    let a=(sUX*n-sX*sU-sY*sV)/D,b=(-sVX*n+sY*sU-sX*sV)/D
    let c=(sU-a*sX+b*sY)/n,d=(sV-b*sX-a*sY)/n
    return CGAffineTransform(a:a,b:b,c:-b,d:a,tx:c,ty:d)
}

func alignFace(_ img: CGImage, face: DetFace) -> CGImage? {
    let S=112, W=img.width, H=img.height
    guard let srcBuf=rgbaPixels(img, toWidth:W, height:H) else { return nil }
    let Tinv=similarityTransform(face.landmarks, arcDst).inverted()
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

func embed(_ face: CGImage, model: MLModel) throws -> [Float]? {
    let S=112
    guard let buf=rgbaPixels(face, toWidth:S, height:S) else { return nil }
    let t=try MLMultiArray(shape:[1,3,S as NSNumber,S as NSNumber], dataType:.float32)
    let plane=S*S
    for y in 0..<S { for x in 0..<S {
        let off=(y*S+x)*4
        t[0*plane+y*S+x]=NSNumber(value:(Float(buf[off  ])-127.5)/127.5)
        t[1*plane+y*S+x]=NSNumber(value:(Float(buf[off+1])-127.5)/127.5)
        t[2*plane+y*S+x]=NSNumber(value:(Float(buf[off+2])-127.5)/127.5)
    }}
    let out=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["input":t]))
    guard let nm=out.featureNames.first(where:{(out.featureValue(for:$0)?.multiArrayValue?.count ?? 0)==512}),
          let arr=out.featureValue(for:nm)?.multiArrayValue else { return nil }
    return l2Norm(floats(arr))
}

func embedCrop(_ img: CGImage, model: MLModel) throws -> [Float]? {
    let W=img.width, H=img.height
    let crop=CGRect(x:(W-200)/2,y:(H-200)/2,width:200,height:200)
    guard let c=img.cropping(to:crop) else { return nil }
    return try embed(c, model:model)
}

struct Pair { let p1,p2: String; let same: Bool }
func imgPath(_ name: String, _ num: Int) -> String {
    "\(lfwDir)/\(name)/\(name)_\(String(format:"%04d",num)).jpg"
}
func readPairs() -> [Pair] {
    guard let raw=try? String(contentsOfFile:pairsFile, encoding:.utf8) else { return [] }
    var lines=raw.split(separator:"\n",omittingEmptySubsequences:true).map{String($0)}
    let h=lines.removeFirst().split(separator:"\t").map{Int($0)!}
    let perFold=h[1]; var out=[Pair]()
    for line in lines.prefix(perFold*h[0]) {
        let c=line.split(separator:"\t").map{String($0)}
        guard c.count==3,let n1=Int(c[1]),let n2=Int(c[2]) else { continue }
        out.append(Pair(p1:imgPath(c[0],n1),p2:imgPath(c[0],n2),same:true))
    }
    for line in lines.dropFirst(perFold*h[0]) {
        let c=line.split(separator:"\t").map{String($0)}
        guard c.count==4,let n1=Int(c[1]),let n2=Int(c[3]) else { continue }
        out.append(Pair(p1:imgPath(c[0],n1),p2:imgPath(c[2],n2),same:false))
    }
    return out
}

// ── Main ─────────────────────────────────────────────────────────────────────

print("LFW Scale≤1 Benchmark")
print(String(repeating:"=",count:50))

let cfg=MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
let det=try loadOrCompile(name:"FaceDetector",cfg:cfg)
let emb=try loadOrCompile(name:"FaceEmbedder",cfg:cfg)

let pairs=readPairs()
var embeddings=[String:[Float]]()
let imgs=Array(Set(pairs.flatMap{[$0.p1,$0.p2]}))
var nDet=0, nFallback=0
let t0=Date()
for (i,path) in imgs.enumerated() {
    guard let img=loadCG(path) else { continue }
    // Use scale ≤ 1.0 for detection
    let faces=try detectFaces(img, model:det, maxScale:1.0)
    if let best=faces.first, let aligned=alignFace(img, face:best),
       let e=try embed(aligned, model:emb) {
        embeddings[path]=e; nDet+=1
    } else if let e=try embedCrop(img, model:emb) {
        embeddings[path]=e; nFallback+=1
    }
    if (i+1)%500==0 {
        let dt=Date().timeIntervalSince(t0)
        print(String(format:"  [%4d/%4d]  det:%d  fallback:%d  %.1f img/s",i+1,imgs.count,nDet,nFallback,Double(i+1)/dt))
    }
}
print(String(format:"  Done: %d embeddings (det:%d fallback:%d) in %.0fs\n",embeddings.count,nDet,nFallback,Date().timeIntervalSince(t0)))

let covered=pairs.filter{embeddings[$0.p1] != nil && embeddings[$0.p2] != nil}
print("  \(covered.count)/\(pairs.count) pairs covered\n")

// 10-fold CV
let foldSize=covered.count/10; var accs=[Float]()
for fold in 0..<10 {
    let testP=Array(covered[(fold*foldSize)..<((fold+1)*foldSize)])
    let trainP=covered.filter{p in !testP.contains(where:{$0.p1==p.p1 && $0.p2==p.p2})}
    var bestT:Float=0.5,bestAcc:Float=0
    for ti in stride(from:Float(-0.5),through:Float(1.0),by:0.01) {
        var c=0
        for p in trainP { guard let e1=embeddings[p.p1],let e2=embeddings[p.p2] else { continue }
            if (dot(e1,e2)>ti)==p.same { c+=1 } }
        let a=Float(c)/Float(trainP.count); if a>bestAcc { bestAcc=a;bestT=ti }
    }
    var tc=0
    for p in testP { guard let e1=embeddings[p.p1],let e2=embeddings[p.p2] else { continue }
        if (dot(e1,e2)>bestT)==p.same { tc+=1 } }
    let ta=Float(tc)/Float(testP.count); accs.append(ta)
    print(String(format:"  Fold %2d: thresh=%.2f  test=%.2f%%",fold+1,bestT,ta*100))
}
let mean=accs.reduce(0,+)/Float(accs.count)
let std=sqrt(accs.map{($0-mean)*($0-mean)}.reduce(0,+)/Float(accs.count))
print(String(repeating:"=",count:50))
print(String(format:"LFW Accuracy (scale≤1): %.2f%% ± %.2f%%",mean*100,std*100))
print(String(repeating:"=",count:50))

// Also print same/different stats for quick look
var same=[Float](),diff=[Float]()
for p in covered.prefix(300) {
    guard let e1=embeddings[p.p1],let e2=embeddings[p.p2] else { continue }
    let s=dot(e1,e2)
    if p.same { same.append(s) } else { diff.append(s) }
}
func stats(_ v:[Float]) -> String {
    guard !v.isEmpty else { return "n/a" }
    let n=Float(v.count),m=v.reduce(0,+)/n,s=sqrt(v.map{($0-m)*($0-m)}.reduce(0,+)/n)
    return String(format:"n=%d mean=%.3f std=%.3f min=%.3f max=%.3f",Int(n),m,s,v.min()!,v.max()!)
}
print("\nFirst 300 pair similarities:")
print("  SAME: \(stats(same))")
print("  DIFF: \(stats(diff))")
