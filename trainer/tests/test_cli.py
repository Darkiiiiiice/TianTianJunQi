import json

from wgai.cli import main


def test_train_without_dataset_returns_2():
    assert main(["train", "--input", "/nonexistent-dataset"]) == 2


def test_inspect_missing_episode_returns_2():
    assert main(["inspect", "--input", "data/episodes/e1"]) == 2


def test_selfplay_then_inspect(tmp_path, capsys):
    root = tmp_path / "episodes"
    assert (
        main(
            [
                "selfplay",
                "--games",
                "2",
                "--seed",
                "1",
                "--out",
                str(root),
            ]
        )
        == 0
    )
    capsys.readouterr()

    episode = root / "game-000001"
    assert episode.is_dir()
    assert main(["inspect", "--input", str(episode), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is True
    assert payload["simulated"] is True
    assert payload["rulesVersion"] == "fanfanqi-1"
    assert payload["errors"] == []

    assert main(["inspect", "--input", str(root), "--json"]) == 0
    batch = json.loads(capsys.readouterr().out)
    assert batch["ok"] is True
    assert batch["count"] == 2
    assert batch["failures"] == 0
    assert {item["episode"] for item in batch["episodes"]}


def test_selfplay_unknown_agent_returns_2(tmp_path):
    assert (
        main(
            [
                "selfplay",
                "--games",
                "1",
                "--seed",
                "1",
                "--out",
                str(tmp_path),
                "--agent0",
                "mcts",
            ]
        )
        == 2
    )
