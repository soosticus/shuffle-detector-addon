"""PySide6 desktop GUI."""

import html
import json
import os
import sys

from PySide6.QtCore import QSettings, Qt, QTimer
from PySide6.QtGui import QAction, QColor
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QFormLayout, QFrame, QHBoxLayout, QLabel, QLineEdit,
    QMainWindow, QMessageBox, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget, QToolButton,
    QTextBrowser, QVBoxLayout, QWidget, QAbstractItemView, QHeaderView,
)

from .. import addon_manager, calc, calculator, data_loader, plan, updater

STATUS_TEXT = {"known": "Known", "learnable": "Learnable", "needs_skill": "Needs skill", "unknown": "?"}
ADDON_STATUS_TEXT = {
    "not_installed": "not installed",
    "up_to_date": "up to date",
    "outdated": "update available",
    "newer": "newer than bundled",
    "no_bundle": "bundled addon missing",
}
COLUMNS = ["Recipe", "Profession", "Status", "Cost", "Net revenue", "Profit", "ROI", "Best exit", "Time/craft", "Profit/hour"]


def _breakdown_html(r):
    def rows(lines, label, prices=False):
        out = []
        for l in lines:
            extra = (
                f"<td align='right'>{calc.fmt_money(l.ah_unit)}</td><td align='right'>{calc.fmt_money(l.vendor_unit)}</td>"
                f"<td align='right'>{calc.fmt_money(l.raw_unit) if l.raw_item else ''}</td>"
                if prices else ""
            )
            out.append(
                f"<tr><td>{l.qty:g} &times; {html.escape(l.name)}</td><td>{html.escape(l.source)}</td>{extra}"
                f"<td align='right'>{calc.fmt_money(l.unit)}</td><td align='right'>{calc.fmt_money(l.total)}</td></tr>"
            )
        extra_h = "<th align='right'>AH</th><th align='right'>Vendor</th><th align='right'>Raw</th>" if prices else ""
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
        f"<p><b>{'Step 1 - ' if r.yields else ''}Craft ({html.escape(r.profession)})</b></p>"
        + rows(r.reagents, "Materials (cheapest source is used)", prices=True),
        f"<p>Craft cost: <b>{calc.fmt_money(r.cost)}</b> <i>(vendor prices are standard prices; reputation discounts are not applied)</i></p>",
        ("<p><b>Crafted item</b></p>" + rows([r.crafted], "Market value of one crafted piece", prices=True)
         if r.crafted else ""),
        ("<p><b>Step 2 - Disenchant (Enchanting)</b></p>" + rows(r.yields, "Average yield per disenchant")
         + f"<p>Disenchant gross: {calc.fmt_money(r.gross)}</p>"
         + (f"<p><i>{r.recipe['yield_samples']} observed disenchants</i></p>" if r.recipe.get("yield_samples")
            else "<p><i>Seed yield estimate, unverified</i></p>") if r.yields else ""),
        "<p><b>Best way to cash out</b></p>" + exits_table(),
        f"<h3>Profit per craft: {calc.fmt_money(r.profit)} via {html.escape(r.exit)} (ROI {roi})</h3>",
    ]
    if r.missing:
        parts.append("<p style='color:#c60'>No price data for: " + html.escape(", ".join(sorted(set(r.missing)))) + "</p>")
    return "".join(parts)


