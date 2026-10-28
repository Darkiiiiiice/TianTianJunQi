import CoreGraphics
import CoreImage
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
    check(
        almost(square.physicalAspect(imageAspect: 1.5), 1.5, 1e-5),
        "物理宽高比按画面比例换算"
    )

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

    // 非均匀列中心：中间有一个比普通列距宽得多的河道。
    let unevenCenters: [CGFloat] = [
        0.03, 0.11, 0.19, 0.27, 0.35, 0.43,
        0.49, 0.63, 0.71, 0.79, 0.87, 0.95,
    ]
    guard let unevenGrid = BoardGrid(
        quad: square,
        rows: 5,
        cols: 12,
        columnCenters: unevenCenters
    ) else {
        check(false, "非均匀格点初始化")
        return
    }
    check(unevenGrid.columnCenters == unevenCenters, "保留非均匀列中心")
    for (index, center) in unevenGrid.cellCenters.enumerated() {
        check(unevenGrid.cellIndex(at: center) == index, "非均匀格点反查 \(index)")
    }
    check(
        almost(unevenGrid.cellCenters[6].x, 0.1 + 0.49 * 0.8, 1e-5),
        "河道旁的格心仍落在中心线上"
    )
    let channel = unevenGrid.cellRect(row: 0, col: 6)
    check(
        almost((channel.u0 + channel.u1) / 2, 0.49, 1e-5),
        "训练格子以中心线为正中"
    )
    check(
        almost(channel.u1 - channel.u0, 0.06, 1e-5),
        "训练格子宽度取较窄的相邻列距"
    )

    let fallback = BoardGrid(
        quad: square,
        rows: 5,
        cols: 12,
        columnCenters: [0.5]
    )
    check(
        almost(fallback?.columnCenters[0] ?? 0, 0.5 / 12, 1e-5),
        "长度不符的中心线退回均分"
    )

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

// MARK: - BoardMask

