import CoreGraphics
import Foundation

/// 归一化图像坐标中的棋盘四边形（左上原点，顺序：左上 → 右上 → 右下 → 左下）。
struct BoardQuad: Equatable, Sendable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    init?(corners: [CGPoint]) {
        guard corners.count == 4 else { return nil }
        self.init(
            topLeft: corners[0],
            topRight: corners[1],
            bottomRight: corners[2],
            bottomLeft: corners[3]
        )
    }

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// 四角的外接矩形（归一化坐标）。
    var bounds: CGRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 平均宽高比（上/下边宽 ÷ 左/右边高）。
    var aspectRatio: CGFloat {
        let top = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        let bottom = hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y)
        let left = hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
        let right = hypot(bottomRight.x - topRight.x, bottomRight.y - topRight.y)
        let width = (top + bottom) / 2
        let height = (left + right) / 2
        return height > 0 ? width / height : 0
    }

    /// 物理像素宽高比。归一化坐标会被画面本身的比例压缩，
    /// 判断「12:5 棋盘」时必须乘上画面宽高比。
    func physicalAspect(imageAspect: CGFloat) -> CGFloat {
        aspectRatio * imageAspect
    }

    /// 四边形面积（鞋带公式，归一化单位）。
    var area: CGFloat {
        let points = corners
        var sum: CGFloat = 0
        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// 四角是否有效：面积够大、凸四边形、没有退化边。
    var isValid: Bool {
        guard area > 0.02 else { return false }
        let points = corners
        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            guard hypot(b.x - a.x, b.y - a.y) > 0.03 else { return false }
            guard (-0.05...1.05).contains(a.x), (-0.05...1.05).contains(a.y) else { return false }
        }

        // 凸性：连续边的叉积同号。
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            let c = points[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-6 { return false }
            if sign == 0 { sign = cross > 0 ? 1 : -1 }
            if cross * sign < 0 { return false }
        }
        return true
    }
}

/// 单应矩阵：把平面点 (u,v) 映射到 (x,y)。
struct Homography: Equatable, Sendable {
    let a, b, c, d, e, f, g, h: CGFloat

    func map(_ point: CGPoint) -> CGPoint {
        let denominator = g * point.x + h * point.y + 1
        guard abs(denominator) > 1e-9 else { return .zero }
        return CGPoint(
            x: (a * point.x + b * point.y + c) / denominator,
            y: (d * point.x + e * point.y + f) / denominator
        )
    }

    /// 求把 `source` 四角映射到 `destination` 四角的单应矩阵。
    static func mapping(from source: [CGPoint], to destination: [CGPoint]) -> Homography? {
        guard source.count == 4, destination.count == 4 else { return nil }

        var matrix = [[CGFloat]](repeating: [CGFloat](repeating: 0, count: 8), count: 8)
        var rhs = [CGFloat](repeating: 0, count: 8)

        for index in 0..<4 {
            let u = source[index].x
            let v = source[index].y
            let x = destination[index].x
            let y = destination[index].y

            matrix[index * 2] = [u, v, 1, 0, 0, 0, -u * x, -v * x]
            rhs[index * 2] = x
            matrix[index * 2 + 1] = [0, 0, 0, u, v, 1, -u * y, -v * y]
            rhs[index * 2 + 1] = y
        }

        guard let solution = solve(matrix, rhs) else { return nil }
        return Homography(
            a: solution[0], b: solution[1], c: solution[2],
            d: solution[3], e: solution[4], f: solution[5],
            g: solution[6], h: solution[7]
        )
    }

