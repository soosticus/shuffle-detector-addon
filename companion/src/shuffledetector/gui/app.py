"""PySide6 desktop GUI."""

import html
import sys

from PySide6.QtCore import QSettings, Qt
from PySide6.QtGui import QAction, QColor
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QFormLayout, QFrame, QHBoxLayout, QLabel,
    QMainWindow, QMessageBox, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget, QToolButton,
    QTextBrowser, QVBoxLayout, QWidget, QAbstractItemView, QHeaderView, QProgressDialog,
)

from .. import addon_manager, calc, data_loader, updater

STATUS_TEXT = {"known": "Known", "learnable": "Learnable", "needs_skill": "Needs skill", "unknown": "?"}
ADDON_STATUS_TEXT = {
    "not_installed": "not installed",
    "up_to_date": "up to date",
    "outdated": "update available",
    "newer": "newer than bundled",
    "no_bundle": "bundled addon missing",
}
COLUMNS = ["Recipe", "Status", "Cost", "Net revenue", "Profit", "ROI", "Best exit"]


def _breakdown_html(r):
    def rows(lines, label, prices=False):
        out = []
        for l in lines:
            extra = (
                f"<td align='right'>{calc.fmt_money(l.ah_unit)}</td><td align='right'>{calc.fmt_money(l.vendor_unit)}</td>"
                if prices else ""
            )
            out.append(
                f"<tr><td>{l.qty:g} &times; {html.escape(l.name)}</td><td>{html.escape(l.source)}</td>{extra}"
                f"<td align='right'>{calc.fmt_money(l.unit)}</td><td align='right'>{calc.fmt_money(l.total)}</td></tr>"
            )
        extra_h = "<th align='right'>AH</th><th align='right'>Vendor</th>" if prices else ""
        return (f"<h4>{label}</h4><table cellpadding='3' width='100%'><tr><th align='left'>Item</th><th align='left'>Source</th>"
                f"{extra_h}<th align='right'>Each</th><th align='right'>Total</th></tr>{''.join(out)}</table>")

    def exits_table():
        out = []
        for e in r.exits:
            off = " (excluded)" if e.label not in r.allowed else ""
            mark = "<b>&#10003; " if e.label == r.exit else ""
            end = "</b>" if mark else ""
            out.append(f"<tr><td>{mark}{e.label}{end}{off}</td><td align='right'>{mark}{calc.fmt_money(e.net)}{end}</td>"
                       f"<td>{html.escape(e.note)}</td></tr>")
        return ("<table cellpadding='3' width='100%'><tr><th align='left'>Option</th><th align='right'>Net per craft</th><th></th></tr>"
                + "".join(out) + "</table>")

    roi = f"{r.roi * 100:.0f}%" if r.roi is not None else "-"
    parts = [
        f"<h3>{html.escape(r.name)}</h3>",
        f"<p>Status: <b>{STATUS_TEXT[r.status]}</b> &middot; Required skill: {r.recipe.get('skill', '?')} "
        f"&middot; Source: {html.escape(r.recipe.get('source', 'unknown'))}</p>",
        "<p><i>Reference data for this recipe is unverified.</i></p>" if not r.recipe.get("verified") else "",
        "<p><b>Step 1 - Craft (Tailoring)</b></p>" + rows(r.reagents, "Materials (cheapest source is used)", prices=True),
        f"<p>Craft cost: <b>{calc.fmt_money(r.cost)}</b> <i>(vendor prices are standard prices; reputation discounts are not applied)</i></p>",
        ("<p><b>Crafted item</b></p>" + rows([r.crafted], "Market value of one crafted piece", prices=True)
         if r.crafted else ""),
        "<p><b>Step 2 - Disenchant (Enchanting)</b></p>" + rows(r.yields, "Average yield per disenchant"),
        f"<p>Disenchant gross: {calc.fmt_money(r.gross)}</p>",
        "<p><b>Best way to cash out</b></p>" + exits_table(),
        f"<h3>Profit per craft: {calc.fmt_money(r.profit)} via {html.escape(r.exit)} (ROI {roi})</h3>",
    ]
    if r.missing:
        parts.append("<p style='color:#c60'>No price data for: " + html.escape(", ".join(sorted(set(r.missing)))) + "</p>")
    return "".join(parts)


