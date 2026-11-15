"""DupeSweep main window."""
from __future__ import annotations

import multiprocessing
import os
import sys

from PySide6.QtCore import Qt, QThread, QTimer, QUrl, Signal
from PySide6.QtGui import QAction, QDesktopServices, QIcon
from PySide6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDialog, QFileDialog, QFrame, QGroupBox,
                               QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow, QMenu,
                               QMessageBox, QProgressBar, QPushButton, QScrollArea, QSlider, QSplitter,
                               QToolButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

from .. import APP_NAME, __version__
from ..config import Config
from ..engine import Cache, Control, Progress, ScanEngine, default_cache_path
from ..matcher import Settings
from ..quarantine import QuarantineStore
from ..session import FILTERS, RULES, SafeModeError, Session
from .widgets import ConfirmDialog, GroupCard, QuarantineDialog, Thumbnails, duration, human_size

PAGE = 20


def resource(name: str) -> str:
    base = getattr(sys, "_MEIPASS", os.path.join(os.path.dirname(__file__), "..", ".."))
    return os.path.join(base, "assets", name)


class ScanThread(QThread):
    progress = Signal(object)
    done = Signal(object)
    failed = Signal(str)

    def __init__(self, settings, cache, roots, exclude, control):
        super().__init__()
        self.args = (settings, cache, roots, exclude, control)

    def run(self):
        settings, cache, roots, exclude, control = self.args
        try:
            engine = ScanEngine(settings, cache, exclude=exclude)
            self.done.emit(engine.run(roots, control, self.progress.emit))
        except Exception as e:      # noqa: BLE001 - show any failure instead of crashing
            import traceback
            self.failed.emit(f"{e}\n\n{traceback.format_exc()[-1500:]}")