    /// 8×8 高斯消元（部分主元）。
    private static func solve(_ input: [[CGFloat]], _ rhsInput: [CGFloat]) -> [CGFloat]? {
        var matrix = input
        var rhs = rhsInput
        let count = rhs.count
        guard matrix.count == count, matrix.allSatisfy({ $0.count == count }) else { return nil }

        for column in 0..<count {
            var pivot = column
            var best = abs(matrix[column][column])
            for row in (column + 1)..<count {
                let candidate = abs(matrix[row][column])
                if candidate > best {
                    best = candidate
                    pivot = row
                }
            }
            guard best > 1e-9 else { return nil }
            if pivot != column {
                matrix.swapAt(pivot, column)
                rhs.swapAt(pivot, column)
            }

            let divisor = matrix[column][column]
            for index in column..<count {
                matrix[column][index] /= divisor
            }
            rhs[column] /= divisor

            for row in 0..<count where row != column {
                let factor = matrix[row][column]
                guard abs(factor) > 1e-12 else { continue }
                for index in column..<count {
                    matrix[row][index] -= factor * matrix[column][index]
                }
                rhs[row] -= factor * rhs[column]
            }
        }
        return rhs
    }
}

/// 5×12 棋盘格点（归一化坐标，行优先）。
///
/// 格线允许非均匀分布：翻翻棋中间有一条比普通格距宽得多的河道。
/// 这里保存每一列/行的中心（而不是共享边界），每个训练格子都以中心为正中、
/// 宽度取相邻列距的较小值，因此黄点始终落在格子中心。
struct BoardGrid: Equatable, Sendable {
    let rows: Int
    let cols: Int
    let quad: BoardQuad
    let forward: Homography
    let inverse: Homography
    /// 每列中心（棋盘 u 坐标，0…1）。
    let columnCenters: [CGFloat]
    /// 每行中心（棋盘 v 坐标，0…1）。
    let rowCenters: [CGFloat]
    /// 行优先，索引 = row * cols + col。
    let cellCenters: [CGPoint]

