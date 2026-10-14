"""The GUI's update flow must not mistake its own closing of the progress dialog for a user cancel."""

import pytest

pytest.importorskip("PySide6.QtWidgets", exc_type=ImportError)  # a missing system library (libEGL) is also an ImportError

from PySide6.QtCore import QSettings
from PySide6.QtWidgets import QApplication, QProgressDialog

from shuffledetector.gui import app as gui


@pytest.fixture
def window(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    qapp = QApplication.instance() or QApplication([])
    settings = QSettings(str(tmp_path / "s.ini"), QSettings.IniFormat)
    win = gui.MainWindow(settings=settings)
    yield win
    win.close()
    qapp.processEvents()


def open_progress(win):
    dlg = QProgressDialog("Downloading", "Cancel", 0, 0, win)
    dlg.canceled.connect(win.update_cancel.set)
    dlg.show()
    win.update_dialog = dlg
    return dlg


def test_closing_the_progress_dialog_is_not_a_cancel(window):
    open_progress(window)
    window.close_update_dialog()
    assert not window.update_cancel.is_set() and window.update_dialog is None


def test_staged_update_is_applied_not_discarded(window, tmp_path, monkeypatch):
    staged = tmp_path / "new"
    staged.mkdir()
    applied = []
    monkeypatch.setattr(gui.selfupdate, "apply_update", lambda root: applied.append(root))
    monkeypatch.setattr(gui.QApplication, "quit", lambda: None)
    window.update_cancel.clear()
    open_progress(window)
    window.on_update_staged(staged)
    assert applied == [staged] and staged.exists()


def test_failure_is_reported_not_swallowed(window, monkeypatch):
    shown = []
    monkeypatch.setattr(gui.QMessageBox, "warning", lambda *a, **k: shown.append(a[2]))
    window.update_cancel.clear()
    open_progress(window)
    window.on_update_failed("boom")
    assert shown and "boom" in shown[0]
