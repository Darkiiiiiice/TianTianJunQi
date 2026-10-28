"""自博弈框架：Agent 接口、随机/启发式对手、对局运行器与 episode 落盘。

设计边界（docs/微信小游戏自动游玩客户端.md §8.4）：

- Agent 只拿 `Observation` + `Rules`，不直接读真实引擎的暗子身份；
- 对局固定 seed 可复现；
- episode 目录与 Swift `StorageKit` 对齐：meta.json / states.jsonl /
  actions.jsonl / reward.json；模拟器额外写 sim.json 保存规则版本、seed、
  双方 Agent 等训练侧信息，避免污染 `meta.json` 的 schema 契约。
"""

from __future__ import annotations

import argparse
import json
import random
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol, Sequence

from .baseline import HeuristicAgent
from .engine import (
    Action,
    CombatResult,
    Flip,
    GameEngine,
    Move,
    Outcome,
    Phase,
    Piece,
)
from .rules import Color, Rules


class Agent(Protocol):
    name: str

    def select(
        self,
        observation,
        rules: Rules,
        rng: random.Random,
    ) -> Action: ...


@dataclass
class RandomAgent:
    name: str = "random"

    def select(self, observation, rules: Rules, rng: random.Random) -> Action:
        actions = observation.legal_actions
        if not actions:
            raise ValueError("没有合法动作")
        return actions[rng.randrange(len(actions))]


@dataclass(frozen=True)
class Step:
    ply: int
    player: int
    color: Color | None
    action: Action
    state: dict
    combat: CombatResult | None
    captured: tuple[Piece, ...]
    revealed: tuple[Piece, ...]
    outcome: Outcome


@dataclass
class GameResult:
    rules_version: str
    seed: int | None
    first_player: int
    outcome: Outcome
    plies: int
    colors: tuple[Color | None, Color | None]
    steps: list[Step]
    final_state: dict
    agents: tuple[str, str]
    duration: float = 0.0

    # -- 结果换算 ---------------------------------------------------------

    def winner(self) -> int | None:
        if self.outcome is Outcome.DRAW:
            return None
        winning_color = (
            Color.RED if self.outcome is Outcome.RED_WIN else Color.BLACK
        )
        for player, color in enumerate(self.colors):
            if color is winning_color:
                return player
        return None

    def result_for_player(self, player: int) -> str:
        winner = self.winner()
        if winner is None:
            return "draw"
        return "win" if winner == player else "loss"

    def score_for_player(self, player: int) -> int:
        result = self.result_for_player(player)
        return {"win": 1, "loss": -1, "draw": 0}[result]

    def summary(self) -> str:
        colors = "/".join(color.value if color else "?" for color in self.colors)
        return (
            f"{self.outcome.value} plies={self.plies} colors={colors} "
            f"agents={self.agents[0]} vs {self.agents[1]}"
        )


# -- 对局 -----------------------------------------------------------------


def play_game(
    rules: Rules,
    agents: Sequence[Agent],
    *,
    seed: int | None = None,
    first_player: int = 0,
) -> GameResult:
    if len(agents) != 2:
        raise ValueError("需要恰好两个 Agent")
    if first_player not in (0, 1):
        raise ValueError("first_player 只能是 0 或 1")

    started = time.perf_counter()
    engine = GameEngine(rules, seed=seed, first_player=first_player)
    agent_rng = random.Random(seed)
    steps: list[Step] = []

    while engine.phase is not Phase.OVER:
        player = engine.turn
        observation = engine.observation(player)
        state = engine.state_dict(player)
        action = agents[player].select(observation, rules, agent_rng)
        record = engine.apply(action)
        steps.append(
            Step(
                ply=record.ply,
                player=record.player,
                color=record.color,
                action=record.action,
                state=state,
                combat=record.combat,
                captured=record.captured,
                revealed=record.revealed,
                outcome=record.outcome,
            )
        )

    final_state = engine.state_dict(engine.turn)
    return GameResult(
        rules_version=rules.version,
        seed=seed,
        first_player=first_player,
        outcome=engine.outcome,
        plies=engine.plies,
        colors=(engine.colors[0], engine.colors[1]),
        steps=steps,
        final_state=final_state,
        agents=(agents[0].name, agents[1].name),
        duration=time.perf_counter() - started,
    )


