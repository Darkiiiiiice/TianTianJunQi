import Foundation

/// 自动标注的投票逻辑（纯函数，与 Vision 解耦，便于单测）。
enum AutoLabelVote {
    struct Result<Label: Hashable> {
        let label: Label
        let votes: Int
        let total: Int
    }

    /// 取距离最近的 `k` 个候选做多数投票；低于 `minVotes` 视为不可信，返回 nil。
    static func winner<Label: Hashable>(
        _ candidates: [(label: Label, distance: Float)],
        k: Int = 5,
        minVotes: Int = 4
    ) -> Result<Label>? {
        guard k > 0, minVotes > 0, minVotes <= k, candidates.count >= minVotes else {
            return nil
        }
        let nearest = candidates
            .sorted { $0.distance < $1.distance }
            .prefix(k)

        var counts: [Label: Int] = [:]
        for item in nearest {
            counts[item.label, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value }),
              best.value >= minVotes
        else { return nil }
        return Result(label: best.key, votes: best.value, total: nearest.count)
    }

    /// 棋子判定：参考库按图片去重后，冷门棋子（军旗、司令）只有几张图，
    /// 永远凑不满 4/5 票，所以除多数票外再放宽几条可验证的通道：
    /// 1. 距离 ≤ 0.10 的近重复图（同一颗棋子的另一帧），且这些近邻标签一致；
    /// 2. 拿到 3 票，且最近的不同棋子明显更远（距离比 ≥ 1.25）；
    /// 3. 只拿到 2 票，但距离比 ≥ 1.25 且最近邻本身足够近（≤ 0.40）。
    static func piece<Label: Hashable>(
        _ candidates: [(label: Label, distance: Float)],
        k: Int = 5
    ) -> Result<Label>? {
        guard k > 0, !candidates.isEmpty else { return nil }
        let ranked = candidates.sorted { $0.distance < $1.distance }
        let nearest = Array(ranked.prefix(k))

        var counts: [Label: Int] = [:]
        var nearestDistance: [Label: Float] = [:]
        for item in ranked {
            if nearestDistance[item.label] == nil {
                nearestDistance[item.label] = item.distance
                counts[item.label] = 0
            }
        }
        for item in nearest {
            counts[item.label, default: 0] += 1
        }

        // 票数相同时取「最近的图更近」的那个，保证结果稳定。
        guard let best = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return (nearestDistance[lhs.key] ?? .greatestFiniteMagnitude)
                > (nearestDistance[rhs.key] ?? .greatestFiniteMagnitude)
        }) else { return nil }

        // 1. 参考库里就有几乎同一张图：它的标签比几张远处的票可信得多。
        //    若这些近重复图标签互相矛盾，说明样本本身有问题，交给人工。
        let nearDuplicates = Array(ranked.prefix { $0.distance <= 0.10 })
        if let same = nearDuplicates.first {
            let labels = Set(nearDuplicates.map(\.label))
            guard labels.count == 1 else { return nil }
            return Result(label: same.label, votes: nearDuplicates.count, total: nearest.count)
        }

        let bestDistance = nearestDistance[best.key] ?? .greatestFiniteMagnitude
        let otherDistance = nearest
            .first { $0.label != best.key }?
            .distance ?? .greatestFiniteMagnitude
        let ratio = otherDistance / max(bestDistance, 0.0001)

        // 2. 多数票；或票数偏少但明显领先（冷门棋子）。
        let clearWinner = ratio >= 1.25
            && (best.value >= 3 || (best.value >= 2 && bestDistance <= 0.40))
        guard best.value >= 4 || clearWinner else { return nil }
        return Result(label: best.key, votes: best.value, total: nearest.count)
    }
}
