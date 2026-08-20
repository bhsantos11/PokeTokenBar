#if os(Linux)
import CGtk
import Foundation

/// The main window — the Linux stand-in for the macOS popover.
///
/// It is a real window rather than a popover attached to the tray icon, because Wayland gives an
/// application no way to position a surface next to a panel item it does not own. So it opens
/// centred and stays on top; that is the closest honest equivalent.
///
/// Content is **rebuilt wholesale** on each refresh instead of diffed. The panel is a few dozen
/// labels refreshed every couple of minutes, so rebuilding costs nothing measurable and removes a
/// whole class of bug where a stale widget keeps showing an old number.
@MainActor
final class PopoverWindow {
    private let store: UsageStore
    private let companion: CompanionStore
    private let window: Widget
    private let stack: Widget
    private let pages: [PopoverTab: Widget]
    private var isVisible = false

    /// Which provider's breakdown is expanded. nil = the first one.
    private var selectedProviderID: String?

    /// What a pending confirmation is armed on. Rows compare against this to decide whether to draw
    /// their action button or the prompt that stands in front of it.
    private enum ConfirmTarget: Equatable {
        case shop(ShopEntry)
        case bag(ItemKind)
        /// Releasing a boxed Pokémon, by index. Irreversible, so it goes through the same ladder.
        case release(Int)
    }

    /// The action awaiting confirmation and the steps it still has to clear, or nil when nothing is
    /// armed. Kept on the window rather than inside the row because `refresh()` rebuilds every row
    /// wholesale — state living in the button would be thrown away by whichever poll landed next.
    ///
    /// Cleared when the panel hides or the tab changes, so an armed confirmation can never sit
    /// waiting behind a tab the player returns to later and clicks blind.
    private var pendingConfirm: (target: ConfirmTarget, steps: [ActionConfirmPolicy.Step])?

    /// Panel size. `set_default_size` is only honoured while the content's natural size is smaller,
    /// so everything inside has to stay within it — see the wrap cap in `Gtk.label`.
    private static let windowWidth: Int32 = 400
    private static let windowHeight: Int32 = 620

    /// Which half of the Collection tab is showing.
    private enum CollectionMode { case dex, log, box, chronicle }
    private var collectionMode: CollectionMode = .dex
    /// Which Pokédex cell is expanded, if any. The grid is a summary; this is the "and what did I
    /// actually catch" answer it cannot fit into a 44pt cell.
    private var selectedSpecies: Int?

    /// Whether the trainer card is showing its name field, and the last export result to report.
    private var renamingTrainer = false
    private var trainerExportNote: String?

    /// Whether the Home hero is showing its rename field instead of the name.
    /// Kept on the window because `refresh()` rebuilds every widget — state inside the row would be
    /// discarded by whichever poll landed while someone was typing.
    private var renamingCompanion = false

    /// Zero-based page of the Chronicle. The store keeps far more entries than one screen shows, and
    /// a diary you cannot read back is a log.
    private var chroniclePage = 0

    /// Zero-based page of the species grid.
    private var dexPage = 0
    /// Rarity filter; nil shows everything. Tapping the active capsule clears it (`l.dexFilterHint`).
    private var rarityFilter: Rarity?
    /// Evolution-line names resolved for catch-log rows, keyed by dex entry id — `dexResolveChainNames`
    /// hits the network on a miss, so a rebuild must not refire it for rows already resolved.
    private var chainNames: [String: [Int: String]] = [:]

    /// 24 per page — the 4×6 grid macOS uses, so both platforms paginate identically.
    private static let dexPageSize = 24
    /// The catch log is a flat list; this bounds how many rows (and sprite fetches) one build costs.
    private static let catchLogLimit = 60

    /// Celebration currently on screen, and the sequence it came from. Held rather than read
    /// straight off the store because the store's copy is consumed as soon as it is shown, while
    /// the banner has to survive the rebuilds that tab switches and refreshes cause.
    private var activeCelebration: String?
    /// The species either side of the celebration: (before, after). `after` is nil for events that
    /// are an arrival rather than a change.
    private var celebrationSprites: (Int, Int?)?
    private var seenCelebrationSeq = -1

    /// Live animation for the Home sprite: the frames, where we are, and a generation counter that
    /// retires the timer when the subject changes. Pixbufs are owned here and unref'd on replace.
    private var animationFrames: [(pixbuf: OpaquePointer, delay: TimeInterval)] = []
    private var animationIndex = 0
    private var animationGeneration = 0
    private var animationImage: Widget?

    /// Sprite bytes already fetched, keyed by "<species>-<shiny>" — avoids re-downloading on every
    /// rebuild, which would otherwise hit the network once per refresh tick.
    private var spriteCache: [String: Data] = [:]

    init(store: UsageStore, companion: CompanionStore, onClose: @escaping () -> Void) {
        self.store = store
        self.companion = companion

        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(asWindow(window), "PokeTokenBar")
        gtk_window_set_default_size(asWindow(window), Self.windowWidth, Self.windowHeight)
        gtk_window_set_keep_above(asWindow(window), 1)
        gtk_window_set_position(asWindow(window), GTK_WIN_POS_CENTER)

        let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.margins(root, top: 10, bottom: 10, start: 10, end: 10)
        gtk_container_add(asContainer(window), root)

        stack = gtk_stack_new()!
        let switcher = gtk_stack_switcher_new()!
        gtk_stack_switcher_set_stack(
            UnsafeMutableRawPointer(switcher).assumingMemoryBound(to: GtkStackSwitcher.self),
            asStack(stack))
        gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER)
        Gtk.pack(root, switcher)

        var built: [PopoverTab: Widget] = [:]
        let l = companion.l
        for (tab, title) in [(PopoverTab.home, l.home), (.shop, l.shop), (.bag, l.bag),
                             (.collection, l.collection), (.trainer, l.trainerTab)] {
            let page = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
            let scroller = gtk_scrolled_window_new(nil, nil)!
            let scrolled = UnsafeMutableRawPointer(scroller).assumingMemoryBound(to: GtkScrolledWindow.self)
            gtk_scrolled_window_set_policy(scrolled, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            // Without this the scroller asks for whatever its widest child wants and the window
            // grows to match — which is how a single long sentence turned a 400pt panel into a
            // full-screen one. Ask for the panel width and let tall content scroll instead.
            gtk_scrolled_window_set_propagate_natural_width(scrolled, 0)
            gtk_scrolled_window_set_propagate_natural_height(scrolled, 0)
            gtk_scrolled_window_set_min_content_width(scrolled, Self.windowWidth - 24)
            gtk_container_add(asContainer(scroller), page)
            gtk_stack_add_titled(asStack(stack), scroller, tab.identifier, title)
            built[tab] = page
        }
        pages = built
        Gtk.pack(root, stack, expand: true)
        observeTabChanges()

        // Closing must hide, not destroy: the tray outlives the window, and destroying it would
        // leave every later `show()` pointing at freed widgets. Returning true stops GTK's default
        // destroy handler.
        let box = GtkCallbackBox { [weak self] in
            self?.hide()
            onClose()
        }
        gtkConnectDeleteEvent(UnsafeMutableRawPointer(window), box: box)
    }

    // MARK: visibility

    var visible: Bool { isVisible }

    func toggle() { isVisible ? hide() : show() }

    /// Switch tabs programmatically. Used by `--window <tab>`; the switcher drives it otherwise.
    /// Clearing armed confirmations has to hang off the **stack**, not off `select(_:)`.
    ///
    /// `GtkStackSwitcher` changes the visible child itself; a user clicking a tab never calls
    /// `select(_:)`. Hooking only the programmatic path let someone arm a purchase, switch tabs,
    /// come back and find the commit still armed — exactly the "never waiting behind a tab"
    /// invariant the confirmation ladder claims. Covers both paths, since `select` moves the stack.
    private func observeTabChanges() {
        gtkConnectNotify(UnsafeMutableRawPointer(stack), property: "visible-child",
                         box: GtkCallbackBox { [weak self] in
                             guard let self else { return }
                             // `notify::visible-child` also fires while `refresh()` tears down and
                             // rebuilds the pages, not only when someone picks another tab. Acting
                             // on every emission made any state set *by* a click get wiped by the
                             // rebuild that same click triggered — the Pokédex detail opened and
                             // vanished within one frame. Compare against the last tab we saw.
                             let name = gtk_stack_get_visible_child_name(asStack(self.stack))
                                 .map { String(cString: $0) }
                             guard name != self.lastVisibleTab else { return }
                             self.lastVisibleTab = name
                             guard self.pendingConfirm != nil || self.selectedSpecies != nil else { return }
                             self.pendingConfirm = nil
                             // Coming back to the Pokédex should land on the grid, not on whatever
                             // cell was open several tabs ago; the Chronicle should land on today.
                             self.selectedSpecies = nil
                             self.chroniclePage = 0
                             self.refresh()
                         })
    }

    /// The tab name at the last emission of `notify::visible-child`, so a rebuild is told apart
    /// from a real tab change.
    private var lastVisibleTab: String?

    func select(_ tab: PopoverTab) {
        pendingConfirm = nil
        gtk_stack_set_visible_child_name(asStack(stack), tab.identifier)
    }

    /// Older saves have dex entries without stored species names; fill them once per session.
    private var didBackfillDexNames = false

    func show() {
        isVisible = true
        // Freeze what was missed before the reference point moves; `refresh()` below renders it.
        companion.markPanelOpened()
        if !didBackfillDexNames {
            didBackfillDexNames = true
            Task { @MainActor in
                await companion.backfillMissingDexNames()
                self.refresh()
            }
        }
        GtkRuntime.hasVisibleWindow = true
        refresh()
        gtk_widget_show_all(window)
        gtk_window_present(asWindow(window))
    }

    func hide() {
        isVisible = false
        // The next "while you were away" starts now, not at the next open — otherwise anything that
        // happens with the panel in front of you is reported back to you as missed.
        companion.markPanelClosed()
        pendingConfirm = nil
        selectedSpecies = nil
        GtkRuntime.hasVisibleWindow = false
        gtk_widget_hide(window)
    }

    /// Rebuild whatever is on screen. Cheap enough to call on every poll (see the type doc).
    func refresh() {
        guard isVisible else { return }
        let l = companion.l
        captureCelebrationIfNeeded(l)
        for (tab, page) in pages {
            Gtk.clear(page)
            switch tab {
            case .home:       buildHome(into: page)
            case .shop:       buildShop(into: page, l)
            case .bag:        buildBag(into: page, l)
            case .collection: buildCollection(into: page, l)
            case .trainer:    buildTrainer(into: page, l)
            }
        }
        gtk_widget_show_all(window)
    }

    /// Pull the sprites the visible tab needs, then rebuild. Async because the first paint may have
    /// to download them.
    func loadSpritesAndRefresh() async {
        await cacheCompanionSprite()
        for kind in ItemKind.allCases { await cacheItemSprite(kind) }
        for item in companion.lineNodes {
            if case .species(let speciesID) = item.content {
                await cacheSprite(speciesID: speciesID, shiny: companion.currentIsShiny)
            }
        }
        // The dex draws one cell per species, the log one per capture — both need sprites, and the
        // dex is the tab that opens first.
        for species in companion.dexSpecies.prefix(Self.dexPageSize * 2) {
            await cacheSprite(speciesID: species.id, shiny: species.isShiny)
        }
        for entry in companion.dexEntriesSorted.prefix(Self.catchLogLimit) {
            await cacheSprite(speciesID: entry.finalID, shiny: entry.isShiny)
        }
        // The Chronicle draws a sprite per entry, and most of its rows came out blank: the species
        // it mentions are historical, so many are no longer in the dex grid or the catch log and
        // nothing else had fetched them. Only the visible page, so a long history is not a download.
        for entry in companion.chronicleEntries.prefix(Self.chronicleLimit * 2) {
            if let id = entry.speciesID { await cacheSprite(speciesID: id, shiny: entry.isShiny) }
        }
        await resolveMissingChainNames()
        refresh()
    }

