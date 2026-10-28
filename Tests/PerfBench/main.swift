import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// M1-9 离线回放基准。
///
/// 把录好的棋盘/屏幕样本重新喂进 app 用的同一套分类器、平滑器和状态构建，
/// 在不依赖实时窗口的情况下量「感知 → 动作」延迟。端到端口径：
/// 棋盘分类 + 稳定投票 + GameState 构建 + 动作/坐标决策 + 注入前延迟（30ms）。
///
/// 用法：
///   perf-bench --app <TianTianJunQi.app> [--boards N] [--screens N] [--out report.json]

struct BenchmarkOptions {
    var appPath: String = ""
    var boardRoot = StorageKit().samplesURL
    var screenRoot = StorageKit().screenSamplesURL
    var outputURL = StorageKit().performanceURL
        .appendingPathComponent("perf-replay.json")
    var boardLimit = 30
    var screenLimit = 20
    /// 注入前固定开销的保守估计：移动事件 → 按下事件的拟人化间隔（20–40ms）。
    var injectionPreDelayMilliseconds: Double = 30

    static func parse(_ arguments: [String]) -> BenchmarkOptions {
        var options = BenchmarkOptions()
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            func value() -> String? {
                guard index + 1 < arguments.count else { return nil }
                index += 1
                return arguments[index]
            }
            switch key {
            case "--app":
                options.appPath = value() ?? options.appPath
            case "--boards":
                options.boardLimit = Int(value() ?? "") ?? options.boardLimit
            case "--screens":
                options.screenLimit = Int(value() ?? "") ?? options.screenLimit
            case "--out":
                if let path = value() {
                    options.outputURL = URL(fileURLWithPath: path)
                }
            case "--help", "-h":
                print("perf-bench --app <app> [--boards N] [--screens N] [--out report.json]")
                exit(0)
            default:
                break
            }
            index += 1
        }
        return options
    }
}

let options = BenchmarkOptions.parse(CommandLine.arguments)

guard !options.appPath.isEmpty,
      let bundle = Bundle(path: options.appPath)
else {
    FileHandle.standardError.write(
        Data("用法：perf-bench --app <TianTianJunQi.app> [--boards N] [--screens N] [--out report.json]\n".utf8)
    )
    exit(64)
}

let ciContext = CIContext(options: [.cacheIntermediates: false])

func checkedDirectories(_ root: URL, prefix: String) -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    )) ?? []
    return urls
        .filter { $0.lastPathComponent.hasPrefix(prefix) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// 均匀抽样，覆盖不同日期/主题，避免只测最后几帧。
func evenlyPicked(_ urls: [URL], limit: Int) -> [URL] {
    guard limit > 0, urls.count > limit else { return urls }
    if limit == 1 { return [urls[urls.count / 2]] }
    return (0..<limit).map { index in
        let position = Double(index) * Double(urls.count - 1) / Double(limit - 1)
        return urls[Int(position.rounded())]
    }
}

func loadPixelBuffer(_ url: URL) -> CVPixelBuffer? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    guard let buffer = PixelBufferRenderer.make(
        width: image.width,
        height: image.height
    ) else { return nil }
    let ciImage = CIImage(cgImage: image)
    guard PixelBufferRenderer.render(ciImage, to: buffer, context: ciContext) else {
        return nil
    }
    return buffer
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    return object as? [String: Any]
}

struct LabelCell {
    let state: String
    let color: String?
    let piece: String?
}

struct BoardSample {
    let name: String
    let pixelBuffer: CVPixelBuffer
    let grid: BoardGrid
    let labels: [Int: LabelCell]
}

