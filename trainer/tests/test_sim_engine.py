"""翻翻棋引擎：翻牌定阵营、走子/铁路/行营、暗子结算、胜负/和棋/重复。"""

from __future__ import annotations

import random
from dataclasses import replace

import pytest

from wgai.sim.board import Board
from wgai.sim.engine import (
    EngineError,
    Flip,
    GameEngine,
    Move,
    Outcome,
    Phase,
    play_actions,
)
from wgai.sim.rules import Color, CombatResult, Piece, PieceKind, Rules


@pytest.fixture(scope="module")
def rules() -> Rules:
    return Rules.load()


def make_engine(
    rules: Rules,
    pieces: dict[int, tuple[Color, PieceKind, bool]],
    *,
    turn: int = 0,
    colors: tuple[Color, Color] = (Color.RED, Color.BLACK),
    phase: Phase = Phase.PLAY,
    plies: int = 0,
    no_capture: int = 0,
    mines: dict[Color, int] | None = None,
) -> GameEngine:
    engine = GameEngine(rules, seed=0)
    engine.board = Board(rules.board)
    engine.phase = phase
    engine.turn = turn
    engine.colors = list(colors)
    engine.prev_flip_color = None
    engine.plies = plies
    engine.no_capture_plies = no_capture
    engine.outcome = Outcome.ONGOING
    engine.history = []
    engine._last_action = None
    for index, (color, kind, revealed) in pieces.items():
        engine.board.place(index, Piece(color, kind), revealed=revealed)
    if mines is None:
        mines = {
            color: sum(
                1
                for piece_color, kind, _ in pieces.values()
                if piece_color is color and kind is PieceKind.MINE
            )
            for color in Color
        }
    engine.mines_on_board = dict(mines)
    return engine


def test_reset_is_deterministic(rules: Rules) -> None:
    first = GameEngine(rules, seed=7)
    second = GameEngine(rules, seed=7)
    assert [cell.piece for cell in first.board.cells] == [
        cell.piece for cell in second.board.cells
    ]
    assert [cell.revealed for cell in first.board.cells] == [
        cell.revealed for cell in second.board.cells
    ]
    assert len(first.board.hidden_indices()) == 50


def test_flip_phase_assigns_color_and_opponent_moves_first(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            0: (Color.RED, PieceKind.COMPANY_COMMANDER, False),
            1: (Color.RED, PieceKind.PLATOON_COMMANDER, False),
            2: (Color.BLACK, PieceKind.COMMANDER, False),
        },
        phase=Phase.FLIP,
        colors=(Color.RED, Color.BLACK),
    )
    engine.colors = [None, None]
    assert all(isinstance(action, Flip) for action in engine.legal_actions())

    engine.apply(Flip(0))
    assert engine.phase is Phase.FLIP
    assert engine.prev_flip_color is Color.RED
    assert engine.turn == 1

    record = engine.apply(Flip(1))
    assert engine.phase is Phase.PLAY
    assert engine.colors == [Color.BLACK, Color.RED]
    assert engine.turn == 0  # 默认由对手先走
    assert record.revealed[0].kind is PieceKind.PLATOON_COMMANDER


def test_first_move_after_flip_can_be_configured(rules: Rules) -> None:
    flipper_rules = replace(
        rules, flags={**rules.flags, "firstMoveAfterFlip": "flipper"}
    )
    engine = make_engine(
        flipper_rules,
        {
            0: (Color.RED, PieceKind.COMPANY_COMMANDER, False),
            1: (Color.RED, PieceKind.PLATOON_COMMANDER, False),
        },
        phase=Phase.FLIP,
    )
    engine.colors = [None, None]
    engine.apply(Flip(0))
    engine.apply(Flip(1))
    assert engine.phase is Phase.PLAY
    assert engine.colors == [Color.BLACK, Color.RED]
    assert engine.turn == 1  # 翻出同色的人先走


