#if os(Linux)
import CGtk
import Dispatch
import Foundation

/// Lets the GTK main loop and Swift concurrency (MainActor) share one thread.
///
/// **The problem.** Both want to be "the loop that owns the main thread". Calling `gtk_main()`
/// blocks inside it, so libdispatch's main queue never runs and none of the `@MainActor` work in
/// `UsageStore` / `CompanionStore` executes. Running only `dispatchMain()` has the mirror problem:
/// GTK events go unprocessed and the tray menu stops responding. Taking Core off MainActor
/// entirely was rejected — that splits code shared with macOS.
///
/// **What we do.** libdispatch is the primary loop (`dispatchMain()`), and GTK is pumped from a
/// repeating timer on the main queue. Given that one of the two loops has to yield, keeping Swift
/// concurrency alive is what lets the shared code stay shared.
///
/// **The cost — idle wakeups.** The pump wakes the CPU at its interval. This repository has
/// already been burned once by wakeup amplification from an always-on animation
/// (`defect-log` §에너지 / "Energy"), so the default is deliberately slack and only tightens when a window is
/// up: 50ms (20Hz) for the tray alone, 16ms (60Hz) with a window. 50ms is imperceptible on a
/// menu click.
///
/// The better fix is Swift 6's custom main executor, putting MainActor directly on the GLib
/// context and removing the pump altogether — worth revisiting once the tray is settled
/// (roadmap Phase 8).
enum GtkRuntime {
    /// Pump interval with no window open. Only the tray menu has to respond, so it runs slack.
    private static let idleInterval: DispatchTimeInterval = .milliseconds(50)
    /// Interval while a window (popover, floating pet) is visible.
    private static let activeInterval: DispatchTimeInterval = .milliseconds(16)

    @MainActor private static var pumping = false

    /// True while a window is up, which tightens the pump. The frontend updates it on show/hide.
    @MainActor static var hasVisibleWindow = false

    /// `gtk_init` — false when there is no display (TTY, SSH). The caller explains and exits.
    static func initialize() -> Bool {
        // The desktop matches a window to its `.desktop` file by app id / WM_CLASS, and that is what
        // gives the task bar an icon and a name. GTK derives it from the executable's filename by
        // default, so a dev run (`PokeTokenBar`) and the installed binary (`poketokenbar`) would
        // claim different identities and only one of them would match `poketokenbar.desktop`.
        // Pinning it makes both resolve.
        g_set_prgname("poketokenbar")
        gdk_set_program_class("poketokenbar")
        guard gtk_init_check(nil, nil) != 0 else { return false }
        applyDefaultWindowIcon()
        return true
    }

    /// Give every window the app icon.
    ///
    /// Falls back to the sprite the tray already generated when the themed icon is not installed
    /// (a dev run out of the build directory), because a blank task-bar entry reads as a broken app.
    private static func applyDefaultWindowIcon() {
        if let theme = gtk_icon_theme_get_default(),
           gtk_icon_theme_has_icon(theme, "poketokenbar") != 0 {
            gtk_window_set_default_icon_name("poketokenbar")
            return
        }
        let fallback = PlatformPaths.appDirectory("tray").appendingPathComponent("companion-egg.png")
        if FileManager.default.fileExists(atPath: fallback.path) {
            gtk_window_set_default_icon_from_file(fallback.path, nil)
        }
    }

    /// Starts pumping GTK events on the main queue. Call once, before `dispatchMain()`.
    static func startPumpFromMainQueue() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !pumping else { return }
                pumping = true
                schedule()
            }
        }
    }

    @MainActor private static func schedule() {
        let interval = hasVisibleWindow ? activeInterval : idleInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated {
                // Drain only what is pending; never block. Passing `true` would stall the main
                // queue whenever GTK has no events.
                while gtk_events_pending() != 0 {
                    _ = gtk_main_iteration_do(0)
                }
                schedule()
            }
        }
    }
}

/// A box that carries a Swift closure through a C callback.
///
/// GTK signals hand back a single `gpointer`. A closure cannot cross into C directly, so it is
/// wrapped in a class whose lifetime we hold manually via `Unmanaged` — the box has to outlive the
/// widget, and leaving it to ARC means the first click calls into freed memory.
final class GtkCallbackBox {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }

    /// An opaque pointer holding a +1 retain. GTK calls the matching release when the widget dies.
    var opaque: UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
}

