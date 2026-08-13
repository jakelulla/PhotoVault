import CoreML
import UIKit

// MARK: - Public types

struct PhotoMLResult {
    let clipEmbedding: [Float]     // 512-dim L2-normalized CLIP image embedding
    /// Videos only: each sampled frame's L2-normalized CLIP embedding
    /// (`clipEmbedding` is then their L2-renormalized mean). nil for photos.
    var clipFrameEmbeddings: [[Float]]? = nil
    let faceEmbeddings: [[Float]]  // N × 512-dim L2-normalized ArcFace embeddings
    let faceRects: [CGRect]        // N bounding boxes, normalized 0…1 in original image space
    /// Per-face Laplacian-variance sharpness, parallel to faceRects/faceEmbeddings.
    /// Defaulted so pre-sharpness initializer call sites keep compiling.
    var faceSharpness: [Float] = []
    /// Whole-frame sharpness at the same fixed 128×128 analysis size, so
    /// scores are comparable across photos regardless of resolution.
    var imageSharpness: Float = 0
}

// MARK: - Engine

/// Runs CLIP visual encoder + SCRFD face detector + ArcFace recognizer entirely
/// on-device using CoreML. Call process(image:) to get embeddings for one photo.
final class OnDeviceMLEngine {
    static let shared = OnDeviceMLEngine()
    private init() {}

    private var clipModel: MLModel?
    private var clipTextModel: MLModel?
    private var detectorModel: MLModel?
    private var embedderModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var modelsLoaded = false

    // MARK: - Load

    func loadModels() throws {
        guard !modelsLoaded else { return }
        let config = MLModelConfiguration()
        // .all enables the Neural Engine — typically 2-4× faster than GPU for
        // these conv nets on iPhone. Accuracy verified identical on LFW:
        // 98.60% ± 1.44% with .all == 98.60% with .cpuAndGPU (2026-06-10).
        config.computeUnits = .all

        guard
            let clipURL  = Bundle.main.url(forResource: "CLIPVisual",    withExtension: "mlmodelc"),
            let textURL  = Bundle.main.url(forResource: "CLIPText",      withExtension: "mlmodelc"),
            let detURL   = Bundle.main.url(forResource: "FaceDetector",  withExtension: "mlmodelc"),
            let embURL   = Bundle.main.url(forResource: "FaceEmbedder",  withExtension: "mlmodelc")
        else { throw MLEngineError.modelsNotFound }

        clipModel      = try MLModel(contentsOf: clipURL,  configuration: config)
        clipTextModel  = try MLModel(contentsOf: textURL,  configuration: config)
        detectorModel  = try MLModel(contentsOf: detURL,   configuration: config)
        embedderModel  = try MLModel(contentsOf: embURL,   configuration: config)
        tokenizer      = CLIPTokenizer()
        modelsLoaded = true
    }

    var isAvailable: Bool { modelsLoaded }

    // MARK: - Process

    func process(cgImage: CGImage) throws -> PhotoMLResult {
        guard modelsLoaded,
              let clip = clipModel,
              let det  = detectorModel,
              let emb  = embedderModel
        else { throw MLEngineError.notLoaded }

        let clipEmb  = try encodeCLIP(cgImage, model: clip)
        let (faceEmbs, faceRects) = try detectAndEmbedFaces(cgImage, detector: det, embedder: emb)
        // Sharpness piggybacks on the inference pass: the CGImage is already
        // decoded and the rects already detected, so each score is just one
        // extra 128×128 grayscale render — negligible next to the models.
        let faceSharp = faceRects.map { sharpness(of: cgImage, normalizedRegion: $0) }
        let imageSharp = sharpness(of: cgImage, normalizedRegion: nil)
        return PhotoMLResult(clipEmbedding: clipEmb, faceEmbeddings: faceEmbs, faceRects: faceRects,
                             faceSharpness: faceSharp, imageSharpness: imageSharp)
    }

    // MARK: - CLIP text (caption search)

