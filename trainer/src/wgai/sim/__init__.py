"""翻翻棋规则引擎与模拟器（M2）。

- `board`    5×12 棋盘、行营斜线、铁路线、工兵 BFS；
- `rules`    棋子/军衔/炸弹/地雷/军旗、`rules.json` 加载与版本；
- `engine`   固定种子开局、翻牌定阵营、合法动作、吃子、胜负/和棋/重复走法；
- `belief`   暗子多重集、确定性采样、确定化引擎克隆；
- `baseline` 启发式基线（翻暗子/按军衔吃/占行营/护旗/避送子）；
- `selfplay` Agent 接口、自博弈、episode 落盘；
- `replay`   episode 读取、模拟器严格重放、真实录制可见转移校验。

规则唯一来源：`shared/rules/fanfanqi.md`；机器可读版本：`shared/rules/rules.json`。
"""

from .baseline import HeuristicAgent, HeuristicWeights, score_action
from .belief import BeliefError, UnseenPool, determinize, determinizations
from .board import Board, BoardSpec, Cell
from .engine import (
    Action,
    EngineError,
    Flip,
    GameEngine,
    Move,
    Observation,
    Outcome,
    Phase,
    play_actions,
)
from .replay import (
    LoadedEpisode,
    ReplayError,
    ReplayReport,
    find_episodes,
    inspect_many,
    inspect_path,
    load_episode,
    validate_episode,
)
from .rules import (
    PIECE_NAMES,
    PIECE_VALUES,
    RANKS,
    Color,
    CombatResult,
    Piece,
    PieceKind,
    Rules,
    RulesError,
    load_rules,
)
from .selfplay import (
    GameResult,
    RandomAgent,
    build_agent,
    play_game,
    play_match,
    write_episode,
)

__all__ = [
    "Action",
    "BeliefError",
    "Board",
    "BoardSpec",
    "Cell",
    "Color",
    "CombatResult",
    "EngineError",
    "Flip",
    "GameEngine",
    "GameResult",
    "HeuristicAgent",
    "HeuristicWeights",
    "LoadedEpisode",
    "Move",
    "Observation",
    "Outcome",
    "PIECE_NAMES",
    "PIECE_VALUES",
    "Phase",
    "Piece",
    "PieceKind",
    "RANKS",
    "RandomAgent",
    "ReplayError",
    "ReplayReport",
    "Rules",
    "RulesError",
    "UnseenPool",
    "build_agent",
    "determinize",
    "determinizations",
    "find_episodes",
    "inspect_many",
    "inspect_path",
    "load_episode",
    "load_rules",
    "play_actions",
    "play_game",
    "play_match",
    "score_action",
    "validate_episode",
    "write_episode",
]