    /// Fill in evolution-line names for catch-log rows saved before names were stored.
    ///
    /// `dexResolveChainNames` fetches and back-fills, so it must run once per entry rather than on
    /// every rebuild — the cache here is what stops a refresh loop re-requesting the same lines.
    private func resolveMissingChainNames() async {
        for entry in companion.dexEntriesSorted.prefix(Self.catchLogLimit) {
            guard chainNames[entry.id] == nil, companion.dexStoredChainNames(entry) == nil else { continue }
            chainNames[entry.id] = await companion.dexResolveChainNames(entry)
        }
    }

    private func cacheCompanionSprite() async {
        if let subject = companion.currentSpeciesID {
            await cacheSprite(speciesID: subject, shiny: companion.currentIsShiny)
        } else if spriteCache["egg"] == nil {
            spriteCache["egg"] = await SpriteStore.shared.eggData()
        }
    }

    private func cacheSprite(speciesID: Int, shiny: Bool) async {
        let key = "\(speciesID)-\(shiny)"
        guard spriteCache[key] == nil else { return }
        spriteCache[key] = await SpriteStore.shared.data(
            speciesID: speciesID, animated: false, shiny: shiny)
    }

    private func cacheItemSprite(_ kind: ItemKind) async {
        guard let name = kind.spriteName else { return }   // no sprite upstream: emoji fallback
        let key = "item-\(name)"
        guard spriteCache[key] == nil else { return }
        spriteCache[key] = await SpriteStore.shared.data(itemName: name)
    }

    /// A pixbuf image widget for a cached sprite, or nil if it has not arrived yet.
    private func spriteImage(_ key: String, size: Int) -> Widget? {
        guard let data = spriteCache[key], let pixbuf = SpriteRenderer.render(data, size: size)
        else { return nil }
        let image = gtk_image_new_from_pixbuf(pixbuf)!
        g_object_unref(UnsafeMutableRawPointer(pixbuf))
        return image
    }

    /// An item's sprite, falling back to its emoji — the same fallback the macOS shop uses when
    /// PokéAPI has no artwork (mints are Gen-8 and simply absent).
    private func itemIcon(_ kind: ItemKind, size: Int) -> Widget {
        if let name = kind.spriteName, let image = spriteImage("item-\(name)", size: size) {
            return image
        }
        let label = Gtk.label("<span size='x-large'>\(Gtk.escape(kind.fallbackEmoji))</span>")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        return label
    }