class MainWindow(QMainWindow):
    def __init__(self, config: Config | None = None, cache: Cache | None = None):
        super().__init__()
        self.config = config or Config()
        self.cache = cache or Cache(default_cache_path())
        self.session = Session(QuarantineStore(self.config.quarantine_root), self.config.safe_mode)
        self.thumbs = Thumbnails()
        self.thread: ScanThread | None = None
        self.control: Control | None = None
        self.page = 0
        self.preferred_folder: str | None = None
        self.setWindowTitle(f"{APP_NAME} – find duplicate and edited photos")
        self.resize(1320, 840)
        if os.path.exists(resource("icon.png")):
            self.setWindowIcon(QIcon(resource("icon.png")))
        self.setAcceptDrops(True)
        self._build_menu()
        split = QSplitter()
        split.addWidget(self._build_sidebar())
        split.addWidget(self._build_results())
        split.setStretchFactor(1, 1)
        split.setSizes([350, 970])
        self.setCentralWidget(split)
        for path, rec in self.config.folders:
            self._add_folder(path, rec)
        self._sync_safe_mode()
        self.refresh()

    # ------------------------------------------------------------------ menu
    def _build_menu(self):
        mb = self.menuBar()
        f = mb.addMenu("&File")
        f.addAction("Add Folder…", self.add_folder_dialog)
        f.addAction("Export Report (CSV)…", self.export_csv)
        f.addSeparator()
        f.addAction("Quit", self.close)
        t = mb.addMenu("&Tools")
        t.addAction("Quarantine…", self.open_quarantine)
        t.addAction("Open Quarantine Folder", self.open_quarantine_folder)
        t.addAction("Change Quarantine Folder…", self.change_quarantine_folder)
        t.addSeparator()
        t.addAction("Clear Cache", self.clear_cache)
        h = mb.addMenu("&Help")
        h.addAction("How DupeSweep keeps your photos safe", self.show_safety)
        h.addAction(f"About {APP_NAME}", self.show_about)

    # --------------------------------------------------------------- sidebar
    def _build_sidebar(self) -> QWidget:
        side = QWidget()
        outer = QVBoxLayout(side)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        lay = QVBoxLayout(inner)

        box = QGroupBox("Folders to scan")
        b = QVBoxLayout(box)
        self.folder_list = QListWidget()
        self.folder_list.setMinimumHeight(110)
        self.folder_list.setToolTip("Tick = include subfolders. Drag folders here to add them.")
        b.addWidget(self.folder_list)
        row = QHBoxLayout()
        add = QPushButton("Add Folder…")
        add.clicked.connect(self.add_folder_dialog)
        rem = QPushButton("Remove")
        rem.clicked.connect(self.remove_folder)
        row.addWidget(add)
        row.addWidget(rem)
        b.addLayout(row)
        hint = QLabel("Ticked folders include their subfolders.")
        hint.setStyleSheet("font-size:11px;")
        b.addWidget(hint)
        lay.addWidget(box)

        box = QGroupBox("Matching")
        b = QVBoxLayout(box)
        note = QLabel("Exact duplicates (identical files) are always found.")
        note.setStyleSheet("font-size:11px;")
        note.setWordWrap(True)
        b.addWidget(note)
        s = self.config.settings
        self.chk_similar = QCheckBox("Also find edited, resized, converted,\ncropped or rotated versions")
        self.chk_similar.setChecked(s.find_similar)
        self.chk_rotation = QCheckBox("Detect rotated versions (90° / 180°)")
        self.chk_rotation.setChecked(s.detect_rotation)
        b.addWidget(self.chk_similar)
        b.addWidget(self.chk_rotation)
        self.adv_btn = QToolButton()
        self.adv_btn.setText("Detection thresholds")
        self.adv_btn.setCheckable(True)
        self.adv_btn.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        self.adv_btn.setArrowType(Qt.RightArrow)
        self.adv_btn.setStyleSheet("border:none;")
        b.addWidget(self.adv_btn)
        self.adv = QWidget()
        a = QVBoxLayout(self.adv)
        a.setContentsMargins(0, 0, 0, 0)
        self.sliders = {}
        for key, title, lo, hi in (("high", "High confidence (same photo)", 70, 98), ("medium", "Medium (likely – verify)", 60, 95),
                                   ("low", "Low (possible match)", 50, 90), ("max_crop", "Crop tolerance per side", 5, 35)):
            lb = QLabel()
            lb.setStyleSheet("font-size:11px;")
            sl = QSlider(Qt.Horizontal)
            sl.setRange(lo, hi)
            sl.setValue(round(getattr(s, key) * 100))
            sl.valueChanged.connect(lambda v, lb=lb, title=title: lb.setText(f"{title}: {v}%"))
            lb.setText(f"{title}: {sl.value()}%")
            a.addWidget(lb)
            a.addWidget(sl)
            self.sliders[key] = sl
        tip = QLabel("Only high-confidence matches are pre-selected. Higher thresholds = fewer, safer matches.")
        tip.setWordWrap(True)
        tip.setStyleSheet("font-size:10px;")
        a.addWidget(tip)
        reset = QPushButton("Reset to defaults")
        reset.clicked.connect(self.reset_settings)
        a.addWidget(reset)
        self.adv.setVisible(False)
        self.adv_btn.toggled.connect(lambda on: (self.adv.setVisible(on), self.adv_btn.setArrowType(Qt.DownArrow if on else Qt.RightArrow)))
        b.addWidget(self.adv)
        lay.addWidget(box)

        box = QGroupBox("Pick the original by")
        b = QVBoxLayout(box)
        self.rule = QComboBox()
        self.rule.addItems(RULES)
        self.rule.currentTextChanged.connect(self.apply_rule)
        b.addWidget(self.rule)
        self.rule_note = QLabel("Prefers highest resolution, least compression, camera EXIF and unedited files. "
                                "Unclear cases are marked MANUAL REVIEW.")
        self.rule_note.setWordWrap(True)
        self.rule_note.setStyleSheet("font-size:11px;")
        b.addWidget(self.rule_note)
        lay.addWidget(box)
        lay.addStretch(1)
        scroll.setWidget(inner)
        outer.addWidget(scroll, 1)

        self.safe = QCheckBox("Safe Mode (preview only)")
        self.safe.setStyleSheet("font-weight:bold;")
        self.safe.clicked.connect(self.toggle_safe_mode)
        outer.addWidget(self.safe)
        self.safe_note = QLabel()
        self.safe_note.setWordWrap(True)
        self.safe_note.setStyleSheet("font-size:11px;")
        outer.addWidget(self.safe_note)

        self.scan_btn = QPushButton("Scan for Duplicates")
        self.scan_btn.setStyleSheet("font-size:14px; font-weight:bold; padding:8px;")
        self.scan_btn.clicked.connect(lambda: self.start_scan())
        outer.addWidget(self.scan_btn)

        self.prog = QWidget()
        p = QVBoxLayout(self.prog)
        p.setContentsMargins(0, 0, 0, 0)
        self.stage_lb = QLabel()
        self.stage_lb.setStyleSheet("font-weight:600;")
        self.bar = QProgressBar()
        self.count_lb, self.folder_lb, self.time_lb = QLabel(), QLabel(), QLabel()
        for lb in (self.count_lb, self.folder_lb, self.time_lb):
            lb.setStyleSheet("font-size:11px;")
        row = QHBoxLayout()
        self.pause_btn = QPushButton("Pause")
        self.pause_btn.clicked.connect(self.toggle_pause)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.cancel_scan)
        row.addWidget(self.pause_btn)
        row.addStretch(1)
        row.addWidget(cancel)
        for w in (self.stage_lb, self.bar, self.count_lb, self.folder_lb, self.time_lb):
            p.addWidget(w)
        p.addLayout(row)
        self.prog.setVisible(False)
        outer.addWidget(self.prog)

        self.status = QLabel("Add a folder and click Scan. Scanning only reads your photos.")
        self.status.setWordWrap(True)
        self.status.setStyleSheet("font-size:11px;")
        self.status.setTextInteractionFlags(Qt.TextSelectableByMouse)
        outer.addWidget(self.status)
        side.setMinimumWidth(310)
        return side

    # --------------------------------------------------------------- results
    def _build_results(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        top = QHBoxLayout()
        self.summary = QLabel()
        self.summary.setStyleSheet("font-size:14px; font-weight:bold;")
        top.addWidget(self.summary)
        top.addStretch(1)
        self.mode = QComboBox()
        self.mode.addItems(["View: Groups", "View: Folders"])
        self.mode.currentIndexChanged.connect(self._mode_changed)
        top.addWidget(self.mode)
        self.q_btn = QPushButton()
        self.q_btn.setStyleSheet("QPushButton:enabled { background:#d64545; color:white; font-weight:bold; padding:6px 14px; }")
        self.q_btn.clicked.connect(self.quarantine_selected)
        top.addWidget(self.q_btn)
        lay.addLayout(top)

        bar = QHBoxLayout()
        self.filter = QComboBox()
        self.filter.addItems(FILTERS)
        self.filter.currentIndexChanged.connect(self._filters_changed)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Filter by path…")
        self.search.setMaximumWidth(240)
        self.search.textChanged.connect(self._filters_changed)
        bar.addWidget(self.filter)
        bar.addWidget(self.search)
        bar.addStretch(1)
        sel = QPushButton("Select ▾")
        menu = QMenu(sel)
        menu.addAction("Select all confirmed duplicates", lambda: (self.session.select_confirmed(), self.refresh()))
        menu.addAction("Clear all selections", lambda: (self.session.clear_all(), self.refresh()))
        sel.setMenu(menu)
        bar.addWidget(sel)
        exp = QPushButton("Export CSV…")
        exp.clicked.connect(self.export_csv)
        bar.addWidget(exp)
        self.qm_btn = QPushButton()
        self.qm_btn.clicked.connect(self.open_quarantine)
        bar.addWidget(self.qm_btn)
        self.trash_btn = QPushButton("Move to Trash…")
        self.trash_btn.clicked.connect(self.trash_selected)
        bar.addWidget(self.trash_btn)
        lay.addLayout(bar)

        body = QSplitter()
        self.tree_box = QWidget()
        tb = QVBoxLayout(self.tree_box)
        tb.setContentsMargins(0, 0, 0, 0)
        self.only_dups = QCheckBox("Only folders with duplicates")
        self.only_dups.setChecked(True)
        self.only_dups.clicked.connect(self._fill_tree)
        tb.addWidget(self.only_dups)
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["Folder", "Images", "Duplicates"])
        self.tree.setColumnWidth(0, 170)
        self.tree.setColumnWidth(1, 50)
        self.tree.itemSelectionChanged.connect(self._folder_selected)
        self.tree.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._tree_menu)
        tb.addWidget(self.tree, 1)
        row = QHBoxLayout()
        b1 = QPushButton("Select confirmed here")
        b1.setToolTip("Select the confirmed duplicates located in this folder")
        b1.clicked.connect(lambda: self._folder_select(True))
        b2 = QPushButton("Clear here")
        b2.clicked.connect(lambda: self._folder_select(False))
        row.addWidget(b1)
        row.addWidget(b2)
        tb.addLayout(row)
        self.tree_box.setVisible(False)
        body.addWidget(self.tree_box)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        body.addWidget(self.scroll)
        body.setStretchFactor(1, 1)
        body.setSizes([300, 700])
        lay.addWidget(body, 1)

        pg = QHBoxLayout()
        self.prev = QPushButton("◀ Previous")
        self.prev.clicked.connect(lambda: self._go(-1))
        self.next = QPushButton("Next ▶")
        self.next.clicked.connect(lambda: self._go(1))
        self.page_lb = QLabel()
        pg.addStretch(1)
        pg.addWidget(self.prev)
        pg.addWidget(self.page_lb)
        pg.addWidget(self.next)
        pg.addStretch(1)
        lay.addLayout(pg)
        return w

    # ---------------------------------------------------------------- folders
    def _add_folder(self, path: str, recursive: bool = True):
        path = os.path.abspath(path)
        if not os.path.isdir(path) or any(self.folder_list.item(i).data(Qt.UserRole) == path for i in range(self.folder_list.count())):
            return
        it = QListWidgetItem(path)
        it.setToolTip(path)
        it.setData(Qt.UserRole, path)
        it.setFlags(it.flags() | Qt.ItemIsUserCheckable)
        it.setCheckState(Qt.Checked if recursive else Qt.Unchecked)
        self.folder_list.addItem(it)

    def roots(self):
        return [(self.folder_list.item(i).data(Qt.UserRole), self.folder_list.item(i).checkState() == Qt.Checked)
                for i in range(self.folder_list.count())]

    def add_folder_dialog(self):
        d = QFileDialog.getExistingDirectory(self, "Choose a folder to scan")
        if d:
            self._add_folder(d)

    def remove_folder(self):
        for it in self.folder_list.selectedItems() or ([self.folder_list.item(self.folder_list.count() - 1)] if self.folder_list.count() else []):
            self.folder_list.takeItem(self.folder_list.row(it))

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        for u in e.mimeData().urls():
            if os.path.isdir(u.toLocalFile()):
                self._add_folder(u.toLocalFile())

    # ---------------------------------------------------------------- settings
    def current_settings(self) -> Settings:
        s = Settings(find_similar=self.chk_similar.isChecked(), detect_rotation=self.chk_rotation.isChecked())
        for key, sl in self.sliders.items():
            setattr(s, key, sl.value() / 100)
        return s

    def reset_settings(self):
        d = Settings()
        for key, sl in self.sliders.items():
            sl.setValue(round(getattr(d, key) * 100))
        self.chk_similar.setChecked(True)
        self.chk_rotation.setChecked(True)

    def _save_config(self):
        self.config.settings = self.current_settings()
        self.config.safe_mode = self.session.safe_mode
        self.config.quarantine_root = self.session.quarantine.root
        self.config.folders = [[p, r] for p, r in self.roots()]
        self.config.save()

    # ---------------------------------------------------------------- safe mode
    def toggle_safe_mode(self):
        if not self.safe.isChecked():
            r = QMessageBox.question(self, "Turn off Safe Mode?",
                                     "With Safe Mode off, the Quarantine and Trash buttons work.\n\n"
                                     "Nothing happens by itself: every action still shows the full list of files "
                                     "and asks you to confirm, and quarantined files can be restored.\n\nTurn Safe Mode off?")
            if r != QMessageBox.Yes:
                self.safe.setChecked(True)
                return
        self.session.safe_mode = self.safe.isChecked()
        self._sync_safe_mode()
        self._save_config()
        self.refresh_header()

    def _sync_safe_mode(self):
        on = self.session.safe_mode
        self.safe.setChecked(on)
        self.safe_note.setText("ON – nothing can be moved or deleted. Scanning only reads your photos." if on else
                               "OFF – Quarantine and Trash are enabled. Every action still asks for confirmation.")
        self.safe_note.setStyleSheet(f"font-size:11px; color:{'#1f9d55' if on else '#d97706'};")

    # ---------------------------------------------------------------- scanning
    def start_scan(self, roots=None):
        roots = roots or self.roots()
        if not roots or self.thread is not None:
            return
        self._save_config()
        self.session.load(_empty_report())
        self.page = 0
        self.refresh()
        self.control = Control()
        self.thread = ScanThread(self.current_settings(), self.cache, roots, [self.session.quarantine.root], self.control)
        self.thread.progress.connect(self.on_progress)
        self.thread.done.connect(self.on_done)
        self.thread.failed.connect(self.on_failed)
        self.scan_btn.setVisible(False)
        self.prog.setVisible(True)
        self.pause_btn.setText("Pause")
        self.status.setText("")
        self.thread.start()

    def on_progress(self, p: Progress):
        self.stage_lb.setText(f"Stage {p.stage} of 5 · {p.name}")
        if p.total > 0:
            self.bar.setRange(0, p.total)
            self.bar.setValue(min(p.done, p.total))
            self.count_lb.setText(f"{p.done:,} of {p.total:,} processed")
        else:
            self.bar.setRange(0, 0)
            self.count_lb.setText(f"{p.done:,} images found" if p.done else "")
        if p.folder:
            pos = f"Folder {p.folder_index} of {p.folder_count}: " if p.folder_index and p.folder_count else "Folder: "
            self.folder_lb.setText(pos + ("…" + p.folder[-34:] if len(p.folder) > 36 else p.folder))
            self.folder_lb.setToolTip(p.folder)
        left = "Paused" if (self.control and self.control.paused) else (f"about {duration(p.eta)} left in this stage" if p.eta else "")
        self.time_lb.setText(f"Elapsed {duration(p.elapsed)}" + (f"  ·  {left}" if left else ""))

    def toggle_pause(self):
        if not self.control:
            return
        if self.control.paused:
            self.control.resume()
            self.pause_btn.setText("Pause")
        else:
            self.control.pause()
            self.pause_btn.setText("Resume")
            self.time_lb.setText("Paused")

    def cancel_scan(self):
        if self.control:
            self.control.cancel()
            self.stage_lb.setText("Cancelling…")

    def _scan_finished(self):
        if self.thread:
            self.thread.wait(5000)
        self.thread, self.control = None, None
        self.prog.setVisible(False)
        self.scan_btn.setVisible(True)

    def on_failed(self, message: str):
        self._scan_finished()
        QMessageBox.critical(self, "Scan failed", "The scan stopped because of an error. No files were changed.\n\n" + message)

    def on_done(self, report):
        self._scan_finished()
        if report.cancelled:
            self.status.setText("Scan cancelled. Work done so far is remembered, so the next scan resumes faster.")
            return
        self.session.load(report)
        if self.rule.currentIndex() != 0:
            self.session.apply_rule(self.rule.currentText(), self.preferred_folder)
        st = report.stats
        review = sum(1 for g in self.session.groups if g.group.manual_review)
        msg = (f"Scanned {st.valid:,} images in {duration(st.seconds)} · {len(self.session.groups)} groups"
               + (f" ({review} need review)" if review else "") + f" · {human_size(self.session.marked_bytes)} can be freed")
        if st.cache_hits:
            msg += f" · {st.cache_hits:,} unchanged images reused"
        if st.skipped:
            msg += f" · {len(st.skipped)} unreadable file(s) skipped"
        self.status.setText(msg)
        self.page = 0
        self._fill_tree()
        self.refresh()

    # ---------------------------------------------------------------- results
    def _selected_folder(self):
        if self.mode.currentIndex() != 1:
            return None
        it = self.tree.currentItem()
        return it.data(0, Qt.UserRole) if it else ""

    def visible_groups(self):
        folder = self._selected_folder()
        if folder == "":
            return []
        return self.session.visible(self.filter.currentText(), self.search.text(), folder)

    def refresh_header(self):
        s = self.session
        n = s.marked_count
        self.summary.setText(f"{len(s.groups)} duplicate groups  ·  {n} selected  ·  {human_size(s.marked_bytes)} to free" if s.groups
                             else ("No duplicates found" if s.stats and s.stats.valid else ""))
        self.q_btn.setText(f"Quarantine {n} file(s)…")
        self.q_btn.setEnabled(n > 0 and not s.safe_mode)
        self.trash_btn.setEnabled(n > 0 and not s.safe_mode)
        tip = "Turn off Safe Mode (bottom left) to enable" if s.safe_mode else ""
        self.q_btn.setToolTip(tip or "Move the selected files to the quarantine folder (can be restored)")
        self.trash_btn.setToolTip(tip or "Move the selected files to the system Trash / Recycle Bin")
        self.qm_btn.setText(f"Quarantine ({len(s.quarantine.items)})")

    def refresh(self):
        groups = self.visible_groups()
        pages = max(1, (len(groups) + PAGE - 1) // PAGE)
        self.page = max(0, min(self.page, pages - 1))
        holder = QWidget()
        lay = QVBoxLayout(holder)
        lay.setSpacing(14)
        shown = groups[self.page * PAGE:(self.page + 1) * PAGE]
        number = {id(g): i + 1 for i, g in enumerate(self.session.groups)}
        folder = self._selected_folder()
        for g in shown:
            card = GroupCard(self.session, g, number[id(g)], self.thumbs, folder or None)
            card.changed.connect(self.refresh_header)
            lay.addWidget(card)
        if not shown:
            msg = ("Select a folder on the left to see its duplicates." if (self.mode.currentIndex() == 1 and folder == "")
                   else "No groups match the current filter." if self.session.groups
                   else "Add folders on the left, then click Scan." if not (self.session.stats and self.session.stats.valid)
                   else "No duplicates were found in these folders.")
            lb = QLabel(msg)
            lb.setAlignment(Qt.AlignCenter)
            lb.setStyleSheet("font-size:14px; padding:60px;")
            lay.addWidget(lb)
        lay.addStretch(1)
        self.scroll.setWidget(holder)
        self.page_lb.setText(f"Page {self.page + 1} of {pages}  ({len(groups)} groups)")
        self.prev.setEnabled(self.page > 0)
        self.next.setEnabled(self.page < pages - 1)
        self.refresh_header()

    def _go(self, d):
        self.page += d
        self.refresh()

    def _filters_changed(self):
        self.page = 0
        self.refresh()

    def _mode_changed(self):
        self.tree_box.setVisible(self.mode.currentIndex() == 1)
        self.page = 0
        self.refresh()

    def _fill_tree(self):
        self.tree.clear()
        roots = [r for r, _ in self.roots()]
        nodes: dict = {}
        for path, count, dups in sorted(self.session.folders):
            if self.only_dups.isChecked() and not dups:
                continue
            parent = None
            p = os.path.dirname(path)
            while p and p != os.path.dirname(p):
                if p in nodes:
                    parent = nodes[p]
                    break
                p = os.path.dirname(p)
            label = path if (parent is None) else os.path.relpath(path, parent.data(0, Qt.UserRole))
            if parent is None:
                for r in roots:
                    if path.startswith(r) and path != r:
                        label = os.path.join(os.path.basename(r), os.path.relpath(path, r))
                    elif path == r:
                        label = os.path.basename(r) or r
            it = QTreeWidgetItem([label, str(count), str(dups)])
            it.setData(0, Qt.UserRole, path)
            it.setToolTip(0, path)
            (parent.addChild(it) if parent else self.tree.addTopLevelItem(it))
            nodes[path] = it
        self.tree.expandAll()

    def _folder_selected(self):
        self.page = 0
        self.refresh()

    def _folder_select(self, on):
        f = self._selected_folder()
        if f:
            (self.session.select_confirmed(f) if on else self.session.clear_all(f))
            self.refresh()

    def _tree_menu(self, pos):
        it = self.tree.itemAt(pos)
        if not it:
            return
        path = it.data(0, Qt.UserRole)
        m = QMenu(self)
        m.addAction("Scan only this folder", lambda: self.start_scan([(path, False)]))
        m.addAction("Scan this folder and subfolders", lambda: self.start_scan([(path, True)]))
        m.addAction("Open folder", lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(path)))
        m.exec(self.tree.viewport().mapToGlobal(pos))

    def apply_rule(self):
        rule = self.rule.currentText()
        if rule == "Inside preferred folder":
            d = QFileDialog.getExistingDirectory(self, "Choose the folder whose copies should be kept")
            if d:
                self.preferred_folder = d
        self.rule_note.setVisible(self.rule.currentIndex() == 0)
        if self.session.relabeler is not None:
            self.session.apply_rule(rule, self.preferred_folder)
            self.refresh()

    # ---------------------------------------------------------------- actions
    def _report(self, message, failures):
        self.status.setText(message)
        if failures:
            QMessageBox.warning(self, f"{len(failures)} file(s) could not be processed", "\n".join(failures[:12]))
        self._fill_tree()
        self.refresh()

    def quarantine_selected(self):
        files = self.session.marked_files()
        if not files:
            return
        dlg = ConfirmDialog(self, f"Move {len(files)} file(s) to the quarantine folder?",
                            f"The files are moved to {self.session.quarantine.root}, keeping their folder structure. "
                            "The original of every group stays where it is. You can restore them at any time.",
                            [f[0] for f in files], sum(f[1] for f in files), "Move to quarantine")
        if dlg.exec() != QDialog.Accepted:
            return
        try:
            moved, failures = self.session.quarantine_marked()
        except SafeModeError as e:
            self.status.setText(str(e))
            return
        self._report(f"Moved {len(moved)} file(s) to quarantine. Restore them any time from Quarantine.", failures)

    def trash_selected(self):
        files = self.session.marked_files()
        if not files:
            return
        dlg = ConfirmDialog(self, f"Move {len(files)} file(s) to the Trash?",
                            "The files are moved to the system Trash / Recycle Bin. The original of every group stays where it is.",
                            [f[0] for f in files], sum(f[1] for f in files), "Move to Trash")
        if dlg.exec() != QDialog.Accepted:
            return
        try:
            done, failures = self.session.trash_marked()
        except SafeModeError as e:
            self.status.setText(str(e))
            return
        self._report(f"Moved {len(done)} file(s) to the Trash.", failures)

    def open_quarantine(self):
        self.session.quarantine.load()
        QuarantineDialog(self, self.session, self._report).exec()
        self.refresh_header()

    def open_quarantine_folder(self):
        os.makedirs(self.session.quarantine.root, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(self.session.quarantine.root))

    def change_quarantine_folder(self):
        d = QFileDialog.getExistingDirectory(self, "Choose the quarantine folder")
        if d:
            self.session.quarantine.set_root(d)
            self._save_config()
            self.refresh_header()

    def export_csv(self):
        if not self.session.groups:
            QMessageBox.information(self, "Nothing to export", "Run a scan first.")
            return
        path, _ = QFileDialog.getSaveFileName(self, "Save report", "DupeSweep-report.csv", "CSV (*.csv)")
        if path:
            try:
                self.session.export_csv(path)
                self.status.setText(f"Report saved to {path}")
            except OSError as e:
                QMessageBox.warning(self, "Could not save", str(e))

    def clear_cache(self):
        self.cache.clear()
        self.status.setText("Cache cleared – the next scan analyses every image again.")

    def show_safety(self):
        QMessageBox.information(self, "How DupeSweep keeps your photos safe",
                                "• Scanning only reads your photos. It never changes, renames or moves them.\n"
                                "• Safe Mode is on by default. While it is on, nothing can be moved or deleted.\n"
                                "• Nothing is ever removed automatically. You choose, and every action lists the files and asks first.\n"
                                "• Quarantine is a move, not a delete. Restore puts files back exactly where they were.\n"
                                "• The original of each group can never be selected for removal.\n"
                                "• Uncertain groups (MANUAL REVIEW, POSSIBLE MATCH) are never pre-selected.\n"
                                "• Permanent deletion is only possible from the Quarantine window, after a second confirmation.")

    def show_about(self):
        QMessageBox.about(self, f"About {APP_NAME}",
                          f"<b>{APP_NAME} {__version__}</b><br>Finds exact duplicates and edited versions of photos, safely.<br><br>"
                          "Open source under the MIT licence.<br>https://github.com/devid9602/DupeSweep")

    def closeEvent(self, e):
        if self.control:
            self.control.cancel()
        if self.thread:
            self.thread.wait(8000)
        self._save_config()
        self.cache.commit()
        e.accept()