    init?(
        quad: BoardQuad,
        rows: Int,
        cols: Int,
        columnCenters: [CGFloat]? = nil,
        rowCenters: [CGFloat]? = nil
    ) {
        guard rows > 0, cols > 0, quad.isValid else { return nil }
        let uCenters = Self.normalizedCenters(columnCenters, count: cols)
        let vCenters = Self.normalizedCenters(rowCenters, count: rows)

        let unit = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1),
        ]
        guard let forward = Homography.mapping(from: unit, to: quad.corners),
              let inverse = Homography.mapping(from: quad.corners, to: unit)
        else { return nil }

        var centers: [CGPoint] = []
        centers.reserveCapacity(rows * cols)
        for row in 0..<rows {
            for col in 0..<cols {
                centers.append(forward.map(CGPoint(x: uCenters[col], y: vCenters[row])))
            }
        }

        self.rows = rows
        self.cols = cols
        self.quad = quad
        self.forward = forward
        self.inverse = inverse
        self.columnCenters = uCenters
        self.rowCenters = vCenters
        self.cellCenters = centers
    }

    /// 归一化棋盘坐标 (u,v) → 图像归一化坐标。
    func point(u: CGFloat, v: CGFloat) -> CGPoint {
        forward.map(CGPoint(x: u, y: v))
    }

    /// 第 `col` 列、第 `row` 行的训练格子范围（u/v）。
    /// 以中心线为正中，半宽取相邻列距的较小值；`inset` 是相对半宽的留边比例。
    func cellRect(
        row: Int,
        col: Int,
        inset: CGFloat = 0
    ) -> (u0: CGFloat, v0: CGFloat, u1: CGFloat, v1: CGFloat) {
        let uHalf = Self.halfPitch(at: col, centers: columnCenters) * (1 - inset)
        let vHalf = Self.halfPitch(at: row, centers: rowCenters) * (1 - inset)
        return (
            columnCenters[col] - uHalf,
            rowCenters[row] - vHalf,
            columnCenters[col] + uHalf,
            rowCenters[row] + vHalf
        )
    }

    /// 每格的图像归一化外接矩形（行优先，索引 = row * cols + col）。
    ///
    /// 自动采样用它把差异统计限制在棋子范围内。透视棋盘上取四角外接矩形会
    /// 略微放大格子、稀释变化占比，但真实走棋仍有 79% 以上，阈值留足余量。
    func cellBoundingRects(inset: CGFloat = 0) -> [CGRect] {
        var rects: [CGRect] = []
        rects.reserveCapacity(rows * cols)
        for row in 0..<rows {
            for col in 0..<cols {
                let cell = cellRect(row: row, col: col, inset: inset)
                let corners = [
                    forward.map(CGPoint(x: cell.u0, y: cell.v0)),
                    forward.map(CGPoint(x: cell.u1, y: cell.v0)),
                    forward.map(CGPoint(x: cell.u1, y: cell.v1)),
                    forward.map(CGPoint(x: cell.u0, y: cell.v1)),
                ]
                let xs = corners.map(\.x)
                let ys = corners.map(\.y)
                let minX = min(max(xs.min() ?? 0, 0), 1)
                let maxX = min(max(xs.max() ?? 0, 0), 1)
                let minY = min(max(ys.min() ?? 0, 0), 1)
                let maxY = min(max(ys.max() ?? 0, 0), 1)
                rects.append(
                    CGRect(
                        x: minX,
                        y: minY,
                        width: max(0, maxX - minX),
                        height: max(0, maxY - minY)
                    )
                )
            }
        }
        return rects
    }

    /// 图像归一化坐标 → 格子索引（row * cols + col）；落在棋盘外返回 nil。
    func cellIndex(at point: CGPoint) -> Int? {
        let uv = inverse.map(point)
        guard (-0.02...1.02).contains(uv.x), (-0.02...1.02).contains(uv.y) else {
            return nil
        }
        guard let firstCol = columnCenters.first, let lastCol = columnCenters.last,
              let firstRow = rowCenters.first, let lastRow = rowCenters.last
        else { return nil }

        let uMin = firstCol - Self.halfPitch(at: 0, centers: columnCenters)
        let uMax = lastCol + Self.halfPitch(at: columnCenters.count - 1, centers: columnCenters)
        let vMin = firstRow - Self.halfPitch(at: 0, centers: rowCenters)
        let vMax = lastRow + Self.halfPitch(at: rowCenters.count - 1, centers: rowCenters)
        guard uv.x >= uMin - 0.01, uv.x <= uMax + 0.01,
              uv.y >= vMin - 0.01, uv.y <= vMax + 0.01
        else { return nil }

        let col = Self.nearestIndex(to: uv.x, centers: columnCenters)
        let row = Self.nearestIndex(to: uv.y, centers: rowCenters)
        return row * cols + col
    }

    /// 把外部传入的中心规整为严格递增的 0…1 数组；不合法时退回均分。
    private static func normalizedCenters(_ input: [CGFloat]?, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let uniform = (0..<count).map { (CGFloat($0) + 0.5) / CGFloat(count) }
        guard let input, input.count == count else { return uniform }

        let values = input.map { min(max($0, 0), 1) }
        for index in 1..<count where values[index] <= values[index - 1] + 1e-6 {
            return uniform
        }
        return values
    }

    /// 相邻列距的较小值的一半。
    private static func halfPitch(at index: Int, centers: [CGFloat]) -> CGFloat {
        guard centers.count > 1 else { return 0.5 }
        let left = index > 0
            ? centers[index] - centers[index - 1]
            : centers[1] - centers[0]
        let right = index < centers.count - 1
            ? centers[index + 1] - centers[index]
            : centers[centers.count - 1] - centers[centers.count - 2]
        return min(left, right) / 2
    }

    private static func nearestIndex(to value: CGFloat, centers: [CGFloat]) -> Int {
        var best = 0
        var distance = CGFloat.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let candidate = abs(value - center)
            if candidate < distance {
                distance = candidate
                best = index
            }
        }
        return best
    }
}

