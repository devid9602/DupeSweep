"""File-safety rules: quarantine, restore, permanent delete, Safe Mode, selection."""
import csv
import hashlib
import os

import pytest

from dupesweep import grouping
from dupesweep.engine import ScanEngine
from dupesweep.matcher import Settings
from dupesweep.quarantine import QuarantineStore
from dupesweep.session import SafeModeError, Session


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def write(root, rel, n, seed):
    p = os.path.join(root, *rel.split("/"))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(bytes((i * 31 + seed) & 0xFF for i in range(n)))
    return p


def test_quarantine_restore_delete(tmp_path):
    lib, q = str(tmp_path / "Photos"), str(tmp_path / "Quarantine")
    orig = write(lib, "2023/Trip/IMG_1.jpg", 50_000, 1)
    d1 = write(lib, "2023/Trip/IMG_1 copy.jpg", 50_000, 1)
    d2 = write(lib, "Backup/फोटो यात्रा/IMG_1 (2).jpg", 50_000, 1)     # non-English folder name with spaces
    d3 = write(lib, "Backup/Deep/A/B/C/small.jpg", 20_000, 2)
    other = write(lib, "2023/Trip/keep_me.jpg", 10_000, 3)
    hashes, h_orig, h_other = [sha(d1), sha(d2), sha(d3)], sha(orig), sha(other)

    store = QuarantineStore(q)
    moved, failures = store.quarantine([(d1, 50_000, orig), (d2, 50_000, orig), (d3, 20_000, orig)])
    assert len(moved) == 3 and not failures
    assert not any(os.path.exists(p) for p in (d1, d2, d3))
    assert sha(orig) == h_orig and sha(other) == h_other                   # untouched
    assert [sha(m.quarantined_path) for m in moved] == hashes              # byte-identical
    assert len(QuarantineStore(q).items) == 3                               # manifest survives a restart

    lonely = write(lib, "Solo/dup.jpg", 1000, 9)
    moved2, failures2 = store.quarantine([(lonely, 1000, os.path.join(lib, "Solo", "missing.jpg"))])
    assert not moved2 and len(failures2) == 1 and os.path.exists(lonely)   # original missing → refused
    moved3, failures3 = store.quarantine([(orig, 50_000, orig)])
    assert not moved3 and os.path.exists(orig)                             # never the original itself

    squatter = write(lib, "2023/Trip/IMG_1 copy.jpg", 777, 5)
    h_squat = sha(squatter)
    restored, failures = store.restore([i.id for i in store.items])
    assert len(restored) == 3 and not failures
    assert sha(d2) == hashes[1] and sha(d3) == hashes[2]
    assert sha(squatter) == h_squat                                         # existing file not overwritten
    assert sha(os.path.join(lib, "2023", "Trip", "IMG_1 copy (restored).jpg")) == hashes[0]
    assert store.items == []
    assert [f for _, _, fs in os.walk(q) for f in fs if not f.endswith(".json")] == []

    moved, _ = store.quarantine([(d2, 50_000, orig), (d3, 20_000, orig)])
    deleted, failures = store.delete_permanently([moved[0].id])
    assert deleted == 1 and len(store.items) == 1 and os.path.exists(moved[1].quarantined_path)
    assert sha(orig) == h_orig


@pytest.fixture
def session(work_copy, tmp_path):
    report = ScanEngine(Settings(), workers=1).run([(work_copy, True)])
    s = Session(QuarantineStore(str(tmp_path / "Quarantine")), safe_mode=True)
    s.load(report)
    return s


def test_safe_mode_blocks_everything(session):
    assert session.marked_count > 0
    count = sum(len(f) for _, _, f in os.walk(os.path.dirname(session.images[0].path) + "/.."))
    for action in (session.quarantine_marked, session.trash_marked, lambda: session.delete_permanently([])):
        with pytest.raises(SafeModeError):
            action()
    assert count == sum(len(f) for _, _, f in os.walk(os.path.dirname(session.images[0].path) + "/.."))


def test_originals_can_never_be_selected(session):
    for g in session.groups:
        assert session.toggle(g, g.original) is False
        session.select_all(g)
        assert g.original not in g.marked
    assert all(os.path.abspath(p) != os.path.abspath(k) for p, _, k in session.marked_files())


def test_quarantine_and_restore_roundtrip(session):
    session.clear_all()
    session.select_confirmed()
    files = session.marked_files()
    hashes = {p: sha(p) for p, _, _ in files}
    originals = {session.images[g.original].path: sha(session.images[g.original].path) for g in session.groups}
    session.safe_mode = False
    moved, failures = session.quarantine_marked()
    assert len(moved) == len(files) and not failures
    assert not any(os.path.exists(p) for p in hashes)
    assert all(sha(p) == h for p, h in originals.items())                   # every original intact
    assert session.marked_count == 0
    restored, failures = session.restore([i.id for i in session.quarantine.items])
    assert len(restored) == len(files) and not failures
    assert all(sha(p) == h for p, h in hashes.items())                       # back, byte-identical


def test_changing_the_original_relabels_and_reselects(session):
    g = next(g for g in session.groups if len(g.group.members) > 3 and not g.group.manual_review)
    other = g.group.members[2].index
    session.set_original(g, other)
    assert g.original == other and g.override and other not in g.marked
    assert g.group.members[0].label == grouping.ORIGINAL
    session.reset_original(g)
    assert not g.override and g.original == g.group.recommended


def test_csv_report(session, tmp_path):
    out = str(tmp_path / "report.csv")
    session.export_csv(out)
    rows = list(csv.DictReader(open(out, encoding="utf-8-sig")))
    assert len(rows) == sum(len(g.group.members) for g in session.groups)
    assert {r["label"] for r in rows} >= {"ORIGINAL", "EXACT DUPLICATE", "EDITED VERSION"}
    assert all(r["action"].startswith("KEEP") for r in rows if r["label"] == "ORIGINAL")