func testBoardMask() {
    print("BoardMask")
    let aspect: CGFloat = 1.54
    let rows = 5
    let cols = 12

    // 均分起点：中心线落在每格正中。
    let base = BoardMask(
        rect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.4),
        rows: rows,
        cols: cols
    )
    check(base.columnCenters.count == cols, "生成 12 条列中心线")
    check(base.rowCenters.count == rows, "生成 5 条行中心线")
    check(almost(base.columnCenters[0], 0.1 + 0.8 / 24), "首列中心 X")
    check(almost(base.rowCenters[0], 0.2 + 0.4 / 10), "首行中心 Y")

    // 外框与格子边界全部由中心线推导。
    let rect = base.rect
    check(almost(rect.minX, 0.1) && almost(rect.maxX, 0.9), "外框左右贴住最外侧中心线")
    check(almost(rect.minY, 0.2) && almost(rect.maxY, 0.6), "外框上下贴住最外侧中心线")
    check(almost(base.columnBounds(0).lowerBound, 0.1), "首列裁剪左边界")
    check(almost(base.columnBounds(cols - 1).upperBound, 0.9), "末列裁剪右边界")
    check(almost(base.rowBounds(0).lowerBound, 0.2), "首行裁剪上边界")
    check(almost(base.rowBounds(rows - 1).upperBound, 0.6), "末行裁剪下边界")
    check(
        almost(base.physicalAspect(imageAspect: aspect), 0.8 * aspect / 0.4, 1e-5),
        "物理宽高比按画面比例换算"
    )

    guard let grid = base.grid() else {
        check(false, "遮罩生成格点")
        return
    }
    check(grid.cellCenters.count == 60, "生成 60 个格心")
    check(almost(grid.cellCenters[0].x, base.columnCenters[0], 1e-5), "格心 X 与中心线一致")
    check(almost(grid.cellCenters[0].y, base.rowCenters[0], 1e-5), "格心 Y 与中心线一致")
    check(grid.cellIndex(at: grid.cellCenters[59]) == 59, "末格反查正确")

    // 只动第 7 列：其它列不受影响，格子允许非均匀。
    let shifted = base.settingColumnCenter(6, to: 0.56)
    check(almost(shifted.columnCenters[6], 0.56), "第 7 列中心线移动")
    for index in 0..<cols where index != 6 {
        check(
            almost(shifted.columnCenters[index], base.columnCenters[index]),
            "第 \(index + 1) 列不受影响"
        )
    }
    check(shifted.columnBounds(6) != base.columnBounds(6), "移动列中心后裁剪范围跟随")
    guard let shiftedGrid = shifted.grid() else {
        check(false, "非均匀遮罩生成格点")
        return
    }
    for row in 0..<rows {
        for col in 0..<cols {
            let index = row * cols + col
            check(
                shiftedGrid.cellIndex(at: shiftedGrid.cellCenters[index]) == index,
                "非均匀格点反查 (\(row),\(col))"
            )
        }
    }
    check(
        almost(shiftedGrid.cellCenters[6].x, 0.56, 1e-5),
        "移动后的列中心仍落在黄点上"
    )

    // 相邻中心线不能穿过彼此。
    let pushedRight = base.settingColumnCenter(5, to: 0.99)
    check(pushedRight.columnCenters[5] < pushedRight.columnCenters[6], "列中心线不会越过右邻居")
    let pushedLeft = base.settingColumnCenter(6, to: 0.0)
    check(pushedLeft.columnCenters[6] > pushedLeft.columnCenters[5], "列中心线不会越过左邻居")

    // 行中心线独立于列。
    let rowShifted = base.settingRowCenter(2, to: 0.45)
    check(almost(rowShifted.rowCenters[2], 0.45), "第 3 行中心线移动")
    check(almost(rowShifted.columnCenters[3], base.columnCenters[3]), "移行不影响列")

    // 均分按钮保留首尾中心线。
    let uneven = base.settingColumnCenter(2, to: 0.3)
    let uniform = uneven.uniformizedColumns()
    check(almost(uniform.columnCenters.first!, base.columnCenters.first!), "列均分保留首列")
    check(almost(uniform.columnCenters.last!, base.columnCenters.last!), "列均分保留末列")

    let anchor = CGPoint(x: 0.5, y: 0.4)
    let zoomed = base.zoomed(by: 1.1, anchor: anchor)
    check(zoomed.rect.width > base.rect.width, "放大增加外框宽度")
    check(
        almost(
            zoomed.physicalAspect(imageAspect: aspect),
            base.physicalAspect(imageAspect: aspect),
            1e-5
        ),
        "缩放不改变物理宽高比"
    )

    let moved = base.moved(by: CGSize(width: 0.05, height: -0.03))
    check(
        almost(moved.center.x, 0.55) && almost(moved.center.y, 0.37, 1e-5),
        "平移更新中心"
    )

    let edge = BoardMask(
        rect: CGRect(x: 0.9, y: 0.95, width: 0.4, height: 0.3),
        rows: rows,
        cols: cols
    ).clamped()
    check(
        edge.columnCenters.allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 },
        "列中心线夹在画面内"
    )
    check(
        edge.rowCenters.allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 },
        "行中心线夹在画面内"
    )

    let detected = BoardQuad(
        topLeft: CGPoint(x: 0.1, y: 0.2),
        topRight: CGPoint(x: 0.9, y: 0.2),
        bottomRight: CGPoint(x: 0.9, y: 0.7),
        bottomLeft: CGPoint(x: 0.1, y: 0.7)
    )
    let fitted = BoardMask.fitting(detected, rows: rows, cols: cols)
    check(
        almost(fitted.center.x, 0.5) && almost(fitted.center.y, 0.45),
        "自动对齐取检测框中心"
    )
    check(
        almost(fitted.rect.width, 0.8) && almost(fitted.rect.height, 0.5),
        "自动对齐取检测框外接矩形"
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
            theme: "test",
            origin: "auto"
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
        check(summary.isAutoSampled, "快照来源为自动采样")

        let manifest = try library.loadManifest(summary)
        check(manifest.cells.count == 60, "meta 包含 60 格")
        check(manifest.origin == "auto", "meta 记录采集来源")
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

// MARK: - AutoLabel

func testAutoLabelVote() {
    print("AutoLabelVote")
    let votes: [(label: String, distance: Float)] = [
        ("连长", 0.1), ("连长", 0.2), ("排长", 0.3), ("连长", 0.15), ("连长", 0.05),
    ]
    check(AutoLabelVote.winner(votes, k: 5, minVotes: 4)?.label == "连长", "5 票中 4 票当选")
    check(AutoLabelVote.winner(votes, k: 5, minVotes: 5) == nil, "票数不足返回 nil")

    let scattered: [(label: String, distance: Float)] = [
        ("司令", 0.1), ("军长", 0.2), ("师长", 0.3), ("旅长", 0.4), ("团长", 0.5),
    ]
    check(AutoLabelVote.winner(scattered, k: 5, minVotes: 2) == nil, "没有多数时返回 nil")
    check(AutoLabelVote.winner([("空", 0.1)], k: 5, minVotes: 4) == nil, "候选少于 minVotes 返回 nil")

    let long: [(label: String, distance: Float)] = [
        ("暗子", 0.1), ("暗子", 0.2), ("暗子", 0.3), ("暗子", 0.4),
        ("明子", 0.5), ("明子", 0.6),
    ]
    check(AutoLabelVote.winner(long, k: 4, minVotes: 4)?.label == "暗子", "只统计最近 k 个候选")

    // 棋子判定：冷门棋子凑不满 4/5 票，靠「3 票 + 明显领先」放行。
    let rare: [(label: String, distance: Float)] = [
        ("司令", 0.25), ("司令", 0.37), ("司令", 0.39), ("团长", 0.65), ("团长", 0.66),
    ]
    check(AutoLabelVote.piece(rare)?.label == "司令", "3/5 票且明显领先时放行")
    check(AutoLabelVote.winner(rare, k: 5, minVotes: 4) == nil, "同样的票数在严格规则下被挡")

    let ambiguous: [(label: String, distance: Float)] = [
        ("团长", 0.27), ("团长", 0.35), ("师长", 0.35), ("师长", 0.36), ("师长", 0.37),
    ]
    check(AutoLabelVote.piece(ambiguous) == nil, "票数接近时不猜")

    // 同一张图换个格子出现：近邻距离接近 0，直接认。
    let identical: [(label: String, distance: Float)] = [
        ("军旗", 0.002), ("军长", 0.48), ("军长", 0.51), ("师长", 0.53), ("旅长", 0.60),
    ]
    check(AutoLabelVote.piece(identical)?.label == "军旗", "几乎同一张图时只看最近邻")

    let conflicting: [(label: String, distance: Float)] = [
        ("军长", 0.001), ("军旗", 0.04), ("军旗", 0.30), ("军旗", 0.32), ("军旗", 0.33),
    ]
    check(AutoLabelVote.piece(conflicting) == nil, "近邻互相打架时不填")

    // 冷门棋子只凑到 2 票，但两张图都很近、第三名明显更远。
    let rareTwo: [(label: String, distance: Float)] = [
        ("司令", 0.31), ("司令", 0.31), ("工兵", 0.62), ("工兵", 0.63), ("军长", 0.63),
    ]
    check(AutoLabelVote.piece(rareTwo)?.label == "司令", "2 票但近且领先时放行")

    // 同样 2 票，但最近邻本身就很远（0.45），不猜。
    let rareFar: [(label: String, distance: Float)] = [
        ("司令", 0.45), ("司令", 0.47), ("工兵", 0.70), ("工兵", 0.72), ("军长", 0.74),
    ]
    check(AutoLabelVote.piece(rareFar) == nil, "最近邻太远时不猜")
}

func testAutoLabelPersistence() {
    print("AutoLabelPersistence")
    var label = SnapshotCellLabel(index: 0, row: 0, col: 0)
    label.applyAuto(state: .revealed, color: .red, piece: "司令")
    check(label.auto == true, "自动标注打标记")
    check(label.isComplete, "自动标注结果是完整标签")
    label.confirm()
    check(label.auto == nil, "确认后清除自动标记")

    var labels = SnapshotLabels(rows: 1, cols: 1, snapshot: "s")
    labels.update(index: 0) {
        $0.applyAuto(state: .hidden, color: nil, piece: nil)
    }
    check(labels.autoCount == 1, "统计自动标注格数")
    labels.confirmAllAuto()
    check(labels.autoCount == 0, "全部确认后自动标记清零")
    check(labels.cells[0].state == .hidden, "全部确认保留标签内容")

    labels.update(index: 0) {
        $0.applyAuto(state: .hidden, color: nil, piece: nil)
    }
    check(labels.autoCount == 1, "重新自动标注")
    labels.clearAuto()
    check(labels.cells[0].state == .unknown, "清除自动标注退回未标")
    check(labels.autoCount == 0, "清除后计数归零")

    // 旧 labels.json 没有 auto 字段，解码不应失败。
    let legacy = """
    {"version":1,"snapshot":"old","rows":1,"cols":1,
     "updatedAt":"2026-10-26T00:00:00Z",
     "cells":[{"index":0,"row":0,"col":0,"state":"hidden"}]}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let old = try? decoder.decode(SnapshotLabels.self, from: Data(legacy.utf8)) {
        check(old.cells[0].auto == nil, "旧标签解码后 auto 为 nil")
        check(old.cells[0].state == .hidden, "旧标签状态保留")
    } else {
        check(false, "旧 labels.json 可解码")
    }
}

// MARK: - BoardChangeDetector / AutoSampleTracker

func makeFingerprint(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (UInt8, UInt8, UInt8) = { _, _ in (16, 16, 16) }
) -> BoardFingerprint {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let color = pixel(x, y)
            let offset = (y * width + x) * 4
            pixels[offset] = color.0
            pixels[offset + 1] = color.1
            pixels[offset + 2] = color.2
            pixels[offset + 3] = 255
        }
    }
    return BoardFingerprint(width: width, height: height, pixels: pixels)
}

func changingBlock(
    _ fingerprint: BoardFingerprint,
    x: Int,
    y: Int,
    size: Int,
    value: UInt8 = 255
) -> BoardFingerprint {
    var pixels = fingerprint.pixels
    for row in y..<min(fingerprint.height, y + size) {
        for col in x..<min(fingerprint.width, x + size) {
            let offset = (row * fingerprint.width + col) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
        }
    }
    return BoardFingerprint(
        width: fingerprint.width,
        height: fingerprint.height,
        pixels: pixels
    )
}

func testBoardChangeDetector() {
    print("BoardChangeDetector")
    let full = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1),
        CGPoint(x: 0, y: 1),
    ]
    let base = makeFingerprint(width: 100, height: 50)
    check(BoardChangeDetector.changedFraction(base, base, boardCorners: full) == 0, "同一画面变化为 0")

    let block = changingBlock(base, x: 10, y: 10, size: 10)
    let fraction = BoardChangeDetector.changedFraction(base, block, boardCorners: full)
    check(fraction != nil && abs(fraction! - 0.02) < 0.0001, "棋盘内 10×10 变化记为 2%")

    // 只有左半边算棋盘：右边 10×10 的变化不应计入。
    let leftHalf = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0.5, y: 0),
        CGPoint(x: 0.5, y: 1),
        CGPoint(x: 0, y: 1),
    ]
    let outsideBlock = changingBlock(base, x: 60, y: 10, size: 10)
    check(
        BoardChangeDetector.changedFraction(base, outsideBlock, boardCorners: leftHalf) == 0,
        "棋盘外变化不计入"
    )

    // 单通道差值低于阈值视为噪声。
    let tiny = changingBlock(base, x: 10, y: 10, size: 10, value: 30)
    check(
        BoardChangeDetector.changedFraction(base, tiny, boardCorners: full, pixelDelta: 20) == 0,
        "低幅度噪声不计入变化"
    )

    let resized = makeFingerprint(width: 120, height: 50)
    check(
        BoardChangeDetector.changedFraction(base, resized, boardCorners: full) == nil,
        "指纹尺寸不同返回 nil"
    )

    // 指纹方向：顶部红色必须落在数组第一行。
    let side = 16
    var raw = [UInt8](repeating: 0, count: side * side * 4)
    func setPixel(_ x: Int, _ y: Int, _ color: (UInt8, UInt8, UInt8)) {
        let offset = (y * side + x) * 4
        raw[offset] = color.0
        raw[offset + 1] = color.1
        raw[offset + 2] = color.2
        raw[offset + 3] = 255
    }
    for y in 0..<side {
        for x in 0..<side {
            let top = y < side / 2
            let left = x < side / 2
            if top && left {
                setPixel(x, y, (255, 0, 0))       // 左上：红
            } else if top {
                setPixel(x, y, (0, 255, 0))       // 右上：绿
            } else if left {
                setPixel(x, y, (0, 0, 255))       // 左下：蓝
            } else {
                setPixel(x, y, (255, 255, 255))   // 右下：白
            }
        }
    }
    if let provider = CGDataProvider(data: Data(raw) as CFData),
       let image = CGImage(
           width: side,
           height: side,
           bitsPerComponent: 8,
           bitsPerPixel: 32,
           bytesPerRow: side * 4,
           space: CGColorSpaceCreateDeviceRGB(),
           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
           provider: provider,
           decode: nil,
           shouldInterpolate: false,
           intent: .defaultIntent
       ),
       let fingerprint = BoardChangeDetector.fingerprint(image: CIImage(cgImage: image), width: side) {
        check(fingerprint.width == side && fingerprint.height == side, "指纹尺寸保持宽高比")
        check(
            fingerprint.pixels[0] > 200
                && fingerprint.pixels[1] < 60
                && fingerprint.pixels[2] < 60,
            "指纹第一行对应图像顶部"
        )
        let bottomOffset = (side - 1) * side * 4
        check(
            fingerprint.pixels[bottomOffset] < 60
                && fingerprint.pixels[bottomOffset + 2] > 200,
            "指纹最后一行对应图像底部"
        )
    } else {
        check(false, "构造方向测试图")
    }
}

// MARK: - 逐格变化（自动采样判定）

/// 测试棋盘：12 列 × 5 行，probe 240×120，每格 20×24 像素。
let testCols = 12
let testRows = 5
let testProbeWidth = 240
let testProbeHeight = 120

func makeTestCellBoxes() -> [BoardCellBox] {
    let rects = (0..<testRows).flatMap { row in
        (0..<testCols).map { col in
            CGRect(
                x: CGFloat(col) / CGFloat(testCols),
                y: CGFloat(row) / CGFloat(testRows),
                width: 1 / CGFloat(testCols),
                height: 1 / CGFloat(testRows)
            )
        }
    }
    return BoardCellBox.grid(
        rows: testRows,
        cols: testCols,
        rects: rects,
        probeWidth: testProbeWidth,
        probeHeight: testProbeHeight
    )
}

func testCell(_ boxes: [BoardCellBox], row: Int, col: Int) -> BoardCellBox? {
    boxes.first { $0.row == row && $0.col == col }
}

func testDelta(_ deltas: [BoardCellDelta], row: Int, col: Int) -> BoardCellDelta? {
    deltas.first { $0.row == row && $0.col == col }
}

/// 整格涂色：模拟翻棋/走子后整格换面。
func fillingCell(
    _ fingerprint: BoardFingerprint,
    box: BoardCellBox,
    value: UInt8 = 200
) -> BoardFingerprint {
    var pixels = fingerprint.pixels
    let width = fingerprint.width
    for y in box.y0..<box.y1 {
        for x in box.x0..<box.x1 {
            let offset = (y * width + x) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
        }
    }
    return BoardFingerprint(
        width: fingerprint.width,
        height: fingerprint.height,
        pixels: pixels
    )
}

/// 只涂最外圈：模拟选中框/高光闪烁（占格约三成面积，颜色变化很小）。
func outliningCell(
    _ fingerprint: BoardFingerprint,
    box: BoardCellBox,
    thickness: Int,
    value: UInt8 = 60
) -> BoardFingerprint {
    var pixels = fingerprint.pixels
    let width = fingerprint.width
    for y in box.y0..<box.y1 {
        for x in box.x0..<box.x1 {
            let isBorder = x < box.x0 + thickness || x >= box.x1 - thickness
                || y < box.y0 + thickness || y >= box.y1 - thickness
            guard isBorder else { continue }
            let offset = (y * width + x) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
        }
    }
    return BoardFingerprint(
        width: fingerprint.width,
        height: fingerprint.height,
        pixels: pixels
    )
}

/// 涂格子顶部 `fraction` 比例：模拟走法箭头/落点提示（只占格内一部分，但对比强）。
func paintingBand(
    _ fingerprint: BoardFingerprint,
    box: BoardCellBox,
    fraction: Double,
    value: UInt8 = 220
) -> BoardFingerprint {
    var pixels = fingerprint.pixels
    let width = fingerprint.width
    let height = box.y1 - box.y0
    let rows = min(height, max(1, Int((Double(height) * fraction).rounded())))
    for y in box.y0..<(box.y0 + rows) {
        for x in box.x0..<box.x1 {
            let offset = (y * width + x) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
        }
    }
    return BoardFingerprint(
        width: fingerprint.width,
        height: fingerprint.height,
        pixels: pixels
    )
}

func testBoardCellDeltas() {
    print("BoardCellDeltas")
    let base = makeFingerprint(width: testProbeWidth, height: testProbeHeight)
    let boxes = makeTestCellBoxes()
    check(boxes.count == testRows * testCols, "生成 60 个格子")

    let empty = BoardChangeDetector.cellDeltas(base, base, boxes: boxes)
    check(
        empty.allSatisfy { $0.fraction == 0 && $0.meanDelta == 0 },
        "同图逐格无变化"
    )

    // 整格换面（翻棋/走子落点）：占比 100%、平均差大。
    guard let revealedCell = testCell(boxes, row: 2, col: 3) else {
        check(false, "取到 (2,3) 格")
        return
    }
    let revealed = fillingCell(base, box: revealedCell)
    let revealedDeltas = BoardChangeDetector.cellDeltas(base, revealed, boxes: boxes)
    if let delta = testDelta(revealedDeltas, row: 2, col: 3) {
        check(delta.fraction > 0.99, "整格变化占比 ≈100%")
        check(delta.meanDelta > 150, "整格变化平均差很大")
        check(
            delta.isPieceChange(minFraction: 0.55, minMeanDelta: 25),
            "整格变化判为棋子变化"
        )
    } else {
        check(false, "取到整格变化统计")
    }
    check(
        revealedDeltas.filter { $0.fraction > 0.5 }.count == 1,
        "只有被涂的那一格发生整格变化"
    )

    // 选中框闪烁：只覆盖格内三成面积、平均差很小。
    guard let selectedCell = testCell(boxes, row: 4, col: 8) else {
        check(false, "取到 (4,8) 格")
        return
    }
    let ringed = outliningCell(base, box: selectedCell, thickness: 2)
    let ringDeltas = BoardChangeDetector.cellDeltas(base, ringed, boxes: boxes)
    if let delta = testDelta(ringDeltas, row: 4, col: 8) {
        check(delta.fraction < 0.4, "选中框只覆盖格内一小部分")
        check(delta.meanDelta < 25, "选中框平均差很小")
        check(
            !delta.isPieceChange(minFraction: 0.55, minMeanDelta: 25),
            "选中框不算棋子变化"
        )
    } else {
        check(false, "取到闪烁格统计")
    }

    // 走法箭头：三成面积、对比很强 —— 占比这一关必须挡住它。
    guard let hintedCell = testCell(boxes, row: 1, col: 1) else {
        check(false, "取到 (1,1) 格")
        return
    }
    let hinted = paintingBand(base, box: hintedCell, fraction: 1.0 / 3.0)
    let hintedDeltas = BoardChangeDetector.cellDeltas(base, hinted, boxes: boxes)
    if let delta = testDelta(hintedDeltas, row: 1, col: 1) {
        check(delta.fraction > 0.25 && delta.fraction < 0.45, "箭头只覆盖约三分之一格")
        check(delta.meanDelta > 50, "箭头颜色对比很强")
        check(
            !delta.isPieceChange(minFraction: 0.55, minMeanDelta: 25),
            "走法箭头不算棋子变化"
        )
    } else {
        check(false, "取到箭头格统计")
    }
}

func testAutoSampleTracker() {
    print("BoardAutoSampleTracker")
    let corners = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1),
        CGPoint(x: 0, y: 1),
    ]
    let base = makeFingerprint(width: testProbeWidth, height: testProbeHeight)
    let boxes = makeTestCellBoxes()
    guard let sourceCell = testCell(boxes, row: 1, col: 3),
          let destinationCell = testCell(boxes, row: 3, col: 3),
          let thirdCell = testCell(boxes, row: 0, col: 0)
    else {
        check(false, "取到测试格")
        return
    }

    let moved = fillingCell(base, box: destinationCell)
    let movedAgain = fillingCell(moved, box: sourceCell, value: 220)
    let movedThird = fillingCell(movedAgain, box: thirdCell, value: 180)

    var config = BoardAutoSamplerConfig()
    config.settleDuration = 0.9
    config.cooldown = 0.8
    config.maxPerGame = 2
    var tracker = BoardAutoSampleTracker(config: config)

    func observe(_ probe: BoardFingerprint, _ time: TimeInterval) -> BoardAutoSampleTracker.Action {
        tracker.observe(probe, cellBoxes: boxes, boardCorners: corners, at: time)
    }

    check(observe(base, 0) == .waiting, "首帧建立基线")
    check(observe(base, 0.3) == .settling, "进入对局后先等静置")
    check(observe(base, 1.0) == .unchanged, "静置后没有变化不采样")

    // 选中框以约 2Hz 开关：整盘漂移约 0.5%，不能重置静置计时。
    let blinkOn = outliningCell(base, box: sourceCell, thickness: 2)
    check(observe(blinkOn, 1.2) == .unchanged, "闪烁不重置静置计时")
    check(
        observe(blinkOn, 1.95) == .unchanged,
        "选中框闪烁不影响静置判定"
    )
    check(
        observe(base, 2.1) == .unchanged,
        "闪烁回落也不触发采样"
    )

    // 真走棋：落点整格换面 → 静置 + 连续两次一致后采样。
    check(observe(moved, 2.2) == .settling, "检测到走棋，重新计时")
    check(observe(moved, 2.6) == .settling, "静置时间不足不采样")
    check(observe(moved, 3.2) == .settling, "静置后先记下变化签名")
    if case .capture(let change) = observe(moved, 3.45) {
        check(true, "连续两次一致后才采样")
        check(change.changedCells == 1, "记录变化格数")
        check(change.maxCellFraction > 0.9, "记录最大单格变化占比")
    } else {
        check(false, "连续两次一致后才采样")
    }
    tracker.recordCapture(moved, at: 3.45)
    check(tracker.gameCaptureCount == 1, "采样计数 +1")

    // 采样后落点棋子继续闪选中框：不能重复采样。
    let blinkAfter = outliningCell(moved, box: destinationCell, thickness: 2)
    check(observe(blinkAfter, 3.6) == .settling, "采样后闪烁进入静置")
    check(observe(blinkAfter, 4.4) == .unchanged, "落点闪烁不重复采样")

    // 下一次真走棋。
    check(observe(movedAgain, 4.5) == .settling, "第二处变化进入静置")
    check(observe(movedAgain, 5.5) == .settling, "第二处变化先记签名")
    if case .capture = observe(movedAgain, 5.75) {
        check(true, "冷却结束后的下一次变化继续采样")
    } else {
        check(false, "冷却结束后的下一次变化继续采样")
    }
    tracker.recordCapture(movedAgain, at: 5.75)

    check(observe(movedThird, 5.9) == .settling, "第三处变化进入静置")
    check(observe(movedThird, 6.9) == .limitReached, "达到单局上限后停止采样")

    tracker.beginGame()
    check(tracker.gameCaptureCount == 0, "新一局重置计数")
    check(observe(base, 10) == .waiting, "新一局重新建立基线")

    // 冷却期内的变化先返回 unchanged，冷却结束后同一局面可补采。
    var slow = BoardAutoSamplerConfig()
    slow.cooldown = 5
    slow.settleDuration = 0.5
    slow.maxPerGame = 10
    var cooled = BoardAutoSampleTracker(config: slow)
    func cooledObserve(
        _ probe: BoardFingerprint,
        _ time: TimeInterval
    ) -> BoardAutoSampleTracker.Action {
        cooled.observe(probe, cellBoxes: boxes, boardCorners: corners, at: time)
    }
    _ = cooledObserve(base, 0)
    _ = cooledObserve(moved, 0.1)
    _ = cooledObserve(moved, 0.7)
    if case .capture = cooledObserve(moved, 0.8) {
        check(true, "首次采样")
    } else {
        check(false, "首次采样")
    }
    cooled.recordCapture(moved, at: 0.8)
    _ = cooledObserve(movedAgain, 0.9)
    check(
        cooledObserve(movedAgain, 1.6) == .unchanged,
        "冷却期内不重复采样"
    )
    _ = cooledObserve(movedAgain, 5.8)
    if case .capture = cooledObserve(movedAgain, 5.9) {
        check(true, "冷却结束后补采同一局面")
    } else {
        check(false, "冷却结束后补采同一局面")
    }

    // 翻棋动画：第一次轮询只看到 50% 的变化，下一次才长到 58%。
    // 占比在变但格集合不变，应该由第二次轮询确认后拍照。
    let halfFlipped = paintingBand(base, box: destinationCell, fraction: 0.5)
    let flipped = paintingBand(base, box: destinationCell, fraction: 0.58)
    var flipConfig = BoardAutoSamplerConfig()
    flipConfig.settleDuration = 0.5
    flipConfig.cooldown = 0
    var flip = BoardAutoSampleTracker(config: flipConfig)
    func flipObserve(
        _ probe: BoardFingerprint,
        _ time: TimeInterval
    ) -> BoardAutoSampleTracker.Action {
        flip.observe(probe, cellBoxes: boxes, boardCorners: corners, at: time)
    }
    _ = flipObserve(base, 0)
    _ = flipObserve(base, 0.6)
    check(flipObserve(halfFlipped, 0.7) == .settling, "第一次看到变化先记下格")
    if case .capture = flipObserve(flipped, 0.8) {
        check(true, "同一格下一次仍在变化就拍照")
    } else {
        check(false, "同一格下一次仍在变化就拍照")
    }

    // 一次性动画（出现又消失）不该采样。
    var transient = BoardAutoSampleTracker(config: flipConfig)
    func transientObserve(
        _ probe: BoardFingerprint,
        _ time: TimeInterval
    ) -> BoardAutoSampleTracker.Action {
        transient.observe(probe, cellBoxes: boxes, boardCorners: corners, at: time)
    }
    _ = transientObserve(base, 0)
    _ = transientObserve(base, 0.6)
    if case .capture = transientObserve(moved, 0.7) {
        check(false, "瞬时变化第一次不拍照")
    } else {
        check(true, "瞬时变化第一次不拍照")
    }
    check(transientObserve(base, 0.8) == .settling, "变化消失后重新静置")
    check(transientObserve(base, 1.4) == .unchanged, "确认没有变化后不拍照")
}

// MARK: - PieceCatalog

func testPieceCatalog() {
    print("PieceCatalog")
    let expected = [
        "commander": "司令",
        "army_commander": "军长",
        "division_commander": "师长",
        "brigade_commander": "旅长",
        "regiment_commander": "团长",
        "battalion_commander": "营长",
        "company_commander": "连长",
        "platoon_commander": "排长",
        "engineer": "工兵",
        "mine": "地雷",
        "bomb": "炸弹",
        "flag": "军旗",
    ]
    check(PieceCatalog.all.count == 12, "12 类棋子")
    check(PieceCatalog.classifierIDs == expected, "分类器 ID 与训练端 PIECE_IDS 一致")
    check(
        Set(PieceCatalog.classifierIDs.values) == Set(PieceCatalog.all),
        "分类器 ID 覆盖全部棋子"
    )
    check(PieceCatalog.name(forClassifierID: "unknown") == nil, "未知 ID 返回 nil")
}

// MARK: - BoardPieceClassifier

func testPieceClassifierMapping() {
    print("BoardPieceClassifier")
    let threshold = 0.55

    var cell = BoardPieceClassifier.observation(
        stateLabel: "empty", stateConfidence: 0.99, minConfidence: threshold
    )
    check(cell.state == .empty, "empty 标签映射为空")
    check(cell.color == nil && cell.piece == nil, "空格不带颜色/棋子")

    cell = BoardPieceClassifier.observation(
        stateLabel: "hidden", stateConfidence: 0.8, minConfidence: threshold
    )
    check(cell.state == .hidden, "hidden 标签映射为暗子")

    cell = BoardPieceClassifier.observation(
        stateLabel: "revealed", stateConfidence: 0.9,
        colorLabel: "red", colorConfidence: 0.95,
        pieceLabel: "commander", pieceConfidence: 0.88,
        minConfidence: threshold
    )
    check(cell.state == .revealed, "三模型齐全映射为明子")
    check(cell.color == .red, "颜色标签映射为红方")
    check(cell.piece == "司令", "军衔 ID 映射为中文名")
    check(abs(cell.confidence - 0.88) < 1e-9, "明子置信度取三模型最小")
    check(cell.isActionable, "完整明子可行动")

    cell = BoardPieceClassifier.observation(
        stateLabel: "revealed", stateConfidence: 0.9,
        colorLabel: "red", colorConfidence: 0.3,
        pieceLabel: "commander", pieceConfidence: 0.95,
        minConfidence: threshold
    )
    check(cell.state == .unknown, "颜色置信度不足降级 unknown")

    cell = BoardPieceClassifier.observation(
        stateLabel: "revealed", stateConfidence: 0.9,
        colorLabel: "blue", colorConfidence: 0.95,
        pieceLabel: "commander", pieceConfidence: 0.95,
        minConfidence: threshold
    )
    check(cell.state == .unknown, "未知颜色标签降级 unknown")

    cell = BoardPieceClassifier.observation(
        stateLabel: "revealed", stateConfidence: 0.9,
        colorLabel: "black", colorConfidence: 0.9,
        pieceLabel: "unknown_piece", pieceConfidence: 0.9,
        minConfidence: threshold
    )
    check(cell.state == .unknown, "未知军衔 ID 降级 unknown")

    cell = BoardPieceClassifier.observation(
        stateLabel: "empty", stateConfidence: 0.4, minConfidence: threshold
    )
    check(cell.state == .unknown, "低置信度状态降级 unknown")

    cell = BoardPieceClassifier.observation(
        stateLabel: "weird", stateConfidence: 0.99, minConfidence: threshold
    )
    check(cell.state == .unknown, "未知状态标签降级 unknown")
}

// MARK: - BoardStateBuilder / GameState

private func stabilized(
    _ cells: [CellObservation],
    rows: Int = 2,
    cols: Int = 2,
    settling: Bool = false
) -> StabilizedBoard {
    StabilizedBoard(
        rows: rows,
        cols: cols,
        cells: cells,
        changedCells: 0,
        isSettling: settling,
        updatedAt: 0
    )
}

func testGameStateEncoding() {
    print("GameState · 序列化")
    var builder = BoardStateBuilder(config: BoardStateBuilderConfig(myColor: .red))
    let cells: [CellObservation] = [
        .revealed(.red, "司令", confidence: 0.98),
        .hidden(),
        .empty(),
        .revealed(.black, "军长", confidence: 0.9),
    ]
    let state = builder.build(
        board: stabilized(cells),
        timers: BoardTimerReading(me: 19, opponent: nil, turn: .me)
    )

    check(state.schema == 1, "schema 固定为 1")
    check(state.phase == .playing, "默认 playing")
    check(state.turn == .red, "我方执红时轮次为 red")
    check(state.legalActions == [0, 1], "未选中：暗格 + 我方明子")
    check(state.board.cells[0].piece == "commander", "棋子序列化为分类器 ID")
    check(state.board.cells[0].color == .red, "明子保留颜色")
    check(state.board.cells[1].piece == nil && state.board.cells[1].color == nil, "暗子不带棋子")
    check(state.board.cells[2].state == .empty, "空格状态")
    check(state.timers?.me == 19, "写入我方倒计时")

    let json = state.jsonString() ?? ""
    check(json.contains("\"legal_actions\":[0,1]"), "JSON 使用 legal_actions 下划线键")
    check(json.contains("\"schema\":1"), "JSON 含 schema")
    check(!json.contains("last_move"), "无移动时不写 last_move")
    check(state.jsonData() != nil, "可编码为 JSON Data")
}

func testTurnResolution() {
    print("BoardStateBuilder · 轮次")
    var builder = BoardStateBuilder(config: BoardStateBuilderConfig(myColor: .red))
    var state = builder.build(
        board: stabilized([.hidden(), .hidden(), .hidden(), .hidden()]),
        timers: BoardTimerReading(me: nil, opponent: 19, turn: .opponent)
    )
    check(state.turn == .black, "对方回合 → 黑方")

    state = builder.build(board: stabilized([.hidden(), .hidden(), .hidden(), .hidden()]))
    check(state.turn == .black, "证据缺失时保持上一次轮次")

    let hit = OCRText(text: "我方走棋", rect: .zero, confidence: 1)
    check(
        BoardTurnReader.turnSignal(hits: [hit], me: nil, opponent: 19) == .me,
        "文案优先于计时器推断"
    )
    check(
        BoardTurnReader.turnSignal(hits: [], me: 19, opponent: nil) == .me,
        "只有我方计时 → 我方回合"
    )
    check(
        BoardTurnReader.turnSignal(hits: [], me: nil, opponent: 19) == .opponent,
        "只有对方计时 → 对方回合"
    )
    check(
        BoardTurnReader.turnSignal(hits: [], me: nil, opponent: nil) == .unknown,
        "两边都没读到 → unknown"
    )

    let me = BoardTurnReader.turnSignal(hits: [], me: 19, opponent: 18)
    check(me == .unknown, "两边都有计时 → 无法判定")
}

func testTimerParsing() {
    print("BoardTurnReader · 倒计时解析")
    check(BoardTurnReader.parseSeconds(from: ["19"]) == 19, "纯数字")
    check(BoardTurnReader.parseSeconds(from: ["19秒"]) == 19, "数字带单位")
    check(BoardTurnReader.parseSeconds(from: ["abc"]) == nil, "无数值返回 nil")
    check(BoardTurnReader.parseSeconds(from: ["361"]) == nil, "超出上限视为误读")
    check(BoardTurnReader.parseSeconds(from: ["", "x", "12"]) == 12, "跳过无效候选")
}

func testLegalActions() {
    print("BoardStateBuilder · legal_actions")
    let cells: [CellObservation] = [
        .revealed(.red, "司令", confidence: 0.98),
        .hidden(),
        .empty(),
        .revealed(.black, "军长", confidence: 0.9),
    ]
    var builder = BoardStateBuilder(config: BoardStateBuilderConfig(myColor: .red))

    var state = builder.build(board: stabilized(cells), selected: 0)
    check(state.legalActions == [2], "选中我方明子：相邻空格可进入，暗格不可作为移动目标")

    state = builder.build(board: stabilized(cells), selected: 3)
    check(state.legalActions == [0, 1], "选中敌方棋子无效，退回选子集合")

    state = builder.build(board: stabilized(cells, settling: true), selected: 0)
    check(state.legalActions.isEmpty, "冻结期不给可行动作")

    state = builder.build(board: stabilized(cells), phase: .result, selected: 0)
    check(state.legalActions.isEmpty, "结算页不给可行动作")

    check(
        BoardStateBuilder.neighbors(row: 0, col: 0, rows: 5, cols: 12) == [12, 1],
        "5×12 左上角四邻"
    )
    check(
        BoardStateBuilder.neighbors(row: 2, col: 5, rows: 5, cols: 12) == [17, 41, 28, 30],
        "5×12 中部四邻顺序为上/下/左/右"
    )
}

func testLastMoveInference() {
    print("BoardStateBuilder · last_move")
    var builder = BoardStateBuilder(config: BoardStateBuilderConfig(myColor: .red))
    let before: [CellObservation] = [
        .revealed(.red, "司令", confidence: 0.98),
        .empty(),
        .hidden(),
        .hidden(),
    ]
    _ = builder.build(board: stabilized(before))
    check(builder.build(board: stabilized(before), selected: nil).lastMove == nil, "首帧无移动")

    let after: [CellObservation] = [
        .empty(),
        .revealed(.red, "司令", confidence: 0.98),
        .hidden(),
        .hidden(),
    ]
    let moved = builder.build(board: stabilized(after))
    check(moved.lastMove == GameMove(from: 0, to: 1), "两格变化且棋子一致 → from 0 to 1")

    let flipped: [CellObservation] = [
        .empty(),
        .revealed(.red, "司令", confidence: 0.98),
        .revealed(.black, "连长", confidence: 0.9),
        .hidden(),
    ]
    let flipState = builder.build(board: stabilized(flipped))
    check(flipState.lastMove == GameMove(from: 0, to: 1), "翻牌不改写 last_move")

    check(
        BoardStateBuilder.inferMove(
            from: before,
            to: after,
            changed: [0]
        ) == nil,
        "只有一格变化不算移动"
    )
}

// MARK: - BoardTap

func testTapGeometry() {
    print("BoardTapGeometry · 坐标换算")
    let quad = BoardQuad(
        corners: [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
        ]
    )!
    let grid = BoardGrid(quad: quad, rows: 5, cols: 12)!
    // 5×12 均分：格心 x = (1/24)、(1/24 + 1/12)…；格心 y = 1/10…
    let first = BoardTapGeometry.contentCenter(of: 0, grid: grid)!
    check(abs(first.x - 1.0 / 24) < 1e-9, "首列格心 u")
    check(abs(first.y - 0.1) < 1e-9, "首行格心 v")
    check(BoardTapGeometry.contentCenter(of: -1, grid: grid) == nil, "负索引返回 nil")
    check(BoardTapGeometry.contentCenter(of: 60, grid: grid) == nil, "越界索引返回 nil")

    // 内容区在窗口内留上下黑边：y 0.1..0.9。
    let contentRect = CGRect(x: 0, y: 0.1, width: 1, height: 0.8)
    let point = BoardTapGeometry.windowPoint(content: CGPoint(x: 0.5, y: 0.5), contentRect: contentRect)
    check(abs(point.x - 0.5) < 1e-9, "内容 x 直接映射到窗口 x")
    check(abs(point.y - 0.5) < 1e-9, "内容 y 经过黑边偏移")

    let viaCell = BoardTapGeometry.windowPoint(of: 0, grid: grid, contentRect: contentRect)!
    check(abs(viaCell.x - 1.0 / 24) < 1e-9, "格心换算 x 与内容坐标一致")
    check(abs(viaCell.y - (0.1 + 0.1 * 0.8)) < 1e-9, "格心换算 y 叠加黑边")
    check(BoardTapGeometry.windowPoint(of: 60, grid: grid, contentRect: contentRect) == nil, "越界格无落点")

    check(BoardTapGeometry.isTappable(CGPoint(x: 0.5, y: 0.5)), "窗口内可点击")
    check(!BoardTapGeometry.isTappable(CGPoint(x: 1.2, y: 0.5)), "窗口外拒绝")
}

func testTapPrecheck() {
    print("BoardTapVerifier · 拒绝条件")
    let cells: [CellObservation] = [
        .revealed(.red, "司令", confidence: 0.98),
        .hidden(),
        .empty(),
        .revealed(.black, "军长", confidence: 0.9),
    ]
    let board = stabilized(cells)
    func refusal(
        _ action: BoardTapAction,
        turn: PieceColor = .red,
        legal: [Int] = [1, 2],
        phase: GamePhase = .playing,
        settling: Bool = false
    ) -> BoardTapRefusal? {
        BoardTapVerifier.refusal(
            for: action,
            board: settling ? stabilized(cells, settling: true) : board,
            turn: turn,
            myColor: .red,
            legalActions: legal,
            phase: phase,
            minPieceConfidence: 0.55
        )
    }

    check(refusal(.flip(cell: 1)) == nil, "翻暗子可点击")
    check(refusal(.flip(cell: 0)) == .cellNotHidden(0), "翻明子被拒")
    check(refusal(.flip(cell: 9)) == .indexOutOfRange(9), "越界被拒")
    check(refusal(.move(from: 0, to: 2)) == nil, "我方子移到空格可点击")
    check(refusal(.move(from: 3, to: 1)) == .sourceNotOwnPiece(3), "敌方子不可移动")
    check(refusal(.move(from: 0, to: 1), legal: [1]) == nil, "目标在可走集合内")
    check(refusal(.move(from: 0, to: 1), legal: [2]) == .destinationNotLegal(1), "目标不在可走集合")
    check(refusal(.move(from: 0, to: 0), legal: [0]) == .destinationNotLegal(0), "原地移动被拒")
    check(refusal(.flip(cell: 1), turn: .black) == .notMyTurn, "对方回合不点")
    check(refusal(.flip(cell: 1), phase: .result) == .phaseNotPlaying, "结算页不点")
    check(refusal(.flip(cell: 1), settling: true) == .settling, "冻结期不点")
}

func testTapVerification() {
    print("BoardTapVerifier · 结果判定")
    let beforeFlip: [CellObservation] = [.hidden(), .empty(), .hidden(), .hidden()]
    let afterFlip: [CellObservation] = [
        .revealed(.red, "司令", confidence: 0.9), .empty(), .hidden(), .hidden(),
    ]
    check(
        BoardTapVerifier.isSatisfied(.flip(cell: 0), before: beforeFlip, after: afterFlip),
        "暗子翻成明子即验证通过"
    )
    check(
        !BoardTapVerifier.isSatisfied(.flip(cell: 0), before: beforeFlip, after: beforeFlip),
        "仍为暗子不通过"
    )
    let afterBadFlip: [CellObservation] = [
        .empty(), .empty(), .hidden(), .hidden(),
    ]
    check(
        !BoardTapVerifier.isSatisfied(.flip(cell: 0), before: beforeFlip, after: afterBadFlip),
        "翻成空格不当作成功"
    )
    let afterNoPiece: [CellObservation] = [
        .unknown(confidence: 0.3), .empty(), .hidden(), .hidden(),
    ]
    check(
        !BoardTapVerifier.isSatisfied(.flip(cell: 0), before: beforeFlip, after: afterNoPiece),
        "分类不可用不当作成功"
    )

    let beforeMove: [CellObservation] = [
        .revealed(.red, "司令", confidence: 0.98), .empty(),
        .hidden(), .hidden(),
    ]
    let afterMove: [CellObservation] = [
        .empty(), .revealed(.red, "司令", confidence: 0.95),
        .hidden(), .hidden(),
    ]
    check(
        BoardTapVerifier.isSatisfied(.move(from: 0, to: 1), before: beforeMove, after: afterMove),
        "源格变空 + 目标格出现同棋子即验证通过"
    )
    check(
        BoardTapVerifier.changedCount(before: beforeMove, after: afterMove) == 2,
        "移动涉及两格变化"
    )
    check(
        BoardTapVerifier.mismatch(.flip(cell: 0), before: beforeFlip, after: beforeFlip)
            .contains("仍是暗子"),
        "翻牌超时说明仍为暗子"
    )

    let afterWrongPiece: [CellObservation] = [
        .empty(), .revealed(.black, "连长", confidence: 0.9),
        .hidden(), .hidden(),
    ]
    check(
        !BoardTapVerifier.isSatisfied(.move(from: 0, to: 1), before: beforeMove, after: afterWrongPiece),
        "目标格棋子不一致不通过"
    )
    check(
        BoardTapVerifier.mismatch(.move(from: 0, to: 1), before: beforeMove, after: afterWrongPiece)
            .contains("不一致"),
        "说明目标格棋子不一致"
    )
    check(
        BoardTapVerifier.mismatch(.move(from: 0, to: 1), before: beforeMove, after: beforeMove)
            .contains("源格"),
        "说明源格未变空"
    )
}

// MARK: - ScreenState / 屏幕状态融合

func testScreenStateLabels() {
    print("ScreenState · 七分类标签")
    check(
        ScreenState.allCases.map(\.rawValue) == [
            "main", "modeLobby", "matching", "board", "result", "popup", "unknown",
        ],
        "七分类顺序与训练目录一致"
    )
    check(ScreenState.main.label == "主菜单", "main 显示为主菜单")
    check(ScreenState.modeLobby.label == "场次选择", "modeLobby 显示为场次选择")
    check(ScreenState.matching.label == "匹配中", "matching 显示为匹配中")
    check(ScreenState.board.label == "牌局", "board 显示为牌局")
    check(ScreenState.result.label == "结算页", "result 显示为结算页")
    check(ScreenState.popup.label == "弹窗", "popup 显示为弹窗")
    check(ScreenState.unknown.label == "未识别", "unknown 显示为未识别")

    check(ScreenState(classifierLabel: "board") == .board, "模型标签 board 映射正确")
    check(ScreenState(classifierLabel: "venue") == .modeLobby, "兼容旧 venue 标签")
    check(ScreenState(classifierLabel: "nope") == nil, "未知标签返回 nil")
}

func testScreenStateFusion() {
    print("ScreenStateFusion · 模型/OCR 融合")

    // 无模型 / 低置信度：OCR 兜底。
    var resolved = ScreenStateFusion.resolve(
        modelLabel: nil, confidence: 0, ocrState: .board
    )
    check(resolved.state == .board && resolved.source == .ocr, "无预测时用 OCR 结果")

    resolved = ScreenStateFusion.resolve(
        modelLabel: nil, confidence: 0, ocrState: .unknown
    )
    check(
        resolved.state == .unknown && resolved.source == .none,
        "模型和 OCR 都认不出时为 unknown/—"
    )

    resolved = ScreenStateFusion.resolve(
        modelLabel: "board", confidence: 0.59, ocrState: .main
    )
    check(resolved.state == .main && resolved.source == .ocr, "置信度低于 0.60 时退回 OCR")

    resolved = ScreenStateFusion.resolve(
        modelLabel: "board", confidence: 0.60, ocrState: .main
    )
    check(resolved.state == .board && resolved.source == .model, "置信度 0.60 达到阈值")

    // 模型高置信：模型为主。
    resolved = ScreenStateFusion.resolve(
        modelLabel: "board", confidence: 0.9, ocrState: .unknown
    )
    check(resolved.state == .board && resolved.source == .model, "模型高置信时采用模型")
    check(ScreenStateFusion.Source.model.rawValue == "模型", "来源显示为模型")
    check(ScreenStateFusion.Source.none.rawValue == "—", "无来源显示为 —")

    // 退出确认弹窗：OCR 必须能覆盖模型误判。
    resolved = ScreenStateFusion.resolve(
        modelLabel: "matching", confidence: 0.95, ocrState: .popup
    )
    check(
        resolved.state == .popup && resolved.source == .ocr,
        "模型误判 matching 时 OCR 弹窗优先"
    )

    resolved = ScreenStateFusion.resolve(
        modelLabel: "popup", confidence: 0.9, ocrState: .popup
    )
    check(resolved.state == .popup && resolved.source == .model, "模型也判弹窗时保留模型来源")

    // 模型 unknown + OCR 命中：以 OCR 为准。
    resolved = ScreenStateFusion.resolve(
        modelLabel: "unknown", confidence: 0.9, ocrState: .result
    )
    check(
        resolved.state == .result && resolved.source == .ocr,
        "模型 unknown 且 OCR 命中时采用 OCR"
    )

    resolved = ScreenStateFusion.resolve(
        modelLabel: "unknown", confidence: 0.9, ocrState: .unknown
    )
    check(
        resolved.state == .unknown && resolved.source == .model,
        "两边都是 unknown 时保留模型来源"
    )

    // 旧标签 / 脏标签。
    resolved = ScreenStateFusion.resolve(
        modelLabel: "venue", confidence: 0.9, ocrState: .unknown
    )
    check(
        resolved.state == .modeLobby && resolved.source == .model,
        "旧 venue 标签仍映射到场次选择"
    )

    resolved = ScreenStateFusion.resolve(
        modelLabel: "garbage", confidence: 0.9, ocrState: .main
    )
    check(resolved.state == .main && resolved.source == .ocr, "无法解析的模型标签退回 OCR")
}

// MARK: - PopupResolver / 弹窗模板（M1-8）

func popupHits(_ texts: [String]) -> [OCRText] {
    texts.enumerated().map { index, text in
        OCRText(
            text: text,
            rect: CGRect(
                x: 0.1,
                y: 0.1 + CGFloat(index) * 0.05,
                width: 0.3,
                height: 0.04
            ),
            confidence: 0.9
        )
    }
}

func testPopupResolver() {
    print("PopupResolver · 已知弹窗模板")

    // 退出确认：只能取消，绝不能点确定。
    var resolution = PopupResolver.resolve(hits: popupHits([
        "现在退出将被判负，并扣除双倍", "入场费，您确定要退出吗？", "取消", "确定",
    ]))
    guard case .known(let exitKind, let exitAction, let exitMatched) = resolution else {
        check(false, "退出确认应命中 exitConfirm")
        return
    }
    check(exitKind == .exitConfirm, "退出确认命中 exitConfirm")
    check(exitAction == .close(.keyword("取消")), "退出确认只点取消")
    check(exitAction != .close(.keyword("确定")), "退出确认绝不点确定")
    check(exitMatched.contains("现在退出将被判负"), "记录退出确认强特征")

    // 没有「取消」时暂停，不能退化成点「确定」。
    resolution = PopupResolver.resolve(hits: popupHits([
        "现在退出将被判负", "确定",
    ]))
    guard case .known(.exitConfirm, .pause(let exitReason), _) = resolution else {
        check(false, "退出确认缺少取消时应暂停")
        return
    }
    check(exitReason.contains("关闭按钮"), "退出确认缺取消时说明原因")

    // 签到弹层：即使含「看广告」，也按签到模板处理并点右上角 X。
    resolution = PopupResolver.resolve(hits: popupHits([
        "登录奖励", "本月累计签到4天", "领取奖励", "看广告额外奖励300金币",
    ]))
    guard case .known(.signIn, .close(.anchor(let signInAnchor)), _) = resolution else {
        check(false, "签到弹层应命中 signIn 并使用锚点")
        return
    }
    check(signInAnchor == PopupAnchor.signInClose.rawValue, "签到弹层使用 signInClose")
    check(signInAnchor != PopupAnchor.genericClose.rawValue, "签到弹层不退化为通用锚点")

    // 任务弹层。
    resolution = PopupResolver.resolve(hits: popupHits([
        "每日任务", "成长任务", "去完成",
    ]))
    guard case .known(.task, .close(.anchor(let taskAnchor)), _) = resolution else {
        check(false, "任务弹层应命中 task")
        return
    }
    check(taskAnchor == PopupAnchor.taskClose.rawValue, "任务弹层使用 taskClose")

    // 个人信息弹层。
    resolution = PopupResolver.resolve(hits: popupHits([
        "个人信息", "游戏ID：1143138803", "四国胜率：0%",
    ]))
    guard case .known(.profile, .close(.anchor(let profileAnchor)), _) = resolution else {
        check(false, "个人信息弹层应命中 profile")
        return
    }
    check(profileAnchor == PopupAnchor.profileClose.rawValue, "个人信息弹层使用 profileClose")

    // 规则弹窗优先点 OCR 关闭字样；没有关闭字样则暂停。
    resolution = PopupResolver.resolve(hits: popupHits([
        "游戏规则", "吃子规则", "关闭",
    ]))
    guard case .known(.rules, .close(.keyword(let ruleClose)), _) = resolution else {
        check(false, "规则弹窗应点关闭")
        return
    }
    check(ruleClose == "关闭", "规则弹窗命中关闭文字")

    resolution = PopupResolver.resolve(hits: popupHits([
        "游戏规则", "吃子规则",
    ]))
    guard case .known(.rules, .pause(let ruleReason), _) = resolution else {
        check(false, "规则弹窗没有关闭目标时应暂停")
        return
    }
    check(ruleReason.contains("关闭按钮"), "规则弹窗缺关闭目标时说明原因")

    // 未知弹窗不能靠「确定」「领取奖励」之类的常见字样盲点。
    resolution = PopupResolver.resolve(hits: popupHits([
        "神秘活动", "确定", "领取奖励",
    ]))
    check(resolution == .unknown, "未知弹窗保持 unknown，不自动关闭")

    // 广告 / 实名：已知但必须暂停。
    resolution = PopupResolver.resolve(hits: popupHits([
        "观看广告", "广告奖励",
    ]))
    guard case .known(.ad, .pause(let adReason), _) = resolution else {
        check(false, "广告弹窗应命中 ad 并暂停")
        return
    }
    check(adReason.contains("广告"), "广告暂停原因可读")

    resolution = PopupResolver.resolve(hits: popupHits([
        "实名认证",
    ]))
    guard case .known(.realName, .pause, _) = resolution else {
        check(false, "实名弹窗应命中 realName 并暂停")
        return
    }

    // 断线重连：有「重新连接」时点它。
    resolution = PopupResolver.resolve(hits: popupHits([
        "网络异常", "重新连接",
    ]))
    guard case .known(.disconnect, .close(.keyword(let reconnect)), _) = resolution else {
        check(false, "断线弹窗应命中 disconnect")
        return
    }
    check(reconnect == "重新连接", "断线弹窗优先点重新连接")

    // 主菜单底栏的「每日签到/任务」不能误判为弹窗。
    resolution = PopupResolver.resolve(hits: popupHits([
        "每日签到", "免费抽奖", "任务", "商城",
    ]))
    check(resolution == .unknown, "主菜单关键字不误判为弹窗")

    check(PopupResolution.unknown.label == "未知弹窗", "unknown 显示为未知弹窗")
    check(
        PopupResolution.known(
            kind: .ad, action: .pause("暂停"), matched: ["观看广告"]
        ).summary.contains("广告"),
        "弹窗摘要包含模板名"
    )
}

func testPopupAnchorDefaults() {
    print("PopupAnchorDefaults · 内置关闭锚点")

    let keys = [
        PopupAnchor.signInClose.rawValue,
        PopupAnchor.taskClose.rawValue,
        PopupAnchor.profileClose.rawValue,
    ]
    for key in keys {
        guard let rect = PopupAnchorDefaults.rect(forKey: key) else {
            check(false, "\(key) 应有内置锚点")
            continue
        }
        check(
            rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1,
            "\(key) 在窗口归一化范围内"
        )
        check(rect.width > 0 && rect.height > 0, "\(key) 面积有效")
    }

    if let signIn = PopupAnchorDefaults.rect(forKey: PopupAnchor.signInClose.rawValue) {
        check(almost(signIn.midX, 0.835, 0.002), "签到关闭点 x 对齐实测 X")
        check(almost(signIn.midY, 0.2725, 0.002), "签到关闭点 y 对齐实测 X")
    }
    if let profile = PopupAnchorDefaults.rect(forKey: PopupAnchor.profileClose.rawValue) {
        check(almost(profile.midX, 0.2655, 0.002), "个人信息关闭点 x 对齐实测 X")
        check(almost(profile.midY, 0.238, 0.002), "个人信息关闭点 y 对齐实测 X")
    }

    check(
        PopupAnchorDefaults.rect(forKey: PopupAnchor.genericClose.rawValue) == nil,
        "通用关闭锚点未校准时不可用"
    )
    check(PopupAnchorDefaults.rect(forKey: "popup.close.nope") == nil, "未知锚点返回 nil")
}

func testPopupRoundTracker() {
    print("PopupRoundTracker · 3 轮预算")

    check(PopupCatalog.maxCloseRounds == 3, "默认最多关闭 3 轮")

    var tracker = PopupRoundTracker(maxRounds: 3)
    check(tracker.remaining == 3, "初始剩余 3 轮")
    check(tracker.beginRound(), "第 1 轮允许")
    check(tracker.beginRound(), "第 2 轮允许")
    check(tracker.beginRound(), "第 3 轮允许")
    check(!tracker.beginRound(), "第 4 轮拒绝")
    check(tracker.remaining == 0, "预算耗尽")

    tracker.reset()
    check(tracker.remaining == 3, "reset 恢复预算")
    check(tracker.beginRound(), "reset 后可再次关闭")

    var zero = PopupRoundTracker(maxRounds: 0)
    check(!zero.beginRound(), "0 轮预算直接拒绝")
}

// MARK: - PerfKit

func testPerfKit() {
    print("PerfKit · 延迟统计")

    var empty = LatencyRecorder(capacity: 4)
    check(empty.stats == nil, "无样本时 stats 为 nil")

    empty.record(.nan)
    empty.record(-1)
    check(empty.values.isEmpty, "非法样本被丢弃")

    var recorder = LatencyRecorder(capacity: 3)
    for value in [10.0, 20.0, 30.0, 40.0] {
        recorder.record(value)
    }
    check(recorder.values == [20, 30, 40], "环形窗口只保留最近 3 个")
    check(recorder.stats?.count == 3, "样本数正确")
    check(recorder.stats?.minMilliseconds == 20, "min 正确")
    check(recorder.stats?.maxMilliseconds == 40, "max 正确")
    check(recorder.stats?.meanMilliseconds == 30, "mean 正确")

    let sorted = (1...100).map(Double.init)
    check(LatencyRecorder.percentile(sorted, 0.50) == 50, "p50 用最近秩")
    check(LatencyRecorder.percentile(sorted, 0.95) == 95, "p95 用最近秩")
    check(LatencyRecorder.percentile(sorted, 0) == 1, "p0 取最小值")
    check(LatencyRecorder.percentile(sorted, 1) == 100, "p100 取最大值")
    check(LatencyRecorder.percentile([], 0.95) == 0, "空数组返回 0")

    check(PerfStage.endToEnd.isAcceptanceGate, "端到端是唯一验收门槛")
    check(!PerfStage.screenOCR.isAcceptanceGate, "OCR 不是验收门槛")
    check(
        PerfStage.endToEnd.referenceBudgetMilliseconds == PerformanceBudget.endToEndMilliseconds,
        "端到端预算与设计文档一致"
    )

    var fast: [PerfStage: LatencyRecorder] = [:]
    var fastEnd = LatencyRecorder()
    fastEnd.record(199)
    fast[.endToEnd] = fastEnd
    let passing = PerfReport.make(
        source: "test",
        recorders: fast,
        environment: [:]
    )
    check(passing.passed, "p95 < 200ms 判定达标")
    check(passing.summaryText.contains("达标"), "摘要显示达标")

    var slow: [PerfStage: LatencyRecorder] = [:]
    var slowEnd = LatencyRecorder()
    slowEnd.record(200)
    slow[.endToEnd] = slowEnd
    let failing = PerfReport.make(
        source: "test",
        recorders: slow,
        environment: [:]
    )
    check(!failing.passed, "p95 = 200ms 不算达标")

    var missing: [PerfStage: LatencyRecorder] = [:]
    var ocr = LatencyRecorder()
    ocr.record(50)
    missing[.screenOCR] = ocr
    let noGate = PerfReport.make(
        source: "test",
        recorders: missing,
        environment: [:]
    )
    check(!noGate.passed, "无端到端样本不判定达标")
    check(noGate.stage(.screenOCR)?.stats.p95Milliseconds == 50, "报告保留分阶段统计")
}

// MARK: - EpisodeRecorder

func makeEpisodeTestState(revealedAt: Int? = nil) -> GameState {
    var cells = (0..<60).map {
        GameCell(i: $0, state: .empty, color: nil, piece: nil, confidence: nil)
    }
    if let revealedAt {
        cells[revealedAt] = GameCell(
            i: revealedAt,
            state: .revealed,
            color: .red,
            piece: "engineer",
            confidence: 0.99
        )
    }
    return GameState(
        phase: .playing,
        board: GameBoard(rows: 5, cols: 12, cells: cells),
        turn: .red,
        selected: nil,
        legalActions: [],
        timers: nil,
        lastMove: nil
    )
}

func readJSONLines(_ url: URL) -> [[String: Any]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

func testEpisodeRecorder() {
    print("EpisodeRecorder")
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("ttj-episode-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let storage = StorageKit(rootURL: root)
    let before = makeEpisodeTestState()
    let after = makeEpisodeTestState(revealedAt: 0)

    let recorder = EpisodeRecorder(storage: storage)
    do {
        try recorder.start(
            initialState: before,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            episodeID: "test"
        )
        try recorder.recordFlip(cell: 0, state: before)
        let directory = try recorder.finish(finalState: after, result: .win)
        check(recorder.episodeID == "test", "episode id 使用调用方指定的值")
        check(directory.lastPathComponent == "test", "episode 目录名正确")
        for name in ["meta.json", "states.jsonl", "actions.jsonl", "reward.json"] {
            check(
                fm.fileExists(atPath: directory.appendingPathComponent(name).path),
                "生成 \(name)"
            )
        }

        let metaData = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] ?? [:]
        check(meta["id"] as? String == "test", "meta.id")
        check(meta["mode"] as? String == "翻翻棋", "meta.mode")
        check(meta["moves"] as? Int == 1, "meta.moves 记录点击数")
        check(meta["result"] as? String == "win", "meta.result")
        check(meta["score"] as? Int == 1, "meta.score")
        check(
            Set(meta.keys) == Set([
                "id", "mode", "startedAt", "duration", "moves", "result", "score",
            ]),
            "meta 只含 schema 字段"
        )

        let states = readJSONLines(directory.appendingPathComponent("states.jsonl"))
        let actions = readJSONLines(directory.appendingPathComponent("actions.jsonl"))
        check(states.count == 2, "states = actions + 1")
        check(actions.count == 1, "一次翻牌写一行动作")
        check(actions[0]["type"] as? String == "tap_cell", "动作是 tap_cell")
        check(actions[0]["cell"] as? Int == 0, "动作 cell 正确")
        check(states[0]["turn"] as? String == "red", "动作前状态 turn")
        check(states[1]["phase"] as? String == "playing", "状态 phase")
    } catch {
        check(false, "EpisodeRecorder 翻牌录制失败：\(error)")
    }

    // 走棋：点源格 + 点目标格，第二步状态带 selected。
    let moveRecorder = EpisodeRecorder(storage: storage)
    do {
        try moveRecorder.start(initialState: before, episodeID: "test")
        try moveRecorder.recordMove(from: 1, to: 2, state: before)
        let directory = try moveRecorder.finish(finalState: after, result: .draw)
        check(directory.lastPathComponent == "test-2", "同名 episode 自动加后缀")
        let states = readJSONLines(directory.appendingPathComponent("states.jsonl"))
        let actions = readJSONLines(directory.appendingPathComponent("actions.jsonl"))
        check(states.count == 3, "走棋 states = 2 次点击 + 终局")
        check(actions.count == 2, "走棋写两次点击")
        check(actions[0]["cell"] as? Int == 1, "第一次点源格")
        check(actions[1]["cell"] as? Int == 2, "第二次点目标格")
        check(states[1]["selected"] as? Int == 1, "第二次点击前 source 已选中")
    } catch {
        check(false, "EpisodeRecorder 走棋录制失败：\(error)")
    }

    // 取消录制会删除半成品目录。
    let cancelled = EpisodeRecorder(storage: storage)
    do {
        try cancelled.start(initialState: before, episodeID: "cancel-me")
        guard let directory = cancelled.directoryURL else {
            check(false, "取消录制前目录存在")
            return
        }
        cancelled.cancel()
        check(!fm.fileExists(atPath: directory.path), "取消后删除半成品目录")
        check(!cancelled.isRecording, "取消后回到未录制")
    } catch {
        check(false, "EpisodeRecorder 取消录制失败：\(error)")
    }
}

// MARK: - Main

testPieceCatalog()
testPieceClassifierMapping()
testScreenStateLabels()
testScreenStateFusion()
testPopupResolver()
testPopupAnchorDefaults()
testPopupRoundTracker()
testGameStateEncoding()
testTurnResolution()
testTimerParsing()
testLegalActions()
testLastMoveInference()
testTapGeometry()
testTapPrecheck()
testTapVerification()
testBoardGeometry()
testBoardMask()
testStabilizerVotesOutNoise()
testStabilizerFiltersLowConfidence()
testStabilizerFreezesBoardWideChange()
testStabilizerResetsOnSizeChange()
testCellObservationNormalization()
testSnapshotLibrary()
testAutoLabelVote()
testAutoLabelPersistence()
testBoardChangeDetector()
testBoardCellDeltas()
testAutoSampleTracker()
testEpisodeRecorder()
testPerfKit()

if failures > 0 {
    print("\n\(failures)/\(checks) 个断言失败")
    exit(1)
}
print("\n全部 Swift 感知测试通过（\(checks) 个断言）")
