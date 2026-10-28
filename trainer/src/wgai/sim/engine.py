"""翻翻棋引擎：固定种子随机开局、翻牌阶段、走棋/吃子、合法动作、胜负。

设计约束（见 docs/微信小游戏自动游玩客户端.md §8.4）：

- 只服务翻翻棋，不做通用棋类引擎；
- 固定种子可复现；
- 规则版本来自 `rules.json`，规则改动必须升级版本；
- 引擎内部知道暗子的真实身份，但 `observation(player)` 只暴露该玩家可见信息。
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable

from .board import Board
from .rules import Color, CombatResult, Piece, PieceKind, Rules


class Phase(str, Enum):
    FLIP = "flip"  # 翻牌定阵营
    PLAY = "play"  # 走棋
    OVER = "over"


class Outcome(str, Enum):
    ONGOING = "ongoing"
    RED_WIN = "red_win"
    BLACK_WIN = "black_win"
    DRAW = "draw"


@dataclass(frozen=True, order=True)
class Flip:
    cell: int

    def __str__(self) -> str:
        return f"flip({self.cell})"


@dataclass(frozen=True, order=True)
class Move:
    from_cell: int
    to_cell: int

    def __str__(self) -> str:
        return f"move({self.from_cell}->{self.to_cell})"


Action = Flip | Move


class EngineError(RuntimeError):
    pass


@dataclass(frozen=True)
class ObservedCell:
    index: int
    state: str  # empty / hidden / revealed
    color: Color | None = None
    piece: PieceKind | None = None


@dataclass(frozen=True)
class Observation:
    """单个玩家可见的局面；暗子的颜色/军衔不出现。"""

    player: int
    phase: Phase
    turn_player: int
    color: Color | None
    colors: tuple[Color | None, Color | None]
    cells: tuple[ObservedCell, ...]
    legal_actions: tuple[Action, ...]
    hidden_count: int
    mines_remaining: dict[Color, int]
    captured: dict[Color, tuple[PieceKind, ...]]
    plies: int
    no_capture_plies: int
    last_action: Action | None
    outcome: Outcome

    def cell(self, index: int) -> ObservedCell:
        return self.cells[index]

    def legal_moves(self) -> list[Move]:
        return [action for action in self.legal_actions if isinstance(action, Move)]

    def legal_flips(self) -> list[Flip]:
        return [action for action in self.legal_actions if isinstance(action, Flip)]


@dataclass(frozen=True)
class MoveRecord:
    ply: int
    player: int
    color: Color | None
    action: Action
    combat: CombatResult | None
    captured: tuple[Piece, ...]
    revealed: tuple[Piece, ...]
    outcome: Outcome


@dataclass
class GameEngine:
    rules: Rules
    seed: int | None = None
    first_player: int = 0

    board: Board = field(init=False)
    phase: Phase = field(init=False, default=Phase.FLIP)
    turn: int = field(init=False, default=0)
    colors: list[Color | None] = field(init=False, default_factory=lambda: [None, None])
    prev_flip_color: Color | None = field(init=False, default=None)
    plies: int = field(init=False, default=0)
    no_capture_plies: int = field(init=False, default=0)
    captured: dict[Color, list[Piece]] = field(init=False, default_factory=dict)
    mines_on_board: dict[Color, int] = field(init=False, default_factory=dict)
    outcome: Outcome = field(init=False, default=Outcome.ONGOING)
    history: list[MoveRecord] = field(init=False, default_factory=list)
    _rng: random.Random = field(init=False, repr=False)
    _last_action: Action | None = field(init=False, default=None)

    def __post_init__(self) -> None:
        self.reset(seed=self.seed, first_player=self.first_player)

    # -- 生命周期 ---------------------------------------------------------

    def reset(self, seed: int | None = None, first_player: int | None = None) -> None:
        if seed is not None:
            self.seed = seed
        if first_player is not None:
            if first_player not in (0, 1):
                raise ValueError("first_player 只能是 0 或 1")
            self.first_player = first_player
        self._rng = random.Random(self.seed)
        self.board = Board(self.rules.board)
        self.phase = Phase.FLIP
        self.turn = self.first_player
        self.colors = [None, None]
        self.prev_flip_color = None
        self.plies = 0
        self.no_capture_plies = 0
        self.captured = {color: [] for color in Color}
        self.mines_on_board = {
            color: self.rules.mines_per_color(color) for color in Color
        }
        self.outcome = Outcome.ONGOING
        self.history = []
        self._last_action = None
        self._place_pieces()

    def _place_pieces(self) -> None:
        spec = self.rules.board
        cells = [index for index in range(spec.size) if not spec.is_camp(index)]
        pieces = self.rules.initial_pieces()
        if len(cells) != len(pieces):
            raise EngineError(
                f"可放格数 {len(cells)} 与棋子数 {len(pieces)} 不一致"
            )
        self._rng.shuffle(cells)
        self._rng.shuffle(pieces)
        for index, piece in zip(cells, pieces):
            self.board.place(index, piece, revealed=False)

    def clone(self) -> "GameEngine":
        clone = object.__new__(GameEngine)
        clone.rules = self.rules
        clone.seed = self.seed
        clone.first_player = self.first_player
        clone.board = self.board.copy()
        clone.phase = self.phase
        clone.turn = self.turn
        clone.colors = list(self.colors)
        clone.prev_flip_color = self.prev_flip_color
        clone.plies = self.plies
        clone.no_capture_plies = self.no_capture_plies
        clone.captured = {color: list(pieces) for color, pieces in self.captured.items()}
        clone.mines_on_board = dict(self.mines_on_board)
        clone.outcome = self.outcome
        clone.history = list(self.history)
        clone._rng = random.Random()
        clone._rng.setstate(self._rng.getstate())
        clone._last_action = self._last_action
        return clone

    # -- 基本查询 ---------------------------------------------------------

    @property
    def current_color(self) -> Color | None:
        return self.colors[self.turn]

    def player_for_color(self, color: Color) -> int:
        for player, assigned in enumerate(self.colors):
            if assigned is color:
                return player
        raise EngineError(f"颜色 {color.value} 尚未分配")

    def piece_at(self, index: int) -> Piece | None:
        piece = self.board.piece_at(index)
        return piece if isinstance(piece, Piece) else None

    def _own_revealed_piece(self, index: int) -> Piece | None:
        cell = self.board.cell(index)
        piece = cell.piece
        if piece is None or not cell.revealed:
            return None
        if self.current_color is None or piece.color is not self.current_color:
            return None
        return piece

    def _mines_remaining(self, color: Color) -> int:
        return self.mines_on_board[color]

    # -- 合法动作 ---------------------------------------------------------

    def legal_actions(self) -> list[Action]:
        if self.phase is Phase.OVER:
            return []
        actions: list[Action] = []
        if self.phase is Phase.FLIP:
            return [Flip(index) for index in self.board.hidden_indices()]
        if self.current_color is None:
            raise EngineError("走棋阶段颜色未分配")

        for index in self.board.revealed_indices():
            piece = self._own_revealed_piece(index)
            if piece is None or not piece.is_movable:
                continue
            for destination in self._destinations(index, piece):
                actions.append(Move(index, destination))
        actions.extend(Flip(index) for index in self.board.hidden_indices())
        return actions

    def _destinations(self, start: int, piece: Piece) -> list[int]:
        spec = self.rules.board
        destinations: list[int] = []

        def can_land(index: int) -> bool:
            return self._can_land(piece, index)

        for neighbor in spec.neighbors(start):
            if can_land(neighbor):
                destinations.append(neighbor)

        if spec.is_railway(start):
            if piece.kind is PieceKind.ENGINEER:
                # 工兵：铁路网 BFS，可转弯。
                reachable = spec.railway_reachable(
                    start,
                    is_blocked=lambda index: not self.board.is_empty(index),
                    can_land=can_land,
                )
                destinations.extend(reachable)
            else:
                # 其他棋子：只能沿同一条直线铁路走，不能转弯。
                for line in spec.railway_slides(start):
                    for index in line:
                        if self.board.is_empty(index):
                            destinations.append(index)
                            continue
                        if can_land(index):
                            destinations.append(index)
                        break

        # 去重且保持稳定顺序。
        return list(dict.fromkeys(destinations))

    def _can_land(self, piece: Piece, index: int) -> bool:
        cell = self.board.cell(index)
        if cell.piece is None:
            return True
        target = cell.piece
        if not isinstance(target, Piece):
            return False
        if target.color is piece.color:
            # 已翻明的己方子挡路；暗子允许“翻开来看看”，由引擎按规则处理。
            return not cell.revealed and self.rules.flag_rule(
                "hiddenFriendlyRevealOnly", True
            )
        if cell.is_camp and self.rules.flag_rule("campSafe", True):
            return False
        if not cell.revealed:
            # 暗子总是可以尝试攻击；翻开后再结算。
            return True
        result = self.rules.resolve_combat(
            piece,
            target,
            defender_in_camp=cell.is_camp,
            defender_mines_remaining=self._mines_remaining(target.color),
        )
        return result is not CombatResult.ILLEGAL

    # -- 执行 -------------------------------------------------------------

    def apply(self, action: Action) -> MoveRecord:
        if self.phase is Phase.OVER:
            raise EngineError("对局已结束")
        legal = self.legal_actions()
        if action not in legal:
            raise EngineError(f"非法动作：{action}")

        player = self.turn
        color = self.current_color
        combat: CombatResult | None = None
        captured: list[Piece] = []
        revealed: list[Piece] = []

        if isinstance(action, Flip):
            piece = self.board.reveal(action.cell)
            if not isinstance(piece, Piece):
                raise EngineError("翻牌目标不是棋子")
            revealed.append(piece)
            if self.phase is Phase.FLIP:
                if self.prev_flip_color is piece.color:
                    self.colors[player] = piece.color
                    self.colors[1 - player] = piece.color.opposite
                    self.phase = Phase.PLAY
                    if self.rules.first_move_after_flip() == "opponent":
                        self.turn = 1 - player
                    else:
                        self.turn = player
                    self.prev_flip_color = None
                else:
                    self.prev_flip_color = piece.color
                    self.turn = 1 - player
                self.plies += 1
            else:
                self.plies += 1
                self.no_capture_plies += 1
                self.turn = 1 - player
        elif isinstance(action, Move):
            attacker = self.piece_at(action.from_cell)
            if attacker is None:
                raise EngineError("起点没有棋子")
            target = self.board.cell(action.to_cell)
            defender = target.piece
            if defender is None:
                self.board.move(action.from_cell, action.to_cell)
            elif not isinstance(defender, Piece):
                raise EngineError("目标不是棋子")
            elif not target.revealed:
                # 攻击暗子：先翻开，再按翻开的真实身份结算。
                self.board.reveal(action.to_cell)
                revealed.append(defender)
                if defender.color is attacker.color:
                    # 同色暗子：视为单独翻棋，双方都留在原地。
                    combat = None
                elif defender.kind is PieceKind.MINE:
                    if attacker.kind is PieceKind.ENGINEER:
                        combat = CombatResult.ATTACKER_WINS
                    elif attacker.kind is PieceKind.BOMB:
                        combat = CombatResult.BOTH_DIE
                    elif self.rules.flag_rule("hiddenMineKillsAttacker", True):
                        # 撞上暗雷：非工兵/炸弹的进攻方阵亡，地雷留在原地。
                        combat = CombatResult.DEFENDER_WINS
                    else:
                        combat = None
                    if combat is not None:
                        captured.extend(
                            self._apply_combat(action, attacker, defender, combat)
                        )
                elif defender.kind is PieceKind.FLAG and (
                    self.rules.flag_rule("flagRequiresMinesCleared", True)
                    and self._mines_remaining(defender.color) > 0
                ):
                    # 雷未挖光：暗军旗只能被翻开，不能被碰撞。
                    combat = None
                else:
                    combat = self.rules.resolve_combat(
                        attacker,
                        defender,
                        defender_in_camp=target.is_camp,
                        defender_mines_remaining=self._mines_remaining(defender.color),
                    )
                    captured.extend(
                        self._apply_combat(action, attacker, defender, combat)
                    )
            else:
                combat = self.rules.resolve_combat(
                    attacker,
                    defender,
                    defender_in_camp=target.is_camp,
                    defender_mines_remaining=self._mines_remaining(defender.color),
                )
                captured.extend(
                    self._apply_combat(action, attacker, defender, combat)
                )

            self.plies += 1
            if captured:
                self.no_capture_plies = 0
            else:
                self.no_capture_plies += 1
            if not (
                self.rules.flag_rule("extraTurnOnCapture", False)
                and captured
                and self.phase is not Phase.OVER
            ):
                self.turn = 1 - player
        else:
            raise EngineError(f"未知动作类型：{action}")

        self._last_action = action
        record = MoveRecord(
            ply=self.plies,
            player=player,
            color=color,
            action=action,
            combat=combat,
            captured=tuple(captured),
            revealed=tuple(revealed),
            outcome=self.outcome,
        )
        self.history.append(record)
        self._check_terminal()
        record = MoveRecord(
            ply=record.ply,
            player=record.player,
            color=record.color,
            action=record.action,
            combat=record.combat,
            captured=record.captured,
            revealed=record.revealed,
            outcome=self.outcome,
        )
        self.history[-1] = record
        return record

    def _apply_combat(
        self,
        action: Move,
        attacker: Piece,
        defender: Piece,
        combat: CombatResult,
    ) -> list[Piece]:
        if combat is CombatResult.ILLEGAL:
            raise EngineError(f"非法吃子：{action}")
        removed: list[Piece] = []
        if combat is CombatResult.ATTACKER_WINS:
            self.board.remove(action.to_cell)
            self.captured[defender.color].append(defender)
            removed.append(defender)
            if defender.kind is PieceKind.MINE:
                self.mines_on_board[defender.color] -= 1
            if defender.kind is PieceKind.FLAG:
                self._finish_win(attacker.color)
            self.board.move(action.from_cell, action.to_cell)
        elif combat is CombatResult.DEFENDER_WINS:
            self.board.remove(action.from_cell)
            self.captured[attacker.color].append(attacker)
            removed.append(attacker)
        elif combat is CombatResult.BOTH_DIE:
            self.board.remove(action.from_cell)
            self.board.remove(action.to_cell)
            self.captured[attacker.color].append(attacker)
            self.captured[defender.color].append(defender)
            removed.extend([attacker, defender])
            if defender.kind is PieceKind.MINE:
                self.mines_on_board[defender.color] -= 1
            if defender.kind is PieceKind.FLAG:
                # 炸弹扛旗：双方同归于尽，但军旗被夺，进攻方仍获胜。
                self._finish_win(attacker.color)
        else:
            raise EngineError(f"未知吃子结果：{combat}")
        return removed

    def _finish_win(self, color: Color) -> None:
        self.phase = Phase.OVER
        self.outcome = (
            Outcome.RED_WIN if color is Color.RED else Outcome.BLACK_WIN
        )

    def _check_terminal(self) -> None:
        if self.phase is Phase.OVER:
            return
        if self._check_repetition():
            return
        if self.phase is Phase.FLIP and not self.legal_actions():
            # 极端兜底：50 枚全部翻完仍没有出现连续同色（理论概率约 2/C(50,25)）。
            # 按最后一枚的颜色定阵营，由对手先走，避免卡死在翻牌阶段。
            color = self.prev_flip_color
            if color is None:
                self.phase = Phase.OVER
                self.outcome = Outcome.DRAW
                return
            flipper = 1 - self.turn
            self.colors[flipper] = color
            self.colors[self.turn] = color.opposite
            self.phase = Phase.PLAY
            self.prev_flip_color = None
            # 50 枚全翻完后可能当前玩家直接无棋可走，继续走一遍终局判定。
            self._check_terminal()
            return
        if self.plies >= self.rules.draw_max_plies:
            self.phase = Phase.OVER
            self.outcome = Outcome.DRAW
            return
        if self.no_capture_plies >= self.rules.draw_no_capture_plies:
            self.phase = Phase.OVER
            self.outcome = Outcome.DRAW
            return
        if self.phase is Phase.PLAY and not self.legal_actions():
            # 当前玩家无棋可走：对方胜。
            loser = self.current_color
            if loser is None:
                raise EngineError("走棋阶段颜色未分配")
            self._finish_win(loser.opposite)

    def _check_repetition(self) -> bool:
        """腾讯规则：玩家连续 8 步内重复走同一着 4 次，判该玩家负。

        规则原文是“玩家连续走过的 8 步内，出现重复走棋 4 次则自动判负”。
        这里按“同一玩家的同一 `(from, to)`”统计：只数该玩家自己的走棋，
        翻牌不算（翻开的格子不可能再翻，天然不会重复）。一来一回的挪子会在
        该玩家的第 7 步触发：A→B、B→A、A→B、B→A、A→B、B→A、A→B。

        注：真实对局是否按“重复局面”而非“重复着法”判定尚未用真实 episode
        验证；M2-6 若出现不一致，只需改这一处并把 `rulesVersion` 升级。
        """
        window = self.rules.repetition_window_moves
        limit = self.rules.repetition_max_repeats
        if window <= 0 or limit <= 0 or self.phase is not Phase.PLAY:
            return False
        if not self.history or not isinstance(self.history[-1].action, Move):
            return False
        mover = self.history[-1].player
        moves = [
            record.action
            for record in self.history
            if record.player == mover and isinstance(record.action, Move)
        ][-window:]
        if len(moves) < limit:
            return False
        last = moves[-1]
        if sum(1 for move in moves if move == last) < limit:
            return False
        mover_color = self.colors[mover]
        if mover_color is None:
            return False
        self._finish_win(mover_color.opposite)
        return True

    # -- 观察 -------------------------------------------------------------

    def observation(self, player: int) -> Observation:
        if player not in (0, 1):
            raise ValueError("player 只能是 0 或 1")
        cells: list[ObservedCell] = []
        hidden_count = 0
        for cell in self.board.cells:
            if cell.piece is None:
                cells.append(ObservedCell(cell.index, "empty"))
            elif not cell.revealed:
                hidden_count += 1
                cells.append(ObservedCell(cell.index, "hidden"))
            else:
                piece = cell.piece
                assert isinstance(piece, Piece)
                cells.append(
                    ObservedCell(
                        cell.index,
                        "revealed",
                        color=piece.color,
                        piece=piece.kind,
                    )
                )
        return Observation(
            player=player,
            phase=self.phase,
            turn_player=self.turn,
            color=self.colors[player],
            colors=(self.colors[0], self.colors[1]),
            cells=tuple(cells),
            legal_actions=tuple(self.legal_actions()),
            hidden_count=hidden_count,
            mines_remaining=dict(self.mines_on_board),
            captured={
                color: tuple(piece.kind for piece in pieces)
                for color, pieces in self.captured.items()
            },
            plies=self.plies,
            no_capture_plies=self.no_capture_plies,
            last_action=self._last_action,
            outcome=self.outcome,
        )

    def state_dict(self, player: int) -> dict:
        """`shared/schema/game_state.schema.json` 兼容的可见状态。

        `player` 必须是当前轮到的玩家；`turn` 是当前回合颜色。翻牌阶段尚未
        分配颜色，用上一张翻出的颜色占位，真正的玩家轮次在
        `Observation.turn_player` 里。
        """
        if player != self.turn:
            raise ValueError(
                f"state_dict 只能记录当前玩家（当前 {self.turn}，请求 {player}）"
            )
        observation = self.observation(player)
        turn = self.current_color
        if turn is None:
            turn = self.prev_flip_color or Color.RED
        cells = []
        for cell in observation.cells:
            item: dict = {"i": cell.index, "state": cell.state}
            if cell.state == "revealed":
                item["color"] = cell.color.value if cell.color else None
                item["piece"] = cell.piece.value if cell.piece else None
            cells.append(item)
        last_move = None
        if isinstance(self._last_action, Move):
            last_move = {
                "from": self._last_action.from_cell,
                "to": self._last_action.to_cell,
            }
        return {
            "schema": 1,
            "phase": "result" if self.phase is Phase.OVER else "playing",
            "board": {
                "rows": self.rules.board.rows,
                "cols": self.rules.board.cols,
                "cells": cells,
            },
            "turn": turn.value,
            "selected": None,
            # schema 里 legal_actions 是可点击格子；同一格可能既是翻牌又是
            # 某个棋子的落点（攻击暗子），这里去重后保持稳定顺序。
            "legal_actions": list(
                dict.fromkeys(
                    action.cell if isinstance(action, Flip) else action.to_cell
                    for action in observation.legal_actions
                )
            ),
            "timers": None,
            "last_move": last_move,
        }

    # -- 调试 -------------------------------------------------------------

    def render(self) -> str:
        return self.board.render()

    def summary(self) -> str:
        colors = "/".join(color.value if color else "?" for color in self.colors)
        return (
            f"{self.phase.value} turn={self.turn} colors={colors} "
            f"plies={self.plies} no_capture={self.no_capture_plies} "
            f"outcome={self.outcome.value}"
        )


def play_actions(
    rules: Rules,
    actions: Iterable[Action],
    *,
    seed: int | None = None,
) -> GameEngine:
    """按给定动作序列回放；用于测试与回放校验。"""
    engine = GameEngine(rules, seed=seed)
    for action in actions:
        engine.apply(action)
    return engine
