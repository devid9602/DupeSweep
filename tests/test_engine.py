"""Detection accuracy on every required scenario, and the cache."""
import os

from dupesweep import grouping
from dupesweep.engine import Cache, Control, ScanEngine
from dupesweep.matcher import Settings
from tests.evaluate import ROLES, evaluate


def test_every_scenario_is_detected(scan, library):
    report, _ = scan
    e = evaluate(report, library)
    for role, title in ROLES:
        ok, total = e["by_role"][role]
        assert ok == total, f"{title}: {ok}/{total} – missed {e['missed']}"


def test_recommended_original_is_the_camera_file(scan, library):
    e = evaluate(scan[0], library)
    assert e["originals"] == e["groups"]


def test_no_false_positives(scan, library):
    e = evaluate(scan[0], library)
    assert e["false_positives"] == []
    assert e["neg_confirmed"] == [], "different photographs with similar backgrounds were confirmed as duplicates"


def test_uncertain_matches_are_never_preselected(scan):
    from dupesweep.engine import auto_marks
    report, _ = scan
    for g in report.groups:
        marks = auto_marks(g)
        assert g.original not in marks
        for m in g.members:
            if m.label == grouping.POSSIBLE or g.manual_review:
                assert m.index not in marks


def test_corrupt_file_is_skipped(scan):
    assert any(p.endswith("broken.jpg") for p, _ in scan[0].stats.skipped)


def test_rescan_uses_cache_and_gives_same_groups(scan, library):
    report, cache_path = scan
    again = ScanEngine(Settings(), Cache(cache_path)).run([(os.path.join(library, "library"), True)])
    assert again.stats.cache_hits == again.stats.discovered
    assert len(again.groups) == len(report.groups)
    assert sorted(len(g.members) for g in again.groups) == sorted(len(g.members) for g in report.groups)


def test_exact_only_mode(library):
    r = ScanEngine(Settings(find_similar=False)).run([(os.path.join(library, "library"), True)])
    labels = {m.label for g in r.groups for m in g.members}
    assert labels <= {grouping.ORIGINAL, grouping.EXACT_DUP}
    assert sum(m.label == grouping.EXACT_DUP for g in r.groups for m in g.members) == 8


def test_non_recursive_scan_and_cancel(library):
    lib = os.path.join(library, "library")
    r = ScanEngine(Settings()).run([(lib, False)])
    assert r.stats.discovered == 0                      # no images directly in the root folder
    c = Control()
    c.cancel()
    r = ScanEngine(Settings()).run([(lib, True)], c)
    assert r.cancelled and r.groups == []


def test_scan_does_not_modify_the_library(library, scan):
    lib = os.path.join(library, "library")
    before = {os.path.join(d, f): os.stat(os.path.join(d, f)).st_mtime_ns for d, _, fs in os.walk(lib) for f in fs}
    ScanEngine(Settings()).run([(lib, True)])
    after = {os.path.join(d, f): os.stat(os.path.join(d, f)).st_mtime_ns for d, _, fs in os.walk(lib) for f in fs}
    assert before == after
