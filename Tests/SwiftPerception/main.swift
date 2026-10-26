import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// 轻量断言：Swift 测试 target 尚未建立，这里用 swiftc 直接编译纯感知内核，
// 由 scripts/run-swift-tests.sh 调用。后续可平移到 XCTest。
var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL  \(message)")
    }
}

func almost(_ a: CGFloat, _ b: CGFloat, _ epsilon: CGFloat = 1e-6) -> Bool {
    abs(a - b) < epsilon
}

// MARK: - BoardGeometry

func testBoardGeometry() {
    print("BoardGeometry")
    let square = BoardQuad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )
    check(square.isValid, "正方形四边形有效")

    guard let grid = BoardGrid(quad: square, rows: 5, cols: 12) else {
        check(false, "5×12 格点初始化")
        return
    }
    check(grid.cellCenters.count == 60, "生成 60 个格心")
    for row in 0..<5 {
        for col in 0..<12 {
            let index = row * 12 + col
            let center = grid.cellCenters[index]
            let expectedX = 0.1 + (CGFloat(col) + 0.5) / 12 * 0.8
            let expectedY = 0.1 + (CGFloat(row) + 0.5) / 5 * 0.8
            check(
                almost(center.x, expectedX, 1e-5) && almost(center.y, expectedY, 1e-5),
                "格心 (\(row),\(col)) 位置正确"
            )
            check(grid.cellIndex(at: center) == index, "格点反查 (\(row),\(col))")
        }
    }

    let perspective = BoardQuad(
        topLeft: CGPoint(x: 0.2, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.15),
        bottomRight: CGPoint(x: 0.85, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.8)
    )
    check(perspective.isValid, "透视四边形有效")
    guard let perspectiveGrid = BoardGrid(quad: perspective, rows: 5, cols: 12) else {
        check(false, "透视格点初始化")
        return
    }
    for (index, center) in perspectiveGrid.cellCenters.enumerated() {
        check(perspectiveGrid.cellIndex(at: center) == index, "透视格点反查 \(index)")
    }
    check(perspectiveGrid.cellIndex(at: CGPoint(x: 0.01, y: 0.01)) == nil, "棋盘外返回 nil")
    check(
        BoardGrid(
            quad: BoardQuad(topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero),
            rows: 5,
            cols: 12
        ) == nil,
        "退化四边形被拒绝"
    )
}

// MARK: - BoardStabilizer

private func board(_ cells: [CellObservation], rows: Int = 2, cols: Int = 2) -> BoardObservation {
    guard let observation = BoardObservation(rows: rows, cols: cols, cells: cells) else {
        fatalError("测试棋盘尺寸不匹配")
    }
    return observation
}

private func hiddenBoard() -> BoardObservation {
    board(Array(repeating: .hidden(), count: 4))
}

func testStabilizerVotesOutNoise() {
    print("BoardStabilizer · 投票")
    var stabilizer = BoardStabilizer()
    var output = stabilizer.update(hiddenBoard(), at: 0)
    check(output?.cells.allSatisfy { $0.state == .unknown } == true, "首帧不足票数输出 unknown")

    output = stabilizer.update(hiddenBoard(), at: 0.1)
    check(output?.cells.allSatisfy { $0.state == .hidden } == true, "两帧一致后稳定为暗子")

    let oneRevealed = board([
        .revealed(.red, "司令"), .hidden(), .hidden(), .hidden(),
    ])
    output = stabilizer.update(oneRevealed, at: 0.2)
    check(output?.cells[0].state == .hidden, "单帧噪声不改变稳定状态")

    output = stabilizer.update(oneRevealed, at: 0.3)
    check(output?.cells[0].state == .revealed, "连续两帧翻牌后更新为明子")
    check(output?.cells[0].color == .red, "保留棋子颜色")
    check(output?.cells[0].piece == "司令", "保留棋子名称")
    check(output?.changedCells == 1, "只统计一格的改变")
}

