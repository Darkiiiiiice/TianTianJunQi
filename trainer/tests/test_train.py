from wgai.train import classification_metrics


def test_classification_metrics_confusion_and_per_class():
    classes = ("empty", "hidden", "revealed")
    y_true = [0, 0, 1, 1, 2]
    y_pred = [0, 1, 1, 2, 2]

    metrics = classification_metrics(y_true, y_pred, classes)

    assert metrics["accuracy"] == 0.6
    assert metrics["samples"] == 5
    assert metrics["confusionMatrix"] == [[1, 1, 0], [0, 1, 1], [0, 0, 1]]

    by_class = {item["class"]: item for item in metrics["perClass"]}
    assert by_class["empty"]["support"] == 2
    assert by_class["empty"]["recall"] == 0.5
    assert by_class["empty"]["precision"] == 1.0
    assert by_class["revealed"]["recall"] == 1.0
    assert by_class["revealed"]["precision"] == 0.5
    assert by_class["revealed"]["f1"] == 0.6667
    # hidden 预测 2 次、命中 1 次
    assert by_class["hidden"]["predicted"] == 2
    assert by_class["hidden"]["precision"] == 0.5

    assert metrics["topConfusions"][0] == {"true": "empty", "predicted": "hidden", "count": 1}


def test_classification_metrics_handles_missing_class():
    metrics = classification_metrics([0, 0], [0, 0], ("empty", "hidden"))
    by_class = {item["class"]: item for item in metrics["perClass"]}
    assert by_class["hidden"]["support"] == 0
    assert by_class["hidden"]["precision"] == 0.0
    assert by_class["hidden"]["recall"] == 0.0