def _batch_html(b):
    m = calc.fmt_money
    if not b.crafts:
        return (f"<h3>{html.escape(b.result.name)}</h3>"
                + "".join(f"<p style='color:#c60'>{html.escape(n)}</p>" for n in b.notes))
    limits = {"availability": "limited by what is listed", "budget": "limited by your budget", "cap": "capped"}
    buy = []
    for p in b.purchases:
        where = ", ".join(x for x in (f"{p.ah_qty} from the AH ({m(p.ah_cost)})" if p.ah_qty else "",
                                       f"{p.vendor_qty} from a vendor ({m(p.vendor_cost)})" if p.vendor_qty else "",
                                       f"{p.custom_qty} at your cost ({m(p.custom_cost)})" if p.custom_qty else "",
                                       f"<span style='color:#c60'>{p.short} unavailable</span>" if p.short else "") if x)
        made = f" <span style='color:gray'>({html.escape(p.note)})</span>" if p.note else ""
        buy.append(f"<tr><td><b>{p.qty:,} &times; {html.escape(p.name)}</b>{made}</td><td>{where or '-'}</td>"
                   f"<td align='right'>{m(p.total)}</td></tr>")
    out = []
    for o in b.outputs:
        rng = f" ({o.low:,}&ndash;{o.high:,})" if o.low != o.high else ""
        out.append(f"<tr><td>{o.expected:,.1f} &times; {html.escape(o.name)}{rng}</td>"
                   f"<td align='right'>{m(o.unit)} each</td><td align='right'>{m(o.value)}</td></tr>")
    spread = b.revenue_low != b.revenue_high
    rng = lambda lo, hi: f" <span style='color:gray'>(90%: {m(lo)} to {m(hi)})</span>" if spread else ""
    parts = [f"<h3>{html.escape(b.result.name)}: {b.crafts:,} crafts"
             + (f" <small>({limits[b.limited_by]})</small>" if b.limited_by else "") + "</h3>",
             "<p><b>Buy</b></p><table cellpadding='3' width='100%'>" + "".join(buy) + "</table>",
             f"<p>Total cost: <b>{m(b.cost)}</b>"
             + (f" &nbsp; Expected time: <b>{calc.fmt_duration(b.seconds)}</b>" if b.seconds else "") + "</p>"]
    if out:
        parts.append(f"<p><b>Expected output</b> ({html.escape(b.exit)}"
                     + (", 90% range per item" if b.exit == "Disenchant" else "") + ")</p>"
                     "<table cellpadding='3' width='100%'>" + "".join(out) + "</table>")
    if b.profit is not None:
        color = "#2e9e44" if b.profit > 0 else "#d04040"
        roi = f", ROI {b.roi * 100:.0f}%" if b.roi is not None else ""
        cut = "" if b.exit == "Vendor" else " after the AH cut"
        parts += [f"<p>Net revenue{cut}: <b>{m(b.revenue)}</b>{rng(b.revenue_low, b.revenue_high)}</p>",
                  f"<h3>Profit: <span style='color:{color}'>{m(b.profit)}</span>{roi}</h3>"
                  + (f"<p style='color:gray'>Likely range: {m(b.profit_low)} to {m(b.profit_high)}</p>" if spread else "")
                  + (f"<p>Profit per hour: <b>{m(b.profit_per_hour)}</b></p>" if b.profit_per_hour is not None else "")]
    parts += [f"<p style='color:gray'><i>{html.escape(n)}</i></p>" for n in b.notes]
    return "".join(parts)


