# Linux feature parity roadmap

Closing the gap between the Linux (GTK3) frontend and the features the macOS app advertises in
[README.md](README.md). Everything below is **buildable** — the two genuinely impossible items
(dragging the floating pet, anchoring the window to the tray icon) are Wayland restrictions and are
recorded at the bottom rather than as tasks.

Shared game logic already runs on both platforms: hatching, evolution lines, natures, shinies,
Rare Candy, the Shop, all ten usage sources. What is missing is Linux **presentation** of things
Core already computes, plus a few Settings controls.

**Last updated: 2026-08-18**

## Status

### Phase 1 — Reading the numbers that Core already has  ⚠️ built, display unverified

> The limits card could not be seen during this work: the Anthropic usage endpoint began
> rate-limiting after many service restarts (`rateLimited` → 300s backoff, repeatedly), so
> `store.limits` stayed nil and the card never rendered. The countdown arithmetic is unit-tested;
> the card itself still needs one look once the rate limit clears.
- [x] Limit **reset countdowns** next to each utilisation meter (`LimitWindow.resetDate`) —
      built on `RelativeTime` (new, 6 tests); corelibs has no `RelativeDateTimeFormatter`
- [x] **Burn-rate forecast** — renders `store.fiveHourForecast` via `l.forecastReach` / `forecastNoReach`
- [x] Provider **status warnings** — only degraded providers, amber/red matching the limit meters

### Phase 2 — Settings controls with no UI  ✅ done, verified on screen
Each of these is a stored value the Linux app already honours but offers no way to change.
- [x] Floating pet **size** slider (48–192px, step 8), resizing the pet live
- [x] **Warning threshold** slider (50–95%) and **critical** (80–100%), matching macOS ranges
- [x] **Keychain opt-out** toggle, with a note stating plainly that it changes nothing on Linux
      (credentials come from `~/.claude/.credentials.json`) — a dead switch is worse than an explained one
- [x] **Refresh limit token** action (`refreshLimitTokenFromKeychain`)

### Phase 3 — Collection, properly
Today's Collection tab is a flat grid of individuals capped at 60. macOS has two distinct views.
- [ ] **Species Pokédex** — `companion.dexSpecies`, 24 per page, with paging controls
- [ ] Rarity **filter** (common / uncommon / rare / legendary), as the macOS dex has
- [ ] ✨ marker for shiny ownership, kept from the current grid
- [ ] **Catch log** — individuals with evolution line, rarity, nature and capture date
      (`dexEntriesSorted`, `dexResolveChainNames`, `isActiveDexEntry`)
- [ ] Segmented control to switch dex ↔ catch log

### Phase 4 — The floating pet, fully
- [ ] **Hover callout** with today's usage (`FloatingPetController.hoverTooltip` is pure — move it
      to Core rather than reimplementing it)
- [ ] **Right-click menu** (open, settings, hide, quit)
- [ ] **Speech-bubble limit alerts** above the pet (`store.currentBubbleAlert`,
      `floatingPetBubbleAlerts`), reusing the Core copy-length guard that stops truncation

### Phase 5 — Housekeeping the app owes the user
- [ ] **Update check** in Settings — `UpdateChecker` already runs; surface it and the available
      version, opening the release page (Linux has no self-apply path)
- [ ] **Save export / import** via a GTK file chooser (`SaveTransfer`, including `sanitized`)

### Gates
- [ ] Every phase verified on the real Plasma panel, not only headless
- [ ] `swift test` still green on Linux; new pure logic covered by tests
- [ ] README gap list shrunk in the same change that closes a gap (all three languages)

## Working rules

- **Move logic to Core rather than reimplementing it.** Anything a macOS view computes that the
  Linux UI also needs (`hoverTooltip`, dex paging maths, bubble layout) belongs in Core, tested
  once, used twice. That is how the name, status line and tabs already got there.
- **Verify against the real panel.** Headless captures prove layout; they do not prove tray or
  notification behaviour. See `.claude/NOTES.md` for the D-Bus recipes.
- **Update the README in the same change.** The gap list is a promise to users; it drifted once
  already by understating what was missing.

## Not doing — Wayland restrictions, not omissions

| Item | Why it cannot be built |
|---|---|
| Dragging the floating pet / remembering its position | The protocol denies a client both its own surface position and the ability to set one. The origin is still persisted in case a future protocol allows it; placement is a KWin window rule today. |
| Anchoring the window to the tray icon, closing on focus-out | Same restriction — there is no way to position a surface next to a panel item the app does not own. |
| In-app self-update | The app cannot know how it was installed (distro package, manual build), and guessing wrong would damage the user's installation. It opens the release page instead. |