/// Connect a signal whose handler takes **(instance, user_data)** — `clicked`, `activate`,
/// `changed` and friends.
///
/// **The arity has to match the signal exactly.** `g_signal_connect_data` takes an untyped
/// `GCallback`, so a wrong signature is not a compile error: GLib pushes the real arguments and the
/// callback reads whichever slot it declared. Using this two-argument helper for a three-argument
/// signal makes `user_data` resolve to the *second* real argument — for `notify::`, that is the
/// `GParamSpec` — and the first `swift_retain` on it segfaults. Use `gtkConnectNotify` for
/// `notify::*` and `gtkConnectDeleteEvent` for `delete-event`.
@discardableResult
func gtkConnect(
    _ instance: UnsafeMutableRawPointer,
    signal: String,
    box: GtkCallbackBox
) -> gulong {
    assertSignalArity(instance, signal, expectedParameters: 0)
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
        _, data in
        guard let data else { return }
        Unmanaged<GtkCallbackBox>.fromOpaque(data).takeUnretainedValue().run()
    }
    let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        data, _ in
        guard let data else { return }
        Unmanaged<GtkCallbackBox>.fromOpaque(data).release()
    }
    return g_signal_connect_data(
        instance, signal,
        unsafeBitCast(callback, to: GCallback.self),
        box.opaque,
        destroy,
        GConnectFlags(rawValue: 0))
}
/// Connect `GtkFlowBox::child-activated`, whose handler takes **(flowbox, child, user_data)**.
///
/// Needs its own helper for the reason spelled out on `gtkConnect`: the arity must match exactly,
/// and this signal carries the activated child in the middle slot. The child is handed to the box
/// as its index, which is the only stable way to map back to the model — the widget pointers are
/// rebuilt on every refresh.
///
/// `child-activated` rather than `selected-children-changed`: selection only changes when the box
/// is in a selecting mode, and a grid of cells that highlight after a click reads as a form control
/// rather than a list of things to open.
@discardableResult
func gtkConnectChildActivated(
    _ instance: UnsafeMutableRawPointer, box: GtkIndexCallbackBox
) -> gulong {
    assertSignalArity(instance, "child-activated", expectedParameters: 1)
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void = { _, child, data in
        guard let data, let child else { return }
        let index = Int(gtk_flow_box_child_get_index(
            child.assumingMemoryBound(to: GtkFlowBoxChild.self)))
        Unmanaged<GtkIndexCallbackBox>.fromOpaque(data).takeUnretainedValue().run(index)
    }
    let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        data, _ in
        guard let data else { return }
        Unmanaged<GtkIndexCallbackBox>.fromOpaque(data).release()
    }
    return g_signal_connect_data(
        instance, "child-activated",
        unsafeBitCast(callback, to: GCallback.self),
        box.opaque, destroy, GConnectFlags(rawValue: 0))
}

/// A callback that receives the activated child's index. Same ownership contract as
/// `GtkCallbackBox`: an opaque +1 retain that GTK releases when the widget dies.
final class GtkIndexCallbackBox {
    let run: (Int) -> Void
    init(_ run: @escaping (Int) -> Void) { self.run = run }
    var opaque: UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
}

