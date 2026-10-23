"""协议模型：GameState / Action / Episode。

对应 shared/schema/*.schema.json（schema 版本 1）。
完整字段冻结与校验在 M2-1 落地；此处先提供可用的骨架定义，
保证 episode 录制（M2-7）与特征输入（M3-2）有统一数据形状。
"""

from __future__ import annotations

from typing import Literal

import msgspec

SCHEMA_VERSION = 1

CellState = Literal["empty", "hidden", "revealed", "unknown"]
PieceColor = Literal["red", "black"]
GamePhase = Literal["playing", "result"]
Outcome = Literal["win", "loss", "draw", "timeout", "error"]


class Cell(msgspec.Struct):
    """单个棋盘格：revealed 时带 color/piece/confidence，其余为 None。"""

    i: int
    state: CellState
    color: PieceColor | None = None
    piece: str | None = None
    confidence: float | None = None


class Board(msgspec.Struct):
    """棋盘：rows/cols 以实测为准（P0-3），禁止在代码里硬编码 4x8。"""

    rows: int
    cols: int
    cells: list[Cell]


class Timers(msgspec.Struct):
    me: float | None = None
    opponent: float | None = None


class LastMove(msgspec.Struct):
    # JSON 键为 "from"/"to"（from 是 Python 关键字，字段名用 from_cell/to_cell）
    from_cell: int = msgspec.field(name="from")
    to_cell: int = msgspec.field(name="to")


class GameState(msgspec.Struct):
    """棋盘逻辑状态，用于回合录制与 MLX 特征输入（设计文档 §7.3）。"""

    board: Board
    schema: int = SCHEMA_VERSION
    phase: GamePhase = "playing"
    turn: PieceColor = "red"
    selected: int | None = None
    legal_actions: list[int] = msgspec.field(default_factory=list)
    timers: Timers | None = None
    last_move: LastMove | None = None


class TapCell(msgspec.Struct, tag="tap_cell"):
    """点击棋盘格：翻牌 / 选中 / 落子。cell 为 0..rows*cols-1。"""

    cell: int


class TapButton(msgspec.Struct, tag="tap_button"):
    """点击按钮：start / again / close / confirm 等（以实测为准）。"""

    name: str


class WaitAction(msgspec.Struct, tag="wait"):
    """等待动画/对手，单位毫秒。"""

    ms: int


Action = TapCell | TapButton | WaitAction


class Episode(msgspec.Struct, rename="camel"):
    """一局对局元信息；状态/动作明细见 states.jsonl / actions.jsonl（设计文档 §5）。"""

    id: str
    mode: str
    started_at: str  # ISO8601
    duration: float  # 秒
    moves: int
    result: Outcome
    score: int = 0