class MainWindow(QMainWindow):
    def __init__(self, path=None, settings=None):
        super().__init__()
        self.setWindowTitle("ShuffleDetector")
        self.resize(1100, 680)
        self.settings = settings or QSettings("ShuffleDetector", "ShuffleDetector")
        self.scan = None
        self.ref = data_loader.load_reference()
        self.results = []
        self.extra_ref = None

        open_act = QAction("Open SavedVariables...", self, triggered=self.open_file)
        ref_act = QAction("Load extra reference data...", self, triggered=self.open_reference)
        reload_act = QAction("Reload", self, triggered=self.reload)
        menu = self.menuBar().addMenu("&File")
        wh_act = QAction("Update recipes && yields from Wowhead...", self, triggered=self.update_from_wowhead)
        for a in (open_act, ref_act, wh_act, reload_act):
            menu.addAction(a)
        self.path = None

        addon_menu = self.menuBar().addMenu("&Addon")
        self.install_act = QAction("Install / update addon", self, triggered=lambda: self.install_selected(True))
        addon_menu.addAction(self.install_act)
        addon_menu.addAction(QAction("Choose WoW folder...", self, triggered=self.choose_wow_folder))
        if not updater.from_source_tree():
            addon_menu.addAction(QAction("Check for updates...", self, triggered=self.check_updates))
        self.auto_update = QAction("Update addon automatically", self, checkable=True)
        self.auto_update.setChecked(self.settings.value("auto_update", True, type=bool))
        self.auto_update.toggled.connect(lambda v: self.settings.setValue("auto_update", v))
        addon_menu.addAction(self.auto_update)

        self.client = QComboBox()
        self.addon_label = QLabel()
        self.client.currentIndexChanged.connect(self.update_addon_label)
        self.realm = QComboBox()
        self.character = QComboBox()
        self.cut = QDoubleSpinBox(minimum=0, maximum=50, value=5, suffix=" %", singleStep=0.5)
        self.mode = QComboBox()
        self.mode.addItem("Average of lowest 5", "avg_low")
        self.mode.addItem("Lowest price", "min")
        self.known_only = QCheckBox("Known recipes only")
        self.known_only.setChecked(True)
        self.sort = QComboBox()
        self.sort.addItem("Profit", "profit")
        self.sort.addItem("ROI", "roi")
        self.exit_boxes = {}
        for label, tip in (("Disenchant", "Disenchant the crafted piece"), ("Sell on AH", "Resell the crafted piece on the AH"),
                           ("Vendor", "Sell the crafted piece to a vendor")):
            box = QCheckBox(label)
            box.setToolTip(tip)
            box.setChecked(True)
            self.exit_boxes[label] = box
        self.cog = QToolButton()
        self.cog.setText("\u2699")
        self.cog.setToolTip("Calculation settings")
        self.cog.setStyleSheet("QToolButton { font-size: 18px; padding: 0 6px; }")
        self.flyout = QFrame(self, Qt.Popup)
        self.flyout.setFrameShape(QFrame.StyledPanel)
        form = QFormLayout(self.flyout)
        form.addRow("Realm", self.realm)
        form.addRow("WoW client", self.client)
        form.addRow("AH cut", self.cut)
        form.addRow("Sell price", self.mode)
        form.addRow("Sort by", self.sort)
        exits_col = QVBoxLayout()
        for box in self.exit_boxes.values():
            exits_col.addWidget(box)
        form.addRow("Exits", exits_col)
        self.cog.clicked.connect(self.show_flyout)

        controls = QHBoxLayout()
        for label, w in (("Character", self.character),):
            controls.addWidget(QLabel(label))
            controls.addWidget(w)
        controls.addWidget(self.known_only)
        controls.addWidget(self.cog)
        controls.addStretch()
        controls.addWidget(self.addon_label)

        self.table = QTableWidget(0, len(COLUMNS))
        self.table.setHorizontalHeaderLabels(COLUMNS)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.verticalHeader().hide()
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(QHeaderView.ResizeToContents)
        header.setSectionResizeMode(0, QHeaderView.Interactive)
        header.setMinimumSectionSize(60)
        self.table.setColumnWidth(0, 230)
        self.table.setWordWrap(False)
        self.table.itemSelectionChanged.connect(self.show_detail)

        self.detail = QTextBrowser()
        self.suggest = QTextBrowser()
        tabs = QTabWidget()
        tabs.addTab(self.detail, "Breakdown")
        tabs.addTab(self.suggest, "Recipes to acquire")
        split = QSplitter(Qt.Horizontal)
        split.addWidget(self.table)
        split.addWidget(tabs)
        split.setSizes([680, 460])
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 2)

        central = QWidget()
        lay = QVBoxLayout(central)
        lay.addLayout(controls, 0)
        lay.addWidget(split, 1)
        self.setCentralWidget(central)
        self.statusBar().showMessage("Open the addon's SavedVariables file to begin.")

        for sig in [b.toggled for b in self.exit_boxes.values()] + [self.cut.valueChanged, self.mode.currentIndexChanged, self.known_only.toggled, self.sort.currentIndexChanged]:
            sig.connect(self.refresh)
        self.realm.currentIndexChanged.connect(self.refresh)
        self.character.currentIndexChanged.connect(self.refresh)

        self.populate_clients()
        self.auto_update_addon()
        path = path or next(iter(data_loader.candidate_saved_variables(self.wow_roots())), None)
        if path:
            self.load(str(path))

    def wow_roots(self):
        saved = self.settings.value("wow_path", "", type=str)
        return [saved] if saved else []

    def populate_clients(self):
        self.client.blockSignals(True)
        self.client.clear()
        for inst in addon_manager.discover_installs(self.wow_roots()):
            self.client.addItem(inst.flavor, inst)
        self.client.blockSignals(False)
        self.update_addon_label()

    def update_addon_label(self):
        inst = self.client.currentData()
        self.install_act.setEnabled(inst is not None)
        if inst is None:
            self.addon_label.setText("Addon: no WoW install found")
            return
        have = inst.installed_version
        text = f"Addon: {'v' + have if have else 'not installed'} - {ADDON_STATUS_TEXT[addon_manager.status(inst)]}"
        self.addon_label.setText(text)

    def install_selected(self, announce=False):
        inst = self.client.currentData()
        if inst is None:
            return
        try:
            version = addon_manager.install_addon(inst)
        except Exception as e:
            QMessageBox.critical(self, "Addon install failed", f"{e}\n\nClose WoW and try again.")
            return
        self.update_addon_label()
        msg = f"Installed addon v{version} to {inst.addons_dir}. Reload the UI (/reload) or restart WoW."
        self.statusBar().showMessage(msg)
        if announce:
            QMessageBox.information(self, "Addon installed", msg)

    def auto_update_addon(self):
        if not self.auto_update.isChecked():
            return
        for i in range(self.client.count()):
            inst = self.client.itemData(i)
            if inst.installed_version and addon_manager.status(inst) == "outdated":
                self.client.setCurrentIndex(i)
                self.install_selected()

    def check_updates(self):
        try:
            rel = updater.latest_release()
            addon_v = updater.download_addon(rel)
        except Exception as e:  # network or GitHub errors
            QMessageBox.warning(self, "Check for updates", f"Could not check for updates:\n{e}")
            return
        lines = []
        if updater.app_update_available(rel):
            lines.append(f"A new companion version ({rel['tag']}) is available:\n{rel['url']}")
        if addon_v:
            lines.append(f"Addon {addon_v} downloaded. It will be installed to WoW now.")
        if not lines:
            lines.append(f"You are up to date (latest release {rel['tag']}).")
        QMessageBox.information(self, "Check for updates", "\n\n".join(lines))
        if addon_v:
            self.update_addon_label()
            self.install_selected(True)

    def choose_wow_folder(self):
        d = QFileDialog.getExistingDirectory(self, "Select the World of Warcraft folder")
        if not d:
            return
        if not addon_manager.installs_in(d):
            QMessageBox.warning(self, "WoW folder", "No Interface/AddOns folder found there.")
            return
        self.settings.setValue("wow_path", d)
        self.populate_clients()

    def open_file(self):
        p, _ = QFileDialog.getOpenFileName(self, "Open SavedVariables", "", "Lua files (*.lua)")
        if p:
            self.load(p)

    def open_reference(self):
        p, _ = QFileDialog.getOpenFileName(self, "Extra reference data", "", "JSON (*.json)")
        if p:
            self.extra_ref = p
            self.reload()

    def update_from_wowhead(self):
        from .. import wowhead
        dlg = QProgressDialog("Contacting Wowhead...", "Cancel", 0, 100, self)
        dlg.setWindowTitle("Wowhead")
        dlg.setWindowModality(Qt.WindowModal)
        dlg.setMinimumDuration(0)

        def progress(done, total, msg):
            dlg.setMaximum(total)
            dlg.setValue(done)
            dlg.setLabelText(f"{msg}  ({done}/{total})")
            QApplication.processEvents()
            return not dlg.wasCanceled()

        try:
            path, n = wowhead.update(progress=progress)
        except KeyboardInterrupt:
            return
        except Exception as e:
            QMessageBox.critical(self, "Wowhead", f"Update failed: {e}")
            return
        finally:
            dlg.close()
        self.reload()
        self.statusBar().showMessage(f"Loaded {n} recipes from Wowhead", 8000)

    def reload(self):
        try:
            self.ref = data_loader.load_reference(extra=self.extra_ref)
        except Exception as e:
            QMessageBox.critical(self, "Reference data", str(e))
            return
        if self.path:
            self.load(self.path)

    def load(self, path):
        try:
            self.scan = data_loader.load_scan_data(path)
        except Exception as e:
            QMessageBox.critical(self, "Could not load data", str(e))
            return
        self.path = path
        for box, values in ((self.realm, self.scan.realms), (self.character, [""] + sorted(self.scan.characters))):
            box.blockSignals(True)
            box.clear()
            for v in values:
                box.addItem(v or "All characters", v or None)
            box.blockSignals(False)
        self.refresh()

    def show_flyout(self):
        self.flyout.adjustSize()
        self.flyout.move(self.cog.mapToGlobal(self.cog.rect().bottomLeft()))
        self.flyout.show()

    def refresh(self):
        if not self.scan or not self.scan.scans:
            self.statusBar().showMessage("No auction scans in file. Run /shuffledetector scan at the auction house.")
            return
        exits = tuple(n for n, b in self.exit_boxes.items() if b.isChecked())
        settings = calc.Settings(ah_cut=self.cut.value() / 100, price_mode=self.mode.currentData(), exits=exits)
        self.results = calc.rank(self.scan, self.ref, settings, self.realm.currentText(), self.character.currentData())
        has_known = any(r.status == "known" for r in self.results)
        shown = [r for r in self.results if r.status == "known"] if self.known_only.isChecked() and has_known else self.results
        if self.sort.currentData() == "roi":
            shown = sorted(shown, key=lambda r: (r.roi is None, -(r.roi or 0)))
        self.shown = shown
        self.table.setRowCount(len(shown))
        for row, r in enumerate(shown):
            roi = f"{r.roi * 100:.0f}%" if r.roi is not None else "-"
            vals = [r.name, STATUS_TEXT[r.status], calc.fmt_money(r.cost),             calc.fmt_money(r.net), calc.fmt_money(r.profit), roi, r.exit]
            for col, v in enumerate(vals):
                item = QTableWidgetItem(v)
                if 2 <= col <= 5:
                    item.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
                if col == 4 and r.profit is not None:
                    item.setForeground(QColor("#2e9e44" if r.profit > 0 else "#d04040"))
                self.table.setItem(row, col, item)
        sugg = calc.suggestions(self.results)
        self.suggest.setHtml(
            "<h3>Profitable recipes you don't know</h3>" + (
                "<ol>" + "".join(
                    f"<li><b>{html.escape(r.name)}</b> - {calc.fmt_money(r.profit)} per craft "
                    f"(skill {r.recipe.get('skill', '?')}, {STATUS_TEXT[r.status]}; {html.escape(r.recipe.get('source', ''))})</li>"
                    for r in sugg
                ) + "</ol>" if sugg else "<p>None found.</p>"
            )
        )
        scanned = self.scan.scans[self.realm.currentText()]
        note = " - Auctionator data (min prices only, no depth)" if scanned["shallow"] else ""
        self.statusBar().showMessage(f"{self.path} - {len(scanned['items'])} items, {scanned['listings']} listings{note}")
        if shown:
            self.table.selectRow(0)
        else:
            self.detail.clear()

    def show_detail(self):
        rows = self.table.selectionModel().selectedRows()
        if rows:
            self.detail.setHtml(_breakdown_html(self.shown[rows[0].row()]))


def main(argv=None):
    argv = sys.argv if argv is None else argv
    updater.use_cached_addon()
    app = QApplication(argv)
    win = MainWindow(argv[1] if len(argv) > 1 else None)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
