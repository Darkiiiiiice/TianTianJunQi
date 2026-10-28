"""翻翻棋规则：棋子、军衔、炸弹/地雷/军旗、吃子判定。

机器可读规则在 `shared/rules/rules.json`，人类可读说明在
`shared/rules/fanfanqi.md`。规则改动必须升级 `rulesVersion`。
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from .board import BoardSpec

REPO_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_RULES_PATH = REPO_ROOT / "shared" / "rules" / "rules.json"


class Color(str, Enum):
    RED = "red"
    BLACK = "black"

    @property
    def opposite(self) -> "Color":
        return Color.BLACK if self is Color.RED else Color.RED


class PieceKind(str, Enum):
    COMMANDER = "commander"
    ARMY_COMMANDER = "army_commander"
    DIVISION_COMMANDER = "division_commander"
    BRIGADE_COMMANDER = "brigade_commander"
    REGIMENT_COMMANDER = "regiment_commander"
    BATTALION_COMMANDER = "battalion_commander"
    COMPANY_COMMANDER = "company_commander"
    PLATOON_COMMANDER = "platoon_commander"
    ENGINEER = "engineer"
    MINE = "mine"
    BOMB = "bomb"
    FLAG = "flag"

    @classmethod
    def from_id(cls, value: str) -> "PieceKind":
        try:
            return cls(value)
        except ValueError as error:
            raise ValueError(f"未知棋子类型：{value}") from error


PIECE_NAMES: dict[PieceKind, str] = {
    PieceKind.COMMANDER: "司令",
    PieceKind.ARMY_COMMANDER: "军长",
    PieceKind.DIVISION_COMMANDER: "师长",
    PieceKind.BRIGADE_COMMANDER: "旅长",
    PieceKind.REGIMENT_COMMANDER: "团长",
    PieceKind.BATTALION_COMMANDER: "营长",
    PieceKind.COMPANY_COMMANDER: "连长",
    PieceKind.PLATOON_COMMANDER: "排长",
    PieceKind.ENGINEER: "工兵",
    PieceKind.MINE: "地雷",
    PieceKind.BOMB: "炸弹",
    PieceKind.FLAG: "军旗",
}

# 启发式估值：用于基线对手与自博弈课程，不参与规则判定。
PIECE_VALUES: dict[PieceKind, float] = {
    PieceKind.COMMANDER: 10.0,
    PieceKind.ARMY_COMMANDER: 8.0,
    PieceKind.DIVISION_COMMANDER: 6.0,
    PieceKind.BRIGADE_COMMANDER: 5.0,
    PieceKind.REGIMENT_COMMANDER: 4.0,
    PieceKind.BATTALION_COMMANDER: 3.0,
    PieceKind.COMPANY_COMMANDER: 2.0,
    PieceKind.PLATOON_COMMANDER: 1.5,
    PieceKind.ENGINEER: 2.5,  # 能排雷、铁路转弯，实战价值高于排长
    PieceKind.MINE: 2.0,
    PieceKind.BOMB: 4.0,
    PieceKind.FLAG: 100.0,
}


@dataclass(frozen=True)
class Piece:
    """棋子的真实身份。

    是否翻开由 `board.Cell.revealed` 唯一决定；`Piece` 本身不携带可见性，
    避免出现“棋子对象说已翻开、格子说没翻开”的双重真相。
    """

    color: Color
    kind: PieceKind

    @property
    def rank(self) -> int | None:
        return RANKS.get(self.kind)

    @property
    def is_movable(self) -> bool:
        return self.kind not in (PieceKind.MINE, PieceKind.FLAG)

    @property
    def value(self) -> float:
        return PIECE_VALUES[self.kind]


# 军衔表与 rules.json 必须一致；这里保留一份静态表用于 Piece.rank 的快速访问，
# Rules 加载时会校验两者一致。
RANKS: dict[PieceKind, int] = {
    PieceKind.COMMANDER: 9,
    PieceKind.ARMY_COMMANDER: 8,
    PieceKind.DIVISION_COMMANDER: 7,
    PieceKind.BRIGADE_COMMANDER: 6,
    PieceKind.REGIMENT_COMMANDER: 5,
    PieceKind.BATTALION_COMMANDER: 4,
    PieceKind.COMPANY_COMMANDER: 3,
    PieceKind.PLATOON_COMMANDER: 2,
    PieceKind.ENGINEER: 1,
}


class CombatResult(str, Enum):
    ATTACKER_WINS = "attacker_wins"
    DEFENDER_WINS = "defender_wins"
    BOTH_DIE = "both_die"
    ILLEGAL = "illegal"


class RulesError(ValueError):
    pass


@dataclass(frozen=True)
class Rules:
    version: str
    board: BoardSpec
    counts: dict[PieceKind, int]
    ranks: dict[PieceKind, int]
    flags: dict[str, bool | str]
    draw_no_capture_plies: int
    draw_max_plies: int
    repetition_window_moves: int = 8
    repetition_max_repeats: int = 4

    # -- 加载 -------------------------------------------------------------

    @classmethod
    def load(cls, path: str | Path | None = None) -> "Rules":
        path = Path(path) if path is not None else DEFAULT_RULES_PATH
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise RulesError(f"读取规则失败：{path}：{error}") from error
        return cls.from_dict(data)

    @classmethod
    def from_dict(cls, data: dict) -> "Rules":
        try:
            version = str(data["rulesVersion"])
            board = BoardSpec.from_dict(data["board"])
            counts = {
                PieceKind.from_id(key): int(value)
                for key, value in data["pieces"].items()
            }
            ranks = {
                PieceKind.from_id(key): int(value)
                for key, value in data["ranks"].items()
            }
            flags = {str(key): value for key, value in data.get("rules", {}).items()}
            draw = data.get("draw", {})
            repetition = data.get("repetition", {})
        except (KeyError, TypeError, ValueError) as error:
            raise RulesError(f"规则文件字段不完整：{error}") from error

        for kind in PieceKind:
            if counts.get(kind, 0) <= 0:
                raise RulesError(f"棋子 {kind.value} 的数量必须为正")
        # counts 是“每方”的数量；棋盘上共 2 份。
        if sum(counts.values()) * 2 != board.size - len(board.camps):
            raise RulesError(
                f"每方棋子数 {sum(counts.values())} ×2 与可放格数 "
                f"{board.size - len(board.camps)} 不一致"
            )
        for kind, rank in ranks.items():
            if RANKS.get(kind) != rank:
                raise RulesError(f"军衔表不一致：{kind.value} {rank} != {RANKS.get(kind)}")
        for kind in RANKS:
            if kind not in ranks:
                raise RulesError(f"军衔表缺少 {kind.value}")

        return cls(
            version=version,
            board=board,
            counts=counts,
            ranks=ranks,
            flags=flags,
            draw_no_capture_plies=int(draw.get("noCapturePlies", 80)),
            draw_max_plies=int(draw.get("maxPlies", 300)),
            repetition_window_moves=int(repetition.get("windowMoves", 8)),
            repetition_max_repeats=int(repetition.get("maxRepeats", 4)),
        )

    # -- 查询 -------------------------------------------------------------

    def mines_per_color(self, color: Color) -> int:
        return self.counts.get(PieceKind.MINE, 0)

    def initial_pieces(self) -> list[Piece]:
        pieces: list[Piece] = []
        for color in Color:
            for kind, count in self.counts.items():
                pieces.extend(Piece(color, kind) for _ in range(count))
        return pieces

    def flag_rule(self, name: str, default: bool = True) -> bool:
        value = self.flags.get(name, default)
        return bool(value)

    def first_move_after_flip(self) -> str:
        value = self.flags.get("firstMoveAfterFlip", "opponent")
        if value not in {"opponent", "flipper"}:
            raise RulesError(f"firstMoveAfterFlip 非法：{value}")
        return str(value)

    # -- 吃子 -------------------------------------------------------------

    def resolve_combat(
        self,
        attacker: Piece,
        defender: Piece,
        *,
        defender_in_camp: bool = False,
        defender_mines_remaining: int | None = None,
    ) -> CombatResult:
        """返回攻击结果；ILLEGAL 表示该落点根本不允许走。

        只处理“已翻明”的防守子。暗子由引擎先翻开再调用本函数；
        若翻开的暗子与攻击方同色，引擎按 `hiddenFriendlyRevealOnly` 单独处理。
        """
        if attacker.color == defender.color:
            return CombatResult.ILLEGAL
        if defender_in_camp and self.flag_rule("campSafe", True):
            return CombatResult.ILLEGAL

        if defender.kind is PieceKind.FLAG:
            if (
                self.flag_rule("flagRequiresMinesCleared", True)
                and (defender_mines_remaining or 0) > 0
            ):
                return CombatResult.ILLEGAL
            # 腾讯规则：地雷挖光后任何棋子都能扛旗；炸弹与军旗同归于尽，
            # 但军旗被夺即判负，引擎会把“同归于尽”同样记为夺旗方获胜。
            if attacker.kind is PieceKind.BOMB:
                return CombatResult.BOTH_DIE
            return CombatResult.ATTACKER_WINS

        if defender.kind is PieceKind.MINE:
            if attacker.kind is PieceKind.ENGINEER:
                return CombatResult.ATTACKER_WINS
            if attacker.kind is PieceKind.BOMB:
                return CombatResult.BOTH_DIE
            return CombatResult.ILLEGAL

        if attacker.kind is PieceKind.BOMB or defender.kind is PieceKind.BOMB:
            return CombatResult.BOTH_DIE

        if attacker.kind in (PieceKind.MINE, PieceKind.FLAG):
            return CombatResult.ILLEGAL

        attacker_rank = attacker.rank
        defender_rank = defender.rank
        if attacker_rank is None or defender_rank is None:
            return CombatResult.ILLEGAL
        if attacker_rank > defender_rank:
            return CombatResult.ATTACKER_WINS
        if attacker_rank < defender_rank:
            return CombatResult.DEFENDER_WINS
        return CombatResult.BOTH_DIE


def load_rules(path: str | Path | None = None) -> Rules:
    return Rules.load(path)