def _empty_report():
    from ..engine import Report, Stats
    return Report([], [], [], Stats(), False, None)


def main() -> int:
    multiprocessing.freeze_support()
    if "--version" in sys.argv:
        print(f"{APP_NAME} {__version__}")
        return 0
    smoke = "--smoke" in sys.argv          # used by the release build to verify the packaged app starts
    if smoke:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)
    app.setStyle("Fusion")
    if os.path.exists(resource("icon.png")):
        app.setWindowIcon(QIcon(resource("icon.png")))
    if smoke:
        import tempfile
        tmp = tempfile.mkdtemp(prefix="dupesweep-smoke-")
        win = MainWindow(Config(os.path.join(tmp, "settings.json")), Cache(os.path.join(tmp, "cache.sqlite")))
        win.show()
        app.processEvents()
        import numpy, PIL, pillow_heif      # noqa: F401 - prove the bundled libraries load
        from ..engine import _init_worker, sha256_file
        with multiprocessing.get_context("spawn").Pool(2, initializer=_init_worker, initargs=(Settings().__dict__.copy(),)) as pool:
            assert len(set(pool.map(sha256_file, [sys.executable] * 4))) == 1      # worker processes start and work
        print(f"{APP_NAME} {__version__} smoke test OK")
        win.close()
        return 0
    win = MainWindow()
    win.show()
    return app.exec()