/// Swallow scroll events on a widget, forwarding them to the nearest scrolled ancestor.
///
/// `GtkScale` treats a scroll as "change my value". Inside a scrolled settings page that means a
/// pointer passing over a slider on its way down the page **silently changes a setting** — the pet
/// size went from 96 to 48 during a routine scroll. Blocking the event outright would leave dead
/// patches where the page refuses to scroll, so the delta is handed to the ancestor instead.
///
/// Handler shape is `(widget, event, user_data) -> gboolean`, and returning TRUE stops the widget
/// from also acting on it.
@discardableResult
func gtkConnectScrollPassthrough(_ instance: UnsafeMutableRawPointer) -> gulong {
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> gboolean = { widget, event, _ in
        guard let widget, let event else { return 0 }
        // Walk up to the scrolled window this slider lives in; without one there is nothing to
        // forward to and the event is simply dropped (still better than moving the slider).
        var ancestor = gtk_widget_get_parent(widget.assumingMemoryBound(to: GtkWidget.self))
        while let current = ancestor,
              g_type_check_instance_is_a(
                  UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self),
                  gtk_scrolled_window_get_type()) == 0 {
            ancestor = gtk_widget_get_parent(current)
        }
        guard let scroller = ancestor else { return 1 }
        let adjustment = gtk_scrolled_window_get_vadjustment(
            UnsafeMutableRawPointer(scroller).assumingMemoryBound(to: GtkScrolledWindow.self))
        var deltaY: Double = 0
        if gdk_event_get_scroll_deltas(event.assumingMemoryBound(to: GdkEvent.self), nil, &deltaY) == 0 {
            // Discrete wheels report a direction rather than a delta.
            var direction = GDK_SCROLL_SMOOTH
            if gdk_event_get_scroll_direction(event.assumingMemoryBound(to: GdkEvent.self),
                                              &direction) != 0 {
                deltaY = direction == GDK_SCROLL_DOWN ? 1 : (direction == GDK_SCROLL_UP ? -1 : 0)
            }
        }
        let step = gtk_adjustment_get_step_increment(adjustment) * 3
        let target = gtk_adjustment_get_value(adjustment) + deltaY * step
        let maximum = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
        gtk_adjustment_set_value(adjustment, min(max(gtk_adjustment_get_lower(adjustment), target),
                                                 max(gtk_adjustment_get_lower(adjustment), maximum)))
        return 1
    }
    return g_signal_connect_data(
        instance, "scroll-event",
        unsafeBitCast(callback, to: GCallback.self),
        nil, nil, GConnectFlags(rawValue: 0))
}

/// Connect a widget's `key-press-event`, handing the callback the keyval and modifier state.
///
/// Handler shape is `(widget, event, user_data) -> gboolean`; returning TRUE marks the key as
/// handled so it does not also reach whatever has focus.
@discardableResult
func gtkConnectKeyPress(_ instance: UnsafeMutableRawPointer, box: GtkKeyCallbackBox) -> gulong {
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> gboolean = { _, event, data in
        guard let data, let event else { return 0 }
        var keyval: guint = 0
        gdk_event_get_keyval(event.assumingMemoryBound(to: GdkEvent.self), &keyval)
        var state = GdkModifierType(rawValue: 0)
        gdk_event_get_state(event.assumingMemoryBound(to: GdkEvent.self), &state)
        let handled = Unmanaged<GtkKeyCallbackBox>.fromOpaque(data).takeUnretainedValue()
            .run(keyval, state.rawValue & GDK_CONTROL_MASK.rawValue != 0)
        return handled ? 1 : 0
    }
    let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        data, _ in
        guard let data else { return }
        Unmanaged<GtkKeyCallbackBox>.fromOpaque(data).release()
    }
    return g_signal_connect_data(
        instance, "key-press-event",
        unsafeBitCast(callback, to: GCallback.self),
        box.opaque, destroy, GConnectFlags(rawValue: 0))
}

/// A key handler: `(keyval, controlHeld) -> handled`. Same ownership contract as `GtkCallbackBox`.
final class GtkKeyCallbackBox {
    let run: (guint, Bool) -> Bool
    init(_ run: @escaping (guint, Bool) -> Bool) { self.run = run }
    var opaque: UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
}

/// Connect a window's `delete-event` (the close button).
///
/// Separate from `gtkConnect` because this signal's handler returns `gboolean`, and returning TRUE
/// is what tells GTK "handled — do not destroy". A tray app must hide rather than destroy: the
/// process outlives the window, and a destroyed one leaves every later `show()` pointing at freed
/// widgets.
@discardableResult
func gtkConnectDeleteEvent(_ instance: UnsafeMutableRawPointer, box: GtkCallbackBox) -> gulong {
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> gboolean = { _, _, data in
        guard let data else { return 0 }
        Unmanaged<GtkCallbackBox>.fromOpaque(data).takeUnretainedValue().run()
        return 1   // handled: suppress the default destroy
    }
    let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        data, _ in
        guard let data else { return }
        Unmanaged<GtkCallbackBox>.fromOpaque(data).release()
    }
    return g_signal_connect_data(
        instance, "delete-event",
        unsafeBitCast(callback, to: GCallback.self),
        box.opaque, destroy, GConnectFlags(rawValue: 0))
}

