"""Grades a scan report against a generated test library's truth.json."""
import json, os
from dupesweep import grouping

ROLES = [("exact", "Exact copy, different filename"), ("resized", "Resized to smaller resolution"),
         ("tone", "Brightness & contrast changed"), ("filter", "Colour filter applied"),
         ("compressed", "Heavily JPEG-compressed"), ("png2jpg", "Converted PNG -> JPG"),
         ("webp", "Converted to WEBP"), ("heic", "Converted to HEIC"), ("crop", "Slightly cropped"),
         ("rot90", "Rotated 90 degrees"), ("rot_small", "Tilted 3 degrees + editor export"), ("nested", "Copy in nested folder")]


def evaluate(report, root):
    truth = json.load(open(os.path.join(root, "truth.json")))
    lib = os.path.join(root, "library") + os.sep
    rel = lambda i: report.images[i].path[len(lib):].replace(os.sep, "/")
    group_of, member = {}, {}
    for gi, g in enumerate(report.groups):
        for m in g.members:
            group_of[rel(m.index)], member[rel(m.index)] = gi, m
    sha = {rel(im.index): im.sha for im in report.images}
    by_role, missed, originals = {}, [], 0
    for g in truth["expect_groups"]:
        gi = group_of.get(g["original"])
        if gi is not None:
            rec = rel(report.groups[gi].recommended)
            if rec == g["original"] or (sha.get(rec) and sha.get(rec) == sha.get(g["original"])):
                originals += 1
        for m in g["members"]:
            if m == g["original"]:
                continue
            role = truth["files"][m]["role"]
            ok, tot = by_role.get(role, (0, 0))
            mm = member.get(m)
            good = gi is not None and group_of.get(m) == gi and mm.label in grouping.CONFIRMED_LABELS + (grouping.ORIGINAL,)
            by_role[role] = (ok + good, tot + 1)
            if not good:
                missed.append(f"{m} -> {mm.label if mm else 'not grouped'}")
    confirmed, flagged = [], []
    for a, b in truth["expect_separate"]:
        if a in group_of and group_of[a] == group_of.get(b):
            la, lb = member[a].label, member[b].label
            (confirmed if (la in grouping.CONFIRMED_LABELS or lb in grouping.CONFIRMED_LABELS) else flagged).append(f"{a} [{la}] + {b} [{lb}]")
    mixed, poss = [], []
    for g in report.groups:
        op = truth["files"].get(rel(g.recommended), {}).get("photo")
        for m in g.members[1:]:
            p = truth["files"].get(rel(m.index), {}).get("photo")
            if p != op:
                (mixed if m.label in grouping.CONFIRMED_LABELS else poss).append(rel(m.index))
    return {"by_role": by_role, "missed": missed, "originals": originals, "groups": len(truth["expect_groups"]),
            "neg_confirmed": confirmed, "neg_flagged": flagged, "neg_total": len(truth["expect_separate"]),
            "false_positives": mixed, "possible_other": poss}


def text(report, root):
    e = evaluate(report, root)
    lab = [m.label for g in report.groups for m in g.members]
    out = [f"Images scanned: {report.stats.valid} (skipped {len(report.stats.skipped)})",
           f"Groups: {len(report.groups)} (manual review {sum(g.manual_review for g in report.groups)})",
           f"Exact {lab.count(grouping.EXACT_DUP)} | Visual {lab.count(grouping.VISUAL)} | Edited {lab.count(grouping.EDITED)} | Possible {lab.count(grouping.POSSIBLE)}", ""]
    for k, title in ROLES:
        if k in e["by_role"]:
            ok, tot = e["by_role"][k]
            out.append(f"{title:36s} {ok}/{tot}  {'PASS' if ok == tot else 'FAIL'}")
    out += [f"{'Recommended original correct':36s} {e['originals']}/{e['groups']}",
            f"Look-alike pairs: {e['neg_total']} total, {len(e['neg_flagged'])} shown as possible only, {len(e['neg_confirmed'])} wrongly confirmed",
            f"False positives (confirmed, different photo): {len(e['false_positives'])}",
            f"Possible matches of a different photo: {len(e['possible_other'])}"]
    out += [f"  ! {x}" for x in e["neg_confirmed"] + e["false_positives"]] + [f"  - missed: {x}" for x in e["missed"]]
    out.append(f"Time: {report.stats.seconds:.1f}s  " + "  ".join(f"{n.split()[0]} {t:.1f}s" for n, t in report.stats.stage_seconds))
    out.append(f"pairs screened {report.stats.pairs_screened}, candidates {report.stats.candidates}, validated {report.stats.validated}, cache hits {report.stats.cache_hits}/{report.stats.discovered}")
    return "\n".join(out)


if __name__ == "__main__":
    import sys
    from dupesweep.engine import ScanEngine, Cache
    from dupesweep.matcher import Settings
    root = sys.argv[1]
    cache = Cache(sys.argv[2]) if len(sys.argv) > 2 else None
    r = ScanEngine(Settings(), cache).run([(os.path.join(root, "library"), True)])
    print(text(r, root))