def test_ordinary_and_camp_movement(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {1: (Color.RED, PieceKind.COMMANDER, True)},
    )
    legal = engine.legal_actions()
    assert Move(1, 0) in legal  # 公路一步
    assert Move(1, 2) in legal
    assert Move(1, 13) in legal
    assert Move(1, 14) in legal  # 斜线进行营
    assert Move(1, 4) in legal  # 在铁路线上可以直走多格

    # 非铁路普通格仍然只能走一步。
    engine.board.move(1, 12)  # (1,0)
    engine.turn = 0
    legal = engine.legal_actions()
    assert Move(12, 13) in legal
    assert Move(12, 14) not in legal

    engine.board.move(12, 1)
    engine.board.move(1, 14)
    engine.turn = 0
    legal = engine.legal_actions()
    assert Move(14, 1) in legal  # 行营可以原路出来
    assert Move(14, 25) in legal  # 行营斜线到普通格


def test_camp_is_safe_from_enemy(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMMANDER, True),
            14: (Color.BLACK, PieceKind.ARMY_COMMANDER, True),
        },
    )
    assert Move(1, 14) not in engine.legal_actions()
    with pytest.raises(EngineError):
        engine.apply(Move(1, 14))


def test_railway_straight_and_engineer_turn(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            29: (Color.RED, PieceKind.COMPANY_COMMANDER, True),
            30: (Color.RED, PieceKind.ENGINEER, True),
        },
    )
    legal = engine.legal_actions()
    assert Move(29, 17) in legal  # 纵向铁路直走
    assert Move(29, 5) in legal
    assert Move(29, 53) in legal
    assert Move(29, 4) not in legal  # 普通棋子不能转直角
    assert Move(30, 4) in legal  # 工兵可以沿铁路转弯


def test_railway_blocker_stops_non_engineer(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMMANDER, True),
            3: (Color.BLACK, PieceKind.PLATOON_COMMANDER, True),
        },
    )
    legal = engine.legal_actions()
    assert Move(1, 3) in legal  # 可以吃挡路的子
    assert Move(1, 4) not in legal  # 但不能穿过它


def test_engineer_cannot_pass_through_blocker(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            29: (Color.RED, PieceKind.ENGINEER, True),
            17: (Color.BLACK, PieceKind.PLATOON_COMMANDER, True),
            41: (Color.BLACK, PieceKind.PLATOON_COMMANDER, True),
        },
    )
    legal = engine.legal_actions()
    assert Move(29, 17) in legal
    assert Move(29, 41) in legal
    assert Move(29, 5) not in legal
    assert Move(29, 53) not in legal


def test_hidden_mine_kills_non_engineer(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMPANY_COMMANDER, True),
            2: (Color.BLACK, PieceKind.MINE, False),
        },
        mines={Color.RED: 0, Color.BLACK: 3},
    )
    record = engine.apply(Move(1, 2))
    assert record.combat is CombatResult.DEFENDER_WINS
    assert engine.board.is_empty(1)
    assert engine.board.is_revealed(2)
    assert engine.piece_at(2).kind is PieceKind.MINE
    assert engine.mines_on_board[Color.BLACK] == 3
    assert [piece.kind for piece in engine.captured[Color.RED]] == [
        PieceKind.COMPANY_COMMANDER
    ]


def test_hidden_mine_is_cleared_by_engineer_or_bomb(rules: Rules) -> None:
    engineer = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.ENGINEER, True),
            2: (Color.BLACK, PieceKind.MINE, False),
        },
        mines={Color.RED: 0, Color.BLACK: 3},
    )
    record = engineer.apply(Move(1, 2))
    assert record.combat is CombatResult.ATTACKER_WINS
    assert engineer.piece_at(2).kind is PieceKind.ENGINEER
    assert engineer.mines_on_board[Color.BLACK] == 2

    bomb = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.BOMB, True),
            2: (Color.BLACK, PieceKind.MINE, False),
        },
        mines={Color.RED: 0, Color.BLACK: 3},
    )
    record = bomb.apply(Move(1, 2))
    assert record.combat is CombatResult.BOTH_DIE
    assert bomb.board.is_empty(1)
    assert bomb.board.is_empty(2)
    assert bomb.mines_on_board[Color.BLACK] == 2


