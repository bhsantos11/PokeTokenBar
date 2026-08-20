# PokeTokenBar roadmap

Two tracks, tracked in one file because they share the same Core.

- **Track A — Linux feature parity.** Closing the gap between the Linux (GTK3) frontend and the
  features the macOS app advertises in [README.md](README.md). Substantially done; what remains is
  verification on a real panel rather than construction.
- **Track B — Gameplay.** The game is currently monotonic: usage only goes up, nothing is ever at
  risk, and the only decision is which item to buy. These are the changes that give it choices,
  rhythm and texture. **G1, G2, G3, G5 and G6 are built** (Linux); G4 is still blocked on a design
  decision. Each carries a macOS gap, since that half cannot be built or verified on this machine.

Everything below is **buildable** — the two genuinely impossible items (dragging the floating pet,
anchoring the window to the tray icon) are Wayland restrictions and are recorded at the bottom
rather than as tasks. Ideas that are not yet decided live in [To refine](#to-refine) and are
deliberately not checkboxes.

**Last updated: 2026-08-19**

## Track A — Linux feature parity

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

### Phase 3 — Collection, properly  ✅ done, verified on screen
Today's Collection tab is a flat grid of individuals capped at 60. macOS has two distinct views.
- [x] **Species Pokédex** — `companion.dexSpecies`, 24 per page (macOS 4×6), with paging controls
- [x] Rarity **filter** capsules with counts; tapping the active one clears it
- [x] ✨ marker for shiny ownership, plus the `Raising` badge for a not-yet-graduated species
- [x] **Catch log** — individuals with evolution line, rarity, nature and capture date; missing
      line names resolved once and cached, so rebuilds do not refetch
- [x] Segmented control to switch dex ↔ catch log

### Phase 4 — The floating pet, fully  ⚠️ built, interaction unverified
- [x] **Hover callout** — `hoverTooltip` moved to `Core/FloatingPetCopy` (4 tests, now running on
      both platforms); macOS keeps a forwarder so its own tests are untouched
- [x] **Right-click menu** (open, settings, hide, quit) — secondary button only, so primary
      clicks still reach the pet's `clicked` handler
- [x] **Speech-bubble limit alerts** above the pet, mirroring `store.currentBubbleAlert`; the
      store owns the 6s TTL so the UI runs no timer of its own

### Phase 5 — Housekeeping the app owes the user  ✅ done, verified on screen
- [x] **Update check** in Settings — status label plus a Check now button (`minInterval: 0`, so an
      explicit press is not swallowed by the 30-minute poll guard); opens the release page
- [x] **Save export / import** via GTK file choosers, with the full macOS import gauntlet:
      decode → summarise → confirm (Cancel is the default) → `applySave`

> Phase 4's three additions are built and compile, but none could be **seen**: headless sway has no
> pointer device, so the right-click menu and the hover callout cannot be triggered, and the bubble
> needs a live limit alert (the usage endpoint is rate-limiting). They need one pass on the real panel.

### Gates (Track A)
- [ ] Every phase verified on the real Plasma panel, not only headless
- [ ] `swift test` still green on Linux; new pure logic covered by tests
- [ ] README gap list shrunk in the same change that closes a gap (all three languages)

## Track B — Gameplay

Nothing here is started. Ordered by value per unit of work, and the order matters: **G1 is first
because it removes a whole category of loss**, and the rest are more fun on top of a game where
mistakes are recoverable.

Each phase names its **open decisions** — the balance numbers and economics are Bernardo's call,
not something to infer from the code. A phase whose decisions are unanswered is not ready to build.

### Phase G1 — The PC Box  ✅ core + Linux UI built, verified on screen
Buying a shop egg permanently destroys the active Pokémon: no Pokédex entry, no trace, no undo
(`buyEgg` deliberately leaves `dex`/`collectedFinals` untouched — "as if it was never drawn").
On 2026-08-19 that cost a ten-hour Bulbasaur to a single unconfirmed click. The confirmation is
fixed; the **destruction** is still the design. A Box turns an irreversible loss into a decision,
and gives the shop egg an honest identity — a swap rather than a trap.

- [x] `boxed: [MonState]` in `CompanionState`, absent-decodes-as-empty so existing saves migrate
      silently, with **per-entry isolation** (`Lossy<MonState>`) like the dex
- [x] Deposit path — `buyEgg` boxes the active Pokémon instead of dropping it
- [x] Withdraw path — swap active ↔ boxed, with the active one going back to the Box
- [x] Growth (`usedAtStage`) survives a Box round-trip — losing it makes the Box a slower discard
- [x] Boxed mons stay visible in the Pokédex and catch log — vanishing from the collection is
      indistinguishable from being lost, which is the anxiety the Box exists to remove
- [x] Every async writer of `state.active` is invalidated on a swap (`activeGeneration`), and a swap
      is refused while a hatch or a Ditto reveal is in flight
- [x] `SaveTransfer.sanitized` clamps boxed individuals with the same rule as the active one
- [x] Regression tests (10) — including a **reload from disk**, the way this feature was most likely
      to fail silently; defect injected and confirmed failing
- [x] Box UI on Linux — a third Collection segment, listing rarity, stage, shiny and growth
- [x] Gate: a boxed Pokémon survives a quit/relaunch cycle (verified by reloading the file, and on
      screen by taking one out and checking the save)
- [ ] **Box UI on macOS** — the Core work is shared and done, but the SwiftUI view does not exist.
      Cannot be built or verified on this machine. **owner: Bernardo** (needs a Mac).

**Decisions taken 2026-08-19 (Bernardo).** Unlimited capacity; free withdrawal (the 1B egg price is
already the cost); graduation still goes straight to the Pokédex; the shop egg always deposits, so
the destructive path is gone rather than merely confirmed.

**Deviation from the plan — the held egg.** The plan did not anticipate that an egg only incubates
while `active == nil`, so taking a Pokémon out mid-incubation leaves a paid-for egg with nowhere to
live. Leaving `eggTier` alongside an active mon would have made `sanitized` treat a 1B–4B guarantee
as a hand-edit and silently delete it. Resolved with an explicit `heldEgg` record: the egg is set
aside intact and resumed via **Back to the egg**, and the anti-leak guard survives because a
guarantee is now only legitimate when an egg — incubating or held — actually exists.
A deliberate consequence: the shop refuses to sell an egg while one is held, and says why.

### Phase G2 — The 5-hour block as a circadian cycle  ✅ built, Linux wired
- [x] `CircadianPhase` (asleep / fresh / steady / winding) as a pure function of the active block
- [x] Wired into `computeState`: `winding` → `.tired`, `asleep` → `.sleep`
- [x] Degrades honestly — an expired or unparseable block reads as `asleep`, never a permanently
      tired pet; the parameter defaults to `.steady` so callers that do not pass it are unaffected
- [x] Tested at every boundary, plus the future-clock and expired-block edges
- [ ] **macOS caller** does not pass the phase, so the rhythm is Linux-only for now. Same reason as
      the Box UI — cannot build or verify here. **owner: Bernardo** (needs a Mac).
- [ ] Gate: seen changing state across a real block boundary on the live panel (needs a 5h window
      to elapse, so it cannot be forced)

**Correction to the plan — the data source.** The plan said to use `store.limits`. That would have
been wrong: the limits endpoint is 429-heavy on this account, and `isLimitWarning` reads only that,
which meant `.tired` was **unreachable whenever limits were rate-limited**. The 5-hour block is
computed *locally* from usage logs (`LocalUsageReader.activeBlock`), so keying the rhythm to it
makes it work regardless of the network — and fixes the pre-existing dead state.

**The open decision dissolved.** "Does sleep pause incubation?" turned out to be a non-question:
growth and incubation only accrue from token usage, and `asleep` means no tokens have flowed for
five hours. There is nothing running to pause. Sleep is therefore presentation, by arithmetic
rather than by choice.

The energy concern in the plan also does not apply: `SpriteAnimationPolicy` sets a frame-rate floor
and knows nothing about display state, so adding states costs nothing at idle.

### Phase G3 — Natures with teeth  ✅ built
- [x] `PokemonNature.growthMultiplier` — **±10% on growth only**, never on `usedSinceInstall` or the
      today/week/month totals, which are real usage statistics and must not carry game modifiers
- [x] Mapping follows the **main-series Speed natures**: Timid / Hasty / Jolly / Naive grow 10%
      faster, Brave / Relaxed / Quiet / Sassy 10% slower, the other 17 are exactly 1.0 — a rule a
      player already knows beats one this project invents
- [x] Visible in the UI — on the Home stage line and in the catch log, which also stopped printing
      the raw English enum case and now shows the localised nature name
- [x] Legacy saves are exactly neutral: nil nature is 1.0, never a silent 0×
- [x] A slow nature still grows on tiny deltas (rounds, never floors — flooring would freeze a slow
      individual forever at the 1-token deltas real usage produces)
- [x] Balance check in tests: the slowest nature still reaches graduation at every rarity
- [x] Regression tests (6), including the nil path and both extremes

**Decision taken.** ±10%, growth only. Rare Candy is deliberately unscaled — it is a purchased
fixed-value item, and making its worth depend on the individual you spend it on turns a simple
consumable into a lookup table.

**Consequence worth knowing.** A test that applied *exactly* `graduationTotal` to force graduation
started failing, because a slow individual now needs more than that. That was the test binding
itself to balance numbers while checking sorting; it now overshoots deliberately. Bernardo's own
Bulbasaur has no nature (unrecoverable after the 2026-08-19 incident) so it is neutral — but a Mint
is now a real decision for it rather than a cosmetic one.

### Phase G6 — Interaction and Home polish  ✅ built, verified on screen
Added 2026-08-19 at Bernardo's request ("more interactible features and spruce up the UI"), after
looking at the panel at its **real 412×620 size** rather than the full-screen headless captures used
earlier — which had been hiding how much dead space the layout carried.

- [x] **Home is now pet-first**: 112px centred sprite, large name, rarity badge, a thicker inset
      growth meter tinted by rarity. The pet was previously a 72px thumbnail while the token counter
      was the biggest thing on screen — the wrong subject for an app about a pet
- [x] **Click the sprite to pet it** — a state-appropriate line in place of the status text
      (a sleeping companion says "…zzZ", a focused one is "fired up"). Changes **no** game state:
      growth, wallet and odds are untouched, because a click that pays turns interaction into labour
- [x] **Nicknames** — click the name to rename inline, Enter or Save commits, empty clears back to
      the species name. Carried into the Pokédex on graduation and shown in the Box and catch log
- [x] Nickname length bounded both when set and at the **import boundary**, by characters not bytes
- [x] **Hover details** — the growth meter shows the exact grouped figure, the sprite says
      "Click to pet", the name says "Click to rename"
- [x] Rarity now has colour: badges and the growth meter share an accent per tier, where every tier
      previously rendered the same flat grey
- [x] Fixed: the companion fell back to the name "Token Egg" whenever its evolution line had not
      loaded, so the panel showed a Pokémon sprite labelled as an egg. Now falls back to `#id`
- [x] Regression tests (11) — including nickname surviving a reload from disk, with the decoder
      omission injected and confirmed failing
- [ ] **macOS**: none of this is wired into the SwiftUI frontend. Core (`pet()`, `setNickname`,
      `tapReaction`) is shared and ready. **owner: Bernardo** (needs a Mac).

**Not done, deliberately.** Affection-from-petting was offered and declined — it would turn a
free interaction into a daily chore.

### Phase G4 — Trade cards
`SaveTransfer` already exports, imports, summarises, confirms and sanitises a whole save. A
single-Pokémon variant would give the project a social hook worth the three-language README work.
This is last because it is the only phase with an unsolved **design** problem, not just unsolved
numbers.

- [ ] Single-`MonState` export/import reusing `SaveTransfer.sanitized` — external files means the
      value-range clamping is mandatory, not optional (see the defect log's external-input rules)
- [ ] Import lands in the Box (depends on **G1**), never over the active Pokémon
- [ ] Import confirmation reuses `ImportConfirmPolicy` — Cancel stays the default
- [ ] Gate: a hand-edited or truncated trade card is rejected with a message, and cannot crash or
      corrupt the receiving save

**Open decision — owner: Bernardo.** Duplication. A file that can be imported twice is a
duplication machine, and the app has no server to arbitrate. Options: accept it and treat cards as
gifts rather than trades; consume the individual on export; or mark cards with an origin id and
refuse re-import of one already seen.

### Phase G5 — Limits that survive a restart  ✅ built
`last-snapshot.json` caches token totals but not limits, so limits are memory-only. Any restart
inside a 429 backoff window shows no values at all. As of 2026-08-19 the panel at least explains
itself (`limitsErrorText` + a placeholder card) instead of silently hiding the section — but
"rate-limited, retrying" is a worse thing to show than the last known numbers marked stale.

- [x] `LimitsCache` persists the last successful `LimitStatus` with its timestamp, in its own file —
      `last-snapshot.json` turned out to be a parity-check artifact the app never reads back
- [x] Restored **before** the first refresh, so a launch straight into a 429 still shows numbers
- [x] Never presented as fresh: `limitsUpdatedAt` is restored too, so the existing `claudeLimitsStale`
      path marks it, and the Linux card now shows a "Stale · 2h 13m" line it previously lacked
- [x] Display only — restoring does not re-arm candy grants or limit alerts, which are edge-triggered
      and would double-grant if replayed from a past value
- [x] Refuses caches older than 24h, from the future (clock adjustment), or corrupt
- [x] Regression tests (7), including both sides of the expiry boundary
- [ ] Not yet seen on screen — needs a launch during a 429 window with a cache present
      (the cache file now exists and is being written, confirmed on the live install)

## To refine

Ideas worth building that are **not yet designed**. Deliberately not checkboxes: turning one into a
task means answering its question first.

### Type affinity from how you actually worked
Bias the hatched species' type by the usage mix that incubated the egg — heavy Opus leaning
Dragon/Psychic, lots of Haiku leaning Flying/Normal, Codex leaning Steel, long saturated 5-hour
blocks leaning Fighting. The appeal is that the Pokédex stops recording *how much* you spent and
starts recording *how you worked*; per-provider tokens and `ModelPricing` are already tracked, so
the data exists.

**Why it is not a task yet.** Bernardo almost exclusively uses Opus. As described, affinity would
narrow his collection to two or three types forever — the mechanic would take variety away from the
person it is meant to reward, which is the opposite of the intent. A monoculture user is the common
case, not the edge case, so this needs a design that survives one.

Directions worth exploring, none chosen:
- Affinity as a **thumb on the scale**, not a gate — a modest weight bump that never zeroes any
  type, so the mix is coloured rather than restricted.
- Affinity that reads **relative change** rather than absolute share: a day with unusually more
  Haiku than *your own* baseline counts as a Haiku day, which gives a monoculture user variety
  without asking them to change how they work.
- Affinity applied to something **other than species** — a type-coloured aura, a badge, a shiny-odds
  nudge — leaving the species roll untouched.
- Scoped affinity: it decides the type only for a *guaranteed* egg bought in the shop, where the
  player has opted in and knows what they are choosing.

Whichever direction wins, the constraint from `docs/reference/provider-extension.md` holds: a
weight table keyed by provider id, never `== "claude_code"` branches in a general path.

## Follow-ups this work surfaced

- [ ] `l.importSaveHint` says a save comes "from another **Mac**". True before this port; now it
      should be device-neutral. It is user-facing copy in ko/en/ja/es, so it wants a real
      translation rather than a guess — **owner: Bernardo** to confirm the wording.
- [ ] The limits card (Phase 1) still has not been seen rendering. The endpoint has been returning
      429 intermittently since 2026-08-18 (94 occurrences), and a second app instance will not run
      alongside the installed service, so capturing it means stopping the user's tray. Waiting for a
      window where limits are live instead.
- [ ] The new **placeholder** limits card (2026-08-19) has not been seen on screen either, for the
      same reason. Its store-side behaviour is covered by tests; the card itself is not.

### Fixed on 2026-08-19 (from a user report)

Both were the same class — the GTK port kept a macOS view's happy path and dropped the state that
explains itself. Recorded in `docs/reference/defect-log.md` under the porting section.

- [x] Shop and bag actions committed on the **first click**; the macOS confirmation ladder had not
      been ported. Rule moved to `ActionConfirmPolicy` in Core so both frontends read one source.
- [x] The limits card was hidden entirely when a fetch failed, which is indistinguishable from the
      feature being gone. The auto-poll path now retains a reason (`limitsErrorText`) and the panel
      renders a card explaining itself. **Persisting the values** is Phase G5, still to do.

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
