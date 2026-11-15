"""Headless end-to-end GUI run: scan, screenshot, Safe Mode, quarantine, restore. usage: gui_smoke.py LIB OUTDIR"""
import os, shutil, sys, tempfile, time
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtWidgets import QApplication, QDialog
from PySide6.QtCore import QTimer
from dupesweep.config import Config
from dupesweep.engine import Cache
from dupesweep.gui import app as gui, widgets


def main():
    src, out = sys.argv[1], sys.argv[2]
    tmp = tempfile.mkdtemp(prefix="ds-gui-")
    lib = os.path.join(tmp, "Photos"); shutil.copytree(src, lib)
    cfg = Config(os.path.join(tmp, "settings.json")); cfg.quarantine_root = os.path.join(tmp, "Quarantine")
    qa = QApplication(sys.argv); qa.setStyle("Fusion")
    win = gui.MainWindow(cfg, Cache(os.path.join(tmp, "cache.sqlite")))
    win.show(); win._add_folder(lib)
    def wait(cond, secs=300):
        t = time.time()
        while not cond() and time.time() - t < secs:
            qa.processEvents(); time.sleep(0.02)
        assert cond(), "timed out"
    def shot(name):
        for _ in range(60): qa.processEvents(); time.sleep(0.02)
        win.grab().save(os.path.join(out, name))
    checks = []
    def check(ok, what): checks.append((ok, what)); print(("PASS  " if ok else "FAIL  ") + what)

    win.start_scan(); wait(lambda: win.thread is None and win.session.stats is not None and win.session.stats.valid > 0)
    s = win.session
    check(len(s.groups) >= 9, f"scan finished in the window: {len(s.groups)} groups, status: {win.status.text()[:60]}")
    shot("1_results.png")
    n0 = s.marked_count
    check(n0 > 0 and not win.q_btn.isEnabled(), "Safe Mode on: files pre-selected but Quarantine button disabled")
    try:
        s.quarantine_marked(); check(False, "Safe Mode blocks quarantine")
    except Exception as e:
        check(type(e).__name__ == "SafeModeError", "Safe Mode blocks quarantine even if called directly")
    files_before = sum(len(f) for _, _, f in os.walk(lib))
    win.mode.setCurrentIndex(1); win._fill_tree(); win.tree.setCurrentItem(win.tree.topLevelItem(0).child(0) or win.tree.topLevelItem(0)); shot("2_folders.png")
    win.mode.setCurrentIndex(0)
    # turn Safe Mode off (bypassing the question box), quarantine through the confirm dialog
    s.safe_mode = False; win._sync_safe_mode(); win.refresh_header()
    check(win.q_btn.isEnabled(), "Safe Mode off: Quarantine button enabled")
    def accept_confirm():
        d = qa.activeModalWidget()
        if isinstance(d, widgets.ConfirmDialog):
            d.grab().save(os.path.join(out, "3_confirm.png")); d.accept()
    QTimer.singleShot(400, accept_confirm); win.quarantine_selected()
    files_after = sum(len(f) for _, _, f in os.walk(lib))
    check(files_before - files_after == n0 and len(s.quarantine.items) == n0, f"{n0} selected files moved to quarantine, nothing else")
    check(all(os.path.exists(s.images[g.original].path) for g in s.groups), "every original is still in place")
    shot("4_after_quarantine.png")
    restored, failures = s.restore([i.id for i in s.quarantine.items])
    check(len(restored) == n0 and not failures and sum(len(f) for _, _, f in os.walk(lib)) == files_before, "Restore All put every file back")
    win.close(); shutil.rmtree(tmp, ignore_errors=True)
    print("ALL GUI CHECKS PASSED" if all(c[0] for c in checks) else "GUI CHECK FAILURES"); sys.exit(0 if all(c[0] for c in checks) else 1)


if __name__ == "__main__":
    main()