/// Connect a `notify::<property>` signal, whose handler takes **(object, pspec, user_data)**.
///
/// Separate from `gtkConnect` because of the extra `GParamSpec` argument — see the warning there.
@discardableResult
func gtkConnectNotify(
    _ instance: UnsafeMutableRawPointer, property: String, box: GtkCallbackBox
) -> gulong {
    assertSignalArity(instance, "notify", expectedParameters: 1)
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void = { _, _, data in
        guard let data else { return }
        Unmanaged<GtkCallbackBox>.fromOpaque(data).takeUnretainedValue().run()
    }
    let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        data, _ in
        guard let data else { return }
        Unmanaged<GtkCallbackBox>.fromOpaque(data).release()
    }
    return g_signal_connect_data(
        instance, "notify::\(property)",
        unsafeBitCast(callback, to: GCallback.self),
        box.opaque, destroy, GConnectFlags(rawValue: 0))
}

/// Connect a right-click on a widget, whose handler takes **(widget, event, user_data)**.
///
/// Only the secondary button fires the box; primary clicks return FALSE so they continue to the
/// widget's own `clicked` handler. Swallowing them here would make the pet unclickable.
@discardableResult
func gtkConnectSecondaryClick(_ instance: UnsafeMutableRawPointer, box: GtkCallbackBox) -> gulong {
    assertSignalArity(instance, "button-press-event", expectedParameters: 1)
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> gboolean = { _, event, data in
        guard let data, let event else { return 0 }
        let click = event.assumingMemoryBound(to: GdkEventButton.self).pointee
        guard click.button == 3 else { return 0 }   // GDK_BUTTON_SECONDARY
        Unmanaged<GtkCallbackBox>.fromOpaque(data).takeUnretainedValue().run()
        return 1
    }
    let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        data, _ in
        guard let data else { return }
        Unmanaged<GtkCallbackBox>.fromOpaque(data).release()
    }
    return g_signal_connect_data(
        instance, "button-press-event",
        unsafeBitCast(callback, to: GCallback.self),
        box.opaque, destroy, GConnectFlags(rawValue: 0))
}

/// Check that a signal really carries the number of parameters the chosen helper assumes.
///
/// This is the only mechanical defence available. `g_signal_connect_data` takes an untyped
/// `GCallback`, so attaching a two-argument callback to a three-argument signal compiles cleanly and
/// then dereferences the wrong stack slot — in the case that prompted this, `notify::active` handed
/// its `GParamSpec` to code expecting the user-data pointer, and the first `swift_retain` on it
/// segfaulted. GLib knows each signal's real arity, so ask it instead of trusting the call site.
///
/// A trap in debug, a log line in release: the mismatch is a programming error, not a user problem.
private func assertSignalArity(
    _ instance: UnsafeMutableRawPointer, _ signal: String, expectedParameters: Int
) {
    // Detail suffixes ("notify::active") are not part of the signal name GLib looks up.
    let name = signal.components(separatedBy: "::").first ?? signal
    // `G_TYPE_FROM_INSTANCE` is a macro, so the class pointer is read from the struct by hand.
    let typeInstance = instance.assumingMemoryBound(to: GTypeInstance.self)
    guard let klass = typeInstance.pointee.g_class else { return }
    let identifier = g_signal_lookup(name, klass.pointee.g_type)
    guard identifier != 0 else {
        AppLog.write("unknown GTK signal '\(name)' — handler will never fire")
        assertionFailure("unknown GTK signal '\(name)'")
        return
    }
    var query = GSignalQuery()
    g_signal_query(identifier, &query)
    guard Int(query.n_params) != expectedParameters else { return }
    let message = "GTK signal '\(name)' takes \(query.n_params) parameter(s), but this helper "
        + "assumes \(expectedParameters) — the callback would read the wrong argument and crash"
    AppLog.write(message)
    assertionFailure(message)
}

#endif   // os(Linux)
