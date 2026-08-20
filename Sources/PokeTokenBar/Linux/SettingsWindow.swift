#if os(Linux)
import CGtk
import Foundation

/// Settings — the Linux counterpart of the macOS settings sheet.
///
/// Every control writes straight through to `UsageStore` / `CompanionStore`, which persist to
/// `UserDefaults` on set. There is no apply/cancel step, matching macOS: a toggle that needs
/// confirming is a toggle people leave in the wrong state.
@MainActor
final class SettingsWindow {
    private let store: UsageStore
    private let companion: CompanionStore
    private let window: Widget
    private let content: Widget
    private var isVisible = false
    /// Set while rebuilding, so programmatic widget updates do not echo back as user edits and
    /// fight the value being restored.
    private var isPopulating = false

    private let updater: UpdateChecker

    init(store: UsageStore, companion: CompanionStore, updater: UpdateChecker) {
        self.store = store
        self.companion = companion
        self.updater = updater

        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(asWindow(window), "PokeTokenBar — Settings")
        gtk_window_set_default_size(asWindow(window), 420, 620)
        gtk_window_set_position(asWindow(window), GTK_WIN_POS_CENTER)

        let scroller = gtk_scrolled_window_new(nil, nil)!
        gtk_scrolled_window_set_policy(
            UnsafeMutableRawPointer(scroller).assumingMemoryBound(to: GtkScrolledWindow.self),
            GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(content, top: 12, bottom: 12, start: 12, end: 12)
        gtk_container_add(asContainer(scroller), content)
        gtk_container_add(asContainer(window), scroller)

        gtkConnectDeleteEvent(UnsafeMutableRawPointer(window),
                              box: GtkCallbackBox { [weak self] in self?.hide() })
    }

    func show() {
        isVisible = true
        GtkRuntime.hasVisibleWindow = true
        rebuild()
        gtk_widget_show_all(window)
        gtk_window_present(asWindow(window))
    }

    func hide() {
        isVisible = false
        GtkRuntime.hasVisibleWindow = false
        gtk_widget_hide(window)
    }

    private func rebuild() {
        isPopulating = true
        defer { isPopulating = false }
        Gtk.clear(content)
        let l = companion.l

        section(l.generalSectionTitle) { box in
            self.dropdown(box, l.language, AppLanguage.allCases.map(\.label),
                          selected: AppLanguage.allCases.firstIndex(of: self.companion.language) ?? 0) { index in
                self.companion.setLanguage(AppLanguage.allCases[index])
                // The whole UI is localised at build time, so a language change means rebuilding
                // every visible surface — not just this window.
                self.rebuild()
                self.onLanguageChange?()
            }
            let presets = UsageStore.intervalPresets
            self.dropdown(box, l.refreshInterval, presets.map { l.intervalLabel($0.value) },
                          selected: presets.firstIndex { $0.value == self.store.refreshInterval } ?? 0) { index in
                self.store.refreshInterval = presets[index].value
            }
            self.dropdown(box, l.limitDisplayModeLabel, [l.limitDisplayUsed, l.limitDisplayRemaining],
                          selected: self.store.limitDisplayMode == .used ? 0 : 1) { index in
                self.store.limitDisplayMode = index == 0 ? .used : .remaining
            }
            self.toggle(box, l.launchAtLogin, LoginItem.isEnabled) { on in
                do { try LoginItem.setEnabled(on) } catch {
                    AppLog.write("autostart toggle failed: \(error)")
                }
            }
        }

        // Linux has a tray, not a menu bar; the macOS wording sent people looking for something
        // their desktop does not have. Same setting, different name for where it shows up.
        section(l.traySectionTitle) { box in
            self.toggle(box, l.todayTokensShort, self.store.showTokensInMenu) { self.store.showTokensInMenu = $0 }
            self.toggle(box, l.todayCost, self.store.showCostInMenu) { self.store.showCostInMenu = $0 }
            self.toggle(box, l.limitPercent, self.store.showLimitInMenu) { self.store.showLimitInMenu = $0 }
        }

        section(l.floatingPetSectionTitle) { box in
            self.toggle(box, l.floatingPetEnableLabel, self.store.floatingPetEnabled) {
                self.store.floatingPetEnabled = $0
                self.onFloatingPetChange?()
            }
            self.slider(box, l.floatingPetSizeLabel, value: self.store.floatingPetSize,
                        range: 48...192, step: 8, format: { "\(Int($0))px" }) {
                self.store.floatingPetSize = $0
                self.onFloatingPetChange?()   // resize the pet as the slider moves
            }
            self.toggle(box, l.floatingPetBubbleAlertsLabel, self.store.floatingPetBubbleAlerts) {
                self.store.floatingPetBubbleAlerts = $0
            }
        }

        section(l.notificationsSection) { box in
            self.toggle(box, l.limitNotificationsLabel, self.store.limitNotifications) {
                self.store.limitNotifications = $0
            }
            self.slider(box, l.warning, value: self.store.warnThreshold,
                        range: 50...95, step: 5, format: TokenFormatter.percent) {
                self.store.warnThreshold = $0
            }
            self.slider(box, l.critical, value: self.store.critThreshold,
                        range: 80...100, step: 5, format: TokenFormatter.percent) {
                self.store.critThreshold = $0
            }
            self.toggle(box, l.companionNotificationsLabel, self.store.companionNotifications) {
                self.store.companionNotifications = $0
            }
            self.toggle(box, l.statusChecksLabel, self.store.statusChecksEnabled) {
                self.store.statusChecksEnabled = $0
            }
        }

        section(l.updateSectionTitle) { box in
            self.toggle(box, l.updateNotificationsLabel, self.store.updateNotificationsEnabled) {
                self.store.updateNotificationsEnabled = $0
            }
            let status = self.row(box, l.checkForUpdatesLabel)
            // State goes in a label rather than a dialog: a check is cheap and usually says
            // "nothing new", which does not deserve interrupting the user.
            let result = Gtk.label("<span size='small'>\(Gtk.escape(self.updateStatusText(l)))</span>",
                                   wrap: true)
            Gtk.addClass(result, "ptb-muted")
            gtk_widget_set_valign(result, GTK_ALIGN_CENTER)
            Gtk.pack(status, result)

            let check = gtk_button_new_with_label(l.checkNowButton)!
            gtk_widget_set_valign(check, GTK_ALIGN_CENTER)
            gtkConnect(UnsafeMutableRawPointer(check), signal: "clicked",
                       box: GtkCallbackBox { [weak self] in
                           guard let self else { return }
                           Task { @MainActor in
                               // minInterval 0: an explicit press must actually check, not be
                               // swallowed by the 30-minute poll guard.
                               await self.updater.check(minInterval: 0)
                               self.rebuild()
                               gtk_widget_show_all(self.window)
                           }
                       })
            Gtk.pack(status, check)

            // Opening the release page is the whole action on Linux — the app cannot know how it
            // was installed (distro package, manual build), and guessing wrong damages the install.
            if let available = self.updater.available {
                self.button(box, "\(l.updateButton) \(available.version)") {
                    if let url = URL(string: available.url) { PlatformOpener.open(url) }
                }
            }
        }

        section(l.advancedSectionTitle) { box in
            self.toggle(box, l.disableKeychain, self.store.disableKeychainAccess) {
                self.store.disableKeychainAccess = $0
            }
            // Say plainly that this does nothing here. The setting is shared with macOS and is
            // honoured by the same code, but Linux reads credentials from a file and never touches
            // a Keychain — a switch that silently changes nothing is worse than an explained one.
            let note = Gtk.label(
                "<span size='small'>\(Gtk.escape(l.disableKeychainLinuxNote))</span>", wrap: true)
            Gtk.addClass(note, "ptb-muted")
            Gtk.pack(box, note)
            self.button(box, l.refreshLimitToken) { [weak self] in
                Task { @MainActor in await self?.store.refreshLimitTokenFromKeychain() }
            }
        }

        section(l.transferSectionTitle) { box in
            let exportHint = Gtk.label("<span size='small'>\(Gtk.escape(l.exportSaveHint))</span>", wrap: true)
            Gtk.addClass(exportHint, "ptb-muted")
            Gtk.pack(box, exportHint)
            self.button(box, l.exportSaveButton) { [weak self] in self?.exportSave(l) }

            let importHint = Gtk.label("<span size='small'>\(Gtk.escape(l.importSaveHint))</span>", wrap: true)
            Gtk.addClass(importHint, "ptb-muted")
            Gtk.pack(box, importHint)
            self.button(box, l.importSaveButton) { [weak self] in self?.importSave(l) }
        }

        section(l.aboutSupportSectionTitle) { box in
            let version = Gtk.label("<span size='small'>PokeTokenBar \(Gtk.escape(AppVersion.current))</span>")
            Gtk.addClass(version, "ptb-muted")
            Gtk.pack(box, version)
            self.button(box, l.showLogFile) { PlatformOpener.reveal(AppLog.logFileURL) }
            self.button(box, l.reportProblem) {
                let body = l.reportMailBody(
                    version: AppVersion.current,
                    os: ProcessInfo.processInfo.operatingSystemVersionString)
                if let url = SupportMail.mailtoURL(
                    subject: l.reportMailSubject(AppVersion.current), body: body) {
                    PlatformOpener.open(url)
                }
            }
        }
    }

    private func updateStatusText(_ l: L) -> String {
        if let available = updater.available { return l.updateFound(available.version) }
        return l.upToDate(AppVersion.current)
    }

    // MARK: save transfer

    private func exportSave(_ l: L) {
        guard let url = chooseFile(title: l.exportSaveLabel, saving: true,
                                   suggestedName: companion.suggestedExportFileName) else { return }
        do {
            let data = try companion.exportedSaveData(
                appVersion: AppVersion.current, deviceName: ProcessInfo.processInfo.hostName)
            try data.write(to: url, options: .atomic)
            PlatformOpener.reveal(url)
        } catch {
            alert(title: l.exportSaveLabel, body: error.localizedDescription)
        }
    }

    /// Import is deliberately a five-step gauntlet, mirroring macOS.
    ///
    /// `CompanionState` decodes leniently — every field has a default — so *any* JSON would decode
    /// "successfully" into an empty state and silently wipe the user's dex. `SaveTransfer.decode`
    /// is what refuses a file that is not ours, and it must be the only way in.
    private func importSave(_ l: L) {
        guard let url = chooseFile(title: l.importSaveLabel, saving: false, suggestedName: nil) else { return }
        let envelope: SaveEnvelope
        do {
            envelope = try SaveTransfer.decode(try Data(contentsOf: url))
        } catch {
            alert(title: l.importSaveLabel, body: l.importErrorMessage(error))
            return
        }

        let incoming = SaveSummary(state: envelope.state)
        let current = companion.transferSummary
        let formatter = DateFormatter()
        formatter.locale = companion.language.displayLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let body = l.importConfirmBody(
            incomingDex: incoming.dexCount,
            incomingTokens: TokenFormatter.compact(incoming.lifetimeTokens),
            exportedAt: formatter.string(from: envelope.exportedAt),
            sourceDevice: envelope.sourceDevice,
            currentDex: current.dexCount,
            currentTokens: TokenFormatter.compact(current.lifetimeTokens))
        // Replace is destructive and irreversible from the UI, so Cancel is the default action —
        // the same choice `ImportConfirmPolicy` encodes for macOS.
        guard confirm(title: l.importConfirmTitle, body: body, confirmLabel: l.importSaveButton) else { return }

        do {
            try companion.applySave(
                envelope,
                todayTokensByProvider: store.todayTokensByProvider,
                todayDate: LocalUsageReader.todayKey(),
                hasUsageData: store.hasUsageData)
            alert(title: l.importSaveLabel,
                  body: l.importSaveDone(dex: incoming.dexCount,
                                         tokens: TokenFormatter.compact(incoming.lifetimeTokens)),
                  warning: false)
        } catch {
            alert(title: l.importSaveLabel, body: l.importErrorMessage(error))
        }
    }

    /// A modal file chooser. Returns nil when the user cancels — which must do nothing at all.
    private func chooseFile(title: String, saving: Bool, suggestedName: String?) -> URL? {
        let action = saving ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN
        guard let dialog = ptb_file_chooser_dialog(
            title, asWindow(window), action, "gtk-cancel", saving ? "gtk-save" : "gtk-open")
        else { return nil }
        defer { gtk_widget_destroy(dialog) }
        if let suggestedName { ptb_chooser_set_current_name(dialog, suggestedName) }
        if saving { ptb_chooser_confirm_overwrite(dialog, 1) }

        guard ptb_dialog_run(dialog) == ptb_response_accept(),
              let path = ptb_chooser_filename(dialog) else { return nil }
        defer { g_free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private func alert(title: String, body: String, warning: Bool = true) {
        guard let dialog = ptb_message_dialog(
            asWindow(window), warning ? GTK_MESSAGE_WARNING : GTK_MESSAGE_INFO,
            GTK_BUTTONS_OK, body) else { return }
        defer { gtk_widget_destroy(dialog) }
        gtk_window_set_title(asWindow(dialog), title)
        _ = ptb_dialog_run(dialog)
    }

    private func confirm(title: String, body: String, confirmLabel: String) -> Bool {
        guard let dialog = ptb_message_dialog(
            asWindow(window), GTK_MESSAGE_WARNING, GTK_BUTTONS_NONE, body) else { return false }
        defer { gtk_widget_destroy(dialog) }
        gtk_window_set_title(asWindow(dialog), title)
        _ = ptb_dialog_add_button(dialog, confirmLabel, ptb_response_accept())
        let cancel = ptb_dialog_add_button(dialog, "gtk-cancel", ptb_response_cancel())
        // Cancel is the default action: Return must never replace a save. macOS encodes the same
        // choice in `ImportConfirmPolicy.keyEquivalent(forButtonAt:)`.
        if let cancel {
            gtk_widget_set_can_default(cancel, 1)
            gtk_widget_grab_default(cancel)
            gtk_widget_grab_focus(cancel)
        }
        return ptb_dialog_run(dialog) == ptb_response_accept()
    }

    /// Called after the language changes, so the tray and popover relabel too.
    var onLanguageChange: (() -> Void)?
    /// Called when the floating-pet toggle flips, so the pet window appears or goes away at once.
    var onFloatingPetChange: (() -> Void)?

    // MARK: building blocks

    private func section(_ title: String, _ body: (Widget) -> Void) {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "ptb-card")
        let heading = Gtk.label(Gtk.escape(title))
        Gtk.addClass(heading, "ptb-section")
        Gtk.pack(card, heading)
        body(card)
        Gtk.pack(content, card)
    }

    private func row(_ parent: Widget, _ title: String) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let label = Gtk.label("<span size='small'>\(Gtk.escape(title))</span>", wrap: true)
        gtk_widget_set_hexpand(label, 1)
        Gtk.pack(row, label, expand: true)
        Gtk.pack(parent, row)
        return row
    }

    private func toggle(
        _ parent: Widget, _ title: String, _ value: Bool, _ onChange: @escaping (Bool) -> Void
    ) {
        let container = row(parent, title)
        let toggle = gtk_switch_new()!
        gtk_switch_set_active(
            UnsafeMutableRawPointer(toggle).assumingMemoryBound(to: GtkSwitch.self), value ? 1 : 0)
        gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
        gtkConnectNotify(UnsafeMutableRawPointer(toggle), property: "active",
                         box: GtkCallbackBox { [weak self] in
                       guard let self, !self.isPopulating else { return }
                       let active = gtk_switch_get_active(
                           UnsafeMutableRawPointer(toggle).assumingMemoryBound(to: GtkSwitch.self)) != 0
                       onChange(active)
                   })
        Gtk.pack(container, toggle)
    }

    private func dropdown(
        _ parent: Widget, _ title: String, _ options: [String], selected: Int,
        _ onChange: @escaping (Int) -> Void
    ) {
        let container = row(parent, title)
        let combo = gtk_combo_box_text_new()!
        let comboText = UnsafeMutableRawPointer(combo).assumingMemoryBound(to: GtkComboBoxText.self)
        for option in options { gtk_combo_box_text_append_text(comboText, option) }
        gtk_combo_box_set_active(
            UnsafeMutableRawPointer(combo).assumingMemoryBound(to: GtkComboBox.self), Int32(selected))
        gtk_widget_set_valign(combo, GTK_ALIGN_CENTER)
        gtkConnect(UnsafeMutableRawPointer(combo), signal: "changed",
                   box: GtkCallbackBox { [weak self] in
                       guard let self, !self.isPopulating else { return }
                       let index = gtk_combo_box_get_active(
                           UnsafeMutableRawPointer(combo).assumingMemoryBound(to: GtkComboBox.self))
                       guard index >= 0 else { return }
                       onChange(Int(index))
                   })
        Gtk.pack(container, combo)
    }

    /// A labelled slider with its current value shown, matching the macOS rows.
    ///
    /// `format` renders the value beside the slider — without it a slider is a guess, and these
    /// control thresholds where the exact number is the whole point.
    private func slider(
        _ parent: Widget, _ title: String, value: Double, range: ClosedRange<Double>, step: Double,
        format: @escaping (Double) -> String, _ onChange: @escaping (Double) -> Void
    ) {
        let container = row(parent, title)
        let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, range.lowerBound,
                                             range.upperBound, step)!
        let scaleRef = UnsafeMutableRawPointer(scale).assumingMemoryBound(to: GtkScale.self)
        gtk_range_set_value(UnsafeMutableRawPointer(scale).assumingMemoryBound(to: GtkRange.self), value)
        gtk_scale_set_draw_value(scaleRef, 0)   // the value is rendered as text beside it instead
        gtk_widget_set_size_request(scale, 140, -1)
        gtk_widget_set_valign(scale, GTK_ALIGN_CENTER)
        // A slider treats scroll as "change my value", so scrolling the page with the pointer over
        // one silently rewrites a setting. Hand the scroll to the page instead.
        gtkConnectScrollPassthrough(UnsafeMutableRawPointer(scale))

        let readout = Gtk.label("<span size='small'>\(Gtk.escape(format(value)))</span>")
        Gtk.addClass(readout, "ptb-muted")
        gtk_widget_set_valign(readout, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(readout, 44, -1)

        gtkConnect(UnsafeMutableRawPointer(scale), signal: "value-changed",
                   box: GtkCallbackBox { [weak self] in
                       guard let self, !self.isPopulating else { return }
                       let current = gtk_range_get_value(
                           UnsafeMutableRawPointer(scale).assumingMemoryBound(to: GtkRange.self))
                       Gtk.setMarkup(readout, "<span size='small'>\(Gtk.escape(format(current)))</span>")
                       onChange(current)
                   })
        Gtk.pack(container, scale)
        Gtk.pack(container, readout)
    }

    private func button(_ parent: Widget, _ title: String, _ action: @escaping () -> Void) {
        let button = gtk_button_new_with_label(title)!
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked", box: GtkCallbackBox(action))
        Gtk.pack(parent, button)
    }
}
#endif   // os(Linux)
