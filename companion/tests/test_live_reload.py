"""Source refresh must not restart the process or lose the user's batch controls."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("PySide6.QtWidgets", exc_type=ImportError)

from PySide6.QtCore import QSettings
from PySide6.QtWidgets import QApplication

from shuffledetector.gui import app as gui, live_reload


@pytest.fixture
def window(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    monkeypatch.setattr(gui.MainWindow, "auto_update_addon", lambda self: None)
    qapp = QApplication.instance() or QApplication([])
    win = gui.MainWindow(settings=QSettings(str(tmp_path / "settings.ini"), QSettings.IniFormat))
    yield win
    win.close()
    qapp.processEvents()


def test_change_requires_stable_poll_and_waits_for_modal(window, monkeypatch):
    changed = (("changed.py", 1, 2),)
    monkeypatch.setattr(live_reload, "disk_signature", lambda root: changed)
    requests = []
    window.source_reload_requested.connect(lambda: requests.append(True))
    window.check_source_changes()
    assert requests == []
    monkeypatch.setattr(gui.QApplication, "activeModalWidget", lambda: window)
    window.check_source_changes()
    assert requests == []
    monkeypatch.setattr(gui.QApplication, "activeModalWidget", lambda: None)
    window.check_source_changes()
    assert requests == [True]
    window.check_source_changes()
    assert requests == [True]


def test_read_failure_is_visible(window, monkeypatch):
    def fail(root):
        raise OSError("cannot read")
    monkeypatch.setattr(live_reload, "disk_signature", fail)
    window.check_source_changes()
    assert "cannot read" in window.statusBar().currentMessage()


def test_lua_edit_refreshes_existing_ui(window, monkeypatch):
    python = ("app.py", 1, 2)
    window.source_signature = (python, ("Shuffle.lua", 1, 2))
    changed = (python, ("Shuffle.lua", 2, 3))
    monkeypatch.setattr(live_reload, "disk_signature", lambda root: changed)
    calls = []
    monkeypatch.setattr(window, "populate_clients", lambda: calls.append("clients"))
    window.source_reload_requested.connect(lambda: calls.append("rebuild"))
    window.calc_crafts.setValue(58)
    table = window.table
    window.check_source_changes()
    assert calls == []
    window.check_source_changes()
    assert calls == ["clients"]
    assert window.table is table
    assert window.calc_crafts.value() == 58
    assert window.source_signature == changed


def test_closing_outer_window_stops_refresh_timers(window):
    shell = gui.CompanionWindow()
    window.setWindowFlags(gui.Qt.Widget)
    shell.setCentralWidget(window)
    shell.show()
    shell.close()
    assert not window.watch_timer.isActive()
    assert not window.source_timer.isActive()
    shell.takeCentralWidget()


def test_session_preserves_batch_and_layout(window):
    window.calc_crafts.setValue(57)
    window.calc_budget.setText("123g 4s")
    window.calc_mode.setCurrentIndex(1)
    window.cut.setValue(7)
    window.tabs.setCurrentIndex(1)
    state = window.session_state()
    window.calc_crafts.setValue(1)
    window.calc_budget.setText("1g")
    window.tabs.setCurrentIndex(0)
    window.restore_session(state)
    assert window.calc_crafts.value() == 57
    assert window.calc_budget.text() == "123g 4s"
    assert window.calc_mode.currentData() == "budget"
    assert window.cut.value() == 7
    assert window.tabs.currentIndex() == 1


def test_selected_recipe_and_material_overrides_survive_restore(window, tmp_path, monkeypatch):
    path = tmp_path / "SavedVariables.lua"
    path.write_text("AHSnapshotDB = {}")
    reference = gui.data_loader.Reference(
        items={1: "Cloth", 2: "Bag"},
        recipes=[{"name": name, "item": 2, "reagents": [{"item": 1, "qty": 2}], "yields": []}
                 for name in ("First bag", "Second bag")],
    )
    scan = gui.data_loader.ScanData(scans={"Realm": {
        "time": 1, "items": {1: {"min": 10, "qty": 100, "prices": [(10, 100)]}},
    }})
    monkeypatch.setattr(gui.data_loader, "load_reference", lambda **kwargs: reference)
    monkeypatch.setattr(gui.data_loader, "load_scan_data", lambda path: scan)
    assert window.reload()
    assert window.load(str(path))
    window.table.selectRow(1)
    window.cost_overrides[1] = 37
    window._save_costs()
    state = window.session_state()
    selected = state["recipe"]
    window.table.selectRow(0)
    window.restore_session(state)
    assert window.shown[window.table.currentRow()].name == selected
    assert window.path == str(path)
    assert window.cost_overrides[1] == 37
    assert '"1": 37' in window.settings.value("material_costs_by_item")


def test_packaged_build_does_not_watch_source(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    qapp = QApplication.instance() or QApplication([])
    monkeypatch.setattr(gui.sys, "frozen", True, raising=False)
    win = gui.MainWindow(settings=QSettings(str(tmp_path / "settings.ini"), QSettings.IniFormat), resumed=True)
    try:
        assert not win.source_timer.isActive()
        assert not win.source_reload_act.isEnabled()
        assert not win.request_source_reload()
    finally:
        win.close()
        qapp.processEvents()


def test_real_reload_and_failure_rollback_in_same_process(tmp_path):
    root = Path(__file__).resolve().parents[2]
    package = tmp_path / "companion/src/shuffledetector"
    shutil.copytree(root / "companion/src/shuffledetector", package, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(root / "common", tmp_path / "common")
    shutil.copytree(root / "addon", tmp_path / "addon")
    script = r'''
import os
from pathlib import Path
from PySide6.QtCore import QSettings
from PySide6.QtWidgets import QApplication, QMainWindow
from shuffledetector.gui import app as gui, live_reload
from shuffledetector import calc

qapp = QApplication([])
old = gui.MainWindow(settings=QSettings(str(Path.cwd() / "settings.ini"), QSettings.IniFormat), resumed=True)
old.calc_crafts.setValue(57)
old.tabs.setCurrentIndex(1)
state, pid = old.session_state(), os.getpid()
source = Path(gui.__file__)
source.write_text(source.read_text() + "\nMainWindow.disk_marker = 'fresh'\n")
new = None
def build(module):
    global new
    new = module.MainWindow(settings=old.settings, resumed=True)
    new.restore_session(state)
    return new
new = live_reload.reload_modules(build)
assert os.getpid() == pid
assert new.disk_marker == "fresh"
assert new.calc_crafts.value() == 57
assert new.tabs.currentIndex() == 1
assert new.watch_timer.isActive()
assert new.source_timer.isActive()
old.close()
assert not old.watch_timer.isActive()
assert not old.source_timer.isActive()
original = calc.fmt_money
calc_source = Path(calc.__file__)
contents = calc_source.read_text()
calc_source.write_text(contents + "\nraise RuntimeError('broken import')\n")
try:
    live_reload.reload_modules()
except RuntimeError as e:
    assert str(e) == "broken import"
else:
    raise AssertionError("reload should fail")
assert calc.fmt_money is original
assert new.calc_crafts.value() == 57
calc_source.write_text(contents + "\nthis is invalid syntax !\n")
try:
    live_reload.reload_modules()
except SyntaxError:
    pass
else:
    raise AssertionError("syntax must be checked before changing modules")
assert calc.fmt_money is original
calc_source.write_text(contents)
try:
    live_reload.reload_modules(lambda module: (_ for _ in ()).throw(RuntimeError("build failed")))
except RuntimeError:
    pass
assert calc.fmt_money is original
new.close()
print("same-process refresh passed")
'''
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", PYTHONPATH=str(package.parent))
    result = subprocess.run([sys.executable, "-c", script], cwd=tmp_path, env=env,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "same-process refresh passed" in result.stdout


def test_running_application_replaces_window_without_restarting(tmp_path):
    root = Path(__file__).resolve().parents[2]
    package = tmp_path / "companion/src/shuffledetector"
    shutil.copytree(root / "companion/src/shuffledetector", package, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(root / "common", tmp_path / "common")
    shutil.copytree(root / "addon", tmp_path / "addon")
    script = r'''
import os
from pathlib import Path
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication, QMainWindow
from shuffledetector.gui import app as gui
qapp = QApplication([])
pid = os.getpid()
gui.MainWindow.auto_update_addon = lambda self: None
old = None
passed = False
def update():
    global old, shell, native_id, geometry, screen
    shell = next(w for w in qapp.topLevelWidgets() if isinstance(w, QMainWindow) and w.isVisible())
    old = shell.centralWidget()
    shell.move(123, 87)
    shell.resize(950, 600)
    native_id, geometry, screen = shell.winId(), shell.geometry(), shell.screen()
    old.calc_crafts.setValue(43)
    old.tabs.setCurrentIndex(1)
    path = Path(gui.__file__)
    path.write_text(path.read_text() + "\nMainWindow.disk_marker = 'updated'\n")
    old.check_source_changes()
    old.check_source_changes()
    QTimer.singleShot(0, verify)
def verify():
    global passed
    new = shell.centralWidget()
    assert new is not old
    assert new.disk_marker == "updated"
    assert new.calc_crafts.value() == 43
    assert new.tabs.currentIndex() == 1
    assert new.source_timer.isActive()
    assert new.watch_timer.isActive()
    assert os.getpid() == pid
    assert shell.winId() == native_id
    assert shell.geometry() == geometry
    assert shell.screen() is screen
    assert new.window() is shell
    assert not new.isWindow()
    # A refresh while minimized must not show or activate a new native window.
    shell.showMinimized()
    old_content = new
    new.request_source_reload()
    assert shell.centralWidget() is not old_content
    assert shell.winId() == native_id
    assert shell.isMinimized()
    passed = True
    qapp.quit()
QTimer.singleShot(0, update)
QTimer.singleShot(5000, qapp.quit)
gui.main(["shuffledetector"])
assert passed, "automatic refresh did not replace the running window"
print("automatic window refresh passed")
'''
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", PYTHONPATH=str(package.parent),
               XDG_CONFIG_HOME=str(tmp_path / "config"))
    result = subprocess.run([sys.executable, "-c", script], cwd=tmp_path, env=env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "automatic window refresh passed" in result.stdout
