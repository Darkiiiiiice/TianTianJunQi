from wgai.cli import main


def test_unimplemented_command_returns_2():
    assert main(["train"]) == 2
    assert main(["inspect", "--input", "data/episodes/e1"]) == 2
