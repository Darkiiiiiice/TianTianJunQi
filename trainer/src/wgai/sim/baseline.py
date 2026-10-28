"""启发式基线：翻暗子、按军衔吃子、占行营、护旗、避免送子。

M2-9 只要求一个“能下完整局、明显强于随机”的基线，不追求棋力上限。
所有判断只使用 `Observation`（公开信息）+ `UnseenPool`（暗子多重集），
不偷看真实暗子身份；这样它也能直接作为真实对局的对手/评测基线。
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .belief import UnseenPool
from .engine import Action, Flip, Move, Observation
from .rules import Color, CombatResult, Piece, PieceKind, Rules


@dataclass(frozen=True)
class HeuristicWeights:
    flip_base: float = 0.10
    flip_railway: float = 0.06
    flip_near_own: float = 0.04
    flip_near_enemy: float = -0.04
    flip_information: float = 0.05

    capture_win: float = 1.0
    capture_trade: float = 0.0
    capture_lose: float = -1.0
    hidden_attack_info: float = 0.15

    move_camp: float = 0.45
    leave_camp: float = -0.45
    move_railway: float = 0.12
    centrality: float = 0.08
    danger: float = -0.30
    defend_flag: float = 0.20
    advance: float = 0.06

    flag_value: float = 100.0


DEFAULT_WEIGHTS = HeuristicWeights()


def _centrality(rules: Rules, index: int) -> float:
    row, col = rules.board.coord(index)
    center_row = (rules.board.rows - 1) / 2
    center_col = (rules.board.cols - 1) / 2
    dr = abs(row - center_row) / max(center_row, 1)
    dc = abs(col - center_col) / max(center_col, 1)
    return max(0.0, 1.0 - (dr + dc) / 2.0)


def _piece_from_cell(observation: Observation, index: int) -> Piece | None:
    cell = observation.cell(index)
    if cell.state != "revealed" or cell.color is None or cell.piece is None:
        return None
    return Piece(cell.color, cell.piece)


def _is_enemy(piece: Piece, observation: Observation) -> bool:
    return observation.color is not None and piece.color is not observation.color


def _combat_score(
    result: CombatResult,
    attacker: Piece,
    defender: Piece,
    weights: HeuristicWeights,
) -> float:
    if result is CombatResult.ATTACKER_WINS:
        bonus = weights.flag_value if defender.kind is PieceKind.FLAG else 0.0
        return defender.value + weights.capture_win + bonus
    if result is CombatResult.BOTH_DIE:
        bonus = weights.flag_value if defender.kind is PieceKind.FLAG else 0.0
        return defender.value - attacker.value + weights.capture_trade + bonus
    if result is CombatResult.DEFENDER_WINS:
        return -attacker.value + weights.capture_lose
    return -1_000.0


def _score_hidden_attack(
    attacker: Piece,
    observation: Observation,
    rules: Rules,
    pool: UnseenPool,
    weights: HeuristicWeights,
) -> float:
    """对暗子格进攻的期望分：按未翻多重集加权。"""
    if pool.total == 0:
        return 0.0
    total = pool.total
    score = weights.hidden_attack_info
    for (color, kind), count in pool.counts.items():
        if count <= 0:
            continue
        p = count / total
        if color is attacker.color:
            # 翻开己方暗子：视为单独翻棋，双方存活。
            score += p * weights.flip_information
            continue
        defender = Piece(color, kind)
        mines_remaining = observation.mines_remaining.get(color, 0)
        if kind is PieceKind.MINE:
            if attacker.kind is PieceKind.ENGINEER:
                result = CombatResult.ATTACKER_WINS
            elif attacker.kind is PieceKind.BOMB:
                result = CombatResult.BOTH_DIE
            else:
                # 撞暗雷：进攻方阵亡，地雷保留。
                result = CombatResult.DEFENDER_WINS
        elif kind is PieceKind.FLAG and mines_remaining > 0:
            # 雷未挖光：只能翻开，不能扛旗。
            score += p * weights.flip_information
            continue
        else:
            result = rules.resolve_combat(
                attacker,
                defender,
                defender_mines_remaining=mines_remaining,
            )
        score += p * _combat_score(result, attacker, defender, weights)
    return score


def _score_flip(
    observation: Observation,
    rules: Rules,
    action: Flip,
    weights: HeuristicWeights,
) -> float:
    score = weights.flip_base + weights.flip_information
    spec = rules.board
    if spec.is_railway(action.cell):
        score += weights.flip_railway
    own_adjacent = 0
    enemy_adjacent = 0
    for neighbor in spec.neighbors(action.cell):
        piece = _piece_from_cell(observation, neighbor)
        if piece is None or observation.color is None:
            continue
        if piece.color is observation.color:
            own_adjacent += 1
        else:
            enemy_adjacent += 1
    score += weights.flip_near_own * own_adjacent
    score += weights.flip_near_enemy * enemy_adjacent
    return score


def _score_move(
    observation: Observation,
    rules: Rules,
    action: Move,
    pool: UnseenPool,
    weights: HeuristicWeights,
) -> float:
    attacker = _piece_from_cell(observation, action.from_cell)
    if attacker is None:
        return -1_000.0
    target_cell = observation.cell(action.to_cell)
    spec = rules.board
    score = 0.0

    if target_cell.state == "hidden":
        score += _score_hidden_attack(attacker, observation, rules, pool, weights)
    elif target_cell.state == "revealed":
        defender = _piece_from_cell(observation, action.to_cell)
        if defender is None:
            return -1_000.0
        result = rules.resolve_combat(
            attacker,
            defender,
            defender_in_camp=spec.is_camp(action.to_cell),
            defender_mines_remaining=observation.mines_remaining.get(
                defender.color, 0
            ),
        )
        score += _combat_score(result, attacker, defender, weights)
    else:
        # 空格：位置分。
        if spec.is_camp(action.to_cell):
            score += weights.move_camp
        if spec.is_camp(action.from_cell):
            score += weights.leave_camp
        if spec.is_railway(action.to_cell):
            score += weights.move_railway
        score += weights.centrality * _centrality(rules, action.to_cell)

        # 危险格：落点旁边有已翻开的更强敌方棋子（或炸弹）。
        danger = 0.0
        for neighbor in spec.neighbors(action.to_cell):
            piece = _piece_from_cell(observation, neighbor)
            if piece is None or not _is_enemy(piece, observation):
                continue
            if piece.kind is PieceKind.BOMB:
                danger += 1.0
            elif piece.rank is not None and attacker.rank is not None:
                if piece.rank >= attacker.rank:
                    danger += 1.0
        if danger:
            score += weights.danger * danger

        # 护旗：如果己方军旗已翻开，落点靠近军旗加分。
        flag_index = _own_flag_index(observation)
        if flag_index is not None:
            distance = _manhattan(rules, action.to_cell, flag_index)
            if distance <= 2:
                score += weights.defend_flag
            score += weights.advance * max(0.0, 1.0 - distance / 6.0)

        # 工兵上铁路是额外机动性。
        if attacker.kind is PieceKind.ENGINEER and spec.is_railway(action.to_cell):
            score += weights.move_railway

    return score


def _manhattan(rules: Rules, a: int, b: int) -> int:
    ar, ac = rules.board.coord(a)
    br, bc = rules.board.coord(b)
    return abs(ar - br) + abs(ac - bc)


def _own_flag_index(observation: Observation) -> int | None:
    for cell in observation.cells:
        if (
            cell.state == "revealed"
            and cell.color is observation.color
            and cell.piece is PieceKind.FLAG
        ):
            return cell.index
    return None


def score_action(
    observation: Observation,
    rules: Rules,
    action: Action,
    *,
    pool: UnseenPool | None = None,
    weights: HeuristicWeights = DEFAULT_WEIGHTS,
) -> float:
    if pool is None:
        pool = UnseenPool.from_observation(observation, rules)
    if isinstance(action, Flip):
        return _score_flip(observation, rules, action, weights)
    if isinstance(action, Move):
        return _score_move(observation, rules, action, pool, weights)
    return -1_000.0


@dataclass
class HeuristicAgent:
    """按启发式分数选动作；同分时用 RNG 打散，保证自博弈有变化。"""

    name: str = "heuristic"
    weights: HeuristicWeights = DEFAULT_WEIGHTS
    temperature: float = 0.0
    _history: list[Action] = field(default_factory=list, init=False, repr=False)
    _last_plies: int = field(default=-1, init=False, repr=False)

    def _repetition_count(self, action: Action, rules: Rules) -> int:
        window = rules.repetition_window_moves
        if window <= 0:
            return 0
        # 引擎只统计“走棋”，翻牌不占重复窗口；这里必须用同一口径，
        # 否则中间夹着翻牌时基线会误以为还安全。
        recent_moves = [
            previous for previous in self._history if isinstance(previous, Move)
        ][-window:]
        return sum(1 for previous in recent_moves if previous == action)

    def select(
        self,
        observation: Observation,
        rules: Rules,
        rng: random.Random,
    ) -> Action:
        actions = list(observation.legal_actions)
        if not actions:
            raise ValueError("没有合法动作")
        if observation.plies <= self._last_plies:
            self._history.clear()
        self._last_plies = observation.plies

        pool = UnseenPool.from_observation(observation, rules)
        rng.shuffle(actions)
        limit = rules.repetition_max_repeats
        scored: list[tuple[float, Action]] = []
        for action in actions:
            score = score_action(
                observation, rules, action, pool=pool, weights=self.weights
            )
            # 再走一次就会凑满“8 步内重复 4 次”，直接判负；基线必须避开。
            if (
                isinstance(action, Move)
                and limit > 0
                and self._repetition_count(action, rules) + 1 >= limit
            ):
                score = -1_000_000.0
            scored.append((score, action))
        if self.temperature <= 0:
            choice = max(scored, key=lambda item: item[0])[1]
            self._history.append(choice)
            return choice
        # 简单 softmax 采样；temperature 越大越随机。
        best = max(score for score, _ in scored)
        probabilities = [
            math.exp((score - best) / self.temperature) for score, _ in scored
        ]
        total = sum(probabilities)
        pick = rng.random() * total
        upto = 0.0
        for probability, (_, action) in zip(probabilities, scored):
            upto += probability
            if pick <= upto:
                self._history.append(action)
                return action
        choice = scored[-1][1]
        self._history.append(choice)
        return choice
