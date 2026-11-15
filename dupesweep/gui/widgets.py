"""Reusable widgets: flow layout, thumbnails, file cards, group cards, dialogs."""
from __future__ import annotations

import os
import subprocess
import sys

from PySide6.QtCore import QObject, QPoint, QRect, QRunnable, QSize, Qt, QThreadPool, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QGuiApplication, QImage, QPixmap
from PySide6.QtWidgets import (QCheckBox, QDialog, QDialogButtonBox, QFrame, QHBoxLayout, QHeaderView, QLabel,
                               QLayout, QMenu, QPlainTextEdit, QPushButton, QSizePolicy, QTableWidget,
                               QTableWidgetItem, QVBoxLayout, QWidget)

from .. import grouping, imaging

LABEL_COLOURS = {grouping.ORIGINAL: "#1f9d55", grouping.EXACT_DUP: "#d64545", grouping.VISUAL: "#dd8a1d",
                 grouping.EDITED: "#8250c4", grouping.POSSIBLE: "#6b7280"}


def human_size(n: float) -> str:
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024
    return ""


def duration(t: float) -> str:
    s = int(round(t))
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def reveal(path: str) -> None:
    """Shows a file in Finder / Explorer / the file manager."""
    try:
        if sys.platform == "darwin":
            subprocess.Popen(["open", "-R", path])
        elif sys.platform == "win32":
            subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(os.path.dirname(path)))
    except OSError:
        pass


class FlowLayout(QLayout):
    """Lays children out left to right, wrapping to new rows."""

    def __init__(self, parent=None, spacing=10):
        super().__init__(parent)
        self._items, self._space = [], spacing
        self.setContentsMargins(0, 0, 0, 0)

    def addItem(self, item):
        self._items.append(item)

    def count(self):
        return len(self._items)

    def itemAt(self, i):
        return self._items[i] if 0 <= i < len(self._items) else None

    def takeAt(self, i):
        return self._items.pop(i) if 0 <= i < len(self._items) else None

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, w):
        return self._layout(QRect(0, 0, w, 0), False)

    def setGeometry(self, rect):
        super().setGeometry(rect)
        self._layout(rect, True)

    def sizeHint(self):
        return self.minimumSize()

    def minimumSize(self):
        s = QSize()
        for it in self._items:
            s = s.expandedTo(it.minimumSize())
        return s

    def _layout(self, rect, apply):
        x, y, row = rect.x(), rect.y(), 0
        for it in self._items:
            w, h = it.sizeHint().width(), it.sizeHint().height()
            if x + w > rect.right() + 1 and row > 0:
                x, y, row = rect.x(), y + row + self._space, 0
            if apply:
                it.setGeometry(QRect(QPoint(x, y), it.sizeHint()))
            x += w + self._space
            row = max(row, h)
        return y + row - rect.y()


class _ThumbSignals(QObject):
    done = Signal(str, QImage)


class _ThumbJob(QRunnable):
    def __init__(self, path, signals):
        super().__init__()
        self.path, self.signals = path, signals

    def run(self):
        rgb = imaging.load_rgb(self.path, 320)
        img = QImage()
        if rgb is not None:
            h, w, _ = rgb.shape
            img = QImage(rgb.tobytes(), w, h, 3 * w, QImage.Format_RGB888).copy()
        try:
            self.signals.done.emit(self.path, img)
        except RuntimeError:        # window already closed
            pass


class Thumbnails(QObject):
    """Loads thumbnails off the UI thread and caches them."""

    def __init__(self):
        super().__init__()
        self.pool = QThreadPool()
        self.pool.setMaxThreadCount(3)
        self.cache: dict = {}
        self.waiting: dict = {}
        self.signals = _ThumbSignals()
        self.signals.done.connect(self._done)

    def request(self, path: str, label: QLabel) -> None:
        pm = self.cache.get(path)
        if pm is not None:
            label.setPixmap(pm)
            return
        first = path not in self.waiting
        self.waiting.setdefault(path, []).append(label)
        if first:
            self.pool.start(_ThumbJob(path, self.signals))

    def _done(self, path: str, img: QImage) -> None:
        pm = QPixmap.fromImage(img).scaled(214, 150, Qt.KeepAspectRatio, Qt.SmoothTransformation) if not img.isNull() else QPixmap()
        if len(self.cache) > 500:
            self.cache.pop(next(iter(self.cache)))
        self.cache[path] = pm
        for label in self.waiting.pop(path, []):
            try:
                label.setPixmap(pm) if not pm.isNull() else label.setText("no preview")
            except RuntimeError:    # card was rebuilt meanwhile
                pass


