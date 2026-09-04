import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.peer_comparison import compare_to_peers


def test_returns_empty_below_min_peers():
    readings = [{"id": "A", "value": 1.0}, {"id": "B", "value": 2.0}]
    assert compare_to_peers(readings, bad_direction="low") == []


def test_global_house_case_flags_the_actually_degraded_units_not_the_healthy_ones():
    """The exact numbers from the real Global House Phitsanulok report. Four of
    six units read low (0.836-0.921) and two read healthy (13.541, 20.0). A
    median/MAD outlier test would flag the two healthy units as the anomaly,
    because they're the numeric minority. This must flag the four degraded
    ones instead, regardless of which side is the majority."""
    readings = [
        {"id": "Inv1", "value": 20.000},
        {"id": "Inv2", "value": 0.836},
        {"id": "Inv3", "value": 0.867},
        {"id": "Inv4", "value": 0.921},
        {"id": "Inv5", "value": 0.872},
        {"id": "Inv6", "value": 13.541},
    ]
    results = compare_to_peers(readings, bad_direction="low")
    flagged = {r["id"] for r in results if r["is_outlier"]}
    assert flagged == {"Inv2", "Inv3", "Inv4", "Inv5"}
    assert "Inv1" not in flagged and "Inv6" not in flagged


def test_uniformly_high_readings_are_not_flagged_when_all_peers_agree():
    """Global House Phitsanulok temperature scenario, generalized: if a
    quirk of this equipment model means every unit normally reads 70-90 degC,
    peer comparison must not manufacture an alarm just because the absolute
    numbers look high — nothing here falls short of what its peers show."""
    readings = [
        {"id": f"Inv{i}", "value": v}
        for i, v in enumerate([70, 75, 80, 85, 88, 90], start=1)
    ]
    results = compare_to_peers(readings, bad_direction="high")
    assert all(not r["is_outlier"] for r in results)


def test_single_genuine_outlier_among_healthy_peers_is_flagged():
    readings = [
        {"id": "Inv1", "value": 20.0},
        {"id": "Inv2", "value": 19.5},
        {"id": "Inv3", "value": 0.5},   # the one bad apple
        {"id": "Inv4", "value": 18.9},
    ]
    results = compare_to_peers(readings, bad_direction="low")
    flagged = {r["id"] for r in results if r["is_outlier"]}
    assert flagged == {"Inv3"}


def test_high_bad_direction_flags_the_hottest_unit():
    readings = [
        {"id": "Inv1", "value": 45.0},
        {"id": "Inv2", "value": 48.0},
        {"id": "Inv3", "value": 47.0},
        {"id": "Inv4", "value": 95.0},  # runs much hotter than its peers
    ]
    results = compare_to_peers(readings, bad_direction="high")
    flagged = {r["id"] for r in results if r["is_outlier"]}
    assert flagged == {"Inv4"}


def test_zero_baseline_does_not_crash():
    readings = [{"id": f"U{i}", "value": 0.0} for i in range(5)]
    results = compare_to_peers(readings, bad_direction="low")
    assert all(r["deviation_pct"] == 0.0 and not r["is_outlier"] for r in results)


def test_invalid_bad_direction_raises():
    import pytest
    with pytest.raises(ValueError):
        compare_to_peers([{"id": "A", "value": 1.0}] * 4, bad_direction="sideways")


def test_relative_threshold_is_tunable():
    readings = [
        {"id": "Inv1", "value": 20.0},
        {"id": "Inv2", "value": 15.0},  # 25% below baseline
        {"id": "Inv3", "value": 19.0},
        {"id": "Inv4", "value": 18.0},
    ]
    # default 40% threshold: 25% shortfall should NOT be flagged
    default_results = compare_to_peers(readings, bad_direction="low")
    assert not any(r["is_outlier"] for r in default_results if r["id"] == "Inv2")
    # a stricter 20% threshold: the same 25% shortfall SHOULD be flagged
    strict_results = compare_to_peers(readings, bad_direction="low", relative_threshold_pct=20.0)
    assert [r for r in strict_results if r["id"] == "Inv2"][0]["is_outlier"] is True