func testStabilizerFiltersLowConfidence() {
    print("BoardStabilizer · 置信度")
    var stabilizer = BoardStabilizer()
    _ = stabilizer.update(hiddenBoard(), at: 0)
    _ = stabilizer.update(hiddenBoard(), at: 0.1)

    let noisy = board([
        .revealed(.black, "军长", confidence: 0.4), .hidden(), .hidden(), .hidden(),
    ])
    _ = stabilizer.update(noisy, at: 0.2)
    let output = stabilizer.update(noisy, at: 0.3)
    check(output?.cells[0].state == .hidden, "低置信度观察不参与投票")

    var config = BoardStabilizerConfig()
    config.requiredVotes = 2
    config.windowSize = 2
    var tieStabilizer = BoardStabilizer(config: config)
    let emptyFirst = board([.empty(), .hidden(), .hidden(), .hidden()])
    let hiddenFirst = board([.hidden(), .hidden(), .hidden(), .hidden()])
    _ = tieStabilizer.update(emptyFirst, at: 0)
    let tie = tieStabilizer.update(hiddenFirst, at: 0.1)
    check(tie?.cells[0].state == .unknown, "平票降级为 unknown")
}

func testStabilizerFreezesBoardWideChange() {
    print("BoardStabilizer · 整盘冻结")
    var stabilizer = BoardStabilizer()
    _ = stabilizer.update(hiddenBoard(), at: 0)
    _ = stabilizer.update(hiddenBoard(), at: 0.1)

    let cleared = board(Array(repeating: .empty(), count: 4))
    var output = stabilizer.update(cleared, at: 0.2)
    check(output?.cells.allSatisfy { $0.state == .hidden } == true, "单帧整盘变化先被投票挡住")
    check(output?.isSettling == false, "单帧不触发冻结")

    output = stabilizer.update(cleared, at: 0.4)
    check(output?.cells.allSatisfy { $0.state == .hidden } == true, "改变未满两票时保持旧盘")
    check(output?.isSettling == true, "检测到整盘变化进入冻结")

    output = stabilizer.update(cleared, at: 0.6)
    check(output?.cells.allSatisfy { $0.state == .hidden } == true, "静置不足时继续冻结")
    check(output?.isSettling == true, "仍在静置")

    output = stabilizer.update(cleared, at: 0.8)
    check(output?.cells.allSatisfy { $0.state == .empty } == true, "静置完成后提交新盘")
    check(output?.isSettling == false, "冻结解除")
    check(output?.changedCells == 4, "整盘变化格数为 4")
}

func testStabilizerResetsOnSizeChange() {
    print("BoardStabilizer · 尺寸切换")
    var stabilizer = BoardStabilizer()
    _ = stabilizer.update(hiddenBoard(), at: 0)
    _ = stabilizer.update(hiddenBoard(), at: 0.1)

    let resized = board(Array(repeating: .hidden(), count: 3), rows: 1, cols: 3)
    var output = stabilizer.update(resized, at: 0.2)
    check(output?.rows == 1 && output?.cols == 3, "切换为新的行列数")
    check(output?.cells.count == 3, "重新初始化历史")
    check(output?.cells.allSatisfy { $0.state == .unknown } == true, "新尺寸首帧为 unknown")

    output = stabilizer.update(resized, at: 0.3)
    check(output?.cells.allSatisfy { $0.state == .hidden } == true, "新尺寸两帧后稳定")
}

func testCellObservationNormalization() {
    print("CellObservation")
    check(CellObservation(state: .empty, color: .red, piece: "司令").color == nil, "空格清空颜色")
    check(CellObservation(state: .hidden, color: .black, piece: "地雷").piece == nil, "暗子清空棋子")
    check(CellObservation.revealed(.red, "司令").isActionable, "完整明子可行动")
    check(!CellObservation(state: .revealed, color: .red).isActionable, "缺棋子名的明子不可行动")
    check(!CellObservation.unknown().isActionable, "unknown 不可行动")
}

// MARK: - SnapshotLibrary

struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let scale: CGFloat
    let timestamp: Double
    let contentRect: CGRect
    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
}

private func makeBoardBuffer(width: Int = 640, height: Int = 400) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        fatalError("CVPixelBufferCreate 失败：\(status)")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?
        .assumingMemoryBound(to: UInt8.self)
    else {
        fatalError("CVPixelBuffer 基址为空")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = min(4, y * 5 / height)
        for x in 0..<width {
            let col = min(11, x * 12 / width)
            let offset = y * bytesPerRow + x * 4
            base[offset] = UInt8(30 + row * 40)      // B
            base[offset + 1] = UInt8(30 + col * 18)  // G
            base[offset + 2] = 200                   // R
            base[offset + 3] = 255                   // A
        }
    }
    return buffer
}