    /// Encode a free-text query into a 512-dim L2-normalized CLIP embedding,
    /// directly comparable to the stored per-photo image embeddings.
    func encodeText(_ text: String) throws -> [Float] {
        guard modelsLoaded, let model = clipTextModel, let tok = tokenizer
        else { throw MLEngineError.notLoaded }

        let ids = tok.encode(text)
        let tensor = try MLMultiArray(shape: [1, 77], dataType: .int32)
        for (i, v) in ids.enumerated() { tensor[i] = NSNumber(value: v) }
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["tokens": tensor]))
        guard let arr = output.featureValue(for: "text_features")?.multiArrayValue else {
            throw MLEngineError.badOutput("CLIPText: missing text_features")
        }
        return l2Normalize(floats(arr))
    }

    // MARK: - CLIP (image-only entry point)

    /// Encode ONE image into a 512-dim L2-normalized CLIP embedding, without
    /// running face detection (unlike `process`). Used for shared-album photo
    /// thumbnails, where only caption search is needed and faces must never be
    /// computed on other people's photos implicitly.
    func encodeImage(_ cgImage: CGImage) throws -> [Float] {
        guard modelsLoaded, let clip = clipModel else { throw MLEngineError.notLoaded }
        return try encodeCLIP(cgImage, model: clip)
    }

    private func encodeCLIP(_ cgImage: CGImage, model: MLModel) throws -> [Float] {
        let tensor = try clipPreprocess(cgImage)
        let input  = try MLDictionaryFeatureProvider(dictionary: ["image": tensor])
        let output = try model.prediction(from: input)
        guard let arr = output.featureValue(for: "image_features")?.multiArrayValue else {
            throw MLEngineError.badOutput("CLIPVisual: missing image_features")
        }
        return l2Normalize(floats(arr))
    }

    /// Resize (shorter side → 224) + center-crop 224×224 + OpenAI CLIP normalization → [1,3,224,224]
    private func clipPreprocess(_ cgImage: CGImage) throws -> MLMultiArray {
        let S = 224
        let srcW = cgImage.width, srcH = cgImage.height
        let scale: CGFloat = srcW < srcH
            ? CGFloat(S) / CGFloat(srcW)
            : CGFloat(S) / CGFloat(srcH)
        let newW = Int((CGFloat(srcW) * scale).rounded())
        let newH = Int((CGFloat(srcH) * scale).rounded())
        let cropX = (newW - S) / 2
        let cropY = (newH - S) / 2

        guard let buf = rgbaPixels(cgImage, toWidth: newW, height: newH) else {
            throw MLEngineError.preprocessFailed
        }
        let mean: [Float] = [0.48145466, 0.4578275,  0.40821073]
        let std:  [Float] = [0.26862954, 0.26130258, 0.27577711]

        let tensor = try MLMultiArray(shape: [1, 3, S as NSNumber, S as NSNumber], dataType: .float32)
        let plane  = S * S
        let rowStride = newW * 4

        let p = tensor.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        for y in 0..<S {
            for x in 0..<S {
                let off = (y + cropY) * rowStride + (x + cropX) * 4
                p[0 * plane + y * S + x] = (Float(buf[off    ]) / 255.0 - mean[0]) / std[0]
                p[1 * plane + y * S + x] = (Float(buf[off + 1]) / 255.0 - mean[1]) / std[1]
                p[2 * plane + y * S + x] = (Float(buf[off + 2]) / 255.0 - mean[2]) / std[2]
            }
        }
        return tensor
    }

    // MARK: - Face detection (SCRFD) + ArcFace embedding

    private struct DetFace {
        var bbox: CGRect           // pixel coords in original image
        var landmarks: [CGPoint]   // 5 pts: L-eye, R-eye, nose, L-mouth, R-mouth
    }

    private func detectAndEmbedFaces(_ cgImage: CGImage,
                                     detector: MLModel,
                                     embedder: MLModel) throws -> (embeddings: [[Float]], rects: [CGRect]) {
        let W = cgImage.width, H = cgImage.height
        let inputSize = 640

        let scale = Float(min(Float(inputSize) / Float(W), Float(inputSize) / Float(H)))
        let newW  = Int((Float(W) * scale).rounded())
        let newH  = Int((Float(H) * scale).rounded())

        guard let buf640 = rgbaPixels(cgImage, toWidth: newW, height: newH) else {
            throw MLEngineError.preprocessFailed
        }

        let tensor = try scrfdTensor(buf640, drawnW: newW, drawnH: newH, inputSize: inputSize)
        let detIn  = try MLDictionaryFeatureProvider(dictionary: ["input": tensor])
        let detOut = try detector.prediction(from: detIn)

        let faces  = decodeSCRFD(detOut, scale: scale, origW: W, origH: H, inputSize: inputSize)

        var embeddings: [[Float]] = []
        var rects: [CGRect] = []
        for face in faces {
            guard let aligned = alignFace(cgImage, face: face) else { continue }
            let faceIn  = try MLDictionaryFeatureProvider(dictionary: ["input": try arcfaceTensor(aligned)])
            let faceOut = try embedder.prediction(from: faceIn)
            let embName = faceOut.featureNames.first(where: {
                (faceOut.featureValue(for: $0)?.multiArrayValue?.count ?? 0) == 512
            })
            guard let name = embName,
                  let arr  = faceOut.featureValue(for: name)?.multiArrayValue else { continue }
            embeddings.append(l2Normalize(floats(arr)))
            // Normalize bbox to 0…1 range
            let b = face.bbox
            rects.append(CGRect(
                x: b.minX / CGFloat(W), y: b.minY / CGFloat(H),
                width: b.width / CGFloat(W), height: b.height / CGFloat(H)
            ))
        }
        return (embeddings, rects)
    }

    private func scrfdTensor(_ buf: [UInt8], drawnW: Int, drawnH: Int, inputSize: Int) throws -> MLMultiArray {
        let tensor = try MLMultiArray(shape: [1, 3,
                                              inputSize as NSNumber,
                                              inputSize as NSNumber], dataType: .float16)
        let plane     = inputSize * inputSize
        let rowStride = drawnW * 4
        // Direct Float16 writes: the boxed NSNumber subscript costs ~100ns
        // per element — at 640×640×3 = 1.2M elements that alone took longer
        // than the model. memset the zero padding, then fill only the drawn
        // region.
        let p = tensor.dataPointer.bindMemory(to: Float16.self, capacity: 3 * plane)
        memset(tensor.dataPointer, 0, 3 * plane * MemoryLayout<Float16>.size)
        for y in 0..<min(drawnH, inputSize) {
            for x in 0..<min(drawnW, inputSize) {
                let off = y * rowStride + x * 4
                p[0 * plane + y * inputSize + x] = Float16((Float(buf[off    ]) - 127.5) / 128.0)
                p[1 * plane + y * inputSize + x] = Float16((Float(buf[off + 1]) - 127.5) / 128.0)
                p[2 * plane + y * inputSize + x] = Float16((Float(buf[off + 2]) - 127.5) / 128.0)
            }
        }
        return tensor
    }

    // MARK: - SCRFD decoder

    private func decodeSCRFD(_ output: MLFeatureProvider, scale: Float,
                              origW: Int, origH: Int, inputSize: Int) -> [DetFace] {
        let strides    = [8, 16, 32]
        let numAnchors = 2
        let detThresh: Float = 0.5
        let nmsThresh: Float = 0.4

        // Identify outputs by shape: col=1 → scores, col=4 → boxes, col=10 → kps
        var byCol: [Int: [(name: String, rows: Int)]] = [:]
        for name in output.featureNames {
            guard let arr = output.featureValue(for: name)?.multiArrayValue else { continue }
            let sh = arr.shape.map { $0.intValue }
            guard sh.count == 2 else { continue }
            byCol[sh[1], default: []].append((name, sh[0]))
        }
        // Sort each group by rows descending → stride 8 first (12800 > 3200 > 800)
        for key in byCol.keys { byCol[key]!.sort { $0.rows > $1.rows } }

        let scoreNames = byCol[1]  ?? []
        let boxNames   = byCol[4]  ?? []
        let kpsNames   = byCol[10] ?? []
        guard scoreNames.count == 3 && boxNames.count == 3 && kpsNames.count == 3 else {
            return []
        }

        var allScores: [Float]    = []
        var allBoxes:  [[Float]]  = []
        var allKps:    [[Float]]  = []

        for s in 0..<3 {
            let stride   = strides[s]
            let featH    = inputSize / stride
            let featW    = inputSize / stride

            guard
                let scoreArr = output.featureValue(for: scoreNames[s].name)?.multiArrayValue,
                let boxArr   = output.featureValue(for: boxNames[s].name)?.multiArrayValue,
                let kpsArr   = output.featureValue(for: kpsNames[s].name)?.multiArrayValue
            else { continue }

            let sp = floats(scoreArr)
            let bp = floats(boxArr)
            let kp = floats(kpsArr)

            var ai = 0  // anchor index
            for y in 0..<featH {
                for x in 0..<featW {
                    let cx = Float(x * stride), cy = Float(y * stride)
                    for _ in 0..<numAnchors {
                        if sp[ai] >= detThresh {
                            let st = Float(stride)
                            allBoxes.append([
                                cx - bp[ai*4+0]*st, cy - bp[ai*4+1]*st,
                                cx + bp[ai*4+2]*st, cy + bp[ai*4+3]*st,
                            ])
                            allScores.append(sp[ai])
                            var lm = [Float](repeating: 0, count: 10)
                            for k in 0..<5 {
                                lm[k*2]   = cx + kp[ai*10+k*2]   * st
                                lm[k*2+1] = cy + kp[ai*10+k*2+1] * st
                            }
                            allKps.append(lm)
                        }
                        ai += 1
                    }
                }
            }
        }

        guard !allScores.isEmpty else { return [] }

        let keep    = nms(allScores, allBoxes, iouThresh: nmsThresh)
        let inv     = 1.0 / scale
        let maxX    = Float(origW - 1), maxY = Float(origH - 1)

        return keep.map { i in
            let b = allBoxes[i]
            let bbox = CGRect(
                x:      CGFloat(max(0, min(b[0]*inv, maxX))),
                y:      CGFloat(max(0, min(b[1]*inv, maxY))),
                width:  CGFloat(max(0, min(b[2]*inv, maxX)) - max(0, min(b[0]*inv, maxX))),
                height: CGFloat(max(0, min(b[3]*inv, maxY)) - max(0, min(b[1]*inv, maxY)))
            )
            let lm = allKps[i]
            let pts = (0..<5).map { k in
                CGPoint(x: CGFloat(max(0, min(lm[k*2]*inv,   maxX))),
                        y: CGFloat(max(0, min(lm[k*2+1]*inv, maxY))))
            }
            return DetFace(bbox: bbox, landmarks: pts)
        }
    }

    // MARK: - Face alignment

    // ArcFace 112×112 reference landmarks (L-eye, R-eye, nose, L-mouth, R-mouth)
    private let arcDst: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    private func alignFace(_ cgImage: CGImage, face: DetFace) -> CGImage? {
        let S = 112, W = cgImage.width, H = cgImage.height
        guard let srcBuf = rgbaPixels(cgImage, toWidth: W, height: H) else { return nil }
        let Tinv = similarityTransform(from: face.landmarks, to: arcDst).inverted()
        var outBuf = [UInt8](repeating: 0, count: S * S * 4)
        for oy in 0..<S { for ox in 0..<S {
            let sp = CGPoint(x: CGFloat(ox), y: CGFloat(oy)).applying(Tinv)
            let sx = Int(sp.x.rounded()), sy = Int(sp.y.rounded())
            guard sx >= 0 && sx < W && sy >= 0 && sy < H else { continue }
            let di = (oy * S + ox) * 4, si = (sy * W + sx) * 4
            outBuf[di] = srcBuf[si]; outBuf[di+1] = srcBuf[si+1]
            outBuf[di+2] = srcBuf[si+2]; outBuf[di+3] = srcBuf[si+3]
        }}
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let prov = CGDataProvider(data: NSData(bytes: outBuf, length: outBuf.count) as CFData)
        else { return nil }
        return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: S * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info, provider: prov,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Least-squares similarity transform T such that T(src[i]) ≈ dst[i].
    /// Similarity: T(x,y) = (a·x − b·y + c, b·x + a·y + d)
    private func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        var sumXX: CGFloat = 0, sumX: CGFloat = 0, sumY: CGFloat = 0
        var sumUX: CGFloat = 0, sumVX: CGFloat = 0
        var sumU: CGFloat  = 0, sumV: CGFloat  = 0

        for i in 0..<src.count {
            let (x, y) = (src[i].x, src[i].y)
            let (u, v) = (dst[i].x, dst[i].y)
            sumXX += x*x + y*y
            sumX  += x;  sumY  += y
            sumUX += u*x + v*y          // = ρ
            sumVX += u*y - v*x          // = -φ  (note: φ = Σ(x·v − y·u))
            sumU  += u;  sumV  += v
        }

        let n = CGFloat(src.count)
        let D = sumXX * n - (sumX*sumX + sumY*sumY)
        guard abs(D) > 1e-10 else { return .identity }

        let a = (sumUX * n - sumX*sumU - sumY*sumV) / D
        let b = (-sumVX * n + sumY*sumU - sumX*sumV) / D   // corrected sign
        let c = (sumU - a*sumX + b*sumY) / n
        let d = (sumV - b*sumX - a*sumY) / n

        // Our: x' = a·x − b·y + c, y' = b·x + a·y + d
        // CG:  x' = m.a·x + m.c·y + m.tx, y' = m.b·x + m.d·y + m.ty
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: c, ty: d)
    }

    // MARK: - ArcFace preprocessing

    private func arcfaceTensor(_ cgImage: CGImage) throws -> MLMultiArray {
        let S = 112
        guard let buf = rgbaPixels(cgImage, toWidth: S, height: S) else {
            throw MLEngineError.preprocessFailed
        }
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
        return tensor
    }

    // MARK: - NMS

    private func nms(_ scores: [Float], _ boxes: [[Float]], iouThresh: Float) -> [Int] {
        let order = (0..<scores.count).sorted { scores[$0] > scores[$1] }
        var suppressed = [Bool](repeating: false, count: scores.count)
        var keep: [Int] = []
        for i in 0..<order.count {
            let ii = order[i]; if suppressed[ii] { continue }
            keep.append(ii)
            for j in (i+1)..<order.count {
                let jj = order[j]
                if !suppressed[jj] && iou(boxes[ii], boxes[jj]) > iouThresh { suppressed[jj] = true }
            }
        }
        return keep
    }

    private func iou(_ a: [Float], _ b: [Float]) -> Float {
        let ix1 = max(a[0], b[0]), iy1 = max(a[1], b[1])
        let ix2 = min(a[2], b[2]), iy2 = min(a[3], b[3])
        let inter = max(0, ix2-ix1) * max(0, iy2-iy1)
        guard inter > 0 else { return 0 }
        return inter / ((a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter + 1e-7)
    }

    // MARK: - Sharpness (Laplacian variance)

    /// Sharpness score for a region of an image: variance of the 3×3
    /// Laplacian [0,1,0; 1,−4,1; 0,1,0] over a 128×128 8-bit grayscale
    /// resample of the region. The FIXED analysis size is the point — it
    /// makes scores comparable across photos of any resolution (a 48MP and
    /// a 12MP shot of the same scene land near the same number).
    ///
    /// `normalizedRegion` (0…1 rect, e.g. a detected face) gets 10% padding
    /// and a 16px-source minimum so tiny faces still yield signal; nil
    /// scores the whole frame. Pure CoreGraphics — needs no loaded models,
    /// so the backfill can use it even where CoreML is unavailable.
    func sharpness(of cgImage: CGImage, normalizedRegion: CGRect?) -> Float {
        let W = CGFloat(cgImage.width), H = CGFloat(cgImage.height)
        guard W >= 1, H >= 1 else { return 0 }

        var source = cgImage
        if let r = normalizedRegion {
            // Pad 10% per side: a little context around the face keeps the
            // crop from being dominated by smooth skin (which scores low on
            // any photo, sharp or blurry).
            var px = r.minX * W, py = r.minY * H
            var pw = r.width * W, ph = r.height * H
            let padX = pw * 0.1, padY = ph * 0.1
            px -= padX; py -= padY; pw += 2 * padX; ph += 2 * padY
            // Below ~16 source pixels there isn't enough detail to measure;
            // grow around the center before clamping to bounds.
            if pw < 16 { px -= (16 - pw) / 2; pw = 16 }
            if ph < 16 { py -= (16 - ph) / 2; ph = 16 }
            let rect = CGRect(x: px, y: py, width: pw, height: ph)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H))
                .integral
            guard rect.width >= 2, rect.height >= 2,
                  let cropped = cgImage.cropping(to: rect) else { return 0 }
            source = cropped
        }

        let S = 128
        var gray = [UInt8](repeating: 0, count: S * S)
        // Keep the buffer pointer valid for the context's whole lifetime —
        // passing &gray directly to CGContext(data:) is UB once the call
        // returns (same dangling-pointer hazard as rgbaPixels below).
        let ok = gray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: S, height: S,
                bitsPerComponent: 8, bytesPerRow: S,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: S, height: S))
            return true
        }
        guard ok else { return 0 }

        // Laplacian response over interior pixels (1-pixel border skipped),
        // then its variance. Integer kernel sums fit easily in Int; the
        // accumulators need Double (sumSq can reach 126² × 1020²).
        var sum = 0.0, sumSq = 0.0
        for y in 1..<(S - 1) {
            let row = y * S
            for x in 1..<(S - 1) {
                let v = Double(
                    Int(gray[row + x - 1]) + Int(gray[row + x + 1])
                    + Int(gray[row - S + x]) + Int(gray[row + S + x])
                    - 4 * Int(gray[row + x]))
                sum += v
                sumSq += v * v
            }
        }
        let n = Double((S - 2) * (S - 2))
        let mean = sum / n
        return Float(max(0, sumSq / n - mean * mean))
    }

    // MARK: - Pixel helpers

    /// Render cgImage into an RGBA byte buffer of size (width × height × 4).
    /// Row 0 = top of image (UIKit / y-down convention).
    private func rgbaPixels(_ cgImage: CGImage, toWidth w: Int, height h: Int) -> [UInt8]? {
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
            // NOTE: no flip transform. A raw CGBitmapContext's memory already has
            // row 0 = top of the drawn image; adding translate+scale(-1) flips it
            // upside down (verified numerically against PIL/OpenCV reference).
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    /// Bulk-read an MLMultiArray without per-element NSNumber boxing —
    /// the boxed subscript costs ~100ns/element, which at SCRFD's ~250k
    /// output values per image dominated decode time.
    ///
    /// IMPORTANT: Neural Engine outputs can be stride-PADDED (e.g. shape
    /// [12800, 1] with strides [32, 1]) — raw contiguous reads silently
    /// return padding garbage. Verify packed layout before taking the fast
    /// path; otherwise gather through the strides.
    private func floats(_ arr: MLMultiArray) -> [Float] {
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

        if packed {
            return gather { $0 }
        }
        if shape.count == 2 {
            // Common case for SCRFD outputs: [rows, cols] with padded rows.
            let cols = shape[1]
            return gather { i in (i / cols) * stride[0] + (i % cols) * stride[1] }
        }
        // Rare layouts: fall back to the stride-aware (boxed) subscript.
        return (0..<n).map { arr[$0].floatValue }
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = (v.reduce(0) { $0 + $1*$1 }).squareRoot() + 1e-10
        return v.map { $0 / norm }
    }

    // MARK: - Error

    enum MLEngineError: Error, LocalizedError {
        case modelsNotFound
        case notLoaded
        case preprocessFailed
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .modelsNotFound:  return "CoreML model files not found in app bundle"
            case .notLoaded:       return "Models not loaded — call loadModels() first"
            case .preprocessFailed: return "Image preprocessing failed"
            case .badOutput(let m): return "Unexpected model output: \(m)"
            }
        }
    }
}