/// 可逐列/逐行调整的棋盘网格遮罩（M1-1 校准用）。
///
/// 翻翻棋的列不是等宽的（中间河道明显更宽），所以这里不再用
/// 「矩形 ÷ 12」推格线，而是直接保存每一列/每一行的中心线：
/// 黄点就是中心线交点，拖哪条线只影响那一列/那一行。
/// 外框和格子边界由中心线推导，训练样本仍按完整格子裁剪。
struct BoardMask: Equatable, Sendable {
    /// 与 `BoardQuad.isValid` 的面积门槛保持一致，并留一点余量。
    static let minimumArea: CGFloat = 0.022
    /// 单边最小比例，避免遮罩被压成线。
    static let minimumSide: CGFloat = 0.05
    /// 相邻两条中心线的最小归一化间距。
    static let minimumPitch: CGFloat = 0.008

    /// 每列中心（归一化图像坐标，0…1）。
    var columnCenters: [CGFloat]
    /// 每行中心（归一化图像坐标，0…1）。
    var rowCenters: [CGFloat]

    /// 按矩形均分生成初始中心线（仅作为起点，之后可逐条拖）。
    init(rect: CGRect, rows: Int, cols: Int) {
        let rowCount = max(1, rows)
        let colCount = max(1, cols)
        let frame = rect.standardized
        self.rowCenters = (0..<rowCount).map {
            frame.minY + (CGFloat($0) + 0.5) / CGFloat(rowCount) * frame.height
        }
        self.columnCenters = (0..<colCount).map {
            frame.minX + (CGFloat($0) + 0.5) / CGFloat(colCount) * frame.width
        }
    }

    /// 从已保存的中心线恢复；数量或位置不合法时退回矩形均分。
    init(
        rect: CGRect,
        rows: Int,
        cols: Int,
        columnCenters: [CGFloat]?,
        rowCenters: [CGFloat]?
    ) {
        self.init(rect: rect, rows: rows, cols: cols)
        if let columnCenters,
           let values = Self.validCenters(columnCenters, count: cols) {
            self.columnCenters = values
        }
        if let rowCenters,
           let values = Self.validCenters(rowCenters, count: rows) {
            self.rowCenters = values
        }
    }

    /// 直接按中心线构造（整份校准只有中心线时使用）。
    init?(columnCenters: [CGFloat], rowCenters: [CGFloat]) {
        guard let columns = Self.validCenters(columnCenters, count: columnCenters.count),
              let rows = Self.validCenters(rowCenters, count: rowCenters.count)
        else { return nil }
        self.columnCenters = columns
        self.rowCenters = rows
    }

    /// 某一列训练格子的左右边界（归一化图像坐标）。
    func columnBounds(_ index: Int) -> ClosedRange<CGFloat> {
        guard columnCenters.indices.contains(index) else { return 0...0 }
        let half = Self.halfPitch(at: index, centers: columnCenters)
        return (columnCenters[index] - half)...(columnCenters[index] + half)
    }

    /// 某一行训练格子的上下边界（归一化图像坐标）。
    func rowBounds(_ index: Int) -> ClosedRange<CGFloat> {
        guard rowCenters.indices.contains(index) else { return 0...0 }
        let half = Self.halfPitch(at: index, centers: rowCenters)
        return (rowCenters[index] - half)...(rowCenters[index] + half)
    }

