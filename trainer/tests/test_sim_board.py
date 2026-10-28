"""棋盘几何：5×12、10 个行营、对称邻接、铁路直线与工兵转弯。"""

from __future__ import annotations

import pytest

from wgai.sim.board import Board, BoardSpec
from wgai.sim.rules import Rules


@pytest.fixture(scope="module")
def rules() -> Rules:
    return Rules.load()


def test_board_shape_and_camps(rules: Rules) -> None:
    spec = rules.board
    assert (spec.rows, spec.cols) == (5, 12)
    assert spec.size == 60
    assert len(spec.camps) == 10
    assert {spec.coord(index) for index in spec.camps} == {
        (1, 2), (1, 4), (2, 3), (3, 2), (3, 4),
        (1, 7), (1, 9), (2, 8), (3, 7), (3, 9),
    }


def test_neighbors_are_symmetric(rules: Rules) -> None:
    spec = rules.board
    for index in range(spec.size):
        for neighbor in spec.neighbors(index):
            assert index in spec.neighbors(neighbor), (index, neighbor)


def test_camp_uses_only_diagonal_roads(rules: Rules) -> None:
    spec = rules.board
    camp = spec.index(1, 2)
    assert set(spec.neighbors(camp)) == {
        spec.index(0, 1),
        spec.index(0, 3),
        spec.index(2, 1),
        spec.index(2, 3),
    }
    # 行营与正上/正下/正左/正右的普通格之间没有公路。
    for row, col in ((0, 2), (2, 2), (1, 1), (1, 3)):
        assert spec.index(row, col) not in spec.neighbors(camp)


def test_ordinary_cell_reaches_camp_diagonally(rules: Rules) -> None:
    spec = rules.board
    ordinary = spec.index(0, 1)
    camp = spec.index(1, 2)
    assert camp in spec.neighbors(ordinary)
    # 普通格仍然只走上下左右；斜线只连行营。
    assert spec.index(1, 1) in spec.neighbors(ordinary)
    assert spec.index(1, 2) in spec.neighbors(ordinary)
    assert spec.index(1, 0) not in spec.neighbors(ordinary)


def test_railway_lines(rules: Rules) -> None:
    spec = rules.board
    assert spec.is_railway(spec.index(0, 5))
    assert spec.is_railway(spec.index(4, 5))
    assert spec.is_railway(spec.index(2, 1))
    assert spec.is_railway(spec.index(2, 5))
    assert spec.is_railway(spec.index(2, 6))
    assert spec.is_railway(spec.index(2, 10))
    assert not spec.is_railway(spec.index(1, 0))
    assert not spec.is_railway(spec.index(2, 2))


def test_railway_slides_are_straight_lines(rules: Rules) -> None:
    spec = rules.board
    slides = list(spec.railway_slides(spec.index(2, 5)))
    assert len(slides) == 2  # 纵向铁路，上下各一条
    up, down = slides
    assert up == (spec.index(1, 5), spec.index(0, 5))
    assert down == (spec.index(3, 5), spec.index(4, 5))

    slides = list(spec.railway_slides(spec.index(0, 5)))
    assert len(slides) == 4  # 横向 + 纵向交叉
    assert slides[0] == (
        spec.index(0, 4), spec.index(0, 3), spec.index(0, 2),
        spec.index(0, 1), spec.index(0, 0),
    )
    assert slides[1][0] == spec.index(0, 6)
    assert slides[2] == ()  # 已经在最上行，没有“向上”
    assert slides[3] == (
        spec.index(1, 5), spec.index(2, 5),
        spec.index(3, 5), spec.index(4, 5),
    )


def test_engineer_reachable_can_turn_at_intersection(rules: Rules) -> None:
    spec = rules.board
    start = spec.index(0, 1)
    reachable = spec.railway_reachable(
        start,
        is_blocked=lambda index: False,
        can_land=lambda index: True,
    )
    assert spec.index(2, 5) in reachable  # 从 (0,5) 转直角向下
    assert spec.index(4, 10) in reachable  # 绕到最下行再转向上


def test_engineer_reachable_cannot_pass_through_blocker(rules: Rules) -> None:
    spec = rules.board
    start = spec.index(2, 5)
    blocked = {spec.index(1, 5), spec.index(3, 5)}
    reachable = spec.railway_reachable(
        start,
        is_blocked=lambda index: index in blocked,
        can_land=lambda index: True,
    )
    assert spec.index(1, 5) in reachable  # 占位格可作为落点
    assert spec.index(3, 5) in reachable
    assert spec.index(0, 5) not in reachable  # 但不能穿过
    assert spec.index(4, 5) not in reachable


def test_board_place_move_reveal_copy(rules: Rules) -> None:
    board = Board(rules.board)
    piece = object()
    board.place(0, piece, revealed=False)
    assert board.is_hidden(0)
    assert not board.is_revealed(0)
    board.reveal(0)
    assert board.is_revealed(0)
    board.move(0, 1)
    assert board.is_empty(0)
    assert board.is_revealed(1)
    assert board.piece_at(1) is piece

    clone = board.copy()
    clone.remove(1)
    assert clone.is_empty(1)
    assert not board.is_empty(1)

    with pytest.raises(ValueError):
        board.place(1, object())
    with pytest.raises(ValueError):
        board.remove(0)


def test_board_spec_roundtrip(rules: Rules) -> None:
    spec = rules.board
    rebuilt = BoardSpec.from_dict(spec.describe())
    assert rebuilt.rows == spec.rows
    assert rebuilt.cols == spec.cols
    assert rebuilt.camps == spec.camps
    assert rebuilt.railway_rows == spec.railway_rows
    assert rebuilt.railway_cols == spec.railway_cols
    for index in range(spec.size):
        assert rebuilt.neighbors(index) == spec.neighbors(index)