def play_match(
    rules: Rules,
    agents: Sequence[Agent],
    games: int,
    *,
    seed: int = 0,
    first_player: int = 0,
) -> list[GameResult]:
    """跑一组固定种子对局；奇数局交换先后手，减少先手偏差。"""
    if games < 0:
        raise ValueError("games 不能为负")
    results: list[GameResult] = []
    for index in range(games):
        results.append(
            play_game(
                rules,
                agents,
                seed=seed + index,
                first_player=(first_player + index) % 2,
            )
        )
    return results


# -- Episode 落盘 ---------------------------------------------------------


def _jsonl_line(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _piece_payload(piece: Piece) -> dict:
    return {"color": piece.color.value, "piece": piece.kind.value}


def _action_payload(step: Step) -> dict:
    action = step.action
    payload = {
        "schema": 1,
        "ply": step.ply,
        "player": step.player,
        "color": step.color.value if step.color else None,
        "kind": "flip" if isinstance(action, Flip) else "move",
        "cell": action.cell if isinstance(action, Flip) else action.to_cell,
        "from": action.from_cell if isinstance(action, Move) else None,
        "to": action.to_cell if isinstance(action, Move) else None,
        "combat": step.combat.value if step.combat else None,
        "captured": [_piece_payload(piece) for piece in step.captured],
        "revealed": [_piece_payload(piece) for piece in step.revealed],
        "outcome": step.outcome.value,
    }
    return payload


def write_episode(
    result: GameResult,
    directory: str | Path,
    *,
    episode_id: str | None = None,
    overwrite: bool = False,
    started_at: datetime | None = None,
) -> Path:
    """把一局自博弈写成 episode 目录，返回目录路径。

    `meta.json` 严格按 `shared/schema/episode.schema.json` 的字段写；
    模拟器额外信息放 `sim.json`。`states.jsonl` 每行是动作前的可见状态，
    最后额外一行是终局状态；因此 `states` 行数 = `actions` 行数 + 1。
    """
    path = Path(directory)
    if path.exists() and not overwrite:
        raise FileExistsError(f"episode 目录已存在：{path}")
    path.mkdir(parents=True, exist_ok=True)

    now = started_at or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    stamp = now.astimezone(timezone.utc).strftime("%Y%m%d-%H%M%S")
    seed_part = f"-s{result.seed}" if result.seed is not None else ""
    eid = episode_id or f"sim-{stamp}{seed_part}"

    meta = {
        "id": eid,
        "mode": "翻翻棋",
        "startedAt": now.astimezone(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "duration": round(result.duration, 3),
        "moves": len(result.steps),
        "result": result.result_for_player(0),
        "score": result.score_for_player(0),
    }
    (path / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    sim = {
        "schema": 1,
        "rulesVersion": result.rules_version,
        "seed": result.seed,
        "firstPlayer": result.first_player,
        "agents": list(result.agents),
        "outcome": result.outcome.value,
        "colors": [color.value if color else None for color in result.colors],
        "plies": result.plies,
    }
    (path / "sim.json").write_text(
        json.dumps(sim, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    with (path / "states.jsonl").open("w", encoding="utf-8") as handle:
        for step in result.steps:
            handle.write(_jsonl_line(step.state) + "\n")
        handle.write(_jsonl_line(result.final_state) + "\n")

    with (path / "actions.jsonl").open("w", encoding="utf-8") as handle:
        for step in result.steps:
            handle.write(_jsonl_line(_action_payload(step)) + "\n")

    rewards = {
        "schema": 1,
        "outcome": result.outcome.value,
        "plies": result.plies,
        "rewards": {
            "0": float(result.score_for_player(0)),
            "1": float(result.score_for_player(1)),
        },
    }
    (path / "reward.json").write_text(
        json.dumps(rewards, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


# -- 命令行 ---------------------------------------------------------------


def build_agent(name: str) -> Agent:
    if name == "random":
        return RandomAgent()
    if name == "heuristic":
        return HeuristicAgent()
    raise ValueError(f"未知 Agent：{name}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="wgai.sim.selfplay",
        description="翻翻棋自博弈并写出 episode",
    )
    parser.add_argument("--games", type=int, default=1)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", required=True, help="episode 输出根目录")
    parser.add_argument("--agent0", default="heuristic")
    parser.add_argument("--agent1", default="random")
    args = parser.parse_args(argv)

    rules = Rules.load()
    agents = [build_agent(args.agent0), build_agent(args.agent1)]
    root = Path(args.out).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    for index in range(args.games):
        result = play_game(
            rules,
            agents,
            seed=args.seed + index,
            first_player=index % 2,
        )
        directory = root / f"game-{args.seed + index:06d}"
        write_episode(result, directory, overwrite=True)
        print(f"[selfplay] {directory} {result.summary()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
