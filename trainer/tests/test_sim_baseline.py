"""启发式基线：动作打分、合法选择、对随机对手不落下风。"""

from __future__ import annotations

import math
import random

import pytest

from wgai.sim.baseline import HeuristicAgent, score_action
from wgai.sim.belief import UnseenPool
from wgai.sim.engine import Flip, GameEngine, Move, Phase
from wgai.sim.rules import Rules
from wgai.sim.selfplay import RandomAgent, play_game


@pytest.fixture(scope="module")
def rules() -> Rules:
    return Rules.load()


def test_score_actions_are_finite(rules: Rules) -> None:
    engine = GameEngine(rules, seed=2)
    rng = random.Random(2)
    for _ in range(15):
        observation = engine.observation(engine.turn)
        pool = UnseenPool.from_observation(observation, rules)
        for action in observation.legal_actions:
            score = score_action(observation, rules, action, pool=pool)
            assert math.isfinite(score)
        engine.apply(rng.choice(observation.legal_actions))


def test_heuristic_returns_legal_action_in_both_phases(rules: Rules) -> None:
    engine = GameEngine(rules, seed=11)
    agent = HeuristicAgent()
    rng = random.Random(11)
    action = agent.select(engine.observation(engine.turn), rules, rng)
    assert isinstance(action, Flip)
    assert action in engine.legal_actions()

    while engine.phase is not Phase.PLAY:
        engine.apply(engine.legal_actions()[0])
    action = agent.select(engine.observation(engine.turn), rules, rng)
    assert action in engine.legal_actions()


def test_heuristic_prefers_capture(rules: Rules) -> None:
    engine = GameEngine(rules, seed=5)
    rng = random.Random(5)
    while engine.phase is not Phase.PLAY:
        engine.apply(rng.choice(engine.legal_actions()))
    observation = engine.observation(engine.turn)
    pool = UnseenPool.from_observation(observation, rules)
    captures = [
        action
        for action in observation.legal_moves()
        if observation.cell(action.to_cell).state == "revealed"
        and observation.cell(action.to_cell).color is not observation.color
    ]
    if not captures:
        pytest.skip("本局开局没有可直接吃的明子")
    scores = [score_action(observation, rules, action, pool=pool) for action in captures]
    assert max(scores) > 0


def test_heuristic_never_loses_to_random(rules: Rules) -> None:
    losses = 0
    wins = 0
    for seed in range(20):
        result = play_game(
            rules,
            [HeuristicAgent(), RandomAgent()],
            seed=seed,
            first_player=seed % 2,
        )
        outcome = result.result_for_player(0)
        if outcome == "loss":
            losses += 1
        elif outcome == "win":
            wins += 1
    assert losses == 0
    assert wins > 0


def test_heuristic_avoids_repetition_with_flips(rules: Rules) -> None:
    """seed=26 曾在来回挪子之间夹翻牌，旧统计把翻牌算进窗口而误判安全。"""
    result = play_game(
        rules, [HeuristicAgent(), RandomAgent()], seed=26, first_player=0
    )
    assert result.result_for_player(0) != "loss"
