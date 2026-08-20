#if os(Linux)
import CGtk
import Foundation

/// The popover's stylesheet, installed once for the whole app.
///
/// GTK theming is CSS, and this deliberately does not hardcode a palette: colours come from the
/// user's GTK theme via `@theme_fg_color` and friends, so the window follows their light/dark
/// setting instead of fighting it. Only the accents that carry meaning — the limit colours — are
/// fixed, because "over the warning threshold" has to read the same on every theme.
enum PopoverStyle {
    static func install() {
        let css = """
        .ptb-card {
          background-color: alpha(@theme_fg_color, 0.05);
          border-radius: 10px;
          padding: 12px;
        }
        .ptb-title      { font-weight: bold; font-size: 13px; }
        .ptb-huge       { font-size: 30px; font-weight: bold; }
        .ptb-muted      { color: alpha(@theme_fg_color, 0.55); font-size: 11px; }
        .ptb-section    { font-size: 11px; font-weight: bold; color: alpha(@theme_fg_color, 0.55); }
        /* A row asking to confirm something it cannot undo. Not muted — the whole point is that it
           reads differently from the description it replaces, so a click does not land on autopilot. */
        /* Readable on both a light and a dark card. The original #d08770 was chosen against the
           dark theme and washed out on light backgrounds — this sits around 4.5:1 on either. */
        .ptb-warning    { font-size: 11px; font-weight: bold; color: #c05621; }
        /* What the companion just said when you clicked it. Deliberately not muted — it is a direct
           answer to something the player did, and muting it makes the click feel unacknowledged. */
        .ptb-reaction   { font-size: 11px; font-style: italic; color: @theme_fg_color; }
        /* A price you can actually pay. Muted grey put the row's whole decision in fine print. */
        .ptb-price      { font-size: 11px; color: alpha(@theme_fg_color, 0.85); }
        /* The Home hero. Slightly lifted off the background so the pet reads as the subject of the
           panel rather than the first row of a list. */
        .ptb-hero {
          background-color: alpha(@theme_fg_color, 0.08);
          padding: 16px 12px;
        }
        /* The sprite is a button so it can be clicked; it must not look like one. Only the hover
           state hints that it is interactive. */
        .ptb-sprite-button {
          background: none;
          border: none;
          box-shadow: none;
          padding: 0;
          min-height: 0;
          min-width: 0;
        }
        .ptb-sprite-button:hover { background-color: alpha(@theme_fg_color, 0.10); border-radius: 12px; }
        /* Dex cells are buttons so they can be opened; they must keep reading as grid cells. */
        .ptb-cell-button {
          background: none;
          border: none;
          box-shadow: none;
          padding: 0;
          min-height: 0;
          min-width: 0;
        }
        .ptb-cell-button:hover { background-color: alpha(@theme_fg_color, 0.10); border-radius: 10px; }
        /* Rarity accents. The badge was one flat grey for every tier, so the rarest thing a player
           owns looked exactly like the commonest.

           Solid fills with an explicit white foreground, not translucent ones: `alpha()` blends into
           whatever is behind it, so the same badge came out dark on the dark theme and washed out on
           the light one — and the label colour was left to the theme, which is how a legendary badge
           ended up light text on a light fill. Each fill is dark enough for white text on both.
           Compound selectors (`.ptb-badge.ptb-rarity-*`) rather than bare ones: `.ptb-badge` is
           declared further down this sheet and, at equal specificity, the later rule wins — so a
           bare `.ptb-rarity-legendary` lost its fill to the badge's grey while its white text
           survived, giving white-on-grey. Raising specificity makes the pairing order-independent. */
        .ptb-badge.ptb-rarity-common    { background-color: #6b7480; color: #ffffff; }
        .ptb-badge.ptb-rarity-uncommon  { background-color: #3d7f57; color: #ffffff; }
        .ptb-badge.ptb-rarity-rare      { background-color: #3a6fb0; color: #ffffff; }
        .ptb-badge.ptb-rarity-legendary { background-color: #a8791a; color: #ffffff; }
        /* The growth meter takes the same accent, so rarity is legible from the bar alone.
           GTK3 needs the `progress` node addressed directly; styling the bar tints the trough. */
        /* The hero's growth bar. The 6px default reads as a hairline under a 112px sprite, and
           edge-to-edge it looks like a divider rather than a meter. */
        .ptb-meter-hero, .ptb-meter-hero trough, .ptb-meter-hero progress {
          min-height: 10px;
          border-radius: 5px;
        }
        .ptb-meter-common progress    { background-image: none; background-color: #8f9aa6; }
        .ptb-meter-uncommon progress  { background-image: none; background-color: #4c9f70; }
        .ptb-meter-rare progress      { background-image: none; background-color: #4a7fd0; }
        .ptb-meter-legendary progress { background-image: none; background-color: #c9a227; }
        .ptb-badge {
          background-color: alpha(@theme_fg_color, 0.12);
          border-radius: 8px;
          padding: 1px 7px;
          font-size: 10px;
          font-weight: bold;
        }
        /* Grid cells: the card padding is sized for full-width rows and would cost 4×24pt across
           a four-column grid, which is what pushed the last column off a 400pt panel. */
        .ptb-cell { background-color: alpha(@theme_fg_color, 0.05); border-radius: 8px; padding: 3px; }
        /* Filter capsules have to fit four words on one row at 400pt. */
        .ptb-chip-tight { padding: 2px 6px; font-size: 9px; }
        .ptb-chip {
          background-color: alpha(@theme_fg_color, 0.08);
          border-radius: 12px;
          padding: 3px 10px;
          font-size: 11px;
        }
        /* A celebration should read as an event, not another data card. */
        .ptb-celebration {
          background-color: alpha(@theme_selected_bg_color, 0.30);
          border: 1px solid @theme_selected_bg_color;
        }
        /* Evolution line: the current stage is ringed, later stages are faded back. */
        .ptb-stage-current { border: 2px solid @theme_selected_bg_color; border-radius: 6px; }
        .ptb-stage-future  { opacity: 0.35; }
        /* Provider incidents. Amber for degraded, red for a real outage — same reading as the
           limit meters, so colour means one thing across the window. */
        .ptb-status-minor { background-color: alpha(#ff9f0a, 0.20); border: 1px solid #ff9f0a; }
        .ptb-status-major { background-color: alpha(#ff453a, 0.20); border: 1px solid #ff453a; }
        /* The pet's alert bubble: a small floating card, tighter than the popover's. */
        .ptb-bubble { padding: 6px 8px; border-radius: 8px; }
        .ptb-chip-on {
          background-color: @theme_selected_bg_color;
          color: @theme_selected_fg_color;
        }
        /* Limit meters. Green / amber / red are the same thresholds the menu bar uses, so a glance
           at either surface means the same thing. */
        progressbar.ptb-ok    trough progress { background-color: #35c759; }
        progressbar.ptb-warn  trough progress { background-color: #ff9f0a; }
        progressbar.ptb-crit  trough progress { background-color: #ff453a; }
        progressbar trough { min-height: 6px; border-radius: 3px; }
        progressbar progress { min-height: 6px; border-radius: 3px; }
        """
        guard let provider = gtk_css_provider_new() else { return }
        gtk_css_provider_load_from_data(provider, css, -1, nil)
        if let screen = gdk_screen_get_default() {
            gtk_style_context_add_provider_for_screen(
                screen, OpaquePointer(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
        g_object_unref(UnsafeMutableRawPointer(provider))
    }
}
#endif   // os(Linux)
