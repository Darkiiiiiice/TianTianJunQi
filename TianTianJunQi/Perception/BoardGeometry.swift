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
struct BoardGrid: Equatable, Sendable {
    let rows: Int
    let cols: Int
    let quad: BoardQuad
    let forward: Homography
    let inverse: Homography
    /// 行优先，索引 = row * cols + col。
    let cellCenters: [CGPoint]

    init?(quad: BoardQuad, rows: Int, cols: Int) {
        guard rows > 0, cols > 0, quad.isValid else { return nil }

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
                let u = (CGFloat(col) + 0.5) / CGFloat(cols)
                let v = (CGFloat(row) + 0.5) / CGFloat(rows)
                centers.append(forward.map(CGPoint(x: u, y: v)))
            }
        }

        self.rows = rows
        self.cols = cols
        self.quad = quad
        self.forward = forward
        self.inverse = inverse
        self.cellCenters = centers
    }

    /// 归一化棋盘坐标 (u,v) → 图像归一化坐标。
    func point(u: CGFloat, v: CGFloat) -> CGPoint {
        forward.map(CGPoint(x: u, y: v))
    }

    /// 图像归一化坐标 → 格子索引（row * cols + col）；落在棋盘外返回 nil。
    func cellIndex(at point: CGPoint) -> Int? {
        let uv = inverse.map(point)
        guard (-0.01...1.01).contains(uv.x), (-0.01...1.01).contains(uv.y) else {
            return nil
        }
        let col = min(cols - 1, max(0, Int(uv.x * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int(uv.y * CGFloat(rows))))
        return row * cols + col
    }
}