func loadBoardSamples(_ urls: [URL]) -> [BoardSample] {
    urls.compactMap { directory in
        guard let meta = readJSON(directory.appendingPathComponent("meta.json")),
              let corners = meta["boardCorners"] as? [[Double]],
              let pixelBuffer = loadPixelBuffer(directory.appendingPathComponent("frame.png"))
        else { return nil }
        let points = corners.compactMap { pair -> CGPoint? in
            guard pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
        guard let quad = BoardQuad(corners: points) else { return nil }
        let rows = meta["rows"] as? Int ?? 5
        let cols = meta["cols"] as? Int ?? 12
        // 快照的 cells[].center 是用采集时的逐列/逐行中心线算出来的。
        // 反投影回棋盘 (u,v)，重建同一套非均匀格点；只按四角均分会整体错位。
        var uByCol: [Int: [CGFloat]] = [:]
        var vByRow: [Int: [CGFloat]] = [:]
        if let cellEntries = meta["cells"] as? [[String: Any]],
           let base = BoardGrid(quad: quad, rows: rows, cols: cols) {
            for entry in cellEntries {
                guard let row = entry["row"] as? Int,
                      let col = entry["col"] as? Int,
                      let center = entry["center"] as? [Double],
                      center.count == 2
                else { continue }
                let unit = base.inverse.map(CGPoint(x: center[0], y: center[1]))
                uByCol[col, default: []].append(unit.x)
                vByRow[row, default: []].append(unit.y)
            }
        }
        let columnCenters = (0..<cols).map { col -> CGFloat in
            let values = uByCol[col] ?? []
            return values.isEmpty ? CGFloat(col) / CGFloat(max(cols - 1, 1)) : values.reduce(0, +) / CGFloat(values.count)
        }
        let rowCenters = (0..<rows).map { row -> CGFloat in
            let values = vByRow[row] ?? []
            return values.isEmpty ? CGFloat(row) / CGFloat(max(rows - 1, 1)) : values.reduce(0, +) / CGFloat(values.count)
        }
        guard let grid = BoardGrid(
            quad: quad,
            rows: rows,
            cols: cols,
            columnCenters: columnCenters,
            rowCenters: rowCenters
        ) else {
            return nil
        }
        var labels: [Int: LabelCell] = [:]
        if let labelObject = readJSON(directory.appendingPathComponent("labels.json")),
           let labelCells = labelObject["cells"] as? [[String: Any]] {
            for cell in labelCells {
                guard let index = cell["index"] as? Int,
                      let state = cell["state"] as? String
                else { continue }
                labels[index] = LabelCell(
                    state: state,
                    color: cell["color"] as? String,
                    piece: cell["piece"] as? String
                )
            }
        }
        return BoardSample(
            name: directory.lastPathComponent,
            pixelBuffer: pixelBuffer,
            grid: grid,
            labels: labels
        )
    }
}

struct ScreenSample {
    let name: String
    let expected: String
    let pixelBuffer: CVPixelBuffer
}

func loadScreenSamples(_ urls: [URL]) -> [ScreenSample] {
    urls.compactMap { directory in
        guard let meta = readJSON(directory.appendingPathComponent("meta.json")),
              let expected = meta["label"] as? String,
              let pixelBuffer = loadPixelBuffer(directory.appendingPathComponent("frame.png"))
        else { return nil }
        return ScreenSample(
            name: directory.lastPathComponent,
            expected: expected,
            pixelBuffer: pixelBuffer
        )
    }
}

func percentileText(_ stats: LatencyStats) -> String {
    String(
        format: "n=%d  p50=%.1f  p95=%.1f  max=%.1f",
        stats.count,
        stats.p50Milliseconds,
        stats.p95Milliseconds,
        stats.maxMilliseconds
    )
}

print("M1-9 回放基准")
print("app: \(options.appPath)")
let environment = PerfEnvironment.current()
for key in environment.keys.sorted() {
    print("  \(key): \(environment[key] ?? "")")
}

var recorders: [PerfStage: LatencyRecorder] = [:]
func record(_ stage: PerfStage, _ milliseconds: Double) {
    var recorder = recorders[stage] ?? LatencyRecorder()
    recorder.record(milliseconds)
    recorders[stage] = recorder
}

// MARK: - 棋盘动作路径（验收门槛）

let allBoardDirectories = checkedDirectories(options.boardRoot, prefix: "snapshot-")
let boardDirectories = evenlyPicked(allBoardDirectories, limit: options.boardLimit)
let boardSamples = loadBoardSamples(boardDirectories)
print("\n棋盘样本：请求 \(options.boardLimit) · 可用 \(allBoardDirectories.count) · 载入 \(boardSamples.count)")

var boardFailures = 0
var boardStateTotal = 0
var boardStateCorrect = 0
var boardPieceTotal = 0
var boardPieceCorrect = 0
if let classifier = try? BoardPieceClassifier(bundle: bundle) {
    var stabilizer = BoardStabilizer()
    var stateBuilder = BoardStateBuilder(config: BoardStateBuilderConfig(myColor: .red))

    for (sampleIndex, sample) in boardSamples.enumerated() {
        let frame = CapturedFrame(
            pixelBuffer: sample.pixelBuffer,
            scale: 1,
            timestamp: 0,
            contentRect: CapturedFrame.fullFrame
        )

        // 先用同一帧喂满投票窗口，只计最后一帧的增量延迟。
        var warmObservation: BoardObservation?
        for warmIndex in 0..<4 {
            guard let observation = try? classifier.classify(
                frame: frame,
                grid: sample.grid
            ) else {
                warmObservation = nil
                break
            }
            warmObservation = observation
            _ = stabilizer.update(
                observation,
                at: Double(sampleIndex * 18 + warmIndex) * 0.2
            )
        }
        if warmObservation == nil {
            boardFailures += 1
            continue
        }

        let classifyStarted = PerfClock.now()
        let observation = try? classifier.classify(frame: frame, grid: sample.grid)
        let classifyMilliseconds = PerfClock.milliseconds(since: classifyStarted)
        record(.boardClassify, classifyMilliseconds)

        guard let observation else {
            boardFailures += 1
            continue
        }

        let stateStarted = PerfClock.now()
        let stable = stabilizer.update(
            observation,
            at: Double(sampleIndex * 18 + 5) * 0.2
        )
        let state = stable.map {
            stateBuilder.build(board: $0, timers: nil)
        }
        let stateMilliseconds = PerfClock.milliseconds(since: stateStarted)
        record(.boardState, stateMilliseconds)

        for (index, label) in sample.labels {
            guard index < observation.cells.count else { continue }
            let cell = observation.cells[index]
            boardStateTotal += 1
            if cell.state.rawValue == label.state {
                boardStateCorrect += 1
            }
            if label.state == CellState.revealed.rawValue {
                boardPieceTotal += 1
                if cell.state == .revealed,
                   cell.color?.rawValue == label.color,
                   cell.piece == label.piece {
                    boardPieceCorrect += 1
                }
            }
        }

        guard let stable, let state, !stable.isSettling else {
            boardFailures += 1
            continue
        }

        let decisionStarted = PerfClock.now()
        let action = state.legalActions.first {
            stable.cells.indices.contains($0)
                && stable.cells[$0].state == .hidden
        } ?? state.legalActions.first
        let point = action.flatMap {
            BoardTapGeometry.windowPoint(
                of: $0,
                grid: sample.grid,
                contentRect: CapturedFrame.fullFrame
            )
        }
        let decisionMilliseconds = PerfClock.milliseconds(since: decisionStarted)
        record(.tapDecision, decisionMilliseconds)

        if point == nil {
            boardFailures += 1
            continue
        }

        // 真实注入里移动 → 按下还有 20–40ms；这里取中位数做固定估计。
        record(.tapClick, options.injectionPreDelayMilliseconds)
        let endToEnd = classifyMilliseconds
            + stateMilliseconds
            + decisionMilliseconds
            + options.injectionPreDelayMilliseconds
        record(.endToEnd, endToEnd)

        if sampleIndex % 5 == 0 || sampleIndex == boardSamples.count - 1 {
            print(String(
                format: "  [%d/%d] %@  board %.1fms · state %.1fms · decision %.1fms · e2e %.1fms",
                sampleIndex + 1,
                boardSamples.count,
                sample.name,
                classifyMilliseconds,
                stateMilliseconds,
                decisionMilliseconds,
                endToEnd
            ))
        }
    }
    if boardFailures > 0 {
        print("  跳过/失败样本：\(boardFailures)")
    }
} else {
    print("棋子分类器加载失败：无法跑棋盘基准")
}

// MARK: - 屏幕切换路径（诊断，不作为动作门槛）

let allScreenDirectories = checkedDirectories(options.screenRoot, prefix: "screen-")
let screenDirectories = evenlyPicked(allScreenDirectories, limit: options.screenLimit)
let screenSamples = loadScreenSamples(screenDirectories)
print("\n屏幕样本：请求 \(options.screenLimit) · 可用 \(allScreenDirectories.count) · 载入 \(screenSamples.count)")

var screenCorrect = 0
var screenTotal = 0
if let classifier = try? ScreenClassifier(bundle: bundle) {
    _ = try? classifier.warmUp()
    for sample in screenSamples {
        let analysis = ScreenAnalyzer.analyze(
            pixelBuffer: sample.pixelBuffer,
            contentRect: CapturedFrame.fullFrame,
            classifier: classifier
        )
        record(.screenOCR, analysis.ocrMilliseconds)
        if let milliseconds = analysis.classifierMilliseconds {
            record(.screenClassify, milliseconds)
        }
        record(.screenTotal, analysis.totalMilliseconds)

        let expected = ScreenState(rawValue: sample.expected)
            ?? ScreenState(classifierLabel: sample.expected)
        screenTotal += 1
        if analysis.state == expected {
            screenCorrect += 1
        }
    }
} else {
    print("屏幕分类器加载失败：无法跑屏幕基准")
}

let screenAccuracy = screenTotal > 0
    ? Double(screenCorrect) / Double(screenTotal)
    : nil
let boardStateAccuracy = boardStateTotal > 0
    ? Double(boardStateCorrect) / Double(boardStateTotal)
    : nil
let boardPieceAccuracy = boardPieceTotal > 0
    ? Double(boardPieceCorrect) / Double(boardPieceTotal)
    : nil

// MARK: - 报告

let note = "离线回放：棋盘路径用于 200ms 验收；屏幕路径是界面切换诊断，不参与动作门槛。"
let report = PerfReport.make(
    source: "replay",
    recorders: recorders,
    environment: environment,
    note: note,
    screenAccuracy: screenAccuracy,
    boardStateAccuracy: boardStateAccuracy,
    boardPieceAccuracy: boardPieceAccuracy
)

print("\n阶段延迟（p95 仅作定位，验收只看端到端）：")
for stage in PerfStage.allCases {
    guard let stats = recorders[stage]?.stats else { continue }
    let budget = stage.referenceBudgetMilliseconds.map { String(format: "  预算 %.0fms", $0) } ?? ""
    print("  \(stage.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(percentileText(stats))\(budget)")
}
if let boardStateAccuracy, let boardPieceAccuracy {
    print(String(
        format: "棋盘状态准确率：%.1f%%（%d/%d）· 明子颜色/军衔：%.1f%%（%d/%d）",
        boardStateAccuracy * 100,
        boardStateCorrect,
        boardStateTotal,
        boardPieceAccuracy * 100,
        boardPieceCorrect,
        boardPieceTotal
    ))
}
if let screenAccuracy {
    print(String(format: "屏幕分类准确率：%.0f%%（%d/%d）", screenAccuracy * 100, screenCorrect, screenTotal))
}
if let end = recorders[.endToEnd]?.stats {
    print(String(
        format: "端到端 p95 %.1fms < %.0fms → %@",
        end.p95Milliseconds,
        PerformanceBudget.endToEndMilliseconds,
        end.p95Milliseconds < PerformanceBudget.endToEndMilliseconds ? "达标" : "超预算"
    ))
} else {
    print("端到端：无有效样本")
}

do {
    try FileManager.default.createDirectory(
        at: options.outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(report).write(to: options.outputURL, options: .atomic)
    print("报告：\(options.outputURL.path)")
} catch {
    FileHandle.standardError.write(
        Data("报告写入失败：\(error.localizedDescription)\n".utf8)
    )
    exit(1)
}
