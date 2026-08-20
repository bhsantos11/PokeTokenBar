#if os(Linux)
import CGtk
import Foundation

/// The opt-in desktop companion — a small always-on-top window showing the sprite.
///
/// **Wayland limits what this can be.** The macOS panel remembers where you dragged it and reopens
/// there; Wayland deliberately denies clients both their own surface position and the ability to set
/// one, so the saved origin cannot be honoured and the compositor places the window. Positioning is
/// therefore the user's job via a KWin window rule. Everything else — always on top, no decorations,
/// transparent background, click to open the popover — works as on macOS.
///
/// The origin is still persisted through `UsageStore`, so nothing is lost if a future protocol
/// (or an X11 session, where it does work) can place it.
@MainActor
final class FloatingPetWindow {
    private let store: UsageStore
    private let companion: CompanionStore
    private let window: Widget
    private let image: Widget
    /// Bubble shown above the sprite for a limit alert; hidden when there is nothing to say.
    private let bubble: Widget
    private let bubbleLabel: Widget
    private let button: Widget
    /// Kept alive for the window's lifetime — GTK menus are not owned by the widget they pop over.
    private var menu: Widget?
    private var currentKey: String?
    private var isVisible = false
    private var lastBubbleKey: String?

    init(
        store: UsageStore, companion: CompanionStore,
        onActivate: @escaping () -> Void, onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.companion = companion

        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(asWindow(window), "PokeTokenBar pet")
        gtk_window_set_decorated(asWindow(window), 0)
        gtk_window_set_keep_above(asWindow(window), 1)
        gtk_window_set_skip_taskbar_hint(asWindow(window), 1)
        gtk_window_set_skip_pager_hint(asWindow(window), 1)
        gtk_window_set_resizable(asWindow(window), 0)
        // A utility type keeps most compositors from giving it a titlebar or a task-switcher entry.
        gtk_window_set_type_hint(asWindow(window), GDK_WINDOW_TYPE_HINT_UTILITY)

        // A button rather than a bare image: it gives keyboard focus, a hover cursor and a click
        // signal for free, and `RELIEF_NONE` keeps it from drawing a button frame around the sprite.
        let petButton = gtk_button_new()!
        button = petButton
        gtk_button_set_relief(
            UnsafeMutableRawPointer(petButton).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
        image = gtk_image_new()!
        gtk_container_add(asContainer(petButton), image)
        gtkConnect(UnsafeMutableRawPointer(petButton), signal: "clicked", box: GtkCallbackBox(onActivate))

        // The bubble sits above the sprite and is packed permanently, shown and hidden rather than
        // added and removed — rebuilding it would drop the widget out from under a running
        // `show_all`, and the pet redraws on every poll.
        bubbleLabel = Gtk.label("", align: GTK_ALIGN_CENTER, wrap: true)
        gtk_label_set_justify(asLabel(bubbleLabel), GTK_JUSTIFY_CENTER)
        gtk_label_set_max_width_chars(asLabel(bubbleLabel), 24)
        bubble = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(bubble, "ptb-card")
        Gtk.addClass(bubble, "ptb-bubble")
        Gtk.pack(bubble, bubbleLabel)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.pack(column, bubble)
        Gtk.pack(column, petButton)
        gtk_container_add(asContainer(window), column)
        enableTransparency()

        buildMenu(onActivate: onActivate, onSettings: onSettings, onQuit: onQuit)
        gtkConnectDeleteEvent(UnsafeMutableRawPointer(window), box: GtkCallbackBox { [weak self] in
            // Closing the pet is the same as switching it off, so the setting matches what is on
            // screen — otherwise it reappears at next launch and reads as a bug.
            self?.store.floatingPetEnabled = false
            self?.hide()
        })
    }

    /// Give the window an RGBA visual so the area around the sprite is see-through rather than a
    /// grey square. Compositor-dependent: without compositing the background falls back to opaque.
    private func enableTransparency() {
        guard let screen = gtk_widget_get_screen(window),
              let visual = gdk_screen_get_rgba_visual(screen) else { return }
        gtk_widget_set_visual(window, visual)
        gtk_widget_set_app_paintable(window, 1)
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    private func show() {
        isVisible = true
        gtk_widget_show_all(window)
        // show_all would reveal the bubble too; its visibility is state, not layout.
        syncBubble()
    }

    /// Right-click menu — open, settings, hide. macOS offers the same from its panel.
    private func buildMenu(
        onActivate: @escaping () -> Void, onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        let l = companion.l
        guard let popup = gtk_menu_new() else { return }
        menu = popup
        let items: [(String, () -> Void)] = [
            // Petting lives in the menu rather than on the primary click, which already opens the
            // panel. Rebinding that would trade a navigation people rely on for a piece of flavour.
            (l.floatingPetMenuPet, { [weak self] in self?.pet() }),
            (l.floatingPetMenuOpen, onActivate),
            (l.settings, onSettings),
            (l.floatingPetMenuHide, { [weak self] in
                // Same contract as closing the window: the setting follows what is on screen.
                self?.store.floatingPetEnabled = false
                self?.hide()
            }),
            (l.quit, onQuit),
        ]
        for (title, action) in items {
            guard let item = gtk_menu_item_new_with_label(title) else { continue }
            gtkConnect(UnsafeMutableRawPointer(item), signal: "activate", box: GtkCallbackBox(action))
            gtk_menu_shell_append(
                UnsafeMutableRawPointer(popup).assumingMemoryBound(to: GtkMenuShell.self), item)
            gtk_widget_show(item)
        }
        // `button-press-event` carries the click, so it needs the 3-argument helper.
        gtkConnectSecondaryClick(UnsafeMutableRawPointer(button), box: GtkCallbackBox { [weak self] in
            guard let self, let popup = self.menu else { return }
            gtk_menu_popup_at_pointer(
                UnsafeMutableRawPointer(popup).assumingMemoryBound(to: GtkMenu.self), nil)
        })
    }

    /// Refresh the hover callout and the alert bubble. Called on every poll.
    func syncCopy() {
        let l = companion.l
        gtk_widget_set_tooltip_text(button, FloatingPetCopy.hoverTooltip(
            todayTokens: store.todayTotalTokens,
            limitUtilization: store.highestLimitUtilization,
            mode: store.limitDisplayMode, l: l))
        syncBubble()
    }

    /// Pet the companion from the desktop, and keep the reply on screen for its window.
    ///
    /// The reply borrows the alert bubble rather than adding a second floating surface: two things
    /// that can appear above the pet would eventually appear at once and overlap.
    private func pet() {
        companion.pet()
        syncBubble()
        // The reaction expires on its own clock, so a repaint has to be scheduled for that moment —
        // nothing else is guaranteed to redraw the pet before the next poll, two minutes later.
        DispatchQueue.main.asyncAfter(deadline: .now() + CompanionStore.petReactionWindow + 0.1) {
            [weak self] in MainActor.assumeIsolated { self?.syncBubble() }
        }
    }

    /// Show the current limit alert above the pet, or nothing.
    ///
    /// `UsageStore` owns the bubble's lifetime — it clears `currentBubbleAlert` after its TTL — so
    /// this only mirrors that state rather than running a timer of its own.
    private func syncBubble() {
        guard isVisible else { return }
        // A limit alert outranks flavour: one is a warning about spending, the other is the pet
        // being pleased to see you. Only when there is no alert does the reaction get the bubble.
        guard store.floatingPetBubbleAlerts, let alert = store.currentBubbleAlert else {
            if let reaction = companion.petReaction {
                Gtk.setMarkup(bubble: bubbleLabel, reaction)
                Gtk.removeClass(bubble, "ptb-status-major")
                Gtk.removeClass(bubble, "ptb-status-minor")
                lastBubbleKey = nil
                gtk_widget_show_all(bubble)
                return
            }
            gtk_widget_hide(bubble)
            lastBubbleKey = nil
            return
        }
        let key = "\(alert.key)-\(alert.isCritical)"
        if key != lastBubbleKey {
            let copy = FloatingPetCopy.bubble(alert, l: companion.l)
            Gtk.setMarkup(bubbleLabel,
                          "<span size='small'><b>\(Gtk.escape(copy.title))</b>\n\(Gtk.escape(copy.body))</span>")
            Gtk.removeClass(bubble, alert.isCritical ? "ptb-status-minor" : "ptb-status-major")
            Gtk.addClass(bubble, alert.isCritical ? "ptb-status-major" : "ptb-status-minor")
            lastBubbleKey = key
        }
        gtk_widget_show_all(bubble)
    }

    private func hide() {
        isVisible = false
        gtk_widget_hide(window)
    }

    /// Swap in the current companion sprite at the configured size.
    func update(spriteData: Data?, key: String) {
        guard isVisible, key != currentKey, let spriteData else { return }
        let size = Int(store.floatingPetSize)
        guard let pixbuf = SpriteRenderer.render(spriteData, size: size) else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
        gtk_image_set_from_pixbuf(asImage(image), pixbuf)
        currentKey = key
    }
}
#endif   // os(Linux)
