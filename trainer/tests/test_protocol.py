"""协议模型骨架测试：JSON 往返 + 契约字段名。"""

import msgspec

from wgai.protocol import (
    SCHEMA_VERSION,
    Action,
    Board,
    Cell,
    Episode,
    GameState,
    LastMove,
    TapCell,
    Timers,
)


def test_game_state_roundtrip():
    state = GameState(
        board=Board(
            rows=4,
            cols=8,
            cells=[
                Cell(i=0, state="hidden"),
                Cell(i=1, state="empty"),
                Cell(i=2, state="revealed", color="red", piece="che", confidence=0.98),
            ],
        ),
        legal_actions=[3, 4, 5, 18],
        timers=Timers(me=12.3, opponent=13.1),
        last_move=LastMove(from_cell=10, to_cell=18),
    )
    encoded = msgspec.json.encode(state)
    decoded = msgspec.json.decode(encoded, type=GameState)
    assert decoded == state
    assert decoded.schema == SCHEMA_VERSION


def test_last_move_json_keys():
    data = msgspec.json.decode(
        msgspec.json.encode(LastMove(from_cell=10, to_cell=18)), type=dict
    )
    assert data == {"from": 10, "to": 18}


def test_action_tagged_union():
    actions: list[Action] = [TapCell(cell=18)]
    encoded = msgspec.json.encode(actions)
    assert b'"type":"tap_cell"' in encoded
    decoded = msgspec.json.decode(encoded, type=list[Action])
    assert decoded == actions


def test_episode_camel_case():
    ep = Episode(
        id="e1",
        mode="翻翻棋",
        started_at="2026-10-23T10:30:00+08:00",
        duration=120.5,
        moves=30,
        result="win",
    )
    assert b'"startedAt"' in msgspec.json.encode(ep)
    decoded = msgspec.json.decode(msgspec.json.encode(ep), type=Episode)
    assert decoded == ep
