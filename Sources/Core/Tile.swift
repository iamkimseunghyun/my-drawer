import Foundation

// MARK: - 타일 인터페이스 (설계 §5.3)
// M0에서 "인터페이스가 존재"하는 게 핵심. 구현은 1타일이어도 무방하나,
// 호출부가 처음부터 타일 추상화에 의존해야 대용량에서 전면 재작성을 피한다.
// 실제 sparse texture / MTLHeap 아틀라스 + apron(gutter) 픽셀은 M2~M3에서 채운다.

public struct TileIndex: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public protocol TileStore: AnyObject {
    /// 한 변의 픽셀 수(apron 제외). 256² 같은 상수는 브러시·VM페이지·캐시 트레이드오프로
    /// 재유도할 값이며 여기서 단정하지 않는다(설계 §5.3).
    var tileSize: Int { get }
    var canvasPixels: SIMD2<Int> { get }

    func hasTile(at index: TileIndex) -> Bool
    /// dirty 영역(document px)을 덮는 타일 인덱스들. 브러시/합성이 부분 갱신할 때 사용.
    func tiles(coveringRect rect: PixelRect) -> [TileIndex]
}

public struct PixelRect: Equatable, Sendable {
    public var origin: SIMD2<Int>
    public var size: SIMD2<Int>
    public init(origin: SIMD2<Int>, size: SIMD2<Int>) { self.origin = origin; self.size = size }
}

/// M0 placeholder: 전체 캔버스를 타일 격자로 나눠 인덱스만 계산. 실제 픽셀 백킹은 미구현.
/// 호출부가 타일 인터페이스로 동작함을 검증하기 위한 최소 구현.
public final class GridTileStore: TileStore {
    public let tileSize: Int
    public let canvasPixels: SIMD2<Int>

    public init(canvasPixels: SIMD2<Int>, tileSize: Int = 256) {
        self.canvasPixels = canvasPixels
        self.tileSize = max(1, tileSize)
    }

    public var tilesPerAxis: SIMD2<Int> {
        SIMD2((canvasPixels.x + tileSize - 1) / tileSize,
              (canvasPixels.y + tileSize - 1) / tileSize)
    }

    public func hasTile(at index: TileIndex) -> Bool {
        let n = tilesPerAxis
        return index.x >= 0 && index.y >= 0 && index.x < n.x && index.y < n.y
    }

    public func tiles(coveringRect rect: PixelRect) -> [TileIndex] {
        let minX = max(0, rect.origin.x / tileSize)
        let minY = max(0, rect.origin.y / tileSize)
        let maxX = min(tilesPerAxis.x - 1, (rect.origin.x + max(0, rect.size.x - 1)) / tileSize)
        let maxY = min(tilesPerAxis.y - 1, (rect.origin.y + max(0, rect.size.y - 1)) / tileSize)
        guard minX <= maxX, minY <= maxY else { return [] }
        var result: [TileIndex] = []
        for y in minY...maxY { for x in minX...maxX { result.append(TileIndex(x: x, y: y)) } }
        return result
    }
}
