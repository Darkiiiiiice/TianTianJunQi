"""Episode 回放：模拟器严格重放、真实 tap_cell 可见转移校验、损坏检测。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from wgai.sim.baseline import HeuristicAgent
from wgai.sim.replay import ReplayError, inspect_path, load_episode
from wgai.sim.rules import Rules
from wgai.sim.selfplay import RandomAgent, play_game, write_episode


@pytest.fixture(scope="module")
def rules() -> Rules:
    return Rules.load()


@pytest.fixture()
def episode(rules: Rules, tmp_path: Path) -> Path:
    result = play_game(
        rules, [HeuristicAgent(), RandomAgent()], seed=2, first_player=0
    )
    return write_episode(result, tmp_path / "episode", overwrite=True)


def _read_jsonl(path: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
        encoding="utf-8",
    )


def test_load_and_strict_replay(episode: Path) -> None:
    loaded = load_episode(episode)
    assert loaded.is_simulated
    assert loaded.sim is not None
    assert loaded.meta["id"] == loaded.episode_id
    assert len(loaded.states) == len(loaded.actions) + 1
    report = inspect_path(episode)
    assert report.ok, report.errors
    assert report.simulated
    assert report.rules_version == "fanfanqi-1"
    assert report.plies == len(loaded.actions)
    assert not report.warnings


def test_missing_episode_raises(tmp_path: Path) -> None:
    with pytest.raises(ReplayError):
        inspect_path(tmp_path / "missing")


def test_tampered_state_is_detected(episode: Path) -> None:
    states = _read_jsonl(episode / "states.jsonl")
    cell = states[0]["board"]["cells"][0]
    cell["state"] = "revealed"
    cell["color"] = "red"
    cell["piece"] = "commander"
    _write_jsonl(episode / "states.jsonl", states)
    report = inspect_path(episode)
    assert not report.ok
    assert report.errors


def test_tampered_action_is_detected(episode: Path) -> None:
    actions = _read_jsonl(episode / "actions.jsonl")
    actions[0]["combat"] = "both_die"
    _write_jsonl(episode / "actions.jsonl", actions)
    report = inspect_path(episode)
    assert not report.ok
    assert any("combat" in message for message in report.errors)


def test_rules_version_mismatch_is_detected(episode: Path) -> None:
    sim = json.loads((episode / "sim.json").read_text(encoding="utf-8"))
    sim["rulesVersion"] = "fanfanqi-0"
    (episode / "sim.json").write_text(json.dumps(sim), encoding="utf-8")
    report = inspect_path(episode)
    assert not report.ok
    assert any("规则版本" in message for message in report.errors)


def test_recorded_tap_cell_episode(episode: Path, tmp_path: Path) -> None:
    """模拟 Swift 真实录制：只有 states/actions，动作是 tap_cell。"""
    target = tmp_path / "recorded"
    target.mkdir()
    (target / "meta.json").write_text(
        (episode / "meta.json").read_text(encoding="utf-8"), encoding="utf-8"
    )
    states = _read_jsonl(episode / "states.jsonl")
    actions = _read_jsonl(episode / "actions.jsonl")

    taps: list[dict] = []
    for index, action in enumerate(actions):
        if action["kind"] == "flip":
            states[index]["selected"] = None
            taps.append({"type": "tap_cell", "cell": action["cell"]})
        else:
            states[index]["selected"] = action["from"]
            taps.append({"type": "tap_cell", "cell": action["to"]})

    _write_jsonl(target / "states.jsonl", states)
    _write_jsonl(target / "actions.jsonl", taps)
    loaded = load_episode(target)
    assert not loaded.is_simulated
    report = inspect_path(target)
    assert report.ok, report.errors
    assert report.simulated is False
    assert report.plies == len(taps)


def test_recorded_episode_detects_bad_flip(episode: Path, tmp_path: Path) -> None:
    target = tmp_path / "bad-recorded"
    target.mkdir()
    (target / "meta.json").write_text(
        (episode / "meta.json").read_text(encoding="utf-8"), encoding="utf-8"
    )
    states = _read_jsonl(episode / "states.jsonl")
    actions = _read_jsonl(episode / "actions.jsonl")
    # 把第一个翻牌动作改成点一个已经翻开的格子。
    flip_index = next(
        index for index, action in enumerate(actions) if action["kind"] == "flip"
    )
    cell = actions[flip_index]["cell"]
    states[flip_index]["board"]["cells"][cell] = {
        "i": cell,
        "state": "revealed",
        "color": "red",
        "piece": "engineer",
    }
    states[flip_index]["selected"] = None
    actions[flip_index] = {"kind": "flip", "cell": cell}
    _write_jsonl(target / "states.jsonl", states)
    _write_jsonl(target / "actions.jsonl", actions)
    report = inspect_path(target)
    assert not report.ok
    assert any("不是 hidden" in message for message in report.errors)


def test_recorded_episode_skips_selection_taps(
    episode: Path, tmp_path: Path
) -> None:
    target = tmp_path / "selection"
    target.mkdir()
    meta = json.loads((episode / "meta.json").read_text(encoding="utf-8"))
    meta["id"] = "selection-taps"
    (target / "meta.json").write_text(json.dumps(meta), encoding="utf-8")

    states = _read_jsonl(episode / "states.jsonl")
    before = json.loads(json.dumps(states[0]))
    # 人为把一个格子标成己方明子，再模拟“点它选中”的 tap；前后棋盘不变。
    cell = before["board"]["cells"][1]
    cell.update({"state": "revealed", "color": "red", "piece": "engineer"})
    before["selected"] = 1
    after = json.loads(json.dumps(before))
    _write_jsonl(target / "states.jsonl", [before, after])
    _write_jsonl(
        target / "actions.jsonl", [{"type": "tap_cell", "cell": 1}]
    )
    report = inspect_path(target)
    # 选中点击只产生 warning，不阻断整局回放。
    assert report.ok
    assert any("未改变棋盘" in message for message in report.warnings)
