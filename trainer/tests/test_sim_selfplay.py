"""自博弈与 episode 落盘：对局运行、结果换算、meta/states/actions/reward。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from wgai.sim.engine import Outcome
from wgai.sim.rules import Rules
from wgai.sim.selfplay import (
    GameResult,
    RandomAgent,
    build_agent,
    play_game,
    play_match,
    write_episode,
)


@pytest.fixture(scope="module")
def rules() -> Rules:
    return Rules.load()


def test_random_selfplay_completes(rules: Rules) -> None:
    result = play_game(rules, [RandomAgent(), RandomAgent()], seed=1)
    assert result.outcome is not Outcome.ONGOING
    assert result.plies == len(result.steps)
    assert result.plies > 0
    assert result.final_state["phase"] == "result"
    assert result.final_state["board"]["rows"] == 5
    assert len(result.final_state["board"]["cells"]) == 60


def test_result_for_player_maps_colors(rules: Rules) -> None:
    result = None
    for seed in range(30):
        candidate = play_game(rules, [RandomAgent(), RandomAgent()], seed=seed)
        if candidate.outcome is not Outcome.DRAW:
            result = candidate
            break
    if result is None:
        pytest.skip("30 局随机自博弈全是和棋")
    winner = result.winner()
    assert winner in (0, 1)
    assert result.result_for_player(winner) == "win"
    assert result.result_for_player(1 - winner) == "loss"
    assert result.score_for_player(winner) == 1
    assert result.score_for_player(1 - winner) == -1


def test_draw_scores_zero(rules: Rules) -> None:
    result = None
    for seed in range(30):
        candidate = play_game(rules, [RandomAgent(), RandomAgent()], seed=seed)
        if candidate.outcome is Outcome.DRAW:
            result = candidate
            break
    if result is None:
        pytest.skip("30 局随机自博弈没有和棋")
    assert result.winner() is None
    assert result.result_for_player(0) == "draw"
    assert result.result_for_player(1) == "draw"
    assert result.score_for_player(0) == 0


def test_play_match_seeds_and_first_player(rules: Rules) -> None:
    results = play_match(
        rules, [RandomAgent(), RandomAgent()], games=4, seed=10, first_player=0
    )
    assert len(results) == 4
    assert [result.seed for result in results] == [10, 11, 12, 13]
    assert [result.first_player for result in results] == [0, 1, 0, 1]


def test_write_episode_layout_and_schema(rules: Rules, tmp_path: Path) -> None:
    result = play_game(rules, [RandomAgent(), RandomAgent()], seed=3)
    path = write_episode(result, tmp_path / "episode", overwrite=False)

    assert (path / "meta.json").is_file()
    assert (path / "sim.json").is_file()
    assert (path / "states.jsonl").is_file()
    assert (path / "actions.jsonl").is_file()
    assert (path / "reward.json").is_file()

    meta = json.loads((path / "meta.json").read_text(encoding="utf-8"))
    assert set(meta) <= {
        "id", "mode", "startedAt", "duration", "moves", "result", "score"
    }
    assert {"id", "mode", "startedAt", "duration", "moves", "result"} <= set(meta)
    assert meta["moves"] == len(result.steps)
    assert meta["result"] in {"win", "loss", "draw", "timeout", "error"}
    assert isinstance(meta["score"], int)
    assert meta["startedAt"].endswith("Z")

    states = (path / "states.jsonl").read_text(encoding="utf-8").splitlines()
    actions = (path / "actions.jsonl").read_text(encoding="utf-8").splitlines()
    assert len(states) == len(result.steps) + 1
    assert len(actions) == len(result.steps)
    for line in states:
        state = json.loads(line)
        assert state["schema"] == 1
        assert len(state["board"]["cells"]) == 60
    for line in actions:
        action = json.loads(line)
        assert action["kind"] in {"flip", "move"}
        assert action["ply"] >= 1
        assert action["outcome"] in {outcome.value for outcome in Outcome}

    sim = json.loads((path / "sim.json").read_text(encoding="utf-8"))
    assert sim["rulesVersion"] == rules.version
    assert sim["seed"] == 3
    assert sim["plies"] == result.plies
    assert sim["outcome"] == result.outcome.value

    reward = json.loads((path / "reward.json").read_text(encoding="utf-8"))
    assert reward["outcome"] == result.outcome.value
    assert reward["rewards"]["0"] == float(result.score_for_player(0))

    with pytest.raises(FileExistsError):
        write_episode(result, path, overwrite=False)
    write_episode(result, path, overwrite=True)


def test_episode_id_and_start_time(rules: Rules, tmp_path: Path) -> None:
    result = play_game(rules, [RandomAgent(), RandomAgent()], seed=4)
    path = write_episode(
        result,
        tmp_path / "named",
        episode_id="my-episode",
        overwrite=False,
    )
    meta = json.loads((path / "meta.json").read_text(encoding="utf-8"))
    assert meta["id"] == "my-episode"


def test_build_agent() -> None:
    assert build_agent("random").name == "random"
    assert build_agent("heuristic").name == "heuristic"
    with pytest.raises(ValueError):
        build_agent("mcts")


def test_game_result_summary(rules: Rules) -> None:
    result: GameResult = play_game(
        rules, [RandomAgent(), RandomAgent()], seed=0
    )
    summary = result.summary()
    assert "agents=random vs random" in summary
    assert f"plies={result.plies}" in summary
