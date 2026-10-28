"""规则表：每方 25 子、军衔、炸弹/地雷/军旗、行营安全与规则版本。"""

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

import pytest

from wgai.sim.rules import (
    Color,
    CombatResult,
    Piece,
    PieceKind,
    Rules,
    RulesError,
)


@pytest.fixture(scope="module")
def rules() -> Rules:
    return Rules.load()


def test_piece_counts_match_tencent_help(rules: Rules) -> None:
    expected = {
        PieceKind.COMMANDER: 1,
        PieceKind.ARMY_COMMANDER: 1,
        PieceKind.DIVISION_COMMANDER: 2,
        PieceKind.BRIGADE_COMMANDER: 2,
        PieceKind.REGIMENT_COMMANDER: 2,
        PieceKind.BATTALION_COMMANDER: 2,
        PieceKind.COMPANY_COMMANDER: 3,
        PieceKind.PLATOON_COMMANDER: 3,
        PieceKind.ENGINEER: 3,
        PieceKind.MINE: 3,
        PieceKind.BOMB: 2,
        PieceKind.FLAG: 1,
    }
    assert rules.counts == expected
    assert sum(rules.counts.values()) == 25
    assert len(rules.initial_pieces()) == 50
    for color in Color:
        pieces = [piece for piece in rules.initial_pieces() if piece.color is color]
        assert len(pieces) == 25


def test_ranks_are_strictly_ordered(rules: Rules) -> None:
    ordered = [
        PieceKind.COMMANDER,
        PieceKind.ARMY_COMMANDER,
        PieceKind.DIVISION_COMMANDER,
        PieceKind.BRIGADE_COMMANDER,
        PieceKind.REGIMENT_COMMANDER,
        PieceKind.BATTALION_COMMANDER,
        PieceKind.COMPANY_COMMANDER,
        PieceKind.PLATOON_COMMANDER,
        PieceKind.ENGINEER,
    ]
    ranks = [rules.ranks[kind] for kind in ordered]
    assert ranks == sorted(ranks, reverse=True)
    assert len(set(ranks)) == len(ranks)


def test_combat_matrix(rules: Rules) -> None:
    red_commander = Piece(Color.RED, PieceKind.COMMANDER)
    red_army = Piece(Color.RED, PieceKind.ARMY_COMMANDER)
    black_commander = Piece(Color.BLACK, PieceKind.COMMANDER)
    black_army = Piece(Color.BLACK, PieceKind.ARMY_COMMANDER)
    black_engineer = Piece(Color.BLACK, PieceKind.ENGINEER)
    black_mine = Piece(Color.BLACK, PieceKind.MINE)
    black_bomb = Piece(Color.BLACK, PieceKind.BOMB)
    black_flag = Piece(Color.BLACK, PieceKind.FLAG)

    assert rules.resolve_combat(red_commander, black_army) is CombatResult.ATTACKER_WINS
    assert rules.resolve_combat(red_army, black_commander) is CombatResult.DEFENDER_WINS
    assert rules.resolve_combat(red_commander, black_commander) is CombatResult.BOTH_DIE
    assert rules.resolve_combat(red_commander, black_engineer) is CombatResult.ATTACKER_WINS
    assert rules.resolve_combat(black_engineer, red_commander) is CombatResult.DEFENDER_WINS

    # 地雷：只有工兵能挖、炸弹能炸，其他棋子不能主动碰。
    assert rules.resolve_combat(black_engineer, black_mine) is CombatResult.ILLEGAL
    assert rules.resolve_combat(
        Piece(Color.RED, PieceKind.ENGINEER), black_mine
    ) is CombatResult.ATTACKER_WINS
    assert rules.resolve_combat(red_commander, black_mine) is CombatResult.ILLEGAL
    assert rules.resolve_combat(
        Piece(Color.RED, PieceKind.BOMB), black_mine
    ) is CombatResult.BOTH_DIE

    # 炸弹与任何棋子同归于尽。
    for defender in (
        black_commander,
        black_engineer,
        black_mine,
        black_flag,
    ):
        assert rules.resolve_combat(
            Piece(Color.RED, PieceKind.BOMB), defender
        ) is CombatResult.BOTH_DIE

    # 军旗：雷未挖光不能碰；雷挖光后任何棋子可扛，炸弹同归于尽但仍算夺旗。
    assert rules.resolve_combat(
        red_commander, black_flag, defender_mines_remaining=1
    ) is CombatResult.ILLEGAL
    assert rules.resolve_combat(
        red_commander, black_flag, defender_mines_remaining=0
    ) is CombatResult.ATTACKER_WINS
    assert rules.resolve_combat(
        Piece(Color.RED, PieceKind.BOMB),
        black_flag,
        defender_mines_remaining=0,
    ) is CombatResult.BOTH_DIE

    # 行营安全岛：敌方棋子不能吃行营里的子。
    assert rules.resolve_combat(
        red_commander, black_army, defender_in_camp=True
    ) is CombatResult.ILLEGAL


def test_camp_safe_can_be_disabled(rules: Rules) -> None:
    disabled = replace(rules, flags={**rules.flags, "campSafe": False})
    assert disabled.resolve_combat(
        Piece(Color.RED, PieceKind.COMMANDER),
        Piece(Color.BLACK, PieceKind.ARMY_COMMANDER),
        defender_in_camp=True,
    ) is CombatResult.ATTACKER_WINS


def test_first_move_after_flip(rules: Rules) -> None:
    assert rules.first_move_after_flip() == "opponent"
    flipper = replace(
        rules, flags={**rules.flags, "firstMoveAfterFlip": "flipper"}
    )
    assert flipper.first_move_after_flip() == "flipper"
    broken = replace(
        rules, flags={**rules.flags, "firstMoveAfterFlip": "nobody"}
    )
    with pytest.raises(RulesError):
        broken.first_move_after_flip()


def test_rules_json_is_valid_and_versioned(rules: Rules) -> None:
    path = Path(__file__).resolve().parents[2] / "shared" / "rules" / "rules.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["rulesVersion"] == rules.version
    assert data["repetition"]["windowMoves"] == rules.repetition_window_moves
    assert data["repetition"]["maxRepeats"] == rules.repetition_max_repeats
    assert data["draw"]["noCapturePlies"] == rules.draw_no_capture_plies
    assert data["draw"]["maxPlies"] == rules.draw_max_plies


def test_invalid_counts_are_rejected(rules: Rules) -> None:
    path = Path(__file__).resolve().parents[2] / "shared" / "rules" / "rules.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["pieces"]["mine"] = 2
    with pytest.raises(RulesError):
        Rules.from_dict(data)


def test_unknown_piece_kind_is_rejected(rules: Rules) -> None:
    path = Path(__file__).resolve().parents[2] / "shared" / "rules" / "rules.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["pieces"]["dragon"] = 1
    with pytest.raises(RulesError):
        Rules.from_dict(data)


def test_piece_helpers() -> None:
    piece = Piece(Color.RED, PieceKind.ENGINEER)
    assert piece.rank == 1
    assert piece.is_movable
    assert piece.value > 0
    assert not Piece(Color.RED, PieceKind.MINE).is_movable
    assert not Piece(Color.RED, PieceKind.FLAG).is_movable