    /// 所有训练格子的外接矩形（也是棋盘外框）。
    var rect: CGRect {
        guard !columnCenters.isEmpty, !rowCenters.isEmpty else { return .zero }
        let minX = columnBounds(0).lowerBound
        let maxX = columnBounds(columnCenters.count - 1).upperBound
        let minY = rowBounds(0).lowerBound
        let maxY = rowBounds(rowCenters.count - 1).upperBound
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    var center: CGPoint {
        let frame = rect
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// 遮罩对应的棋盘四角（左上 → 右上 → 右下 → 左下）。
    func quad() -> BoardQuad? {
        let frame = rect
        guard frame.width > 0, frame.height > 0 else { return nil }
        return BoardQuad(
            topLeft: CGPoint(x: frame.minX, y: frame.minY),
            topRight: CGPoint(x: frame.maxX, y: frame.minY),
            bottomRight: CGPoint(x: frame.maxX, y: frame.maxY),
            bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
        )
    }

    /// 用中心线生成完整的棋盘格点；列数/行数由中心线数量决定。
    func grid() -> BoardGrid? {
        guard let quad = quad() else { return nil }

        let frame = rect
        guard frame.width > 0, frame.height > 0 else { return nil }

        let uCenters = columnCenters.map { ($0 - frame.minX) / frame.width }
        let vCenters = rowCenters.map { ($0 - frame.minY) / frame.height }

        return BoardGrid(
            quad: quad,
            rows: rowCenters.count,
            cols: columnCenters.count,
            columnCenters: uCenters,
            rowCenters: vCenters
        )
    }

    /// 物理像素宽高比（只用于提示，不参与约束）。
    func physicalAspect(imageAspect: CGFloat) -> CGFloat {
        let frame = rect
        guard frame.height > 0 else { return 0 }
        return frame.width * imageAspect / frame.height
    }

    /// 夹到画面内，并保证最小间距/面积。
    func clamped() -> BoardMask {
        var result = self
        result.columnCenters = Self.clampedCenters(columnCenters)
        result.rowCenters = Self.clampedCenters(rowCenters)

        let frame = result.rect
        let area = frame.width * frame.height
        if area > 0, area < Self.minimumArea {
            let factor = sqrt(Self.minimumArea / area)
            let anchor = result.center
            result.columnCenters = result.columnCenters.map {
                anchor.x + ($0 - anchor.x) * factor
            }
            result.rowCenters = result.rowCenters.map {
                anchor.y + ($0 - anchor.y) * factor
            }
            result.columnCenters = Self.clampedCenters(result.columnCenters)
            result.rowCenters = Self.clampedCenters(result.rowCenters)
        }
        return result
    }

    /// 以 `anchor`（归一化图像坐标）为不动点整体缩放；间距不足时拒绝缩小。
    func zoomed(by factor: CGFloat, anchor: CGPoint) -> BoardMask {
        guard factor > 0, factor.isFinite, factor != 1 else { return self }
        if factor < 1 {
            let minX = Self.minimumPitch(for: columnCenters)
            let minY = Self.minimumPitch(for: rowCenters)
            if minX > 0, minY > 0 {
                let floor = max(
                    Self.minimumPitch / minX,
                    Self.minimumPitch / minY
                )
                if factor < floor { return self }
            }
        }

        var result = self
        result.columnCenters = columnCenters.map {
            anchor.x + ($0 - anchor.x) * factor
        }
        result.rowCenters = rowCenters.map {
            anchor.y + ($0 - anchor.y) * factor
        }
        return result.clamped()
    }

    /// 按归一化偏移平移；整体不会移出画面。
    func moved(by delta: CGSize) -> BoardMask {
        guard let minX = columnCenters.first, let maxX = columnCenters.last,
              let minY = rowCenters.first, let maxY = rowCenters.last
        else { return self }

        let dx = min(max(delta.width, -minX), 1 - maxX)
        let dy = min(max(delta.height, -minY), 1 - maxY)
        var result = self
        result.columnCenters = columnCenters.map { $0 + dx }
        result.rowCenters = rowCenters.map { $0 + dy }
        return result.clamped()
    }

    /// 单独移动某一列的中心线（侧栏滑杆 / 方向键）。
    func settingColumnCenter(_ index: Int, to value: CGFloat) -> BoardMask {
        guard columnCenters.indices.contains(index) else { return self }
        var result = self
        let lower = index > 0
            ? columnCenters[index - 1] + Self.minimumPitch
            : 0
        let upper = index < columnCenters.count - 1
            ? columnCenters[index + 1] - Self.minimumPitch
            : 1
        result.columnCenters[index] = min(max(value, lower), max(lower, upper))
        return result
    }

    /// 单独移动某一行的中心线。
    func settingRowCenter(_ index: Int, to value: CGFloat) -> BoardMask {
        guard rowCenters.indices.contains(index) else { return self }
        var result = self
        let lower = index > 0
            ? rowCenters[index - 1] + Self.minimumPitch
            : 0
        let upper = index < rowCenters.count - 1
            ? rowCenters[index + 1] - Self.minimumPitch
            : 1
        result.rowCenters[index] = min(max(value, lower), max(lower, upper))
        return result
    }

    /// 保留首尾中心线，把中间的列重新均分。
    func uniformizedColumns() -> BoardMask {
        guard columnCenters.count > 2,
              let first = columnCenters.first,
              let last = columnCenters.last
        else { return self }
        var result = self
        let step = (last - first) / CGFloat(columnCenters.count - 1)
        result.columnCenters = (0..<columnCenters.count).map {
            first + CGFloat($0) * step
        }
        return result
    }

    /// 保留首尾中心线，把中间的行重新均分。
    func uniformizedRows() -> BoardMask {
        guard rowCenters.count > 2,
              let first = rowCenters.first,
              let last = rowCenters.last
        else { return self }
        var result = self
        let step = (last - first) / CGFloat(rowCenters.count - 1)
        result.rowCenters = (0..<rowCenters.count).map {
            first + CGFloat($0) * step
        }
        return result
    }

    /// 用自动检测到的四边形初始化遮罩（在框内均分）。
    static func fitting(_ quad: BoardQuad, rows: Int = 5, cols: Int = 12) -> BoardMask {
        let bounds = quad.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return BoardMask(
                rect: CGRect(x: 0.07, y: 0.2, width: 0.86, height: 0.6),
                rows: rows,
                cols: cols
            ).clamped()
        }
        return BoardMask(rect: bounds, rows: rows, cols: cols).clamped()
    }

    // MARK: - 推导

    /// 相邻中心线的较小间距的一半：训练格子以中心为正中，不把大河道算进去。
    private static func halfPitch(at index: Int, centers: [CGFloat]) -> CGFloat {
        guard centers.count > 1 else { return 0.5 }
        let left = index > 0
            ? centers[index] - centers[index - 1]
            : centers[1] - centers[0]
        let right = index < centers.count - 1
            ? centers[index + 1] - centers[index]
            : centers[centers.count - 1] - centers[centers.count - 2]
        return min(left, right) / 2
    }

    /// 相邻中心线的平均间距。
    private static func minimumPitch(for centers: [CGFloat]) -> CGFloat {
        guard centers.count > 1, let first = centers.first, let last = centers.last else {
            return 0
        }
        return (last - first) / CGFloat(centers.count - 1)
    }

    private static func validCenters(_ input: [CGFloat], count: Int) -> [CGFloat]? {
        guard input.count == count, count > 0 else { return nil }
        let values = input.map { min(max($0, 0), 1) }
        for index in 1..<count where values[index] <= values[index - 1] + 1e-6 {
            return nil
        }
        return values
    }

    private static func clampedCenters(_ input: [CGFloat]) -> [CGFloat] {
        guard !input.isEmpty else { return [] }
        var values = input.map { min(max($0, 0), 1) }
        guard values.count > 1 else { return values }

        let pitch = Self.minimumPitch
        for index in 1..<values.count {
            values[index] = max(values[index], values[index - 1] + pitch)
        }
        if let last = values.last, last > 1 {
            let shift = last - 1
            values = values.map { $0 - shift }
            if values[0] < 0 {
                let count = CGFloat(values.count)
                values = (0..<values.count).map { CGFloat($0) / max(count - 1, 1) }
            }
        }
        return values
    }
}

extension Calibration {
    /// 用当前校准（棋盘四角 + 逐列/逐行中心线）生成完整格点。
    /// 概览页叠加网格、手动采集、对局自动采样都走这一处，避免几何口径漂移。
    func boardGrid(rows: Int, cols: Int) -> BoardGrid? {
        guard let quad = BoardQuad(corners: boardCorners) else { return nil }
        let mask = BoardMask(
            rect: quad.bounds,
            rows: rows,
            cols: cols,
            columnCenters: boardColumnCenters,
            rowCenters: boardRowCenters
        )
        return mask.grid()
    }
}