    /// Take a newly fired celebration for display, exactly once.
    ///
    /// Keyed on `celebrationSeq` rather than on the optional itself, the way the macOS header does
    /// it: consuming the store's copy immediately would otherwise let the same event replay every
    /// time the panel rebuilt.
    private func captureCelebrationIfNeeded(_ l: L) {
        guard let celebration = companion.celebration,
              companion.celebrationSeq != seenCelebrationSeq else { return }
        seenCelebrationSeq = companion.celebrationSeq
        let name = companion.displayName
        // Which sprites to put beside the words. The Chronicle already recorded the before and after
        // species for this very event, so the banner reads them rather than the store keeping a
        // second copy of the same fact.
        celebrationSprites = companion.chronicleEntries.first.flatMap { entry -> (Int, Int?)? in
            guard let from = entry.speciesID else { return nil }
            switch (celebration, entry.kind) {
            case (.evolve, .evolved):          return (from, entry.toSpeciesID)
            case (.hatch, .hatched):           return (from, nil)
            case (.dittoReveal, .dittoRevealed): return (from, nil)
            default:                           return nil
            }
        }
        switch celebration {
        case .hatch(let shiny):
            activeCelebration = "\(shiny ? l.notifShinyHatchTitle : l.notifHatchTitle)\n\(l.notifHatchBody(name))"
        case .evolve:
            // The **new form's** name, not the companion's. `displayName` is the nickname, so this
            // read "Evolved into Sprout!" — naming the thing that did not change, and leaving out
            // the one thing the message exists to announce.
            // `justEvolvedTo` is cleared when the 4s event window closes, while this banner lives
            // for 30s and is captured on whichever refresh happens next — often after that window.
            // The Chronicle entry keeps the new form permanently, so it is the durable source.
            let form = celebrationSprites?.1.map { companion.speciesName($0) }
                ?? companion.justEvolvedTo ?? name
            activeCelebration = "\(l.notifEvolveTitle)\n\(l.notifEvolveBody(form))"
        case .dittoReveal(let shiny):
            activeCelebration = shiny ? l.notifShinyDittoRevealTitle : l.notifDittoRevealTitle
        }
        companion.consumeCelebration()

        // Self-clearing: a congratulation still sitting there an hour later reads as stale UI.
        let shown = seenCelebrationSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.seenCelebrationSeq == shown else { return }
                self.activeCelebration = nil
                self.celebrationSprites = nil
                self.refresh()
            }
        }
    }

    /// The moment something happened, in words **and** in sprites.
    ///
    /// Evolution is the payoff the whole app builds towards, and it used to be a line of text — the
    /// one thing the player wanted to see, the change itself, was the thing the banner did not show.
    /// For an evolution the two forms sit either side of an arrow; for a hatch or a reveal, the one
    /// who arrived stands next to the words.
    private func celebrationBanner(_ text: String) -> Widget {
        let banner = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(banner, "ptb-card")
        Gtk.addClass(banner, "ptb-celebration")

        if let (from, to) = celebrationSprites {
            let strip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
            gtk_widget_set_halign(strip, GTK_ALIGN_CENTER)
            let shiny = companion.currentIsShiny
            if let before = spriteImage("\(from)-\(shiny)", size: 48)
                ?? spriteImage("\(from)-false", size: 48) {
                Gtk.pack(strip, before)
            }
            // The arrow only earns its place when there is something on the other side of it. The
            // new form's sprite may not be cached yet — it is downloaded after the evolution — and
            // an arrow pointing at nothing reads as a missing image rather than a transformation.
            if let to, let after = spriteImage("\(to)-\(shiny)", size: 56)
                ?? spriteImage("\(to)-false", size: 56) {
                let arrow = Gtk.label("<span size='large'>→</span>")
                gtk_widget_set_valign(arrow, GTK_ALIGN_CENTER)
                Gtk.pack(strip, arrow)
                Gtk.pack(strip, after)
            }
            Gtk.pack(banner, strip)
        }

        let label = Gtk.label("<b>\(Gtk.escape(text))</b>", align: GTK_ALIGN_CENTER, wrap: true)
        gtk_label_set_justify(asLabel(label), GTK_JUSTIFY_CENTER)
        Gtk.pack(banner, label)
        return banner
    }

    // MARK: companion animation

    /// Animate the Home sprite if this species has a Gen-V animated sprite.
    ///
    /// The popover runs at the sprite's native rate (floor 0), unlike the tray: this surface only
    /// exists while someone is looking at it, so the idle-wakeup argument that caps the tray at
    /// 2.5fps does not apply here (`SpriteAnimationPolicy`).
    private func startAnimation(on image: Widget, key: String) {
        animationGeneration += 1
        releaseAnimationFrames()
        animationImage = image
        animationIndex = 0

        guard let speciesID = companion.currentSpeciesID,
              PokemonAssets.hasAnimatedSprite(speciesID: speciesID) else { return }
        let generation = animationGeneration
        let shiny = companion.currentIsShiny
        Task { @MainActor in
            guard let gif = await SpriteStore.shared.data(
                speciesID: speciesID, animated: true, shiny: shiny),
                  generation == self.animationGeneration else { return }
            let frames = SpriteRenderer.renderFrames(gif, size: 72)
            guard frames.count > 1, generation == self.animationGeneration else {
                for frame in frames { g_object_unref(UnsafeMutableRawPointer(frame.pixbuf)) }
                return
            }
            self.animationFrames = frames
            self.scheduleFrame(generation: generation)
        }
    }

    private func scheduleFrame(generation: Int) {
        guard generation == animationGeneration, animationFrames.count > 1, isVisible else { return }
        let frame = animationFrames[animationIndex % animationFrames.count]
        DispatchQueue.main.asyncAfter(deadline: .now() + max(frame.delay, 0.02)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration, self.isVisible,
                      let image = self.animationImage else { return }
                self.animationIndex += 1
                let next = self.animationFrames[self.animationIndex % self.animationFrames.count]
                gtk_image_set_from_pixbuf(asImage(image), next.pixbuf)
                self.scheduleFrame(generation: generation)
            }
        }
    }

    /// Frames are owned here, so replacing them has to unref the old ones or the pixbufs leak —
    /// a species change every few minutes would otherwise accumulate megabytes over a long session.
    private func releaseAnimationFrames() {
        for frame in animationFrames { g_object_unref(UnsafeMutableRawPointer(frame.pixbuf)) }
        animationFrames = []
    }

    // MARK: Shop

    private func buildShop(into page: Widget, _ l: L) {
        let wallet = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(wallet, "ptb-card")
        // The wallet used to be a bare number under the word "Shop". A large figure with no label
        // does not say whether it is what you earned or what you have left, and after a purchase it
        // drops — which looks like the growth meter went backwards, though it never does.
        let caption = Gtk.label(Gtk.escape(l.walletAvailable))
        Gtk.addClass(caption, "ptb-section")
        Gtk.pack(wallet, caption)
        let amount = Gtk.label(
            "<span size='large'><b>\(Gtk.escape(TokenFormatter.compact(companion.availableTokens)))</b></span>")
        gtk_widget_set_tooltip_text(amount, TokenFormatter.grouped(companion.availableTokens))
        Gtk.pack(wallet, amount)

        let breakdownText = l.walletBreakdown(TokenFormatter.compact(companion.walletEarned),
                                              TokenFormatter.compact(companion.walletSpent))
        let breakdown = Gtk.label("<span size='small'>\(Gtk.escape(breakdownText))</span>", wrap: true)
        Gtk.addClass(breakdown, "ptb-muted")
        Gtk.pack(wallet, breakdown)

        // What the balance actually means for the list below it: the best thing in reach, or how far
        // off the cheapest thing is. Otherwise every visit starts by comparing prices by hand.
        if let best = companion.bestAffordable {
            let text = l.walletCanAfford(l.shopEntryName(best))
            let line = Gtk.label("<span size='small'>\(Gtk.escape(text))</span>", wrap: true)
            Gtk.addClass(line, "ptb-price")
            Gtk.pack(wallet, line)
        }
        if let goal = companion.nextGoal {
            let text = l.walletNextGoal(l.shopEntryName(goal.entry),
                                        TokenFormatter.compact(goal.remaining))
            let line = Gtk.label("<span size='small'>\(Gtk.escape(text))</span>", wrap: true)
            Gtk.addClass(line, "ptb-muted")
            Gtk.pack(wallet, line)
        }
        Gtk.pack(page, wallet)

        for entry in companion.shopEntries {
            Gtk.pack(page, shopRow(entry, l))
        }
    }

    private func shopRow(_ entry: ShopEntry, _ l: L) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "ptb-card")

        let title: String
        let subtitle: String
        let affordable: Bool
        let alreadyOwned: Bool
        switch entry {
        case .item(let kind):
            Gtk.pack(row, itemIcon(kind, size: 32))
            title = l.itemName(kind)
            subtitle = l.itemDescription(kind)
            affordable = companion.canBuy(kind)
            alreadyOwned = kind.isPassive && companion.itemCount(kind) > 0
        case .egg(let tier):
            let icon = spriteImage("egg", size: 32) ?? Gtk.label("<span size='x-large'>🥚</span>")
            Gtk.pack(row, icon)
            title = l.eggName(tier)
            // The egg's own description, not the generic shop hint. This line is the only place that
            // says buying one sends the current companion away, and the row shipped without it.
            // A disabled button with no reason reads as a bug. A held egg is the one blocker that
            // is not about money, so it has to say so — the fix is a click away on the Box tab.
            subtitle = companion.hasHeldEgg ? l.boxHeldEggBlocksPurchase : l.eggDescription(tier)
            affordable = companion.canBuyEgg(tier)
            alreadyOwned = false
        }

        // While this row is the armed one, its description line carries the prompt instead — the
        // question lands where the player is already reading rather than in a separate dialog.
        let armed = armedStep(for: .shop(entry))
        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)

        // Title row, with the guaranteed tier as a coloured badge. macOS has carried this since the
        // premium eggs shipped; without it the three eggs differ only by a word in their names, and
        // the 4B one looks like the 1B one.
        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.pack(titleRow, Gtk.label("<b>\(Gtk.escape(title))</b>"))
        if case .egg(let tier) = entry, let tier {
            let badge = Gtk.label(Gtk.escape(l.rarityLabel(tier).uppercased()))
            Gtk.addClass(badge, "ptb-badge")
            Gtk.addClass(badge, "ptb-rarity-\(tier.rawValue)")
            gtk_widget_set_valign(badge, GTK_ALIGN_CENTER)
            Gtk.pack(titleRow, badge)
        }
        Gtk.pack(text, titleRow)
        let body = armed.map { shopPrompt(step: $0, entry: entry, l) } ?? subtitle
        let desc = Gtk.label("<span size='small'>\(Gtk.escape(body))</span>", wrap: true)
        Gtk.addClass(desc, armed == nil ? "ptb-muted" : "ptb-warning")
        Gtk.pack(text, desc)
        // The price is the decision on this row, so it is not fine print. When it is out of reach,
        // say so here instead of only greying the button — a disabled control with no reason reads
        // as a bug (the same rule the limits placeholder follows).
        let priceText = "\(l.shopPriceLabel) \(TokenFormatter.compact(entry.price))"
        let price = Gtk.label(affordable || alreadyOwned
            ? "<span size='small'><b>\(Gtk.escape(priceText))</b></span>"
            : "<span size='small'><b>\(Gtk.escape(priceText))</b> · \(Gtk.escape(l.notEnoughTokens))</span>")
        Gtk.addClass(price, affordable || alreadyOwned ? "ptb-price" : "ptb-muted")
        gtk_widget_set_tooltip_text(price, TokenFormatter.grouped(entry.price))
        Gtk.pack(text, price)
        Gtk.pack(row, text, expand: true)

        if alreadyOwned {
            let owned = Gtk.label("<span size='small'>\(Gtk.escape(l.ownedAlready))</span>")
            gtk_widget_set_valign(owned, GTK_ALIGN_CENTER)
            Gtk.pack(row, owned)
            return row
        }

        if let step = armed {
            Gtk.pack(row, confirmControls(label: shopConfirmLabel(step: step, l),
                                          destructive: ActionConfirmPolicy.discardsCompanion(entry),
                                          l) { [weak self] in
                guard let self, self.advanceConfirm(.shop(entry)) else { return }
                switch entry {
                case .item(let kind):
                    _ = self.companion.buy(kind)
                case .egg(let tier):
                    _ = self.companion.buyEgg(tier)
                    self.select(.home)   // show the new egg straight away, as macOS does after a reroll
                }
                Task { @MainActor in await self.loadSpritesAndRefresh() }
            })
            return row
        }

        let button = gtk_button_new_with_label(l.buy)!
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        // Insufficient balance disables the button rather than hiding it, so the price stays
        // legible as a goal instead of the row silently losing its action.
        gtk_widget_set_sensitive(button, affordable ? 1 : 0)
        // This arms the ladder; it never buys. How many steps stand between here and the purchase
        // is `ActionConfirmPolicy`'s call, not this row's.
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self else { return }
                       self.pendingConfirm = (
                           .shop(entry),
                           ActionConfirmPolicy.steps(buying: entry,
                                                     currentIsShiny: self.companion.currentIsShiny))
                       self.refresh()
                   })
        Gtk.pack(row, button)
        return row
    }

    // MARK: Bag

    private func buildBag(into page: Widget, _ l: L) {
        // Who the items act on, before the items themselves. A column of Use buttons with no visible
        // subject leaves the player guessing what they are about to spend a 500M item on.
        Gtk.pack(page, bagTargetCard(l))

        let owned = companion.ownedItems
        guard !owned.isEmpty else {
            let empty = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            Gtk.margins(empty, top: 24)
            Gtk.pack(empty, Gtk.label("<b>\(Gtk.escape(l.bagEmptyTitle))</b>", align: GTK_ALIGN_CENTER))
            // An empty bag should say how bags stop being empty, not just that it is empty.
            let hint = Gtk.label("<span size='small'>\(Gtk.escape(l.bagEmptyHint))</span>",
                                 align: GTK_ALIGN_CENTER, wrap: true)
            Gtk.addClass(hint, "ptb-muted")
            Gtk.pack(empty, hint)
            Gtk.pack(page, empty)
            return
        }
        for (kind, count) in owned {
            Gtk.pack(page, bagRow(kind, count, l))
        }
    }

    /// The companion an item would be spent on, with its stage — so "Use" has a visible subject.
    private func bagTargetCard(_ l: L) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(card, "ptb-card")
        let caption = Gtk.label("<span size='small'>\(Gtk.escape(l.bagUsingOn))</span>")
        Gtk.addClass(caption, "ptb-section")
        gtk_widget_set_valign(caption, GTK_ALIGN_CENTER)
        Gtk.pack(card, caption)

        guard companion.hasActive else {
            let none = Gtk.label("<span size='small'>\(Gtk.escape(l.bagNoTarget))</span>", wrap: true)
            Gtk.addClass(none, "ptb-muted")
            gtk_widget_set_valign(none, GTK_ALIGN_CENTER)
            Gtk.pack(card, none, expand: true)
            return card
        }
        if let id = companion.currentSpeciesID,
           let image = spriteImage("\(id)-\(companion.currentIsShiny)", size: 32)
            ?? spriteImage("\(id)-false", size: 32) {
            Gtk.pack(card, image)
        }
        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        Gtk.pack(text, Gtk.label("<b>\(Gtk.escape(companion.displayName))</b>"))
        let stage = Gtk.label("<span size='small'>\(Gtk.escape(companion.stageText))</span>")
        Gtk.addClass(stage, "ptb-muted")
        Gtk.pack(text, stage)
        Gtk.pack(card, text, expand: true)
        return card
    }

    private func bagRow(_ kind: ItemKind, _ count: Int, _ l: L) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "ptb-card")
        Gtk.pack(row, itemIcon(kind, size: 32))

        // Same swap as the shop rows: while armed, the count line becomes the question.
        let armed = armedStep(for: .bag(kind))
        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        Gtk.pack(text, Gtk.label("<b>\(Gtk.escape(l.itemName(kind)))</b>"))
        let body = armed == nil ? l.ownedCount(count) : l.useOnCurrent(companion.displayName)
        let countLabel = Gtk.label("<span size='small'>\(Gtk.escape(body))</span>", wrap: true)
        Gtk.addClass(countLabel, armed == nil ? "ptb-muted" : "ptb-warning")
        Gtk.pack(text, countLabel)
        // What the item actually does. The Shop says it, the Bag did not — so once you owned a thing
        // there was nowhere left to find out what it was for.
        if armed == nil {
            let effect = Gtk.label("<span size='small'>\(Gtk.escape(l.itemDescription(kind)))</span>",
                                   wrap: true)
            Gtk.addClass(effect, "ptb-muted")
            Gtk.pack(text, effect)
            let amount = Gtk.label(
                "<span size='small'><b>\(Gtk.escape(l.itemEffect(kind, currentNature: companion.currentNature, companion.language)))</b></span>")
            Gtk.pack(text, amount)
        }
        Gtk.pack(row, text, expand: true)

        // Passive items apply just by being owned — there is nothing to press, so no button.
        guard !kind.isPassive else {
            let applied = Gtk.label("<span size='small'>\(Gtk.escape(l.ownedAlready))</span>")
            gtk_widget_set_valign(applied, GTK_ALIGN_CENTER)
            Gtk.pack(row, applied)
            return row
        }

        if armed != nil {
            Gtk.pack(row, confirmControls(label: l.use, destructive: false, l) { [weak self] in
                guard let self, self.advanceConfirm(.bag(kind)) else { return }
                switch kind {
                case .rareCandy: _ = self.companion.useRareCandy()
                case .mint:      _ = self.companion.useMint()
                case .shinyCharm: break   // passive; handled above
                }
                self.select(.home)   // the evolution / nature-change toast plays on Home, as on macOS
                Task { @MainActor in await self.loadSpritesAndRefresh() }
            })
            return row
        }

        let button = gtk_button_new_with_label(l.useItem)!
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        // Consumables need something to act on; before the first hatch there is no companion.
        gtk_widget_set_sensitive(button, companion.hasActive ? 1 : 0)
        gtk_widget_set_tooltip_text(button, companion.hasActive ? nil : l.useAfterHatch)
        // Arms only — a candy spent on the wrong stage is not recoverable either.
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self else { return }
                       self.pendingConfirm = (.bag(kind), ActionConfirmPolicy.steps(using: kind))
                       self.refresh()
                   })
        Gtk.pack(row, button)
        return row
    }

    // MARK: Confirmation ladder

    /// The step the row for `target` should be showing, or nil when it is not the armed row.
    private func armedStep(for target: ConfirmTarget) -> ActionConfirmPolicy.Step? {
        guard let pending = pendingConfirm, pending.target == target else { return nil }
        return pending.steps.first
    }

    /// Clear one step off the armed ladder. Returns true when nothing is left to ask and the caller
    /// should commit; false when a further step was shown instead (the panel is already rebuilt).
    private func advanceConfirm(_ target: ConfirmTarget) -> Bool {
        guard let pending = pendingConfirm, pending.target == target else { return false }
        let rest = Array(pending.steps.dropFirst())
        guard rest.isEmpty else {
            pendingConfirm = (target, rest)
            refresh()
            return false
        }
        pendingConfirm = nil
        return true
    }

    private func shopPrompt(step: ActionConfirmPolicy.Step, entry: ShopEntry, _ l: L) -> String {
        switch (step, entry) {
        case (.shinyWarning, _):          return l.freshEggShinyWarning
        case (.confirm, .egg(let tier)):  return l.eggConfirm(companion.displayName, l.eggName(tier))
        case (.confirm, .item(let kind)): return l.buyConfirm(l.itemName(kind))
        }
    }

    private func shopConfirmLabel(step: ActionConfirmPolicy.Step, _ l: L) -> String {
        step == .shinyWarning ? l.freshEggDiscardShiny : l.buy
    }

    /// The Confirm/Cancel pair that stands in for a row's action button while it is armed.
    ///
    /// Cancel is drawn last but is the plain button, and nothing is set as the window default — an
    /// action that cannot be undone should not be reachable by a stray Return, the same reasoning
    /// `ImportConfirmPolicy` encodes for the import dialog.
    private func confirmControls(label: String, destructive: Bool, _ l: L,
                                 commit: @escaping () -> Void) -> Widget {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)

        let go = gtk_button_new_with_label(label)!
        if destructive { Gtk.addClass(go, "destructive-action") }
        gtkConnect(UnsafeMutableRawPointer(go), signal: "clicked", box: GtkCallbackBox(commit))
        Gtk.pack(box, go)

        let cancel = gtk_button_new_with_label(l.cancel)!
        gtkConnect(UnsafeMutableRawPointer(cancel), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self else { return }
                       self.pendingConfirm = nil
                       self.refresh()
                   })
        Gtk.pack(box, cancel)
        return box
    }

    // MARK: Collection

    private func buildCollection(into page: Widget, _ l: L) {
        // The empty-state short-circuit has to consider the Box too: `dexEntries` already counts
        // boxed mons, but a held egg with an empty box and no captures still needs the tab to open,
        // otherwise the only way back to a paid egg is unreachable.
        guard !companion.dexEntries.isEmpty || companion.hasHeldEgg
                || !companion.chronicleEntries.isEmpty else {
            let empty = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            Gtk.margins(empty, top: 24)
            Gtk.pack(empty, Gtk.label("<b>\(Gtk.escape(l.dexEmptyTitle))</b>", align: GTK_ALIGN_CENTER))
            let hint = Gtk.label("<span size='small'>\(Gtk.escape(l.dexEmptyHint))</span>",
                                 align: GTK_ALIGN_CENTER)
            Gtk.addClass(hint, "ptb-muted")
            Gtk.pack(empty, hint)
            Gtk.pack(page, empty)
            return
        }

        // Pokédex ⇄ catch log. Two views of the same data: the dex folds individuals into one cell
        // per species, the log keeps every capture.
        let segments = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(segments, GTK_ALIGN_CENTER)
        for (mode, title) in [(CollectionMode.dex, l.dexTitle), (.log, l.catchLogTitle),
                              (.box, boxSegmentTitle(l)), (.chronicle, l.chronicleTitle)] {
            let button = gtk_button_new_with_label(title)!
            Gtk.addClass(button, "ptb-chip")
            if mode == collectionMode { Gtk.addClass(button, "ptb-chip-on") }
            gtk_button_set_relief(
                UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
            gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                       box: GtkCallbackBox { [weak self] in
                           self?.selectedSpecies = nil
                           self?.chroniclePage = 0
                           self?.collectionMode = mode
                           self?.refresh()
                       })
            Gtk.pack(segments, button)
        }
        Gtk.pack(page, segments)
        // The rarity filter belongs to the two collection views; the Box is a short list of
        // individuals you act on, and filtering it would just hide the one you came for.
        // Hidden for the Box (a short list you act on) and while a species is expanded (the filter
        // would narrow a grid that is not on screen).
        if collectionMode != .box, collectionMode != .chronicle,
           !(collectionMode == .dex && selectedSpecies != nil) {
            Gtk.pack(page, rarityFilterRow(l))
        }

        switch collectionMode {
        case .dex: buildSpeciesDex(into: page, l)
        case .log: buildCatchLog(into: page, l)
        case .box: buildBox(into: page, l)
        case .chronicle: buildChronicle(into: page, l)
        }
    }

    // MARK: Trainer card

    /// The journey so far, on one card. Deliberately a separate tab rather than another Collection
    /// segment: the Collection answers "what do I have", this answers "how far have I come", and
    /// four chips was already the most the 412pt panel carries comfortably.
    /// - Parameter forExport: leaves out the controls. A shared image with a "Save as image" button
    ///   painted into it looks like a screenshot someone forgot to crop, and the note under the
    ///   button would bake this machine's file path into a picture meant to be sent to other people.
    private func buildTrainer(into page: Widget, _ l: L, forExport: Bool = false) {
        let stats = companion.trainerStats
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "ptb-card")
        Gtk.addClass(card, "ptb-hero")

        let caption = Gtk.label(Gtk.escape(l.trainerCardTitle), align: GTK_ALIGN_CENTER)
        Gtk.addClass(caption, "ptb-section")
        Gtk.pack(card, caption)
        Gtk.pack(card, trainerNameRow(l))
        // The companion, on the card. This is the one artifact meant to leave the app, and a page of
        // figures with no picture on it is a spreadsheet — the Pokémon is the reason any of the
        // numbers mean anything.
        if let id = companion.currentSpeciesID,
           let image = spriteImage("\(id)-\(companion.currentIsShiny)", size: 72)
            ?? spriteImage("\(id)-false", size: 72) {
            let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            gtk_widget_set_halign(holder, GTK_ALIGN_CENTER)
            Gtk.pack(holder, image)
            let caption = Gtk.label("<span size='small'>\(Gtk.escape(companion.displayName))</span>",
                                    align: GTK_ALIGN_CENTER)
            Gtk.addClass(caption, "ptb-muted")
            Gtk.pack(holder, caption)
            Gtk.pack(card, holder)
        }

        if let days = stats.daysJourneyed {
            let journey = Gtk.label("<span size='small'>\(Gtk.escape(l.trainerDays(days)))</span>",
                                    align: GTK_ALIGN_CENTER)
            Gtk.addClass(journey, "ptb-muted")
            Gtk.pack(card, journey)
        }

        // Completion reads against species *seen*, not the whole national dex — 5 of 649 would be
        // a discouraging and meaningless number for a tray pet.
        let completion = Gtk.meter(fraction: stats.completion, cssClass: "ptb-meter-hero")
        Gtk.margins(completion, top: 4, start: 24, end: 24)
        Gtk.pack(card, completion)
        let seen = Gtk.label(
            "<span size='small'>\(Gtk.escape(l.trainerSeen(stats.speciesGraduated, stats.speciesSeen)))</span>",
            align: GTK_ALIGN_CENTER)
        Gtk.addClass(seen, "ptb-muted")
        Gtk.pack(card, seen)
        Gtk.pack(page, card)

        var rows: [(String, String)] = [
            (l.trainerGraduations, String(stats.graduations)),
            (l.trainerShiny, String(stats.shinySpecies)),
            (l.trainerParty, String(stats.inParty)),
            (l.trainerBox, String(stats.inBox)),
            (l.trainerLifetime, TokenFormatter.compact(stats.lifetimeTokens)),
            (l.trainerSpent, TokenFormatter.compact(stats.spentTokens)),
        ]
        if let rarest = stats.rarestGraduated { rows.append((l.trainerRarest, l.rarityLabel(rarest))) }
        // One achievement on the card, so a shared image says something about the journey rather
        // than only counting it.
        if let highlight = stats.highlightAchievement {
            rows.append((l.achievementsTitle, l.achievementName(highlight)))
        }
        if let favourite = stats.favouriteSpeciesID {
            rows.append((l.trainerFavourite, companion.speciesName(favourite)))
        }
        let statCard = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(statCard, "ptb-card")
        for (label, value) in rows { Gtk.pack(statCard, trainerStatRow(label, value)) }
        Gtk.pack(page, statCard)

        Gtk.pack(page, achievementsCard(l, earnedOnly: forExport))

        guard !forExport else { return }
        let export = gtk_button_new_with_label(l.trainerExport)!
        gtk_widget_set_halign(export, GTK_ALIGN_CENTER)
        gtkConnect(UnsafeMutableRawPointer(export), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in self?.exportTrainerCard(l) })
        Gtk.pack(page, export)

        if let note = trainerExportNote {
            let label = Gtk.label("<span size='small'>\(Gtk.escape(note))</span>",
                                  align: GTK_ALIGN_CENTER, wrap: true)
            Gtk.addClass(label, "ptb-muted")
            Gtk.pack(page, label)
        }
    }

    /// Render the trainer card to a PNG the player can keep or share.
    ///
    /// Drawing is delegated to GTK rather than hand-rolled with Cairo: a `GtkOffscreenWindow` lays
    /// out and paints the very same widgets the tab shows, so the image cannot drift from the screen
    /// as the card changes. The alternative — a second, hand-drawn rendering — is a promise to keep
    /// two layouts in step forever.
    private func exportTrainerCard(_ l: L) {
        let offscreen = gtk_offscreen_window_new()!
        let content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(content, top: 16, bottom: 16, start: 16, end: 16)
        // The panel is 412pt wide; the exported card keeps that proportion so the layout it was
        // designed for is the layout that gets saved.
        gtk_widget_set_size_request(content, 412, -1)
        buildTrainer(into: content, l, forExport: true)
        gtk_container_add(asContainer(offscreen), content)
        gtk_widget_show_all(offscreen)
        // Let GTK allocate and draw before asking for the pixels; without this the surface is empty.
        while gtk_events_pending() != 0 { gtk_main_iteration_do(0) }

        defer { gtk_widget_destroy(offscreen) }
        guard let pixbuf = gtk_offscreen_window_get_pixbuf(asOffscreenWindow(offscreen)) else {
            trainerExportNote = l.trainerExportFailed
            refresh()
            return
        }
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }

        let path = Self.trainerCardExportPath(now: Date())
        var error: UnsafeMutablePointer<GError>?
        // `gdk_pixbuf_save` is variadic and unreachable from Swift; `savev` takes the same options
        // as parallel key/value arrays, and NULL/NULL means "no options".
        let ok = gdk_pixbuf_savev(pixbuf, path.path, "png", nil, nil, &error)
        if let error { g_error_free(error) }
        trainerExportNote = ok != 0 ? l.trainerExported(path.path) : l.trainerExportFailed
        refresh()
    }

    /// Where an exported card lands: the user's Pictures directory, else home.
    ///
    /// Resolved through `FileManager`, **not** by reading `XDG_PICTURES_DIR` directly — a GUI app
    /// launched from a desktop file or a systemd unit does not inherit the shell environment, which
    /// is exactly why `UsageEnvironmentTests` forbids direct environment reads in this target.
    /// The file name itself is `TrainerCard.exportFileName`, in Core so it can be tested.
    static func trainerCardExportPath(now: Date) -> URL {
        let directory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return directory.appendingPathComponent(TrainerCard.exportFileName(now: now))
    }

    /// Achievements, earned first. Locked ones stay visible and named — a hidden list gives the
    /// player nothing to aim at, and every one of these describes something they could go and do.
    /// - Parameter earnedOnly: on the exported card, leave the locked ones out. In the app they are
    ///   something to aim at; in a picture someone shares they are a published list of what that
    ///   person has not done yet, and they double the height of the image.
    private func achievementsCard(_ l: L, earnedOnly: Bool = false) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "ptb-card")
        let earned = companion.earnedAchievements
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let caption = Gtk.label(Gtk.escape(l.achievementsTitle))
        Gtk.addClass(caption, "ptb-section")
        Gtk.pack(header, caption)
        let count = Gtk.label(
            "<span size='small'>\(Gtk.escape(l.achievementsEarned(earned.count, Achievement.allCases.count)))</span>")
        Gtk.addClass(count, "ptb-muted")
        gtk_widget_set_halign(count, GTK_ALIGN_END)
        Gtk.pack(header, count, expand: true)
        Gtk.pack(card, header)

        for achievement in earned { Gtk.pack(card, achievementRow(achievement, earned: true, l)) }
        guard !earnedOnly else { return card }
        for achievement in companion.lockedAchievements {
            Gtk.pack(card, achievementRow(achievement, earned: false, l))
        }
        return card
    }

    private func achievementRow(_ a: Achievement, earned: Bool, _ l: L) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        // A filled/hollow mark rather than colour alone, so the two states are told apart without
        // relying on colour vision.
        let mark = Gtk.label(earned ? "◆" : "◇")
        gtk_widget_set_valign(mark, GTK_ALIGN_START)
        Gtk.addClass(mark, earned ? "ptb-price" : "ptb-muted")
        Gtk.pack(row, mark)

        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        var title = l.achievementName(a)
        if let progress = companion.achievementProgress(a), !earned {
            title += " (\(progress.current)/\(progress.target))"
        }
        let name = Gtk.label("<span size='small'><b>\(Gtk.escape(title))</b></span>")
        gtk_widget_set_halign(name, GTK_ALIGN_START)
        if !earned { Gtk.addClass(name, "ptb-muted") }
        Gtk.pack(text, name)
        let detail = Gtk.label("<span size='small'>\(Gtk.escape(l.achievementDetail(a)))</span>", wrap: true)
        Gtk.addClass(detail, "ptb-muted")
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        Gtk.pack(text, detail)
        Gtk.pack(row, text, expand: true)
        return row
    }

    private func trainerStatRow(_ label: String, _ value: String) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label("<span size='small'>\(Gtk.escape(label))</span>")
        Gtk.addClass(name, "ptb-muted")
        Gtk.pack(row, name)
        let amount = Gtk.label("<span size='small'><b>\(Gtk.escape(value))</b></span>")
        gtk_widget_set_halign(amount, GTK_ALIGN_END)
        Gtk.pack(row, amount, expand: true)
        return row
    }

    /// The trainer's name — click to set it. Same inline pattern as renaming a Pokémon.
    private func trainerNameRow(_ l: L) -> Widget {
        if renamingTrainer {
            return inlineNameEditor(current: companion.trainerName ?? "",
                                    placeholder: l.trainerNoName, hint: l.trainerNameHint, l) { [weak self] text in
                self?.companion.setTrainerName(text)
                self?.renamingTrainer = false
            }
        }
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(row, GTK_ALIGN_CENTER)
        let button = gtk_button_new()!
        gtk_button_set_relief(
            UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
        let shown = companion.trainerName ?? l.trainerNoName
        let label = Gtk.label("<span size='x-large'><b>\(Gtk.escape(shown))</b></span>")
        gtk_container_add(asContainer(button), label)
        gtk_widget_set_tooltip_text(button, l.trainerNameTooltip)
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       self?.renamingTrainer = true
                       self?.refresh()
                   })
        Gtk.pack(row, button)
        return row
    }

    // MARK: Chronicle

    /// The companion's diary. Sentences are built at read time from stored events, so switching the
    /// app language rewrites the whole history rather than leaving old entries in the old language.
    private func buildChronicle(into page: Widget, _ l: L) {
        let entries = companion.chronicleEntries
        guard !entries.isEmpty else {
            let empty = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            Gtk.margins(empty, top: 24)
            Gtk.pack(empty, Gtk.label("<b>\(Gtk.escape(l.chronicleEmptyTitle))</b>", align: GTK_ALIGN_CENTER))
            let hint = Gtk.label("<span size='small'>\(Gtk.escape(l.chronicleEmptyHint))</span>",
                                 align: GTK_ALIGN_CENTER, wrap: true)
            Gtk.addClass(hint, "ptb-muted")
            Gtk.pack(empty, hint)
            Gtk.pack(page, empty)
            return
        }
        let pageCount = max(1, (entries.count + Self.chronicleLimit - 1) / Self.chronicleLimit)
        // Entries only ever get added at the front, so a page index can outrun the list after a
        // reload with a shorter history; clamp rather than draw an empty page.
        chroniclePage = min(chroniclePage, pageCount - 1)
        let start = chroniclePage * Self.chronicleLimit
        let visible = Array(entries[start..<min(start + Self.chronicleLimit, entries.count)])

        var lastDay: String?
        for entry in visible {
            // A date heading per day, so a long history reads as a diary rather than one long list.
            let day = Self.dateFormatter(companion.language).string(from: entry.at)
            if day != lastDay {
                lastDay = day
                let heading = Gtk.label("<span size='small'>\(Gtk.escape(day))</span>")
                Gtk.addClass(heading, "ptb-section")
                Gtk.margins(heading, top: 8)
                Gtk.pack(page, heading)
            }
            Gtk.pack(page, chronicleRow(entry, l))
        }

        guard pageCount > 1 else { return }
        let pager = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_halign(pager, GTK_ALIGN_CENTER)
        Gtk.margins(pager, top: 8)
        // "‹" walks towards the present, "›" towards the past — the list is newest-first, so the
        // arrows read as moving through time rather than through a list.
        Gtk.pack(pager, pagerButton("‹", enabled: chroniclePage > 0) { [weak self] in
            self?.chroniclePage -= 1; self?.refresh()
        })
        let label = Gtk.label(
            "<span size='small'>\(Gtk.escape(l.dexPageLabel(chroniclePage + 1, pageCount)))</span>")
        Gtk.addClass(label, "ptb-muted")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        Gtk.pack(pager, label)
        Gtk.pack(pager, pagerButton("›", enabled: chroniclePage < pageCount - 1) { [weak self] in
            self?.chroniclePage += 1; self?.refresh()
        })
        Gtk.pack(page, pager)
    }

    private func chronicleRow(_ entry: ChronicleEntry, _ l: L) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "ptb-card")
        if let speciesID = entry.speciesID,
           let image = spriteImage("\(speciesID)-\(entry.isShiny)", size: 32)
            ?? spriteImage("\(speciesID)-false", size: 32) {
            gtk_widget_set_valign(image, GTK_ALIGN_START)
            Gtk.pack(row, image)
        }
        let text = Gtk.label("<span size='small'>\(Gtk.escape(companion.chronicleLine(entry)))</span>",
                             wrap: true)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        Gtk.pack(row, text, expand: true)
        return row
    }

    /// How many diary entries fill one page.
    ///
    /// Twelve, not forty: the pager sits under the list, and forty entries buried it behind a long
    /// scroll — a control you have to go looking for is one most people never find. Twelve is about
    /// a screen and a half, so the way to older entries is always close to hand.
    private static let chronicleLimit = 12

    /// Box tab label, carrying the count so a Pokémon waiting in there is visible without opening it.
    private func boxSegmentTitle(_ l: L) -> String {
        companion.boxCount > 0 ? "\(l.boxTitle) (\(companion.boxCount))" : l.boxTitle
    }

    // MARK: Box

    private func buildBox(into page: Widget, _ l: L) {
        // The held egg comes first: it is the thing with a cost attached, and the shop refuses to
        // sell a new egg while it exists, so the way to resolve it must be the first thing seen.
        if companion.hasHeldEgg { Gtk.pack(page, heldEggCard(l)) }

        guard !companion.boxedMons.isEmpty else {
            let empty = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            Gtk.margins(empty, top: 24)
            Gtk.pack(empty, Gtk.label("<b>\(Gtk.escape(l.boxEmptyTitle))</b>", align: GTK_ALIGN_CENTER))
            let hint = Gtk.label("<span size='small'>\(Gtk.escape(l.boxEmptyHint))</span>",
                                 align: GTK_ALIGN_CENTER, wrap: true)
            Gtk.addClass(hint, "ptb-muted")
            Gtk.pack(empty, hint)
            Gtk.pack(page, empty)
            return
        }
        for (index, mon) in companion.boxedMons.enumerated() {
            Gtk.pack(page, boxRow(index, mon, l))
        }
    }

    private func heldEggCard(_ l: L) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(card, "ptb-card")
        Gtk.pack(card, spriteImage("egg", size: 32) ?? Gtk.label("<span size='x-large'>🥚</span>"))

        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        Gtk.pack(text, Gtk.label("<b>\(Gtk.escape(l.boxHeldEggTitle))</b>"))
        var detail = l.boxHeldEggHint
        if let tier = companion.heldEggGuarantee { detail = "\(l.eggGuaranteeHint(tier)) · \(detail)" }
        let hint = Gtk.label("<span size='small'>\(Gtk.escape(detail))</span>", wrap: true)
        Gtk.addClass(hint, "ptb-muted")
        Gtk.pack(text, hint)
        let progress = Gtk.label(
            "<span size='small'>\(Int((companion.heldEggProgress * 100).rounded()))%</span>")
        Gtk.addClass(progress, "ptb-muted")
        Gtk.pack(text, progress)
        Gtk.pack(card, text, expand: true)

        let button = gtk_button_new_with_label(l.boxReturnToEgg)!
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        gtk_widget_set_sensitive(button, companion.canReturnToHeldEgg ? 1 : 0)
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self else { return }
                       _ = self.companion.returnToHeldEgg()
                       self.select(.home)
                       Task { @MainActor in await self.loadSpritesAndRefresh() }
                   })
        Gtk.pack(card, button)
        return card
    }

    private func boxRow(_ index: Int, _ mon: MonState, _ l: L) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "ptb-card")
        // `displayShiny` rather than `mon.isShiny` — a disguised Ditto must not show its shiny
        // sprite here before the reveal.
        let shiny = CompanionStore.displayShiny(mon)
        Gtk.pack(row, spriteImage("\(mon.currentID)-\(shiny)", size: 40)
                      ?? spriteImage("\(mon.currentID)-false", size: 40)
                      ?? Gtk.label("<span size='x-large'>❔</span>"))

        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let shinyMark = shiny ? "✨ " : ""
        let name = companion.boxedDisplayName(mon)
        Gtk.pack(text, Gtk.label("<b>\(Gtk.escape(shinyMark + name))</b>"))
        // While the release is armed, this line carries the question — the same place the shop and
        // bag put theirs, so the confirmation always appears where the description was.
        let metaText = armedStep(for: .release(index)) != nil
            ? l.boxReleaseConfirm(name)
            : "\(l.rarityLabel(mon.rarity)) · \(l.stage(mon.stageIndex + 1, mon.totalForms))"
        let meta = Gtk.label("<span size='small'>\(Gtk.escape(metaText))</span>", wrap: true)
        Gtk.addClass(meta, armedStep(for: .release(index)) != nil ? "ptb-warning" : "ptb-muted")
        Gtk.pack(text, meta)
        // Growth is the whole reason the Box beats a discard — show that it survived.
        let growth = Gtk.label("<span size='small'>\(Gtk.escape(l.boxGrowth)) "
            + "\(Gtk.escape(TokenFormatter.compact(mon.usedAtStage)))</span>")
        Gtk.addClass(growth, "ptb-muted")
        Gtk.pack(text, growth)
        Gtk.pack(row, text, expand: true)

        // Releasing is the one irreversible action left in the app, so it uses the confirmation
        // ladder the shop and bag use rather than acting on a single click.
        if armedStep(for: .release(index)) != nil {
            Gtk.pack(row, confirmControls(label: l.boxRelease, destructive: true, l) { [weak self] in
                guard let self, self.advanceConfirm(.release(index)) else { return }
                _ = self.companion.release(at: index)
                Task { @MainActor in await self.loadSpritesAndRefresh() }
            })
            return row
        }

        let releaseButton = gtk_button_new_with_label(l.boxRelease)!
        gtk_button_set_relief(
            UnsafeMutableRawPointer(releaseButton).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
        gtk_widget_set_valign(releaseButton, GTK_ALIGN_CENTER)
        Gtk.addClass(releaseButton, "ptb-muted")
        gtkConnect(UnsafeMutableRawPointer(releaseButton), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self else { return }
                       self.pendingConfirm = (.release(index), [.confirm])
                       self.refresh()
                   })
        Gtk.pack(row, releaseButton)

        let button = gtk_button_new_with_label(l.boxWithdraw)!
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        gtk_widget_set_sensitive(button, companion.canWithdraw(at: index) ? 1 : 0)
        if companion.hasActive {
            gtk_widget_set_tooltip_text(button, l.boxSwapHint(companion.displayName))
        }
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self else { return }
                       _ = self.companion.withdraw(at: index)
                       self.select(.home)
                       Task { @MainActor in await self.loadSpritesAndRefresh() }
                   })
        Gtk.pack(row, button)
        return row
    }

    /// Rarest first, as macOS orders them — deliberately not the enum's declaration order.
    private static let rarityDisplayOrder: [Rarity] = [.legendary, .rare, .uncommon, .common]

    /// Rarity capsules with counts. Tapping the active one clears the filter (`l.dexFilterHint`).
    ///
    /// The counts differ by view and that is intentional: the Pokédex counts **species**, the catch
    /// log counts **individuals** (`dexCount`). Using one for both would make the capsules disagree
    /// with the list they filter.
    private func rarityFilterRow(_ l: L) -> Widget {
        // A flow box rather than a plain row: four rarity words do not always fit on one line at
        // 400pt in every language, and clipping the last capsule hides a filter entirely.
        let row = gtk_flow_box_new()!
        let flow = UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkFlowBox.self)
        gtk_flow_box_set_selection_mode(flow, GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(flow, 4)
        // Ask for all four on one line and let the box fill the panel. Centring it instead makes the
        // flow box request its minimum width, which is one capsule — and they stack vertically.
        gtk_flow_box_set_min_children_per_line(flow, 4)
        gtk_flow_box_set_homogeneous(flow, 1)
        gtk_widget_set_halign(row, GTK_ALIGN_FILL)
        let species = companion.dexSpecies
        for rarity in Self.rarityDisplayOrder {
            let count = collectionMode == .dex
                ? species.filter { $0.rarity == rarity }.count
                : companion.dexCount(rarity)
            let button = gtk_button_new_with_label("\(l.rarityLabel(rarity)) \(count)")!
            Gtk.addClass(button, "ptb-chip")
            Gtk.addClass(button, "ptb-chip-tight")
            if rarityFilter == rarity { Gtk.addClass(button, "ptb-chip-on") }
            gtk_button_set_relief(
                UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
            gtk_widget_set_tooltip_text(button, l.dexFilterHint)
            // Kept visible but disabled at zero, so the row does not reflow as the dex fills up.
            gtk_widget_set_sensitive(button, count > 0 ? 1 : 0)
            gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                       box: GtkCallbackBox { [weak self] in
                           guard let self else { return }
                           self.rarityFilter = self.rarityFilter == rarity ? nil : rarity
                           self.dexPage = 0   // the old page may not exist under the new filter
                           self.refresh()
                       })
            gtk_container_add(asContainer(row), button)
        }
        return row
    }

    /// One cell per owned species, 24 to a page — the same 4×6 grid macOS uses.
    private func buildSpeciesDex(into page: Widget, _ l: L) {
        if let selectedSpecies {
            Gtk.pack(page, speciesDetailCard(selectedSpecies, l))
            return
        }
        let all = companion.dexSpecies
        let species = rarityFilter.map { r in all.filter { $0.rarity == r } } ?? all
        let pageCount = max(1, (species.count + Self.dexPageSize - 1) / Self.dexPageSize)
        // A filter change can strand the page past the end; clamp rather than show a blank grid.
        dexPage = min(dexPage, pageCount - 1)
        let start = dexPage * Self.dexPageSize
        let visible = Array(species[start..<min(start + Self.dexPageSize, species.count)])

        // Unfiltered on purpose: the filtered count is already on the active capsule.
        let total = Gtk.label("<span size='small'>\(Gtk.escape(l.dexSpeciesTotal(all.count)))</span>",
                              align: GTK_ALIGN_CENTER)
        Gtk.addClass(total, "ptb-muted")
        Gtk.pack(page, total)

        // A `GtkGrid` of buttons rather than a `GtkFlowBox`.
        //
        // FlowBox was the natural fit for a wrapping grid, but neither `child-activated` nor
        // `selected-children-changed` ever fired for a pointer click here, while plain buttons work
        // everywhere else in this panel. Rather than keep guessing at its event handling, the cells
        // are buttons — the column count was fixed at 4 anyway, so the wrapping FlowBox provided was
        // never actually used.
        let grid = gtk_grid_new()!
        let g = UnsafeMutableRawPointer(grid).assumingMemoryBound(to: GtkGrid.self)
        // **Not** column-homogeneous: with a filter leaving two species, homogeneous columns stretch
        // those two across the full width and the grid stops looking like a grid. A fixed cell width
        // keeps every cell the same size whatever the filter leaves.
        gtk_grid_set_row_spacing(g, 6)
        gtk_grid_set_column_spacing(g, 6)
        gtk_widget_set_halign(grid, GTK_ALIGN_CENTER)
        for (index, entry) in visible.enumerated() {
            let button = gtk_button_new()!
            gtk_button_set_relief(
                UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
            Gtk.addClass(button, "ptb-cell-button")
            // 4 across the 412pt panel, minus padding and the 6pt gaps.
            gtk_widget_set_size_request(button, 88, -1)
            gtk_widget_set_tooltip_text(button, l.dexCellTooltip)
            gtk_container_add(asContainer(button), speciesCell(entry, l))
            let speciesID = entry.id
            gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                       box: GtkCallbackBox { [weak self] in
                           guard let self else { return }
                           self.selectedSpecies = speciesID
                           self.refresh()
                       })
            gtk_grid_attach(g, button, Int32(index % 4), Int32(index / 4), 1, 1)
        }
        Gtk.pack(page, grid)

        guard pageCount > 1 else { return }
        let pager = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_halign(pager, GTK_ALIGN_CENTER)
        Gtk.pack(pager, pagerButton("‹", enabled: dexPage > 0) { [weak self] in
            self?.dexPage -= 1; self?.refresh()
        })
        let label = Gtk.label(
            "<span size='small'>\(Gtk.escape(l.dexPageLabel(dexPage + 1, pageCount)))</span>")
        Gtk.addClass(label, "ptb-muted")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        Gtk.pack(pager, label)
        Gtk.pack(pager, pagerButton("›", enabled: dexPage < pageCount - 1) { [weak self] in
            self?.dexPage += 1; self?.refresh()
        })
        Gtk.pack(page, pager)
    }

    private func pagerButton(_ glyph: String, enabled: Bool, _ action: @escaping () -> Void) -> Widget {
        let button = gtk_button_new_with_label(glyph)!
        gtk_button_set_relief(
            UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
        gtk_widget_set_sensitive(button, enabled ? 1 : 0)
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked", box: GtkCallbackBox(action))
        return button
    }

    private func speciesCell(_ species: CompanionStore.DexSpecies, _ l: L) -> Widget {
        let cell = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        Gtk.addClass(cell, "ptb-cell")
        // 44pt, as macOS uses — four of these plus padding is what fits the panel width.
        if let image = spriteImage("\(species.id)-\(species.isShiny)", size: 44)
            ?? spriteImage("\(species.id)-false", size: 44) {
            Gtk.pack(cell, image)
        }
        var name = Gtk.escape(species.name)
        if species.isShiny { name = "✨ " + name }
        Gtk.pack(cell, Gtk.label("<span size='x-small'>\(name)</span>", align: GTK_ALIGN_CENTER))
        // "Raising" marks a cell backed only by the companion in hand — buying a fresh egg discards
        // it and the cell disappears, which would look like data loss without the badge.
        if species.isRaising {
            let badge = Gtk.label("<span size='x-small'>\(Gtk.escape(l.dexRaising))</span>",
                                  align: GTK_ALIGN_CENTER)
            Gtk.addClass(badge, "ptb-badge")
            Gtk.pack(cell, badge)
        }
        return cell
    }

    /// The expanded card for one species: which individuals it covers, and what each one was.
    ///
    /// The grid folds a species into a single cell on purpose, so two Bulbasaurs raised months apart
    /// look like one entry. This is where they separate again — nickname, nature, when it was caught,
    /// and whether it is still being raised.
    private func speciesDetailCard(_ speciesID: Int, _ l: L) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "ptb-card")
        Gtk.addClass(card, "ptb-hero")

        let species = companion.dexSpecies.first { $0.id == speciesID }
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        if let image = spriteImage("\(speciesID)-\(species?.isShiny ?? false)", size: 64)
            ?? spriteImage("\(speciesID)-false", size: 64) {
            Gtk.pack(header, image)
        }
        let titleBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(titleBox, GTK_ALIGN_CENTER)
        let shinyMark = (species?.isShiny ?? false) ? "✨ " : ""
        Gtk.pack(titleBox, Gtk.label(
            "<span size='large'><b>\(Gtk.escape(shinyMark + (species?.name ?? "#\(speciesID)")))</b></span>"))
        if let rarity = species?.rarity {
            let badge = Gtk.label(Gtk.escape(l.rarityLabel(rarity).uppercased()))
            Gtk.addClass(badge, "ptb-badge")
            Gtk.addClass(badge, "ptb-rarity-\(rarity.rawValue)")
            gtk_widget_set_halign(badge, GTK_ALIGN_START)
            Gtk.pack(titleBox, badge)
        }
        Gtk.pack(header, titleBox, expand: true)

        let close = gtk_button_new_with_label(l.dexBackToGrid)!
        gtk_widget_set_valign(close, GTK_ALIGN_CENTER)
        gtkConnect(UnsafeMutableRawPointer(close), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       self?.selectedSpecies = nil
                       self?.refresh()
                   })
        Gtk.pack(header, close)
        Gtk.pack(card, header)

        // Every individual whose evolution line passes through this species — the same rule the
        // grid uses to decide the species is owned at all, so the two views cannot disagree.
        let individuals = companion.dexEntriesSorted.filter { $0.chainOrder.contains(speciesID) }
        let count = Gtk.label("<span size='small'>\(Gtk.escape(l.dexIndividualsOwned(individuals.count)))</span>")
        Gtk.addClass(count, "ptb-muted")
        Gtk.pack(card, count)

        for entry in individuals.prefix(Self.speciesDetailLimit) {
            Gtk.pack(card, speciesDetailRow(entry, l))
        }
        if individuals.count > Self.speciesDetailLimit {
            let more = Gtk.label(
                "<span size='small'>+\(individuals.count - Self.speciesDetailLimit)</span>")
            Gtk.addClass(more, "ptb-muted")
            Gtk.pack(card, more)
        }
        return card
    }

    /// One individual inside the species detail.
    private func speciesDetailRow(_ entry: DexEntry, _ l: L) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        var facts: [String] = []
        if let nature = entry.nature {
            facts.append(nature.name(companion.language))
            if let effect = l.natureGrowthEffect(nature) { facts.append(effect) }
        }
        if let caughtAt = entry.caughtAt {
            facts.append(Self.dateFormatter(companion.language).string(from: caughtAt))
        } else if companion.isRaisingDexEntry(entry) {
            facts.append(l.dexRaising)
        }
        let name = entry.nickname ?? l.dexIndividualUnnamed
        Gtk.pack(row, Gtk.label("<span size='small'><b>\(Gtk.escape(name))</b></span>"))
        let detail = Gtk.label("<span size='small'>\(Gtk.escape(facts.joined(separator: " · ")))</span>",
                               wrap: true)
        Gtk.addClass(detail, "ptb-muted")
        Gtk.pack(row, detail, expand: true)
        return row
    }

    /// How many individuals the detail card lists before collapsing into a count.
    private static let speciesDetailLimit = 8

    /// Every individual caught, newest first, with its line, rarity, nature and capture date.
    private func buildCatchLog(into page: Widget, _ l: L) {
        let all = companion.dexEntriesSorted
        let entries = rarityFilter.map { r in all.filter { $0.rarity == r } } ?? all
        // Unfiltered, matching the species dex above.
        let total = Gtk.label("<span size='small'>\(Gtk.escape(l.dexTotal(all.count)))</span>",
                              align: GTK_ALIGN_CENTER)
        Gtk.addClass(total, "ptb-muted")
        Gtk.pack(page, total)
        for entry in entries.prefix(Self.catchLogLimit) { Gtk.pack(page, catchLogRow(entry, l)) }
        if entries.count > Self.catchLogLimit {
            let more = Gtk.label(
                "<span size='small'>+\(entries.count - Self.catchLogLimit)</span>",
                align: GTK_ALIGN_CENTER)
            Gtk.addClass(more, "ptb-muted")
            Gtk.pack(page, more)
        }
    }

    private func catchLogRow(_ entry: DexEntry, _ l: L) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "ptb-card")
        if companion.isRaisingDexEntry(entry) { Gtk.addClass(row, "ptb-stage-current") }
        if let image = spriteImage("\(entry.finalID)-\(entry.isShiny)", size: 44)
            ?? spriteImage("\(entry.finalID)-false", size: 44) {
            Gtk.pack(row, image)
        }

        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)

        // Names come from the entry when it was saved with them; older saves need a fetch, which is
        // cached here so a rebuild does not re-request the same line.
        let names = chainNames[entry.id] ?? companion.dexStoredChainNames(entry)
        let line = entry.chainOrder
            .map { names?[$0] ?? "#\($0)" }
            .joined(separator: " → ")
        var heading = Gtk.escape(line)
        if entry.isShiny { heading = "✨ " + heading }
        Gtk.pack(text, Gtk.label("<span size='small'><b>\(heading)</b></span>", wrap: true))

        var facts = [l.rarityLabel(entry.rarity)]
        // Localised name, not `rawValue` — the raw case is an English identifier that leaked into
        // the UI. And the growth effect beside it, so a nature reads as a trait rather than a label.
        if let nature = entry.nature {
            facts.append(nature.name(companion.language))
            if let effect = l.natureGrowthEffect(nature) { facts.append(effect) }
        }
        if let caughtAt = entry.caughtAt {
            facts.append(Self.dateFormatter(companion.language).string(from: caughtAt))
        }
        if companion.isRaisingDexEntry(entry) { facts.append(l.dexRaising) }
        let detail = Gtk.label("<span size='small'>\(Gtk.escape(facts.joined(separator: " · ")))</span>",
                               wrap: true)
        Gtk.addClass(detail, "ptb-muted")
        Gtk.pack(text, detail)
        Gtk.pack(row, text, expand: true)
        return row
    }

    /// Capture dates in the app's language, not the system's.
    private static func dateFormatter(_ language: AppLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.displayLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }


    // MARK: Home

    private func buildHome(into page: Widget) {
        let l = companion.l
        if let celebration = activeCelebration { Gtk.pack(page, celebrationBanner(celebration)) }
        if let away = awayCard(companion.l) { Gtk.pack(page, away) }
        for banner in providerStatusBanners() { Gtk.pack(page, banner) }
        Gtk.pack(page, companionCard(l))
        Gtk.pack(page, totalsCard(l))
        if let line = evolutionLine() { Gtk.pack(page, line) }
        if !store.snapshots.isEmpty { Gtk.pack(page, providerCard(l)) }
        // A missing limits card and a hidden one look identical on screen, so the placeholder is not
        // optional decoration: without it a restart during a 429 backoff reads as "the feature broke"
        // (2026-08-19 report). macOS keeps its header and a load row for the same reason.
        if let limits = store.limits {
            Gtk.pack(page, limitsCard(l, limits))
        } else if store.snapshots.contains(where: { $0.providerID == "claude_code" }) {
            Gtk.pack(page, limitsPlaceholderCard(l))
        }
        if store.snapshots.isEmpty {
            Gtk.pack(page, Gtk.label("<span size='small'>\(Gtk.escape(l.dexEmptyHint))</span>",
                                     align: GTK_ALIGN_CENTER))
        }
    }

    /// Sprite + name + rarity + progress, matching the macOS home header.
    /// The Home hero — the companion, centred and large.
    ///
    /// It used to be a 72px thumbnail in a row, which made the token counter the biggest thing on
    /// screen. For an app whose point is the pet, the pet should be the thing you look at; the
    /// numbers are why it grows, not what it is. The vertical layout also uses the panel height,
    /// which the old row left mostly empty.
    private func companionCard(_ l: L) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "ptb-card")
        Gtk.addClass(card, "ptb-hero")

        Gtk.pack(card, heroSprite())
        Gtk.pack(card, heroHeading(l))

        // Egg and hatched companion track different quantities, so the subtitle, the meter and the
        // remaining-amount line all switch together.
        let stage = companion.isEgg ? l.eggIncubating
            : (companion.isFinalStage ? l.finalForm : companion.stageText)
        // The nature's growth effect rides on the stage line: this is the one place the player
        // watches the bar move, so an unexplained ±10% would read as the meter being wrong.
        var stageText = stage
        if !companion.isEgg, let effect = l.natureGrowthEffect(companion.currentNature) {
            stageText += " · \(effect)"
        }
        let stageLabel = Gtk.label("<span size='small'>\(Gtk.escape(stageText))</span>",
                                   align: GTK_ALIGN_CENTER)
        Gtk.addClass(stageLabel, "ptb-muted")
        Gtk.pack(card, stageLabel)

        let fraction = companion.isEgg ? companion.eggProgress : companion.progress
        // Tinted by rarity so the bar itself says what you are raising. An egg has no rarity yet
        // (the roll happens at hatch), so it keeps the default accent.
        let meter = Gtk.meter(fraction: fraction,
                              cssClass: companion.rarity.map { "ptb-meter-\($0.rawValue)" })
        Gtk.addClass(meter, "ptb-meter-hero")
        Gtk.margins(meter, top: 4, start: 24, end: 24)
        // Hover detail: the compact form on screen ("109.1M") hides the exact figure, and this is
        // the number people actually want to check against their own usage.
        gtk_widget_set_tooltip_text(meter, companion.isEgg
            ? l.eggToHatch(TokenFormatter.grouped(companion.eggTokensToHatch))
            : l.toGraduation(TokenFormatter.grouped(companion.tokensToNext)))
        Gtk.pack(card, meter)

        let remaining = companion.isEgg
            ? l.eggToHatch(TokenFormatter.compact(companion.eggTokensToHatch))
            : l.toGraduation(TokenFormatter.compact(companion.tokensToNext))
        let remainingLabel = Gtk.label(
            "<span size='small'>\(Gtk.escape(remaining))  ·  \(Int((fraction * 100).rounded()))%</span>",
            align: GTK_ALIGN_CENTER)
        Gtk.addClass(remainingLabel, "ptb-muted")
        Gtk.pack(card, remainingLabel)

        // A pet reaction takes the status line's place while it is showing — two lines of chatter
        // stacked on top of each other reads as noise, and the reaction is the one you just asked for.
        let statusText = companion.petReaction ?? companion.statusLine
        let status = Gtk.label("<span size='small'>\(Gtk.escape(statusText))</span>",
                               align: GTK_ALIGN_CENTER, wrap: true)
        Gtk.addClass(status, companion.petReaction != nil ? "ptb-reaction" : "ptb-muted")
        Gtk.pack(card, status)

        return card
    }

    /// The sprite, clickable. Clicking pets the companion — flavour only, no game state changes.
    private func heroSprite() -> Widget {
        let key = companion.currentSpeciesID.map { "\($0)-\(companion.currentIsShiny)" } ?? "egg"
        let holder = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_halign(holder, GTK_ALIGN_CENTER)

        guard let data = spriteCache[key], let pixbuf = SpriteRenderer.render(data, size: 112) else {
            return holder
        }
        let image = gtk_image_new_from_pixbuf(pixbuf)!
        g_object_unref(UnsafeMutableRawPointer(pixbuf))
        // A plain GtkImage takes no input, so the click has to go through an event box. Flat +
        // no relief keeps it looking like a sprite rather than a button with a picture in it.
        let button = gtk_button_new()!
        gtk_button_set_relief(
            UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
        Gtk.addClass(button, "ptb-sprite-button")
        gtk_container_add(asContainer(button), image)
        gtk_widget_set_tooltip_text(button, companion.l.petTooltip)
        gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self else { return }
                       self.companion.pet()
                       self.refresh()
                       // The reaction expires on its own clock; without a repaint scheduled for that
                       // moment it would sit on screen until the next poll happens to redraw.
                       DispatchQueue.main.asyncAfter(
                           deadline: .now() + CompanionStore.petReactionWindow + 0.1
                       ) { [weak self] in
                           MainActor.assumeIsolated { self?.refresh() }
                       }
                   })
        Gtk.pack(holder, button)
        // The static frame goes up first so the card never appears empty, then the animation
        // takes over the same widget if this species has one.
        startAnimation(on: image, key: key)
        return holder
    }

    /// Name + rarity badge. The name is a button: clicking it opens the rename row.
    private func heroHeading(_ l: L) -> Widget {
        if renamingCompanion { return renameRow(l) }
        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(heading, GTK_ALIGN_CENTER)

        let nameButton = gtk_button_new()!
        gtk_button_set_relief(
            UnsafeMutableRawPointer(nameButton).assumingMemoryBound(to: GtkButton.self), GTK_RELIEF_NONE)
        let nameLabel = Gtk.label("<span size='x-large'><b>\(Gtk.escape(companion.displayName))</b></span>")
        gtk_container_add(asContainer(nameButton), nameLabel)
        // Renaming needs something to rename; an egg has no individual yet.
        gtk_widget_set_sensitive(nameButton, companion.hasActive ? 1 : 0)
        if companion.hasActive { gtk_widget_set_tooltip_text(nameButton, l.renameTooltip) }
        gtkConnect(UnsafeMutableRawPointer(nameButton), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       guard let self, self.companion.hasActive else { return }
                       self.renamingCompanion = true
                       self.refresh()
                   })
        Gtk.pack(heading, nameButton)

        if let rarity = companion.rarity {
            let badge = Gtk.label(Gtk.escape(l.rarityLabel(rarity).uppercased()))
            Gtk.addClass(badge, "ptb-badge")
            Gtk.addClass(badge, "ptb-rarity-\(rarity.rawValue)")
            gtk_widget_set_valign(badge, GTK_ALIGN_CENTER)
            Gtk.pack(heading, badge)
        }
        return heading
    }

    /// Inline rename for the companion. Inline rather than a dialog for the same reason the shop
    /// confirmations are inline: a transient window losing focus takes the dialog with it.
    private func renameRow(_ l: L) -> Widget {
        inlineNameEditor(current: companion.displayName,
                         placeholder: companion.speciesDisplayName,
                         hint: l.nicknameHint, l) { [weak self] text in
            self?.companion.setNickname(text)
            self?.renamingCompanion = false
        }
    }

    /// A one-field inline editor: entry, Save, Cancel, and a hint. Shared by the companion nickname
    /// and the trainer name so the two cannot drift in behaviour — Enter commits in both.
    private func inlineNameEditor(current: String, placeholder: String, hint: String, _ l: L,
                                  commitText: @escaping (String?) -> Void) -> Widget {
        let row = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let entryRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(entryRow, GTK_ALIGN_CENTER)

        let entry = gtk_entry_new()!
        gtk_entry_set_text(asEntry(entry), current)
        gtk_entry_set_max_length(asEntry(entry), Int32(CompanionStore.nicknameMaxLength))
        gtk_entry_set_width_chars(asEntry(entry), 16)
        gtk_entry_set_placeholder_text(asEntry(entry), placeholder)
        Gtk.pack(entryRow, entry)

        let commit = GtkCallbackBox { [weak self] in
            guard let self else { return }
            commitText(gtk_entry_get_text(asEntry(entry)).map { String(cString: $0) })
            self.refresh()
        }
        // Enter in the field commits, as well as the button — a one-field form that only accepts
        // a mouse click is the kind of thing people try Enter on first and conclude is broken.
        gtkConnect(UnsafeMutableRawPointer(entry), signal: "activate", box: commit)

        let saveButton = gtk_button_new_with_label(l.save)!
        gtkConnect(UnsafeMutableRawPointer(saveButton), signal: "clicked", box: commit)
        Gtk.pack(entryRow, saveButton)

        let cancelButton = gtk_button_new_with_label(l.cancel)!
        gtkConnect(UnsafeMutableRawPointer(cancelButton), signal: "clicked",
                   box: GtkCallbackBox { [weak self] in
                       self?.renamingCompanion = false
                       self?.renamingTrainer = false
                       self?.refresh()
                   })
        Gtk.pack(entryRow, cancelButton)
        Gtk.pack(row, entryRow)

        let hintLabel = Gtk.label("<span size='small'>\(Gtk.escape(hint))</span>",
                                  align: GTK_ALIGN_CENTER, wrap: true)
        Gtk.addClass(hintLabel, "ptb-muted")
        Gtk.pack(row, hintLabel)
        return row
    }

    /// What happened since the panel was last open.
    ///
    /// The Chronicle has always known, but nothing surfaced it: a pet that evolves while you work
    /// does so unwitnessed, and opening the panel showed only the end state. nil when nothing
    /// happened, so the card never says "nothing happened" — that is not worth a card.
    private func awayCard(_ l: L) -> Widget? {
        let away = companion.awaySummary
        guard !away.isEmpty else { return nil }
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(card, "ptb-card")

        if let headline = away.headline, let id = headline.speciesID,
           let image = spriteImage("\(id)-\(headline.isShiny)", size: 32)
            ?? spriteImage("\(id)-false", size: 32) {
            gtk_widget_set_valign(image, GTK_ALIGN_CENTER)
            Gtk.pack(card, image)
        }
        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let title = Gtk.label("<span size='small'>\(Gtk.escape(l.awayTitle))</span>")
        Gtk.addClass(title, "ptb-section")
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        Gtk.pack(text, title)
        // The counts, then the single most notable event in the Chronicle's own words — the numbers
        // say how much, the sentence says what it felt like.
        let counts = l.awayCounts(hatched: away.hatched, evolved: away.evolved,
                                  graduated: away.graduated, shinies: away.shinies)
        let countsLabel = Gtk.label("<span size='small'><b>\(Gtk.escape(counts))</b></span>", wrap: true)
        gtk_widget_set_halign(countsLabel, GTK_ALIGN_START)
        Gtk.pack(text, countsLabel)
        if let headline = away.headline {
            let line = Gtk.label(
                "<span size='small'>\(Gtk.escape(companion.chronicleLine(headline)))</span>", wrap: true)
            Gtk.addClass(line, "ptb-muted")
            gtk_widget_set_halign(line, GTK_ALIGN_START)
            Gtk.pack(text, line)
        }
        Gtk.pack(card, text, expand: true)
        return card
    }

    /// A row per provider currently reporting an incident.
    ///
    /// Only degraded providers appear (`hasIssue`): a green "all fine" row would take space in the
    /// one place the user came to read numbers. The provider's own wording is shown rather than a
    /// paraphrase, because it is the authoritative description of what is broken.
    private func providerStatusBanners() -> [Widget] {
        store.statuses
            .filter { $0.value.indicator.hasIssue }
            .sorted { $0.key < $1.key }
            .map { providerID, status in
                let name = store.snapshots.first { $0.providerID == providerID }?.displayName
                    ?? providerID
                let banner = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
                Gtk.addClass(banner, "ptb-card")
                Gtk.addClass(banner, status.indicator == .minor ? "ptb-status-minor" : "ptb-status-major")
                Gtk.pack(banner, Gtk.label("<b>\(Gtk.escape(name))</b>"))
                Gtk.pack(banner, Gtk.label(
                    "<span size='small'>\(Gtk.escape(status.description))</span>", wrap: true))
                return banner
            }
    }

    /// The evolution line: what this companion has been, is, and can still become.
    ///
    /// Stages already passed are shown at full strength, the current one is ringed, and future ones
    /// are dimmed — an unresolved branch is a "?" because the line genuinely is not decided yet.
    /// Returns nil for an egg, which has no line to show.
    private func evolutionLine() -> Widget? {
        let items = companion.lineNodes
        guard items.count > 1 else { return nil }
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(row, "ptb-card")
        gtk_widget_set_halign(row, GTK_ALIGN_CENTER)

        for (index, item) in items.enumerated() {
            if index > 0 {
                let arrow = Gtk.label("<span size='small'>→</span>")
                Gtk.addClass(arrow, "ptb-muted")
                gtk_widget_set_valign(arrow, GTK_ALIGN_CENTER)
                Gtk.pack(row, arrow)
            }
            let cell: Widget
            switch item.content {
            case .species(let speciesID):
                let key = "\(speciesID)-\(companion.currentIsShiny)"
                cell = spriteImage(key, size: 40) ?? Gtk.label("<span size='small'>#\(speciesID)</span>")
            case .mystery:
                cell = Gtk.label("<span size='large'>?</span>")
            }
            switch item.state {
            case .current: Gtk.addClass(cell, "ptb-stage-current")
            case .future:  Gtk.addClass(cell, "ptb-stage-future")
            case .done:    break
            }
            Gtk.pack(row, cell)
        }
        return row
    }

    /// Today's total, with week and month beneath it.
    private func totalsCard(_ l: L) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(card, "ptb-card")

        let caption = Gtk.label(Gtk.escape(l.todayTokens))
        Gtk.addClass(caption, "ptb-section")
        Gtk.pack(card, caption)

        let headline = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let big = Gtk.label("<b>\(Gtk.escape(TokenFormatter.compact(store.todayTotalTokens)))</b>")
        Gtk.addClass(big, "ptb-huge")
        Gtk.pack(headline, big)

        // The exact figure sits next to the abbreviated one, as on macOS — "319.9M" is for glancing,
        // the grouped number is for anyone reconciling against a bill.
        let exact = Gtk.label("<span size='small'>\(Gtk.escape(TokenFormatter.grouped(store.todayTotalTokens)))</span>")
        Gtk.addClass(exact, "ptb-muted")
        gtk_widget_set_valign(exact, GTK_ALIGN_END)
        Gtk.pack(headline, exact)

        if store.showsCost {
            let cost = Gtk.label("<span size='small'>\(Gtk.escape(TokenFormatter.cost(store.todayCostTotal)))</span>")
            Gtk.addClass(cost, "ptb-muted")
            gtk_widget_set_valign(cost, GTK_ALIGN_END)
            gtk_widget_set_hexpand(cost, 1)
            gtk_widget_set_halign(cost, GTK_ALIGN_END)
            Gtk.pack(headline, cost, expand: true)
        }
        Gtk.pack(card, headline)

        let periods = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 16)
        Gtk.pack(periods, periodLabel(l.thisWeek, store.weekTotalTokens, store.weekCostTotal))
        Gtk.pack(periods, periodLabel(l.thisMonth, store.monthTotalTokens, store.monthCostTotal))
        Gtk.pack(card, periods)
        return card
    }

    private func periodLabel(_ title: String, _ tokens: Int, _ cost: Double) -> Widget {
        var markup = "<span size='small'>\(Gtk.escape(title)) <b>\(Gtk.escape(TokenFormatter.compact(tokens)))</b>"
        if store.showsCost { markup += " \(Gtk.escape(TokenFormatter.cost(cost)))" }
        markup += "</span>"
        let label = Gtk.label(markup)
        Gtk.addClass(label, "ptb-muted")
        return label
    }

    /// Provider chips plus the selected provider's token breakdown.
    private func providerCard(_ l: L) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "ptb-card")

        let chips = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let selected = selectedProviderID ?? store.snapshots.first?.providerID
        for snapshot in store.snapshots {
            let button = gtk_button_new_with_label(snapshot.displayName)!
            Gtk.addClass(button, "ptb-chip")
            if snapshot.providerID == selected { Gtk.addClass(button, "ptb-chip-on") }
            gtk_button_set_relief(
                UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self),
                GTK_RELIEF_NONE)
            let id = snapshot.providerID
            gtkConnect(UnsafeMutableRawPointer(button), signal: "clicked",
                       box: GtkCallbackBox { [weak self] in
                           self?.selectedProviderID = id
                           self?.refresh()
                       })
            Gtk.pack(chips, button)
        }
        Gtk.pack(card, chips)

        guard let snapshot = store.snapshots.first(where: { $0.providerID == selected }),
              let today = snapshot.today
        else { return card }

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.pack(heading, Gtk.label("<b>\(Gtk.escape(snapshot.displayName))</b>"))
        let total = Gtk.label("<b>\(Gtk.escape(TokenFormatter.compact(today.totalTokens)))</b>")
        gtk_widget_set_hexpand(total, 1)
        gtk_widget_set_halign(total, GTK_ALIGN_END)
        Gtk.pack(heading, total, expand: true)
        if snapshot.reportsCost {
            Gtk.pack(heading, Gtk.label("<span size='small'>\(Gtk.escape(TokenFormatter.cost(today.totalCost)))</span>"))
        }
        Gtk.pack(card, heading)

        let parts = [
            ("in", today.inputTokens), ("out", today.outputTokens),
            ("cache w", today.cacheCreationTokens), ("cache r", today.cacheReadTokens),
        ]
        let breakdown = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        for (name, value) in parts {
            let label = Gtk.label(
                "<span size='small'>\(name) <b>\(Gtk.escape(TokenFormatter.compact(value)))</b></span>")
            Gtk.addClass(label, "ptb-muted")
            Gtk.pack(breakdown, label)
        }
        Gtk.pack(card, breakdown)
        return card
    }

    /// The limits card with no values yet — header plus why. Ordered most specific first: an expired
    /// session needs a re-login, a retained fetch error explains itself (429 and friends), and before
    /// the first poll there is nothing wrong to report.
    private func limitsPlaceholderCard(_ l: L) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(card, "ptb-card")
        let caption = Gtk.label(Gtk.escape(l.limitsOfficial))
        Gtk.addClass(caption, "ptb-section")
        Gtk.pack(card, caption)

        let reason: String
        if store.disableKeychainAccess {
            // The fetch is switched off, so nothing is loading and nothing is retrying. Saying
            // "Loading…" forever is the same silent-hide problem in a different costume.
            reason = l.limitRefreshNoCredential
        } else if store.limitsAuthExpired {
            reason = l.claudeAuthExpiredTitle
        } else if let error = store.limitsErrorText {
            reason = error
        } else {
            reason = l.limitsLoading
        }
        let body = Gtk.label("<span size='small'>\(Gtk.escape(reason))</span>", wrap: true)
        Gtk.addClass(body, "ptb-muted")
        Gtk.pack(card, body)
        return card
    }

    /// The official Claude limit windows — utilisation, reset countdown and burn-rate forecast.
    private func limitsCard(_ l: L, _ limits: LimitStatus) -> Widget {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "ptb-card")
        let caption = Gtk.label(Gtk.escape(l.limitsOfficial))
        Gtk.addClass(caption, "ptb-section")
        Gtk.pack(card, caption)
        // Values restored from disk on launch, or left over through a long 429 backoff, must never
        // read as "just fetched" — a stale percentage presented as current is worse than no card.
        if store.claudeLimitsStale {
            let stale = Gtk.label("<span size='small'>\(Gtk.escape(l.staleLimits))"
                + "\(store.limitsUpdatedAt.flatMap { RelativeTime.elapsed(since: $0) }.map { " · " + $0 } ?? "")</span>")
            Gtk.addClass(stale, "ptb-warning")
            Gtk.pack(card, stale)
        }

        let windows: [(String, LimitWindow?)] = [
            (l.fiveHourSession, limits.fiveHour),
            (l.weekly, limits.sevenDay),
            (l.weeklyOpus, limits.sevenDayOpus),
            (l.weeklySonnet, limits.sevenDaySonnet),
        ]
        for (title, window) in windows {
            // A window with no utilisation has not been reported by the API — showing an empty
            // meter would read as "0% used", which is the opposite of "unknown".
            guard let window, let utilization = window.utilization else { continue }
            Gtk.pack(card, limitRow(title, utilization, resetsAt: window.resetDate))
        }
        if let forecast = forecastLine(l) { Gtk.pack(card, forecast) }
        return card
    }

    /// "At current rate, limit hit at 14:32" — or that it will not be reached before the reset.
    ///
    /// `UsageStore.fiveHourForecast` already decides both, including refusing to extrapolate from a
    /// burn rate too low to be meaningful, so this only renders the answer.
    private func forecastLine(_ l: L) -> Widget? {
        guard let forecast = store.fiveHourForecast else { return nil }
        let text = forecast.beforeReset
            ? l.forecastReach(RelativeTime.clockTime(forecast.depletionDate,
                                                     locale: companion.language.displayLocale))
            : l.forecastNoReach
        let label = Gtk.label("<span size='small'>\(Gtk.escape(text))</span>", wrap: true)
        Gtk.addClass(label, "ptb-muted")
        return label
    }

    private func limitRow(_ title: String, _ utilization: Double, resetsAt: Date?) -> Widget {
        let l = companion.l
        let row = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.pack(heading, Gtk.label("<span size='small'>\(Gtk.escape(title))</span>"))

        // How long the window still has. Hidden once it has passed rather than shown as a negative;
        // the next refresh brings the new window anyway.
        if let resetsAt, let countdown = RelativeTime.remaining(until: resetsAt) {
            let reset = Gtk.label(
                "<span size='small'>\(Gtk.escape(l.reset)) \(Gtk.escape(countdown))</span>")
            Gtk.addClass(reset, "ptb-muted")
            Gtk.pack(heading, reset)
        }

        let percent = Gtk.label(
            "<span size='small'><b>\(Gtk.escape(TokenFormatter.percent(utilization)))</b></span>")
        gtk_widget_set_hexpand(percent, 1)
        gtk_widget_set_halign(percent, GTK_ALIGN_END)
        Gtk.pack(heading, percent, expand: true)
        Gtk.pack(row, heading)

        // Same thresholds the menu bar and the limit notifications use, so one glance means one thing.
        let meter = Gtk.meter(fraction: utilization)
        if utilization >= store.critThreshold {
            Gtk.addClass(meter, "ptb-crit")
        } else if utilization >= store.warnThreshold {
            Gtk.addClass(meter, "ptb-warn")
        } else {
            Gtk.addClass(meter, "ptb-ok")
        }
        Gtk.pack(row, meter)
        return row
    }
}

private extension PopoverTab {
    /// Stable identifier for `gtk_stack_add_titled`; the visible title is localised separately.
    var identifier: String {
        switch self {
        case .home: return "home"
        case .shop: return "shop"
        case .bag: return "bag"
        case .collection: return "collection"
        case .trainer: return "trainer"
        }
    }
}
#endif   // os(Linux)
