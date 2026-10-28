from wgai.cli import main


def test_train_without_dataset_returns_2():
    assert main(["train", "--input", "/nonexistent-dataset"]) == 2


def test_unimplemented_command_returns_2():
    assert main(["inspect", "--input", "data/episodes/e1"]) == 2