def badge(text: str, colour: str) -> QLabel:
    b = QLabel(text)
    b.setStyleSheet(f"background:{colour}; color:white; border-radius:8px; padding:1px 8px; font-size:11px; font-weight:bold;")
    b.setSizePolicy(QSizePolicy.Maximum, QSizePolicy.Fixed)
    return b


def _small(text: str) -> QLabel:
    lb = QLabel(text)
    lb.setStyleSheet("font-size:11px;")
    return lb


class FileCard(QFrame):
    """One image inside a duplicate group."""
    keepRequested = Signal(int)
    toggled = Signal(int)

    def __init__(self, image, member, is_original, marked, thumbs: Thumbnails, dimmed=False):
        super().__init__()
        self.image, self.member, self.is_original = image, member, is_original
        self.setObjectName("fileCard")
        self.setFixedWidth(236)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(3)

        label = grouping.ORIGINAL if is_original else member.label
        top = QHBoxLayout()
        top.addWidget(badge(label, LABEL_COLOURS[label]))
        self.sel_badge = badge("SELECTED", "#d64545")
        top.addWidget(self.sel_badge)
        top.addStretch(1)
        lay.addLayout(top)

        self.thumb = QLabel("loading…")
        self.thumb.setAlignment(Qt.AlignCenter)
        self.thumb.setFixedSize(218, 152)
        self.thumb.setStyleSheet("background: rgba(127,127,127,0.12); border-radius:6px;")
        lay.addWidget(self.thumb)
        thumbs.request(image.path, self.thumb)

        name = QLabel(self._elide(image.name, 34))
        name.setStyleSheet("font-weight:600;")
        name.setToolTip(image.path)
        lay.addWidget(name)
        folder = _small(self._elide(image.folder, 33, head=True))
        folder.setToolTip(image.path)
        folder.setTextInteractionFlags(Qt.TextSelectableByMouse)
        lay.addWidget(folder)
        m = image.meta
        import datetime as dt
        lay.addWidget(_small(f"{m.format} · {m.width}×{m.height} · {human_size(image.size)}"))
        lay.addWidget(_small("Modified " + dt.datetime.fromtimestamp(image.mtime).strftime("%d %b %Y, %H:%M")))
        if not is_original:
            conf = QLabel(f"Similarity {round(member.similarity * 100)}% · {grouping.CONFIDENCE_NAMES[member.confidence]} confidence")
            conf.setStyleSheet("font-size:11px; font-weight:600;" + ("" if member.confidence >= grouping.HIGH else "color:#d97706;"))
            lay.addWidget(conf)
            meth = _small(self._elide(member.method, 44))
            meth.setToolTip(member.method)
            lay.addWidget(meth)
            if member.notes:
                notes = _small(", ".join(member.notes))
                notes.setWordWrap(True)
                notes.setMaximumHeight(44)
                notes.setToolTip("\n".join(member.notes))
                lay.addWidget(notes)
        lay.addStretch(1)

        row = QHBoxLayout()
        self.keep = QPushButton("Original" if is_original else "Keep as original")
        self.keep.setEnabled(not is_original)
        self.keep.clicked.connect(lambda: self.keepRequested.emit(member.index))
        row.addWidget(self.keep)
        row.addStretch(1)
        self.check = QCheckBox("Select")
        self.check.setToolTip("Select this file for removal (Quarantine or Trash)")
        self.check.setEnabled(not is_original)
        self.check.setChecked(marked)
        self.check.clicked.connect(lambda: self.toggled.emit(member.index))
        row.addWidget(self.check)
        lay.addLayout(row)
        self.dimmed = dimmed
        self.set_marked(marked)

    @staticmethod
    def _elide(s: str, n: int, head=False) -> str:
        if len(s) <= n:
            return s
        return ("…" + s[-(n - 1):]) if head else (s[:n // 2 - 1] + "…" + s[-(n - n // 2):])

    def set_marked(self, marked: bool) -> None:
        self.check.setChecked(marked)
        self.sel_badge.setVisible(marked)
        border = "#1f9d55" if self.is_original else ("#d64545" if marked else "rgba(127,127,127,0.25)")
        self.setStyleSheet(f"#fileCard {{ border:2px solid {border}; border-radius:10px; background: palette(base); }}")
        self.setWindowOpacity(1.0)

    def mouseDoubleClickEvent(self, e):
        QDesktopServices.openUrl(QUrl.fromLocalFile(self.image.path))

    def contextMenuEvent(self, e):
        menu = QMenu(self)
        menu.addAction("Show in folder", lambda: reveal(self.image.path))
        menu.addAction("Open", lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(self.image.path)))
        menu.addAction("Copy path", lambda: QGuiApplication.clipboard().setText(self.image.path))
        menu.exec(e.globalPos())


class GroupCard(QFrame):
    """A duplicate group: header, explanation and its file cards."""
    changed = Signal()

    def __init__(self, session, ui_group, number, thumbs, highlight_folder=None):
        super().__init__()
        self.session, self.g, self.number, self.thumbs, self.highlight = session, ui_group, number, thumbs, highlight_folder
        self.setObjectName("groupCard")
        self.outer = QVBoxLayout(self)
        self.outer.setContentsMargins(12, 10, 12, 12)
        self.cards: dict = {}
        self.build()

    def build(self):
        while self.outer.count():
            it = self.outer.takeAt(0)
            if it.widget():
                it.widget().deleteLater()
            elif it.layout():
                _clear(it.layout())
        g = self.g.group
        review = g.manual_review
        self.setStyleSheet(f"#groupCard {{ border:1px solid {'#e0a800' if review else 'rgba(127,127,127,0.3)'}; "
                           f"border-radius:12px; background: palette(alternate-base); }}")
        head = QHBoxLayout()
        title = QLabel(f"Group {self.number}")
        title.setStyleSheet("font-size:14px; font-weight:bold;")
        head.addWidget(title)
        if review:
            head.addWidget(badge("MANUAL REVIEW", "#c78a00"))
        head.addWidget(badge(g.scope, "#3b82f6"))
        head.addWidget(QLabel(f"{len(g.members)} files"))
        head.addStretch(1)
        self.frees = QLabel()
        head.addWidget(self.frees)
        for text, fn in (("Select all duplicates", self._select_all), ("Clear", self._clear)):
            b = QPushButton(text)
            b.clicked.connect(fn)
            head.addWidget(b)
        if self.g.override:
            b = QPushButton("Reset to recommended")
            b.clicked.connect(self._reset)
            head.addWidget(b)
        self.outer.addLayout(head)
        if review and g.review_reason:
            why = QLabel("⚠ " + g.review_reason + ". Nothing in this group was pre-selected – choose the original yourself.")
            why.setWordWrap(True)
            why.setStyleSheet("color:#c2410c; font-size:12px;")
            self.outer.addWidget(why)
        elif not self.g.override and g.reasons:
            why = _small("Recommended original: " + ", ".join(g.reasons))
            why.setWordWrap(True)
            self.outer.addWidget(why)
        holder = QWidget()
        flow = FlowLayout(holder)
        self.cards = {}
        for m in g.members:
            im = self.session.images[m.index]
            card = FileCard(im, m, m.index == self.g.original, m.index in self.g.marked, self.thumbs,
                            self.highlight is not None and im.folder != self.highlight)
            card.keepRequested.connect(self._keep)
            card.toggled.connect(self._toggle)
            flow.addWidget(card)
            self.cards[m.index] = card
        self.outer.addWidget(holder)
        self._refresh()

    def _refresh(self):
        for i, card in self.cards.items():
            card.set_marked(i in self.g.marked)
        freed = sum(self.session.images[i].size for i in self.g.marked)
        self.frees.setText(f"Frees {human_size(freed)}" if freed else "")
        self.changed.emit()

    def _toggle(self, index):
        self.session.toggle(self.g, index)
        self._refresh()

    def _select_all(self):
        self.session.select_all(self.g)
        self._refresh()

    def _clear(self):
        self.session.clear(self.g)
        self._refresh()

    def _keep(self, index):
        self.session.set_original(self.g, index)
        self.build()

    def _reset(self):
        self.session.reset_original(self.g)
        self.build()


def _clear(layout):
    while layout.count():
        it = layout.takeAt(0)
        if it.widget():
            it.widget().deleteLater()
        elif it.layout():
            _clear(it.layout())


class ConfirmDialog(QDialog):
    """Lists every file and folder before anything is moved or deleted."""

    def __init__(self, parent, title, explanation, paths, total_bytes, confirm_text, danger=False):
        super().__init__(parent)
        self.setWindowTitle("Please confirm")
        self.resize(680, 480)
        lay = QVBoxLayout(self)
        t = QLabel(title)
        t.setStyleSheet("font-size:15px; font-weight:bold;")
        lay.addWidget(t)
        folders: dict = {}
        for p in paths:
            folders.setdefault(os.path.dirname(p), []).append(os.path.basename(p))
        lay.addWidget(QLabel(f"{len(paths)} file(s) · {human_size(total_bytes)} · in {len(folders)} folder(s)"))
        ex = QLabel(explanation)
        ex.setWordWrap(True)
        lay.addWidget(ex)
        box = QPlainTextEdit()
        box.setReadOnly(True)
        box.setPlainText("\n".join(f"{len(n)} × {f}\n" + "\n".join("      " + x for x in sorted(n)) for f, n in sorted(folders.items())))
        lay.addWidget(box, 1)
        bb = QDialogButtonBox()
        self.ok = bb.addButton(confirm_text, QDialogButtonBox.AcceptRole)
        cancel = bb.addButton("Cancel", QDialogButtonBox.RejectRole)
        cancel.setDefault(True)
        self.ok.setStyleSheet(f"background:{'#d64545' if danger else '#dd8a1d'}; color:white; font-weight:bold; padding:5px 14px;")
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        lay.addWidget(bb)


class QuarantineDialog(QDialog):
    """Restore or permanently delete quarantined files."""

    def __init__(self, parent, session, on_change):
        super().__init__(parent)
        self.session, self.on_change = session, on_change
        self.setWindowTitle("Quarantine")
        self.resize(860, 520)
        lay = QVBoxLayout(self)
        self.info = QLabel()
        lay.addWidget(self.info)
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["File", "Original folder", "Quarantined", "Size"])
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.table.setSelectionMode(QTableWidget.NoSelection)
        lay.addWidget(self.table, 1)
        row = QHBoxLayout()
        for text, fn in (("Select all", lambda: self._check(True)), ("Select none", lambda: self._check(False))):
            b = QPushButton(text)
            b.clicked.connect(fn)
            row.addWidget(b)
        row.addStretch(1)
        self.restore_sel = QPushButton("Restore selected")
        self.restore_sel.clicked.connect(lambda: self._restore(self._ids()))
        self.restore_all = QPushButton("Restore all")
        self.restore_all.clicked.connect(lambda: self._restore([i.id for i in session.quarantine.items]))
        self.delete = QPushButton("Delete permanently…")
        self.delete.setStyleSheet("color:#d64545;")
        self.delete.clicked.connect(self._delete)
        close = QPushButton("Close")
        close.clicked.connect(self.accept)
        for b in (self.restore_sel, self.restore_all, self.delete, close):
            row.addWidget(b)
        lay.addLayout(row)
        self.fill()

    def fill(self):
        items = sorted(self.session.quarantine.items, key=lambda i: i.date, reverse=True)
        self.table.setRowCount(len(items))
        for r, it in enumerate(items):
            first = QTableWidgetItem(os.path.basename(it.original_path))
            first.setFlags(Qt.ItemIsUserCheckable | Qt.ItemIsEnabled)
            first.setCheckState(Qt.Unchecked)
            first.setData(Qt.UserRole, it.id)
            self.table.setItem(r, 0, first)
            self.table.setItem(r, 1, QTableWidgetItem(os.path.dirname(it.original_path)))
            self.table.setItem(r, 2, QTableWidgetItem(it.date.replace("T", " ")))
            self.table.setItem(r, 3, QTableWidgetItem(human_size(it.size)))
        self.table.resizeColumnToContents(0)
        total = sum(i.size for i in items)
        self.info.setText(f"<b>{len(items)} file(s)</b> · {human_size(total)} · stored in {self.session.quarantine.root}")
        self.delete.setEnabled(not self.session.safe_mode and bool(items))
        self.delete.setToolTip("Turn off Safe Mode to enable" if self.session.safe_mode else "")
        self.restore_all.setEnabled(bool(items))
        self.restore_sel.setEnabled(bool(items))

    def _check(self, on):
        for r in range(self.table.rowCount()):
            self.table.item(r, 0).setCheckState(Qt.Checked if on else Qt.Unchecked)

    def _ids(self):
        return [self.table.item(r, 0).data(Qt.UserRole) for r in range(self.table.rowCount())
                if self.table.item(r, 0).checkState() == Qt.Checked]

    def _restore(self, ids):
        if not ids:
            return
        restored, failures = self.session.restore(ids)
        self.fill()
        self.on_change(f"Restored {len(restored)} file(s) to their original folders.", failures)

    def _delete(self):
        ids = set(self._ids())
        items = [i for i in self.session.quarantine.items if i.id in ids]
        if not items:
            return
        dlg = ConfirmDialog(self, f"Permanently delete {len(items)} file(s)?",
                            "These quarantined files will be erased for good. This cannot be undone.",
                            [i.original_path for i in items], sum(i.size for i in items), "Delete permanently", danger=True)
        if dlg.exec() == QDialog.Accepted:
            n, failures = self.session.delete_permanently(ids)
            self.fill()
            self.on_change(f"Permanently deleted {n} quarantined file(s).", failures)