class MainWindow(QMainWindow):
    def __init__(self, path=None, settings=None):
        super().__init__()
        self.setWindowTitle("ShuffleDetector")
        self.resize(1100, 680)
        self.settings = settings or QSettings("ShuffleDetector", "ShuffleDetector")
        self.scan = None
        self.base_ref = self.ref = data_loader.load_reference()
        self.results = []
        self.shown = []
        self.extra_ref = None

        open_act = QAction("Open SavedVariables...", self, triggered=self.open_file)
        ref_act = QAction("Load extra reference data...", self, triggered=self.open_reference)
        reload_act = QAction("Reload", self, triggered=self.reload)
        menu = self.menuBar().addMenu("&File")
        for a in (open_act, ref_act, reload_act):
            menu.addAction(a)
        self.path = None
        self.loaded_mtime = None
        addon_menu = self.menuBar().addMenu("&Addon")
        self.install_act = QAction("Install / update addon", self, triggered=lambda: self.install_selected(True))
        addon_menu.addAction(self.install_act)
        self.send_act = QAction("Send selected shuffle to game", self, triggered=self.send_plan)
        addon_menu.addAction(self.send_act)
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
        self.profession = QComboBox()
        self.known_only = QCheckBox("Known recipes only")
        self.known_only.setChecked(True)
        self.sort = QComboBox()
        self.sort.addItem("Profit", "profit")
        self.sort.addItem("ROI", "roi")
        self.sort.addItem("Profit per hour", "hour")
        self.craft_time = QDoubleSpinBox(minimum=0, maximum=600, value=30, suffix=" s", singleStep=1)
        self.craft_time.setToolTip("Casting time of one craft. A recipe's own craft_seconds in the reference data overrides it.")
        self.de_time = QDoubleSpinBox(minimum=0, maximum=60, value=3, suffix=" s", singleStep=0.5)
        self.de_time.setToolTip("Casting time of one disenchant")
        self.exit_boxes = {}
        for label, tip in (("Disenchant", "Disenchant the crafted piece"), ("Sell on AH", "Resell the crafted piece on the AH"),
                           ("Vendor", "Sell the crafted piece to a vendor")):
            box = QCheckBox(label)
            box.setToolTip(tip)
            box.setChecked(self.settings.value(f"exit/{label}", True, type=bool))
            box.toggled.connect(lambda v, k=label: self.settings.setValue(f"exit/{k}", v))
            self.exit_boxes[label] = box
        self.cog = QToolButton()
        self.cog.setText("\u2699")
        self.cog.setToolTip("Calculation settings")
        cog_font = self.cog.font()
        cog_font.setPointSizeF(max(cog_font.pointSizeF(), 9.0) * 1.6)
        self.cog.setFont(cog_font)
        self.cog.setStyleSheet("QToolButton { padding: 0 6px; }")
        self.flyout = QFrame(self, Qt.Popup)
        self.flyout.setFrameShape(QFrame.StyledPanel)
        form = QFormLayout(self.flyout)
        form.addRow("Realm", self.realm)
        form.addRow("WoW client", self.client)
        form.addRow("AH cut", self.cut)
        form.addRow("Sell price", self.mode)
        form.addRow("Craft time", self.craft_time)
        form.addRow("Disenchant time", self.de_time)
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
        controls.addWidget(QLabel("Profession"))
        controls.addWidget(self.profession)
        controls.addWidget(self.known_only)
        controls.addWidget(self.cog)
        self.send_btn = QToolButton()
        self.send_btn.setText("Send to game")
        self.send_btn.setToolTip("Write the selected shuffle to the addon for the in-game shuffle tracker and macro (then /reload)")
        self.send_btn.clicked.connect(self.send_plan)
        controls.addWidget(self.send_btn)
        controls.addStretch()
        controls.addWidget(self.addon_label)

        self.table = QTableWidget(0, len(COLUMNS))
        self.table.setHorizontalHeaderLabels(COLUMNS)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.verticalHeader().hide()
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(QHeaderView.Interactive)
        header.setMinimumSectionSize(60)
        self.table.setColumnWidth(0, 230)
        self.table.setWordWrap(False)
        self.table.itemSelectionChanged.connect(self.show_detail)

        self.detail = QTextBrowser()
        self.suggest = QTextBrowser()
        self.calc_mode = QComboBox()
        self.calc_mode.addItem("Number of crafts", "crafts")
        self.calc_mode.addItem("Budget", "budget")
        self.calc_crafts = QSpinBox(minimum=1, maximum=calculator.MAX_CRAFTS, value=20)
        self.calc_budget = QLineEdit("100g")
        self.calc_budget.setToolTip("For example 250g, 12g 30s or a number of copper")
        self.calc_budget.setMaximumWidth(120)
        self.cost_overrides = {}
        try:
            self.cost_overrides = {int(k): int(v) for k, v in
                                   json.loads(self.settings.value("material_costs_by_item", "{}", type=str)).items()}
        except (ValueError, TypeError, AttributeError):
            pass
        self.cost_rows = {}
        self.cost_form = QFormLayout()
        self.cost_box = QWidget()
        self.cost_box.setLayout(self.cost_form)
        self.calc_out = QTextBrowser()
        calc_page = QWidget()
        calc_lay = QVBoxLayout(calc_page)
        calc_row = QHBoxLayout()
        for w in (QLabel("Plan by"), self.calc_mode, self.calc_crafts, self.calc_budget):
            calc_row.addWidget(w)
        calc_row.addStretch()
        calc_lay.addLayout(calc_row)
        self.cost_title = QLabel("Cost per material: the market average for this batch; type your own average to replace it")
        calc_lay.addWidget(self.cost_title)
        calc_lay.addWidget(self.cost_box)
        calc_lay.addWidget(self.calc_out, 1)
        self.calc_mode.currentIndexChanged.connect(self.update_calc)
        self.calc_crafts.valueChanged.connect(self.update_calc)
        self.calc_budget.textChanged.connect(self.update_calc)
        tabs = QTabWidget()
        tabs.addTab(self.detail, "Breakdown")
        tabs.addTab(calc_page, "Calculator")
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

        for sig in [b.toggled for b in self.exit_boxes.values()] + [self.cut.valueChanged, self.craft_time.valueChanged, self.de_time.valueChanged, self.mode.currentIndexChanged, self.known_only.toggled, self.sort.currentIndexChanged, self.profession.currentIndexChanged]:
            sig.connect(self.refresh)
        self.realm.currentIndexChanged.connect(self.refresh)
        self.character.currentIndexChanged.connect(self.refresh)

        self.populate_clients()
        self.auto_update_addon()
        path = path or next(iter(data_loader.candidate_saved_variables(self.wow_roots())), None)
        if path:
            self.load(str(path))
        self.watch_timer = QTimer(self, interval=2000, timeout=self.check_for_changes)
        self.watch_timer.start()

    def check_for_changes(self):
        """Reload when the game rewrites the SavedVariables file (or one appears)."""
        try:
            path = self.path or next(iter(data_loader.candidate_saved_variables(self.wow_roots())), None)
            if not path:
                return
            mtime = os.stat(path).st_mtime
        except OSError:
            return
        if self.path and mtime == self.loaded_mtime:
            return
        if self.load(str(path), silent=True):
            self.statusBar().showMessage(f"Reloaded {path} (changed in game)", 8000)

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

    def send_plan(self):
        rows = self.table.selectionModel().selectedRows()
        inst = self.client.currentData()
        if not rows or inst is None:
            QMessageBox.information(self, "Send to game", "Select a shuffle and a WoW client first.")
            return
        result = self.shown[rows[0].row()]
        try:
            plan.write_plan(inst, plan.build_plan(result))
        except Exception as e:
            QMessageBox.critical(self, "Send to game failed", str(e))
            return
        msg = (f"Sent {result.name} to {inst.flavor}. In game: /reload, then /shuffledetector shuffle "
               "to show the button (or bind a key under Key Bindings > AddOns).")
        self.statusBar().showMessage(msg)
        QMessageBox.information(self, "Sent to game", msg)

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

    def reload(self):
        try:
            self.base_ref = data_loader.load_reference(extra=self.extra_ref)
            self.ref = self.base_ref.with_observed(self.scan) if self.scan else self.base_ref
        except Exception as e:
            QMessageBox.critical(self, "Reference data", str(e))
            return
        self.populate_professions()
        if self.path:
            self.load(self.path)

    def populate_professions(self):
        wanted = self.profession.currentData() or self.settings.value("profession", "", type=str) or None
        names = sorted({calc.recipe_profession(r) for r in self.ref.recipes})
        self.profession.blockSignals(True)
        self.profession.clear()
        self.profession.addItem("All professions", None)
        for n in names:
            self.profession.addItem(n, n)
        idx = self.profession.findData(wanted)
        self.profession.setCurrentIndex(max(idx, 0))
        self.profession.blockSignals(False)

    def load(self, path, silent=False):
        try:
            mtime = os.stat(path).st_mtime
            self.scan = data_loader.load_scan_data(path)
        except Exception as e:
            if not silent:
                QMessageBox.critical(self, "Could not load data", str(e))
            return False
        self.path = path
        self.loaded_mtime = mtime
        self.ref = self.base_ref.with_observed(self.scan)
        self.populate_professions()
        selected = (self.realm.currentText(), self.character.currentData())
        for box, values in ((self.realm, self.scan.realms), (self.character, [""] + sorted(self.scan.characters))):
            box.blockSignals(True)
            box.clear()
            for v in values:
                box.addItem(v or "All characters", v or None)
            box.blockSignals(False)
        for box, value in ((self.realm, selected[0]), (self.character, selected[1])):
            idx = box.findData(value) if box is self.character else box.findText(value)
            if idx >= 0:
                box.blockSignals(True)
                box.setCurrentIndex(idx)
                box.blockSignals(False)
        self.refresh()
        return True

    def show_flyout(self):
        self.flyout.adjustSize()
        self.flyout.move(self.cog.mapToGlobal(self.cog.rect().bottomLeft()))
        self.flyout.show()

    def refresh(self):
        if not self.scan or not self.scan.scans:
            self.statusBar().showMessage("No auction scans in file. Run /shuffledetector scan at the auction house.")
            return
        exits = tuple(n for n, b in self.exit_boxes.items() if b.isChecked())
        rows = self.table.selectionModel().selectedRows()
        keep = self.shown[rows[0].row()].name if rows and rows[0].row() < len(self.shown) else None
        settings = calc.Settings(ah_cut=self.cut.value() / 100, price_mode=self.mode.currentData(), exits=exits,
                                 craft_seconds=self.craft_time.value(), disenchant_seconds=self.de_time.value())
        chosen = self.profession.currentData()
        self.settings.setValue("profession", chosen or "")
        self.results = calc.rank(self.scan, self.ref, settings, self.realm.currentText(), self.character.currentData(),
                                 professions=[chosen] if chosen else None)
        has_known = any(r.status == "known" for r in self.results)
        self.known_only.setText("Known recipes only" if has_known else "Known recipes only (none recorded)")
        self.known_only.setToolTip(
            "" if has_known else "No known recipes are recorded for this selection, so all recipes are shown. "
            "In game, open the profession window on the character, then /reload.")
        shown = [r for r in self.results if r.status == "known"] if self.known_only.isChecked() and has_known else self.results
        if self.sort.currentData() == "roi":
            shown = sorted(shown, key=lambda r: (r.roi is None, -(r.roi or 0)))
        elif self.sort.currentData() == "hour":
            shown = sorted(shown, key=lambda r: (r.profit_per_hour is None, -(r.profit_per_hour or 0)))
        self.shown = shown
        self.table.setUpdatesEnabled(False)
        self.table.blockSignals(True)
        self.table.setRowCount(len(shown))
        for row, r in enumerate(shown):
            roi = f"{r.roi * 100:.0f}%" if r.roi is not None else "-"
            vals = [r.name, r.profession, STATUS_TEXT[r.status], calc.fmt_money(r.cost), calc.fmt_money(r.net), calc.fmt_money(r.profit), roi, r.exit,
                    calc.fmt_duration(r.seconds), calc.fmt_money(r.profit_per_hour)]
            for col, v in enumerate(vals):
                item = QTableWidgetItem(v)
                if 3 <= col <= 6 or col >= 8:
                    item.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
                if col == 5 and r.profit is not None:
                    item.setForeground(QColor("#2e9e44" if r.profit > 0 else "#d04040"))
                self.table.setItem(row, col, item)
        for col in range(1, len(COLUMNS)):
            self.table.resizeColumnToContents(col)
        self.table.blockSignals(False)
        self.table.setUpdatesEnabled(True)
        sugg =calc.suggestions(self.results)
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
        if self.known_only.isChecked() and not has_known:
            note += " - no known recipes recorded: open the profession window in game, then /reload"
        self.statusBar().showMessage(f"{self.path} - {len(scanned['items'])} items, {scanned['listings']} listings{note}")
        if shown:
            self.table.selectRow(next((i for i, r in enumerate(shown) if r.name == keep), 0))
            self.show_detail()
        else:
            self.detail.clear()
            self.update_calc()

    def show_detail(self):
        rows = self.table.selectionModel().selectedRows()
        if rows:
            self.detail.setHtml(_breakdown_html(self.shown[rows[0].row()]))
        self.update_calc()

    def _rebuild_cost_rows(self, materials):
        while self.cost_form.rowCount():
            self.cost_form.removeRow(0)
        self.cost_rows = {}
        for item, name, _ in materials:
            boxes, line = [], QHBoxLayout()
            for suffix, top, width in (("g", 9_999_999, 95), ("s", 99, 55), ("c", 99, 55)):
                box = QSpinBox(minimum=0, maximum=top, suffix=suffix)
                box.setMaximumWidth(width)
                box.setButtonSymbols(QSpinBox.NoButtons)
                box.setAlignment(Qt.AlignRight)
                box.setToolTip("Your average cost per unit. Grey is the market average.")
                box.valueChanged.connect(lambda _v, i=item: self._cost_edited(i))
                boxes.append(box)
                line.addWidget(box)
            reset = QToolButton()
            reset.setText("Use market")
            reset.setToolTip("Go back to the market average")
            reset.clicked.connect(lambda _checked=False, i=item: self._cost_reset(i))
            line.addWidget(reset)
            line.addStretch()
            self.cost_rows[item] = (boxes, reset)
            self.cost_form.addRow(name, line)
        self.cost_box.setVisible(bool(materials))
        self.cost_title.setVisible(bool(materials))

    def _fill_cost_rows(self, materials):
        for item, _, market in materials:
            boxes, reset = self.cost_rows[item]
            own = item in self.cost_overrides
            copper = self.cost_overrides[item] if own else (round(market) if market is not None else 0)
            for box, value in zip(boxes, (copper // 10000, copper // 100 % 100, copper % 100)):
                box.blockSignals(True)
                box.setValue(value)
                box.blockSignals(False)
                box.setStyleSheet("" if own else "color: gray;")
            reset.setEnabled(own)

    def _cost_edited(self, item):
        g, s, c = (box.value() for box in self.cost_rows[item][0])
        self.cost_overrides[item] = g * 10000 + s * 100 + c
        self._save_costs()
        self.update_calc()

    def _cost_reset(self, item):
        self.cost_overrides.pop(item, None)
        self._save_costs()
        self.update_calc()

    def _save_costs(self):
        self.settings.setValue("material_costs_by_item", json.dumps({str(k): v for k, v in self.cost_overrides.items()}))

    def update_calc(self):
        rows = self.table.selectionModel().selectedRows()
        by_budget = self.calc_mode.currentData() == "budget"
        self.calc_crafts.setVisible(not by_budget)
        self.calc_budget.setVisible(by_budget)
        if not rows or rows[0].row() >= len(self.shown) or not self.scan or not self.scan.scans:
            self.calc_out.setHtml("<p>Select a shuffle to plan a batch.</p>")
            self._rebuild_cost_rows([])
            return
        budget = None
        if by_budget:
            try:
                budget = calculator.parse_money(self.calc_budget.text())
            except ValueError as e:
                self.calc_out.setHtml(f"<p style='color:#c60'>{html.escape(str(e))}</p>")
                return
        exits = tuple(n for n, b in self.exit_boxes.items() if b.isChecked())
        settings = calc.Settings(ah_cut=self.cut.value() / 100, price_mode=self.mode.currentData(), exits=exits,
                                 craft_seconds=self.craft_time.value(), disenchant_seconds=self.de_time.value())
        items = calculator.realm_items(self.scan, self.realm.currentText())
        result = self.shown[rows[0].row()]
        crafts = None if by_budget else self.calc_crafts.value()
        market = calculator.calculate(result, items, self.ref, settings, crafts=crafts, budget=budget)
        materials = calculator.market_costs(result.recipe, items, self.ref, market.crafts)
        if list(self.cost_rows) != [m[0] for m in materials]:
            self._rebuild_cost_rows(materials)
        self._fill_cost_rows(materials)
        costs = {i: c for i, c in self.cost_overrides.items() if i in self.cost_rows}
        batch = calculator.calculate(result, items, self.ref, settings, crafts=crafts, budget=budget, costs=costs)
        self.calc_out.setHtml(_batch_html(batch))


def main(argv=None):
    argv = sys.argv if argv is None else argv
    updater.use_cached_addon()
    app = QApplication(argv)
    win = MainWindow(argv[1] if len(argv) > 1 else None)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
