"""shared/ 契约文件骨架测试：schema 可解析、game profile 可加载。"""

import json
import pathlib

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMA_DIR = REPO_ROOT / "shared" / "schema"


def test_all_schemas_parse():
    files = sorted(SCHEMA_DIR.glob("*.schema.json"))
    assert [f.name for f in files] == [
        "action.schema.json",
        "episode.schema.json",
        "game_state.schema.json",
        "manifest.schema.json",
        "model.schema.json",
    ]
    for path in files:
        data = json.loads(path.read_text())
        assert data["$schema"] == "https://json-schema.org/draft/2020-12/schema"
        assert "title" in data


def test_game_profile_parses():
    data = yaml.safe_load(
        (REPO_ROOT / "shared" / "game-profiles" / "tiantian-junqi.yaml").read_text()
    )
    assert data["game"] == "天天军棋"
    assert data["mode"] == "翻翻棋"
    assert "com.tencent.xinWeChat" in data["window"]["ownerBundleIDs"]
    assert "天天军棋" in data["window"]["titleContains"]
    assert data["opponent"]["default"] in {"aiPractice", "quickMatch", "friendRoom"}
    assert data["board"]["rows"] > 0
    assert data["board"]["cols"] > 0
