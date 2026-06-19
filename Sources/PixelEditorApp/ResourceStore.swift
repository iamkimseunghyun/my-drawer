import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import Core

/// 픽셀 리소스의 단일 소유자 (설계 §3.2). 값 모델(`Document`)과 분리.
/// 두 종류를 보유: 가져온 이미지(`CGImage`, 불변) / 페인트 레이어(`PaintCanvas`, 가변).
/// 합성기엔 둘 다 CIImage로 제공. M3 strict concurrency 시 `actor`로 승격(설계 §2).
final class ResourceStore {
    private var images: [TileStoreHandle: CGImage] = [:]
    private var paints: [TileStoreHandle: PaintCanvas] = [:]
    private var ciCache: [TileStoreHandle: CIImage] = [:]

    // 가져온 이미지
    func set(_ image: CGImage, for handle: TileStoreHandle) {
        images[handle] = image; ciCache[handle] = nil
    }
    func image(for handle: TileStoreHandle) -> CGImage? { images[handle] }

    // 페인트 레이어
    func createPaintCanvas(_ handle: TileStoreHandle, width: Int, height: Int) {
        paints[handle] = PaintCanvas(width: width, height: height); ciCache[handle] = nil
    }
    func paintCanvas(_ handle: TileStoreHandle) -> PaintCanvas? { paints[handle] }
    func isPaint(_ handle: TileStoreHandle) -> Bool { paints[handle] != nil }

    /// 레이어 마스크 캔버스(불투명 흰색 = 전부 보임). 마스크도 paint canvas라 브러시로 칠한다.
    func createMaskCanvas(_ handle: TileStoreHandle, width: Int, height: Int) {
        let pc = PaintCanvas(width: width, height: height)
        pc.fillSolid(RGBA8(255, 255, 255, 255))
        paints[handle] = pc; ciCache[handle] = nil
    }

    /// 레이어 콘텐츠 픽셀 크기(히트테스트용).
    func contentSize(_ handle: TileStoreHandle) -> SIMD2<Int>? {
        if let pc = paints[handle] { return SIMD2(pc.width, pc.height) }
        if let cg = images[handle] { return SIMD2(cg.width, cg.height) }
        return nil
    }

    /// CIImage 캐시 무효화 (해당 레이어가 변경됐을 때).
    func invalidate(_ handle: TileStoreHandle) { ciCache[handle] = nil }

    /// 메모리 압박 시 파생 캐시 제거(원본 픽셀은 유지, lazy 재생성). 설계 §8.
    func evictDerivedCaches() { ciCache.removeAll() }

    /// 합성기(Compositor)에 넘길 CIImage 소스 맵.
    func ciSources() -> [TileStoreHandle: CIImage] {
        var out: [TileStoreHandle: CIImage] = [:]
        for (h, cg) in images {
            let img = ciCache[h] ?? CIImage(cgImage: cg)
            ciCache[h] = img; out[h] = img
        }
        for (h, pc) in paints {
            if let cached = ciCache[h] { out[h] = cached }
            else if let cg = pc.makeCGImage() {
                let img = CIImage(cgImage: cg); ciCache[h] = img; out[h] = img
            }
        }
        return out
    }

    // MARK: 직렬화 — 참조 핸들만 png로 (이미지/페인트 모두 평탄화)
    func pngData(referencedBy handles: Set<TileStoreHandle>) -> [String: Data] {
        var out: [String: Data] = [:]
        for h in handles {
            let cg: CGImage? = images[h] ?? paints[h]?.makeCGImage()
            if let cg, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                out["\(h.id.uuidString).png"] = data
            }
        }
        return out
    }
    func load(_ named: [String: Data]) {
        images.removeAll(); paints.removeAll(); ciCache.removeAll()
        for (name, data) in named {
            guard let id = UUID(uuidString: (name as NSString).deletingPathExtension),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            images[TileStoreHandle(id: id)] = cg   // 재열기 시 평탄화됨(페인트 재편집은 M2b)
        }
    }
}
