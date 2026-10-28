"""暗子信念：未翻棋子多重集、确定性采样与“确定化”引擎克隆。

翻翻棋的公开信息比表面多：所有翻开的棋子、所有被吃掉的棋子都是公开的，
因此每种颜色还剩哪些棋子是完全可推的；不确定的只是“哪一枚暗子在哪一格”。
本模块就做这一层：

- `UnseenPool`：从 `Observation` 反推未翻棋子的 (颜色, 军衔) 多重集；
- `UnseenPool.sample()`：用给定 RNG 均匀采样一份暗子分配；
- `determinize()`：把真实引擎克隆成“暗子按信念采样”的版本，供 MCTS/搜索使用。

初始摆放是均匀随机的，所以给定已翻棋子后，剩余棋子到剩余暗子格的分配
也是均匀的；直接 shuffle 即可，不需要按格子加权。
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Iterable

from .engine import GameEngine, Observation
from .rules import Color, Piece, PieceKind, Rules


class BeliefError(ValueError):
    pass


@dataclass(frozen=True)
class UnseenPool:
    """尚未翻开的棋子多重集，键为 (颜色, 军衔)。"""

    counts: dict[tuple[Color, PieceKind], int]

    def __post_init__(self) -> None:
        for key, count in self.counts.items():
            if count < 0:
                raise BeliefError(f"未翻棋子数量为负：{key} = {count}")

    # -- 构造 -------------------------------------------------------------

    @classmethod
    def from_observation(cls, observation: Observation, rules: Rules) -> "UnseenPool":
        counts: dict[tuple[Color, PieceKind], int] = {
            (color, kind): rules.counts[kind]
            for color in Color
            for kind in PieceKind
        }
        for cell in observation.cells:
            if cell.state != "revealed":
                continue
            if cell.color is None or cell.piece is None:
                raise BeliefError(f"明子缺少颜色/军衔：{cell.index}")
            key = (cell.color, cell.piece)
            counts[key] = counts.get(key, 0) - 1
        for color, kinds in observation.captured.items():
            for kind in kinds:
                key = (color, kind)
                counts[key] = counts.get(key, 0) - 1
        pool = cls(counts)
        if pool.total != observation.hidden_count:
            raise BeliefError(
                f"未翻棋子多重集 {pool.total} 与暗子格数 "
                f"{observation.hidden_count} 不一致"
            )
        return pool

    # -- 查询 -------------------------------------------------------------

    @property
    def total(self) -> int:
        return sum(self.counts.values())

    def pieces(self) -> list[Piece]:
        pieces: list[Piece] = []
        for (color, kind), count in sorted(
            self.counts.items(), key=lambda item: (item[0][0].value, item[0][1].value)
        ):
            pieces.extend(Piece(color, kind) for _ in range(count))
        return pieces

    def color_counts(self) -> dict[Color, int]:
        result = {color: 0 for color in Color}
        for (color, _), count in self.counts.items():
            result[color] += count
        return result

    def kind_counts(self, color: Color) -> dict[PieceKind, int]:
        return {
            kind: self.counts.get((color, kind), 0)
            for kind in PieceKind
        }

    def probability(self, color: Color, kind: PieceKind) -> float:
        if self.total == 0:
            return 0.0
        return self.counts.get((color, kind), 0) / self.total

    # -- 采样 -------------------------------------------------------------

    def sample(self, rng: random.Random) -> list[Piece]:
        pieces = self.pieces()
        rng.shuffle(pieces)
        return pieces


def determinize(
    engine: GameEngine,
    player: int,
    rng: random.Random,
) -> GameEngine:
    """返回真实引擎的克隆，但暗子身份按 `player` 的信念重新采样。

    明子、被吃子、轮次、计时等全部保留；只有 `hidden` 格子的棋子身份改变。
    返回的克隆仍然知道采样后的“真实身份”，因此可以直接调用
    `legal_actions()` / `apply()` 做搜索。
    """
    observation = engine.observation(player)
    pool = UnseenPool.from_observation(observation, engine.rules)
    hidden = [
        cell.index for cell in observation.cells if cell.state == "hidden"
    ]
    sampled = pool.sample(rng)
    if len(hidden) != len(sampled):
        raise BeliefError(
            f"暗子格 {len(hidden)} 与采样棋子 {len(sampled)} 不一致"
        )

    clone = engine.clone()
    for index, piece in zip(hidden, sampled):
        cell = clone.board.cell(index)
        if cell.piece is None or cell.revealed:
            raise BeliefError(f"格子 {index} 不是暗子格")
        cell.piece = piece

    # 地雷剩余数是公开信息；按采样后的棋盘重算，避免与真实引擎串味。
    clone.mines_on_board = {
        color: sum(
            1
            for cell in clone.board.cells
            if cell.piece is not None
            and cell.piece.kind is PieceKind.MINE
            and cell.piece.color is color
        )
        for color in Color
    }
    return clone


def determinizations(
    engine: GameEngine,
    player: int,
    count: int,
    *,
    seed: int | None = None,
) -> list[GameEngine]:
    """生成 `count` 个确定化克隆；同一 seed 可复现。"""
    if count < 0:
        raise ValueError("count 不能为负")
    rng = random.Random(seed)
    return [determinize(engine, player, rng) for _ in range(count)]


def hidden_cells(observation: Observation) -> Iterable[int]:
    return (cell.index for cell in observation.cells if cell.state == "hidden")
