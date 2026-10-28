"""Episode 读取与回放校验（M2-6 / M2-10）。

支持两类 episode：

1. **模拟器 episode**：带 `sim.json`（seed / firstPlayer / rulesVersion）。
   可以完整重放：逐动作重建引擎、比对动作前状态、动作结果和终局。
2. **真实录制 episode**：没有 seed，只有 `states.jsonl` / `actions.jsonl`。
   只做“可见状态转移”校验：翻牌格必须从 hidden 变 revealed；走棋源格必须
   是己方明子；吃子/阵亡/同归于尽后的格子占用必须与动作记录一致。

真实录制的动作既支持模拟器的 `kind/from/to` 格式，也支持
`shared/schema/action.schema.json` 的 `{"type":"tap_cell","cell":N}`；
后者用动作前状态里的 `selected` 推断走棋起点。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from .engine import Flip, GameEngine, Move, Phase
from .rules import Rules


class ReplayError(ValueError):
    pass


@dataclass
class LoadedEpisode:
    path: Path
    meta: dict
    sim: dict | None
    states: list[dict]
    actions: list[dict]
    reward: dict | None

    @property
    def episode_id(self) -> str:
        return str(self.meta.get("id", self.path.name))

    @property
    def is_simulated(self) -> bool:
        return self.sim is not None


@dataclass
class ReplayReport:
    path: Path
    episode_id: str
    ok: bool = True
    simulated: bool = False
    rules_version: str | None = None
    plies: int = 0
    outcome: str | None = None
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, message: str) -> None:
        self.ok = False
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def summary(self) -> str:
        status = "OK" if self.ok else "FAILED"
        kind = "sim" if self.simulated else "recorded"
        return (
            f"{status} {self.episode_id} ({kind}, {self.plies} plies, "
            f"{self.outcome or '?'})"
        )


# -- 读取 -----------------------------------------------------------------


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ReplayError(f"缺少文件：{path}") from error
    except json.JSONDecodeError as error:
        raise ReplayError(f"JSON 解析失败：{path}：{error}") from error
    if not isinstance(data, dict):
        raise ReplayError(f"顶层不是对象：{path}")
    return data


def _read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        raise ReplayError(f"缺少文件：{path}")
    rows: list[dict] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ReplayError(f"JSONL 解析失败：{path}:{number}：{error}") from error
        if not isinstance(row, dict):
            raise ReplayError(f"JSONL 行不是对象：{path}:{number}")
        rows.append(row)
    return rows


def load_episode(path: str | Path) -> LoadedEpisode:
    directory = Path(path).expanduser()
    if directory.is_file():
        directory = directory.parent
    if not directory.is_dir():
        raise ReplayError(f"episode 目录不存在：{directory}")
    meta = _read_json(directory / "meta.json")
    sim_path = directory / "sim.json"
    sim = _read_json(sim_path) if sim_path.is_file() else None
    states = _read_jsonl(directory / "states.jsonl")
    actions = _read_jsonl(directory / "actions.jsonl")
    reward_path = directory / "reward.json"
    reward = _read_json(reward_path) if reward_path.is_file() else None
    return LoadedEpisode(
        path=directory,
        meta=meta,
        sim=sim,
        states=states,
        actions=actions,
        reward=reward,
    )


# -- 校验工具 -------------------------------------------------------------


def _cell_map(state: dict) -> dict[int, dict]:
    board = state.get("board") or {}
    cells = board.get("cells") or []
    result: dict[int, dict] = {}
    for cell in cells:
        index = cell.get("i")
        if not isinstance(index, int):
            raise ReplayError("状态里有格子缺少整数 i")
        result[index] = cell
    return result


def _normalized_state(state: dict) -> dict:
    """用于严格比对的规范化：legal_actions 排序，忽略空 timers。"""
    normalized = json.loads(json.dumps(state, ensure_ascii=False))
    legal = normalized.get("legal_actions")
    if isinstance(legal, list):
        normalized["legal_actions"] = sorted(legal)
    if normalized.get("timers") is None:
        normalized.pop("timers", None)
    return normalized


def _piece_payload(piece) -> dict:
    return {"color": piece.color.value, "piece": piece.kind.value}


def _payload_piece(payload: dict) -> tuple[str | None, str | None]:
    return payload.get("color"), payload.get("piece")


def _compare_piece_lists(
    report: ReplayReport,
    label: str,
    actual: list[dict],
    expected: list[dict],
    *,
    strict: bool,
) -> None:
    actual_pairs = [_payload_piece(item) for item in actual]
    expected_pairs = [_payload_piece(item) for item in expected]
    if not actual_pairs and not expected_pairs:
        return
    if sorted(actual_pairs) != sorted(expected_pairs):
        message = f"{label} 不一致：实际 {actual_pairs}，记录 {expected_pairs}"
        if strict:
            report.error(message)
        else:
            report.warn(message)


def _infer_action(before: dict, action: dict) -> dict | None:
    """把模拟器动作或 tap_cell 统一成 {kind, cell, from, to}。"""
    if action.get("kind") in ("flip", "move"):
        return action
    if action.get("type") == "tap_cell":
        cell = action.get("cell")
        if not isinstance(cell, int):
            return None
        cells = _cell_map(before)
        target = cells.get(cell)
        if target is None:
            return None
        source = before.get("selected")
        if isinstance(source, int):
            # 已选中棋子时点任意目标格都是走棋/攻击；目标可能是暗子。
            return {"kind": "move", "from": source, "to": cell, "cell": cell}
        if target.get("state") == "hidden":
            return {"kind": "flip", "cell": cell}
        return None
    return None


def _validate_visible_transition(
    report: ReplayReport,
    before: dict,
    after: dict,
    action: dict,
    *,
    strict: bool,
) -> None:
    before_cells = _cell_map(before)
    after_cells = _cell_map(after)
    kind = action.get("kind")
    if kind == "flip":
        cell = action.get("cell")
        if not isinstance(cell, int):
            report.error("翻牌动作缺少 cell")
            return
        old = before_cells.get(cell, {})
        new = after_cells.get(cell, {})
        if old.get("state") != "hidden":
            report.error(f"翻牌格 {cell} 在动作前不是 hidden：{old.get('state')}")
        if new.get("state") != "revealed":
            report.error(f"翻牌格 {cell} 在动作后不是 revealed：{new.get('state')}")
        revealed = action.get("revealed") or []
        if len(revealed) == 1:
            color, piece = _payload_piece(revealed[0])
            if (new.get("color"), new.get("piece")) != (color, piece):
                report.error(
                    f"翻牌格 {cell} 记录为 {color}/{piece}，"
                    f"状态为 {new.get('color')}/{new.get('piece')}"
                )
    elif kind == "move":
        source = action.get("from")
        target = action.get("to", action.get("cell"))
        if not isinstance(source, int) or not isinstance(target, int):
            report.error("走棋动作缺少 from/to")
            return
        old_source = before_cells.get(source, {})
        new_source = after_cells.get(source, {})
        old_target = before_cells.get(target, {})
        new_target = after_cells.get(target, {})
        if old_source.get("state") != "revealed":
            report.error(f"走棋源格 {source} 不是明子：{old_source.get('state')}")
            return
        color = action.get("color")
        if color and old_source.get("color") != color:
            report.error(
                f"走棋源格 {source} 颜色 {old_source.get('color')} "
                f"与动作颜色 {color} 不一致"
            )

        source_empty = new_source.get("state") == "empty"
        target_empty = new_target.get("state") == "empty"
        board_unchanged = (
            new_source.get("state") == old_source.get("state")
            and new_source.get("piece") == old_source.get("piece")
            and new_target.get("state") == old_target.get("state")
            and new_target.get("piece") == old_target.get("piece")
        )
        if board_unchanged:
            # 真实录制里可能把“点选己方棋子”也记成 tap_cell；它不改变棋盘。
            report.warn(f"动作 {action} 未改变棋盘，按选中/无效点击跳过")
            return

        # 同色暗子/雷未挖光的军旗：只翻开，双方留在原地。
        reveal_only = (
            old_target.get("state") == "hidden"
            and new_target.get("state") == "revealed"
            and new_source.get("state") == "revealed"
        )
        if reveal_only:
            if new_source.get("piece") != old_source.get("piece"):
                report.error(f"翻开暗子后源格 {source} 棋子发生变化")
            if action.get("combat") not in (None, ""):
                report.warn(
                    f"翻开暗子通常不产生战斗，但记录 combat={action.get('combat')}"
                )
            return

        combat = action.get("combat")
        if source_empty and target_empty:
            # 同归于尽；真实 tap_cell 录制可能没有 combat 字段。
            if combat not in (None, "", "both_die"):
                report.error(
                    f"源格和目标格都为空，但记录 combat={combat}"
                )
            return
        if source_empty:
            # 目标格留下棋子：进攻方胜或防守方胜。
            if combat == "both_die":
                report.error(f"记录为同归于尽，但目标格 {target} 仍有棋子")
            elif combat == "attacker_wins" and color:
                if new_target.get("color") != color:
                    report.error(
                        f"进攻方获胜后目标格 {target} 颜色 "
                        f"{new_target.get('color')} 与动作颜色 {color} 不一致"
                    )
            elif combat == "defender_wins" and color:
                if new_target.get("color") == color:
                    report.error(
                        f"防守方获胜后目标格 {target} 仍是动作颜色 {color}"
                    )
            elif combat not in (None, "", "attacker_wins", "defender_wins"):
                report.warn(f"未知 combat：{combat}")
            return

        # 源格仍有棋子：只可能是翻开暗子，或录制到了选中/非法点击。
        report.error(
            f"走棋后源格 {source} 仍有棋子（{new_source.get('state')}），"
            f"目标格 {target} 为 {new_target.get('state')}"
        )
    else:
        report.warn(f"跳过非棋盘动作：{action}")


# -- 严格重放 -------------------------------------------------------------


def _replay_simulated(
    episode: LoadedEpisode,
    report: ReplayReport,
    rules: Rules,
) -> None:
    assert episode.sim is not None
    seed = episode.sim.get("seed")
    first_player = int(episode.sim.get("firstPlayer", 0))
    engine = GameEngine(rules, seed=seed, first_player=first_player)
    for index, action in enumerate(episode.actions):
        if engine.phase is Phase.OVER:
            report.error(f"动作 {index + 1} 出现在对局结束之后")
            return
        player = engine.turn
        expected_state = _normalized_state(engine.state_dict(player))
        if index < len(episode.states):
            recorded_state = _normalized_state(episode.states[index])
            if recorded_state != expected_state:
                report.error(
                    f"动作 {index + 1} 前状态不一致："
                    f"重放 {expected_state.get('turn')} vs "
                    f"记录 {recorded_state.get('turn')}"
                )
                return
        parsed = _infer_action(episode.states[index] if index < len(episode.states) else {}, action)
        if parsed is None:
            report.error(f"动作 {index + 1} 无法解析：{action}")
            return
        try:
            game_action = (
                Flip(int(parsed["cell"]))
                if parsed["kind"] == "flip"
                else Move(int(parsed["from"]), int(parsed["to"]))
            )
        except (KeyError, TypeError, ValueError) as error:
            report.error(f"动作 {index + 1} 字段非法：{error}")
            return
        try:
            record = engine.apply(game_action)
        except Exception as error:  # EngineError / ValueError
            report.error(f"动作 {index + 1} 重放失败：{error}")
            return
        if action.get("combat") != (record.combat.value if record.combat else None):
            report.error(
                f"动作 {index + 1} combat 不一致："
                f"重放 {record.combat.value if record.combat else None} vs "
                f"记录 {action.get('combat')}"
            )
        _compare_piece_lists(
            report,
            f"动作 {index + 1} captured",
            [_piece_payload(piece) for piece in record.captured],
            action.get("captured") or [],
            strict=True,
        )
        _compare_piece_lists(
            report,
            f"动作 {index + 1} revealed",
            [_piece_payload(piece) for piece in record.revealed],
            action.get("revealed") or [],
            strict=True,
        )
        if action.get("outcome") not in (None, record.outcome.value):
            report.error(
                f"动作 {index + 1} outcome 不一致："
                f"重放 {record.outcome.value} vs 记录 {action.get('outcome')}"
            )
        if index + 1 < len(episode.states):
            recorded_next = _normalized_state(episode.states[index + 1])
            replayed_next = _normalized_state(engine.state_dict(engine.turn))
            if recorded_next != replayed_next:
                report.error(f"动作 {index + 1} 后状态不一致")
                return

    if len(episode.states) not in (len(episode.actions), len(episode.actions) + 1):
        report.warn(
            f"states 行数 {len(episode.states)} 与 actions 行数 "
            f"{len(episode.actions)} 不匹配"
        )
    if len(episode.states) == len(episode.actions) + 1:
        final_recorded = _normalized_state(episode.states[-1])
        final_replayed = _normalized_state(engine.state_dict(engine.turn))
        if final_recorded != final_replayed:
            report.error("终局状态不一致")
    expected_outcome = episode.sim.get("outcome")
    if expected_outcome and expected_outcome != engine.outcome.value:
        report.error(
            f"终局结果不一致：重放 {engine.outcome.value} vs sim {expected_outcome}"
        )
    if episode.reward and episode.reward.get("outcome") not in (None, engine.outcome.value):
        report.error(
            f"reward.outcome 不一致：{episode.reward.get('outcome')} vs "
            f"{engine.outcome.value}"
        )
    report.plies = engine.plies
    report.outcome = engine.outcome.value


# -- 入口 -----------------------------------------------------------------


def validate_episode(
    episode: LoadedEpisode,
    *,
    rules: Rules | None = None,
    strict: bool = True,
) -> ReplayReport:
    rules = rules or Rules.load()
    report = ReplayReport(
        path=episode.path,
        episode_id=episode.episode_id,
        simulated=episode.is_simulated,
        rules_version=(episode.sim or {}).get("rulesVersion"),
    )

    for key in ("id", "mode", "startedAt", "duration", "moves", "result"):
        if key not in episode.meta:
            report.error(f"meta.json 缺少 {key}")
    if not episode.meta.get("id"):
        report.error("meta.json 的 id 为空")
    if not episode.meta.get("mode"):
        report.error("meta.json 的 mode 为空")
    if episode.meta.get("result") not in {
        "win", "loss", "draw", "timeout", "error"
    }:
        report.error(f"meta.json 的 result 非法：{episode.meta.get('result')}")
    if not isinstance(episode.meta.get("duration"), (int, float)):
        report.error("meta.json 的 duration 不是数字")
    if not isinstance(episode.meta.get("moves"), int):
        report.error("meta.json 的 moves 不是整数")
    elif episode.meta["moves"] != len(episode.actions):
        report.warn(
            f"meta.json 的 moves={episode.meta['moves']} 与 actions 行数 "
            f"{len(episode.actions)} 不一致"
        )
    if episode.sim and episode.sim.get("rulesVersion") not in (None, rules.version):
        report.error(
            f"规则版本不一致：episode {episode.sim.get('rulesVersion')} vs "
            f"当前 {rules.version}"
        )
    if len(episode.states) < len(episode.actions):
        report.error(
            f"states 行数 {len(episode.states)} 少于 actions 行数 "
            f"{len(episode.actions)}"
        )
    if not episode.actions:
        report.warn("episode 没有动作")

    # 逐行状态结构检查。
    for index, state in enumerate(episode.states):
        if state.get("phase") not in ("playing", "result"):
            report.error(f"状态 {index} 的 phase 非法：{state.get('phase')}")
        if state.get("turn") not in ("red", "black"):
            report.error(f"状态 {index} 的 turn 非法：{state.get('turn')}")
        legal = state.get("legal_actions")
        if not isinstance(legal, list) or any(
            not isinstance(cell, int) for cell in legal
        ):
            report.error(f"状态 {index} 的 legal_actions 不是整数数组")
        board = state.get("board") or {}
        if board.get("rows") != rules.board.rows or board.get("cols") != rules.board.cols:
            report.error(
                f"状态 {index} 棋盘尺寸 {board.get('rows')}x{board.get('cols')} "
                f"不是 {rules.board.rows}x{rules.board.cols}"
            )
        cells = board.get("cells") or []
        if len(cells) != rules.board.size:
            report.error(
                f"状态 {index} 格子数 {len(cells)} "
                f"不是 {rules.board.size}"
            )
        indices = [cell.get("i") for cell in cells if isinstance(cell, dict)]
        if len(indices) != len(cells) or len(set(indices)) != len(cells):
            report.error(f"状态 {index} 的格子 i 缺失或重复")
        elif any(
            not isinstance(cell, int) or not 0 <= cell < rules.board.size
            for cell in indices
        ):
            report.error(f"状态 {index} 的格子 i 越界")
        for cell in cells:
            if not isinstance(cell, dict):
                continue
            if cell.get("state") not in ("empty", "hidden", "revealed", "unknown"):
                report.error(
                    f"状态 {index} 格子 {cell.get('i')} 的 state 非法："
                    f"{cell.get('state')}"
                )

    if report.errors:
        return report

    if episode.is_simulated:
        _replay_simulated(episode, report, rules)
        return report

    # 真实录制：只校验可见转移。
    for index, action in enumerate(episode.actions):
        before = episode.states[index] if index < len(episode.states) else {}
        after = (
            episode.states[index + 1]
            if index + 1 < len(episode.states)
            else None
        )
        parsed = _infer_action(before, action)
        if parsed is None:
            report.warn(f"动作 {index + 1} 无法解析，跳过：{action}")
            continue
        if after is None:
            report.warn(f"动作 {index + 1} 没有后续状态，跳过转移校验")
            continue
        _validate_visible_transition(
            report, before, after, {**action, **parsed}, strict=strict
        )
    report.plies = len(episode.actions)
    report.outcome = (episode.reward or {}).get("outcome") or (
        episode.meta.get("result")
    )
    return report


def inspect_path(path: str | Path, *, rules: Rules | None = None, strict: bool = True) -> ReplayReport:
    episode = load_episode(path)
    return validate_episode(episode, rules=rules, strict=strict)


def find_episodes(root: str | Path) -> list[Path]:
    """找出目录下的 episode：单局目录或递归查找含 meta.json 的子目录。"""
    base = Path(root).expanduser()
    if base.is_file():
        base = base.parent
    if (base / "meta.json").is_file():
        return [base]
    if not base.is_dir():
        raise ReplayError(f"路径不存在：{base}")
    episodes = sorted(
        {
            marker.parent
            for marker in base.rglob("meta.json")
            if (marker.parent / "states.jsonl").is_file()
        }
    )
    if not episodes:
        raise ReplayError(f"目录下没有 episode：{base}")
    return episodes


def inspect_many(
    root: str | Path,
    *,
    rules: Rules | None = None,
    strict: bool = True,
) -> list[ReplayReport]:
    rules = rules or Rules.load()
    return [
        inspect_path(path, rules=rules, strict=strict)
        for path in find_episodes(root)
    ]
