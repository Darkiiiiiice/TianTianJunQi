"""暗子信念：未翻多重集、均匀采样、确定化克隆。"""

from __future__ import annotations

import random

import pytest

from wgai.sim.belief import (
    BeliefError,
    UnseenPool,
    determinizations,
    determinize,
    hidden_cells,
)
from wgai.sim.engine import GameEngine, Phase
from wgai.sim.rules import Color, Piece, PieceKind, Rules


@pytest.fixture(scope="module")
def rules() -> Rules:
    return Rules.load()


def play_random(rules: Rules, *, seed: int, steps: int) -> GameEngine:
    engine = GameEngine(rules, seed=seed)
    rng = random.Random(seed)
    for _ in range(steps):
        if engine.phase is Phase.OVER:
            break
        engine.apply(rng.choice(engine.legal_actions()))
    return engine


def test_pool_counts_match_observation(rules: Rules) -> None:
    engine = play_random(rules, seed=3, steps=12)
    observation = engine.observation(engine.turn)
    pool = UnseenPool.from_observation(observation, rules)
    assert pool.total == observation.hidden_count
    assert pool.color_counts()[Color.RED] + pool.color_counts()[Color.BLACK] == pool.total
    for color in Color:
        for kind, count in pool.kind_counts(color).items():
            assert 0 <= count <= rules.counts[kind]
            assert (color, kind) in pool.counts or count == 0


def test_pool_can_be_empty_after_all_revealed(rules: Rules) -> None:
    engine = play_random(rules, seed=1, steps=100)
    observation = engine.observation(engine.turn)
    pool = UnseenPool.from_observation(observation, rules)
    assert pool.total == observation.hidden_count
    if observation.hidden_count == 0:
        assert pool.pieces() == []
        assert pool.probability(Color.RED, PieceKind.COMMANDER) == 0.0


def test_sample_preserves_multiset(rules: Rules) -> None:
    engine = play_random(rules, seed=4, steps=8)
    observation = engine.observation(engine.turn)
    pool = UnseenPool.from_observation(observation, rules)
    rng = random.Random(9)
    sampled = pool.sample(rng)
    assert len(sampled) == pool.total
    assert sorted((piece.color, piece.kind) for piece in sampled) == sorted(
        (piece.color, piece.kind) for piece in pool.pieces()
    )


def test_determinize_preserves_visible_and_samples_hidden(rules: Rules) -> None:
    engine = play_random(rules, seed=6, steps=14)
    player = engine.turn
    observation = engine.observation(player)
    pool = UnseenPool.from_observation(observation, rules)
    clone = determinize(engine, player, random.Random(12))

    hidden = list(hidden_cells(observation))
    assert len(hidden) == pool.total
    sampled = [clone.piece_at(index) for index in hidden]
    assert all(isinstance(piece, Piece) for piece in sampled)
    assert sorted((piece.color, piece.kind) for piece in sampled) == sorted(
        (piece.color, piece.kind) for piece in pool.pieces()
    )

    for cell in observation.cells:
        if cell.state == "empty":
            assert clone.board.is_empty(cell.index)
        elif cell.state == "revealed":
            assert clone.piece_at(cell.index) == engine.piece_at(cell.index)
            assert clone.board.is_revealed(cell.index)
        else:
            assert clone.board.is_hidden(cell.index)

    # 地雷剩余数按采样后的棋盘重算，不能沿用真实引擎的暗雷位置。
    for color in Color:
        actual = sum(
            1
            for index in range(rules.board.size)
            if (piece := clone.piece_at(index)) is not None
            and piece.kind is PieceKind.MINE
            and piece.color is color
        )
        assert clone.mines_on_board[color] == actual


def test_determinizations_are_reproducible(rules: Rules) -> None:
    engine = play_random(rules, seed=7, steps=10)
    player = engine.turn
    first = determinizations(engine, player, 3, seed=21)
    second = determinizations(engine, player, 3, seed=21)
    hidden = list(hidden_cells(engine.observation(player)))
    for left, right in zip(first, second):
        assert [left.piece_at(index) for index in hidden] == [
            right.piece_at(index) for index in hidden
        ]


def test_determinize_does_not_mutate_original(rules: Rules) -> None:
    engine = play_random(rules, seed=8, steps=6)
    before = [engine.piece_at(index) for index in range(rules.board.size)]
    determinize(engine, engine.turn, random.Random(3))
    after = [engine.piece_at(index) for index in range(rules.board.size)]
    assert before == after


def test_negative_pool_is_rejected() -> None:
    with pytest.raises(BeliefError):
        UnseenPool({(Color.RED, PieceKind.COMMANDER): -1})