func testSnapshotLibrary() {
    print("SnapshotLibrary")
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("ttj-snapshot-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let frame = CapturedFrame(
        pixelBuffer: makeBoardBuffer(),
        scale: 1,
        timestamp: 0,
        contentRect: CapturedFrame.fullFrame
    )
    let quad = BoardQuad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )
    guard let grid = BoardGrid(quad: quad, rows: 5, cols: 12) else {
        check(false, "测试棋盘初始化")
        return
    }

    do {
        _ = try BoardSnapshotExporter(rootURL: root).export(
            frame: frame,
            grid: grid,
            windowSize: CGSize(width: 640, height: 400),
            theme: "test"
        )

        let library = SnapshotLibrary(rootURL: root)
        let list = try library.list()
        check(list.count == 1, "扫描到 1 份快照")
        guard let summary = list.first else {
            check(false, "缺少快照摘要")
            return
        }
        check(summary.isValidManifest, "meta.json 可读")
        check(summary.rows == 5 && summary.cols == 12, "快照行列正确")
        check(summary.cellCount == 60, "快照格数正确")

        let manifest = try library.loadManifest(summary)
        check(manifest.cells.count == 60, "meta 包含 60 格")
        check(fileManager.fileExists(atPath: root.path), "样本根目录存在")

        guard var labels = SnapshotLabels(manifest: manifest, snapshot: summary.id) else {
            check(false, "从 manifest 创建标签")
            return
        }
        check(labels.cells.count == 60, "标签包含 60 格")
        check(!labels.isComplete, "默认标签不完整")
        check(labels.completeCount == 0, "默认已标数为 0")

        labels.setAll(.hidden)
        check(labels.isComplete, "全部暗子后标签完整")
        check(labels.completeCount == 60, "全部暗子已标 60 格")

        labels.update(index: 7) { label in
            label.setState(.revealed)
            label.setColor(.black)
            label.setPiece("炸弹")
        }
        check(labels.cells[7].state == .revealed, "第 7 格改为明子")
        check(labels.cells[7].displayLabel == "黑炸弹", "明子显示为黑炸弹")
        check(labels.cells[7].isComplete, "完整明子标签有效")

        labels.update(index: 8) { label in
            label.setState(.revealed)
        }
        check(!labels.cells[8].isComplete, "未选棋子的明子标签不完整")
        check(labels.incompleteCount == 1, "未完成数为 1")

        labels.update(index: 8) { label in
            label.setState(.empty)
        }
        check(labels.isComplete, "改回空格后恢复完整")

        try library.saveLabels(labels, for: summary)
        check(fileManager.fileExists(atPath: library.labelsURL(for: summary).path), "labels.json 已写入")
        guard let loaded = try library.loadLabels(summary) else {
            check(false, "labels.json 可读")
            return
        }
        check(loaded.cells == labels.cells, "标签逐格往返一致")
        check(loaded.snapshot == summary.id, "标签记录快照 ID")
        check(loaded.isComplete, "往返后标签完整")

        let copied = loaded.copied(to: "snapshot-copy")
        check(copied?.cells == loaded.cells, "复制标签保留逐格内容")
        check(copied?.snapshot == "snapshot-copy", "复制标签更新快照 ID")

        check(
            library.imageURL(for: manifest.cells[0], in: summary).pathExtension == "png",
            "格子图片为 PNG"
        )
        if let source = CGImageSourceCreateWithURL(
            library.imageURL(for: manifest.cells[0], in: summary) as CFURL, nil
        ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            check(image.width == 128 && image.height == 128, "格子图片为 128×128")
        } else {
            check(false, "格子图片可读取")
        }

        var invalid = labels
        invalid.rows = 4
        do {
            try library.saveLabels(invalid, for: summary)
            check(false, "尺寸不一致时应拒绝保存")
        } catch {
            check(true, "尺寸不一致时拒绝保存")
        }

        let missing = SnapshotLibrary(rootURL: root.appendingPathComponent("missing"))
        let missingList = try missing.list()
        check(missingList.isEmpty, "不存在的样本目录返回空列表")
    } catch {
        check(false, "SnapshotLibrary 抛出异常：\(error)")
    }
}

// MARK: - Main

testBoardGeometry()
testStabilizerVotesOutNoise()
testStabilizerFiltersLowConfidence()
testStabilizerFreezesBoardWideChange()
testStabilizerResetsOnSizeChange()
testCellObservationNormalization()
testSnapshotLibrary()

if failures > 0 {
    print("\n\(failures)/\(checks) 个断言失败")
    exit(1)
}
print("\n全部 Swift 感知测试通过（\(checks) 个断言）")
