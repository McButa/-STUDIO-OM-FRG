"""
Directional peer comparison for measured values across equipment of the same
category, in the same evidence batch (same site visit).

WHY NOT median/MAD (the "textbook" outlier stat): I tried it first, by hand,
against the exact Global House Phitsanulok numbers before writing this file.
Insulation resistance readings were [Inv1: 20, Inv2: 0.836, Inv3: 0.867,
Inv4: 0.921, Inv5: 0.872, Inv6: 13.541] MOhm. Four of the six units read low
— so the median sits inside the LOW cluster, and a standard median/MAD
outlier test flags Inv1 and Inv6 (the two healthy units) as the "anomaly"
and leaves Inv2-5 (the actually degraded ones) alone. That is exactly
backwards, and it is precisely the kind of technically-correct-but-
engineering-wrong mistake this whole exercise is trying to eliminate.
Majority-vote statistics cannot tell you which direction is "bad" — only a
human (or a known physical direction of concern) can.

So instead: every parameter this module is used for must declare a
`bad_direction` ("low" or "high" — is a smaller or larger number the
concerning one). The comparison baseline is the BEST reading currently
observed among the peers (max, if low=bad; min, if high=bad) — i.e. "what
these units are demonstrably capable of reading right now, under today's
identical conditions." A unit is flagged when it falls meaningfully short of
that achievable baseline, regardless of whether it's in the majority or the
minority of the batch. This correctly flags Inv2-5 above (they're ~95%
below what Inv1 proves is achievable right now) and correctly leaves a
uniform "all six units read 70-90 degC" batch alone (nothing falls far
short of its peers' best, even though the absolute numbers might be high).
"""

MIN_PEERS = 4  # below this, "peer comparison" isn't statistically meaningful
DEFAULT_RELATIVE_THRESHOLD_PCT = 40.0


def compare_to_peers(readings: list, bad_direction: str, relative_threshold_pct: float = DEFAULT_RELATIVE_THRESHOLD_PCT, min_peers: int = MIN_PEERS) -> list:
    """
    readings: list of {"id": <anything>, "value": float}, all for the SAME
        parameter, SAME category, SAME evidence batch.
    bad_direction: "low" (smaller value = worse, e.g. insulation resistance)
        or "high" (larger value = worse, e.g. temperature).
    relative_threshold_pct: how far short of the best peer's reading (as a
        percentage of that reading) a unit must fall before it's flagged.
        Not an absolute engineering limit — a statement about this specific
        batch, right now: "meaningfully worse than what peers just proved is
        achievable under the same conditions."
    min_peers: fewer than this many comparable readings and peer comparison
        doesn't mean anything statistically — returns [] rather than forcing
        a comparison out of too little data.

    Returns a list of dicts (one per input reading, same order), each with
    the original keys plus: baseline, deviation_pct, is_outlier.
    Returns [] if len(readings) < min_peers.
    """
    if bad_direction not in ("low", "high"):
        raise ValueError("bad_direction must be 'low' or 'high'")
    if len(readings) < min_peers:
        return []

    values = [r["value"] for r in readings]
    baseline = max(values) if bad_direction == "low" else min(values)

    results = []
    for r in readings:
        value = r["value"]
        if baseline == 0:
            deviation_pct = 0.0
        elif bad_direction == "low":
            deviation_pct = max((baseline - value) / baseline * 100, 0.0)
        else:
            deviation_pct = max((value - baseline) / baseline * 100, 0.0)
        results.append({
            **r,
            "baseline": baseline,
            "deviation_pct": round(deviation_pct, 1),
            "is_outlier": deviation_pct >= relative_threshold_pct,
        })
    return results

