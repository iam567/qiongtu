import CoreGraphics
import Foundation
import Vision

/// 一张脸的位置和五官关键点。坐标都是归一化的图片坐标，原点在左上角。
struct FaceInfo: Equatable, Codable {
    var box: CGRect
    /// 沿下颌从一侧到另一侧的轮廓线。
    var contour: [CGPoint] = []
    var leftEye: [CGPoint] = []
    var rightEye: [CGPoint] = []
    var leftBrow: [CGPoint] = []
    var rightBrow: [CGPoint] = []
    var outerLips: [CGPoint] = []
    var innerLips: [CGPoint] = []
    var nose: [CGPoint] = []
    var leftPupil: CGPoint?
    var rightPupil: CGPoint?
    /// 鼻梁中线（从眉心到鼻尖）。
    var noseCrest: [CGPoint]?
    /// 脸的正中线（额头到下巴）。
    var medianLine: [CGPoint]?
    /// 头在画面里歪了多少（弧度，顺时针为正）和左右转了多少；系统给不出时是 nil。
    var roll: CGFloat?
    var yaw: CGFloat?

    /// 关键点是否可信。脸太小、太糊时（以及在 iOS 模拟器里）系统给出的五官会挤成一团，
    /// 这时只做磨皮和美白，不做依赖五官位置的口红、腮红、瘦脸、大眼。
    var hasReliableLandmarks: Bool {
        guard contour.count >= 5, leftEye.count >= 3, rightEye.count >= 3, box.width > 0 else { return false }
        func center(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        let l = center(leftEye), r = center(rightEye)
        let jaw = abs(contour[0].x - contour[contour.count - 1].x)
        return abs(l.x - r.x) > box.width * 0.18 && jaw > box.width * 0.45
    }
}

/// 用系统自带的 Vision 找人脸，全部在本机完成。
enum FaceDetector {
    /// 整张找一遍，找不到再分块放大找小脸。
    static func detect(in image: CGImage) -> [FaceInfo] {
        let found = direct(in: image)
        return found.isEmpty ? FaceFinder.deep(image) : found
    }

    /// 只整张找一遍。
    static func direct(in image: CGImage) -> [FaceInfo] {
        #if DEBUG
        // 模拟器里 Vision 的五官关键点是坏的，测试时可以放一份在 Mac 上算好的结果进来。
        if ProcessInfo.processInfo.environment["XIUTU_TEST_BASE"] != nil,
           let data = FileManager.default.contents(atPath: NSTemporaryDirectory() + "faces_override.json"),
           let faces = try? JSONDecoder().decode([FaceInfo].self, from: data) {
            return faces
        }
        #endif
        let request = VNDetectFaceLandmarksRequest()
        #if targetEnvironment(simulator)
        // 模拟器没有真机的神经网络硬件，不指定 CPU 时检测会时灵时不灵。
        request.usesCPUOnly = true
        #endif
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let size = CGSize(width: image.width, height: image.height)
        let faces: [FaceInfo] = (request.results ?? []).map { observation in
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                guard let region else { return [] }
                return region.pointsInImage(imageSize: size).map {
                    CGPoint(x: $0.x / size.width, y: 1 - $0.y / size.height)
                }
            }
            let b = observation.boundingBox
            var face = FaceInfo(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            if let lm = observation.landmarks {
                face.contour = points(lm.faceContour)
                face.leftEye = points(lm.leftEye)
                face.rightEye = points(lm.rightEye)
                face.leftBrow = points(lm.leftEyebrow)
                face.rightBrow = points(lm.rightEyebrow)
                face.outerLips = points(lm.outerLips)
                face.innerLips = points(lm.innerLips)
                face.nose = points(lm.nose)
                face.leftPupil = points(lm.leftPupil).first
                face.rightPupil = points(lm.rightPupil).first
                face.noseCrest = points(lm.noseCrest)
                face.medianLine = points(lm.medianLine)
            }
            // Vision 的 roll 以逆时针为正，这里换成和画面一致的顺时针为正。
            face.roll = observation.roll.map { -CGFloat(truncating: $0) }
            face.yaw = observation.yaw.map { CGFloat(truncating: $0) }
            return face
        }
        // 最大的脸排最前，默认选它。
        return faces.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
    }
}
