"""SavedVariables and excluded characters must stay scoped to the selected client."""

import json

import pytest

pytest.importorskip("PySide6.QtWidgets", exc_type=ImportError)

from PySide6.QtCore import QSettings, QTimer
from PySide6.QtWidgets import QApplication, QCheckBox, QDialog

from shuffledetector import addon_manager, data_loader
from shuffledetector.gui import app as gui


@pytest.fixture
def clients(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    app = QApplication.instance() or QApplication([])
    installs = []
    files = []
    for flavor, character in (("_beta_", "Beta-Realm"), ("_release_", "Live-Realm")):
        root = tmp_path / flavor
        addons = root / "Interface/AddOns"
        addons.mkdir(parents=True)
        path = root / "WTF/Account/test/SavedVariables/ShuffleDetector.lua"
        path.parent.mkdir(parents=True)
        path.write_text(f'AHSnapshotDB = {{ characters = {{ ["{character}"] = {{ professions = {{}} }} }} }}')
        files.append(path)
        installs.append(addon_manager.Install(flavor, addons))
    monkeypatch.setattr(addon_manager, "discover_installs", lambda roots: installs)
    monkeypatch.setattr(gui.MainWindow, "auto_update_addon", lambda self: None)
    settings = QSettings(str(tmp_path / "settings.ini"), QSettings.IniFormat)
    window = gui.MainWindow(settings=settings)
    yield window, installs, files
    window.close()
    app.processEvents()


def test_switch_client_replaces_data_and_remembers_install(clients):
    window, installs, files = clients
    assert window.path == str(files[0])
    assert set(window.scan.characters) == {"Beta-Realm"}
    window.client.setCurrentIndex(1)
    assert window.path == str(files[1])
    assert set(window.scan.characters) == {"Live-Realm"}
    assert window.settings.value("selected_install") == str(files[1].parents[4])
    window.populate_clients()
    assert window.client.currentData() == installs[1]
    assert window.path == str(files[1])


def test_client_without_saved_variables_clears_stale_results(clients):
    window, _, files = clients
    files[1].unlink()
    window.table.setRowCount(2)
    window.detail.setHtml("stale")
    window.calc_out.setHtml("stale")
    window.client.setCurrentIndex(1)
    assert window.path is None and window.scan is None
    assert window.table.rowCount() == 0
    assert not window.detail.toPlainText()
    assert not window.calc_out.toPlainText()
    window.check_for_changes()
    assert window.path is None


def test_exclusion_scoped_to_install_and_reversible(clients, monkeypatch):
    window, _, files = clients
    recipe = {"name": "Beta recipe", "item": 20, "spell": 10, "reagents": [{"item": 1, "qty": 2}]}
    scan = data_loader.ScanData(characters={"Same-Realm": {"professions": {
        "Tailoring": {"recipes": [recipe]}}}})
    monkeypatch.setattr(data_loader, "load_scan_data", lambda path: data_loader.ScanData(characters=scan.characters.copy()))
    key = window.install_key()
    window.settings.setValue("excluded_characters_by_install", json.dumps({key: ["Same-Realm"]}))
    before = files[0].read_bytes()
    assert window.load(str(files[0]))
    assert not window.scan.characters
    assert not any(r["name"] == "Beta recipe" for r in window.ref.recipes)
    assert files[0].read_bytes() == before
    window.client.setCurrentIndex(1)
    assert "Same-Realm" in window.scan.characters
    assert any(r["name"] == "Beta recipe" for r in window.ref.recipes)
    window.settings.setValue("excluded_characters_by_install", "{}")
    window.client.setCurrentIndex(0)
    assert "Same-Realm" in window.scan.characters


def test_manual_file_selects_matching_install(clients):
    window, installs, files = clients
    assert window.load(str(files[1]))
    assert window.client.currentData() == installs[1]
    assert set(window.scan.characters) == {"Live-Realm"}


def test_no_prices_clears_previous_display(clients):
    window, _, files = clients
    window.table.setRowCount(2)
    window.suggest.setHtml("stale")
    assert window.load(str(files[0]))
    assert window.table.rowCount() == 0
    assert not window.suggest.toPlainText()


def test_character_management_dialog_saves_without_touching_game(clients):
    window, _, files = clients
    original = files[0].read_bytes()

    def save():
        dialog = QApplication.activeModalWidget()
        assert isinstance(dialog, QDialog)
        boxes = dialog.findChildren(QCheckBox)
        assert len(boxes) == 1
        boxes[0].setChecked(False)
        dialog.accept()

    QTimer.singleShot(0, save)
    window.manage_characters()
    assert not window.scan.characters
    assert files[0].read_bytes() == original
    assert window.excluded_characters()[window.install_key()] == ["Beta-Realm"]


def test_startup_and_poll_use_saved_install_only(clients):
    window, installs, files = clients
    window.client.setCurrentIndex(1)
    replacement = gui.MainWindow(settings=window.settings, resumed=True)
    try:
        assert replacement.client.currentData() == installs[1]
        assert replacement.path == str(files[1])
        replacement.clear_loaded_data()
        replacement.check_for_changes()
        assert replacement.path == str(files[1])
    finally:
        replacement.close()