def test_hidden_friendly_piece_is_only_revealed(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMPANY_COMMANDER, True),
            2: (Color.RED, PieceKind.PLATOON_COMMANDER, False),
        },
    )
    record = engine.apply(Move(1, 2))
    assert record.combat is None
    assert not record.captured
    assert engine.board.is_revealed(2)
    assert engine.piece_at(1).kind is PieceKind.COMPANY_COMMANDER
    assert engine.piece_at(2).kind is PieceKind.PLATOON_COMMANDER
    assert engine.turn == 1
    assert engine.no_capture_plies == 1


def test_hidden_flag_needs_mines_cleared(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMMANDER, True),
            2: (Color.BLACK, PieceKind.FLAG, False),
            3: (Color.BLACK, PieceKind.MINE, False),
            59: (Color.BLACK, PieceKind.COMMANDER, True),
        },
        mines={Color.RED: 0, Color.BLACK: 1},
    )
    record = engine.apply(Move(1, 2))
    assert record.combat is None
    assert engine.board.is_revealed(2)
    assert engine.piece_at(1).kind is PieceKind.COMMANDER
    engine.turn = 0
    assert Move(1, 2) not in engine.legal_actions()

    # 挖掉最后一颗雷后，军旗才可以被扛。
    engine.board.remove(3)
    engine.mines_on_board[Color.BLACK] = 0
    engine.turn = 0
    assert Move(1, 2) in engine.legal_actions()
    record = engine.apply(Move(1, 2))
    assert record.combat is CombatResult.ATTACKER_WINS
    assert engine.phase is Phase.OVER
    assert engine.outcome is Outcome.RED_WIN
    assert engine.piece_at(2).kind is PieceKind.COMMANDER
    assert engine.piece_at(2).color is Color.RED


def test_bomb_takes_flag_but_still_wins(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.BOMB, True),
            2: (Color.BLACK, PieceKind.FLAG, True),
        },
        mines={Color.RED: 0, Color.BLACK: 0},
    )
    record = engine.apply(Move(1, 2))
    assert record.combat is CombatResult.BOTH_DIE
    assert engine.phase is Phase.OVER
    assert engine.outcome is Outcome.RED_WIN
    assert engine.board.is_empty(1)
    assert engine.board.is_empty(2)
    assert {piece.kind for piece in engine.captured[Color.RED]} == {PieceKind.BOMB}
    assert {piece.kind for piece in engine.captured[Color.BLACK]} == {PieceKind.FLAG}


def test_mine_and_flag_are_immobile(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.MINE, True),
            2: (Color.RED, PieceKind.FLAG, True),
        },
    )
    assert engine.legal_actions() == []


def test_no_legal_move_loses(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.FLAG, True),
            59: (Color.BLACK, PieceKind.COMMANDER, True),
        },
        mines={Color.RED: 0, Color.BLACK: 0},
    )
    assert engine.legal_actions() == []
    engine._check_terminal()
    assert engine.phase is Phase.OVER
    assert engine.outcome is Outcome.BLACK_WIN


def test_max_plies_draw(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMMANDER, True),
            59: (Color.BLACK, PieceKind.COMMANDER, True),
        },
        plies=rules.draw_max_plies - 1,
    )
    engine.apply(Move(1, 0))
    assert engine.phase is Phase.OVER
    assert engine.outcome is Outcome.DRAW


def test_no_capture_plies_draw(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMMANDER, True),
            59: (Color.BLACK, PieceKind.COMMANDER, True),
        },
        no_capture=rules.draw_no_capture_plies - 1,
    )
    engine.apply(Move(1, 0))
    assert engine.phase is Phase.OVER
    assert engine.outcome is Outcome.DRAW


def test_repetition_loses_after_four_same_moves_in_eight(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            0: (Color.RED, PieceKind.COMMANDER, True),
            59: (Color.BLACK, PieceKind.COMMANDER, True),
        },
    )
    # 红方在 0/1 之间来回；黑方在 58/59 之间配合。红方第 7 步时
    # 0→1 已经出现 4 次（第 1/3/5/7 步），应判红方负。
    sequence = [(0, 1), (59, 58), (1, 0), (58, 59)] * 4
    for index, move in enumerate(sequence, 1):
        if engine.phase is Phase.OVER:
            break
        engine.apply(Move(*move))
        if index == 9:
            assert engine.phase is Phase.PLAY  # 3 次还不判负
    assert engine.phase is Phase.OVER
    assert engine.outcome is Outcome.BLACK_WIN
    assert engine.plies == 13


def test_repetition_does_not_count_flips(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            0: (Color.RED, PieceKind.COMMANDER, True),
            1: (Color.RED, PieceKind.PLATOON_COMMANDER, False),
            2: (Color.BLACK, PieceKind.PLATOON_COMMANDER, False),
            59: (Color.BLACK, PieceKind.COMMANDER, True),
        },
    )
    engine.apply(Flip(1))
    engine.apply(Move(59, 58))
    engine.apply(Flip(2))
    engine.apply(Move(58, 59))
    assert engine.phase is Phase.PLAY


def test_observation_hides_hidden_identity(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            0: (Color.RED, PieceKind.COMMANDER, False),
            1: (Color.BLACK, PieceKind.PLATOON_COMMANDER, True),
        },
        mines={Color.RED: 0, Color.BLACK: 0},
    )
    observation = engine.observation(0)
    hidden = observation.cell(0)
    assert hidden.state == "hidden"
    assert hidden.color is None
    assert hidden.piece is None
    revealed = observation.cell(1)
    assert revealed.state == "revealed"
    assert revealed.color is Color.BLACK
    assert revealed.piece is PieceKind.PLATOON_COMMANDER
    assert observation.hidden_count == 1
    assert observation.player == 0
    assert observation.turn_player == 0
    assert observation.color is Color.RED


def test_state_dict_matches_schema_and_dedupes_actions(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMMANDER, True),
            2: (Color.BLACK, PieceKind.PLATOON_COMMANDER, False),
        },
        mines={Color.RED: 0, Color.BLACK: 0},
    )
    state = engine.state_dict(0)
    assert state["schema"] == 1
    assert state["phase"] == "playing"
    assert state["turn"] == "red"
    assert state["board"]["rows"] == 5
    assert state["board"]["cols"] == 12
    assert len(state["board"]["cells"]) == 60
    assert state["selected"] is None
    assert state["timers"] is None
    assert state["last_move"] is None
    # 2 号格既是暗子（可翻），又是红司令的落点（可攻击）；schema 里只应出现一次。
    assert state["legal_actions"].count(2) == 1

    engine.apply(Move(1, 0))
    state = engine.state_dict(1)
    assert state["last_move"] == {"from": 1, "to": 0}
    assert state["turn"] == "black"
    with pytest.raises(ValueError):
        engine.state_dict(0)


def test_clone_is_independent(rules: Rules) -> None:
    engine = make_engine(
        rules,
        {
            1: (Color.RED, PieceKind.COMMANDER, True),
            59: (Color.BLACK, PieceKind.COMMANDER, True),
        },
    )
    clone = engine.clone()
    clone.apply(Move(1, 0))
    assert engine.board.is_empty(1) is False
    assert engine.board.piece_at(1).kind is PieceKind.COMMANDER
    assert clone.board.is_empty(1)
    assert engine.turn == 0
    assert clone.turn == 1


def test_play_actions_replays_same_outcome(rules: Rules) -> None:
    engine = GameEngine(rules, seed=5)
    rng = random.Random(5)
    actions = []
    while engine.phase is not Phase.OVER:
        action = rng.choice(engine.legal_actions())
        actions.append(action)
        engine.apply(action)
    replayed = play_actions(rules, actions, seed=5)
    assert replayed.outcome is engine.outcome
    assert replayed.plies == engine.plies
    assert replayed.colors == engine.colors
