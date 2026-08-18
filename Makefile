# PokeTokenBar — canonical runbook.
#
# `make` with no target prints the list below. Targets are grouped by platform where they differ:
# the Linux tray frontend and the macOS .app bundle are built by different toolchains, but share
# one source tree and one test suite.
#
# Release is deliberately NOT a target — scripts/release.sh is interactive, irreversible and
# macOS-only. See docs/reference/release-workflow.md.

SHELL := /bin/bash
.DEFAULT_GOAL := help

UNAME_S := $(shell uname -s)
BIN_NAME := PokeTokenBar
DEBUG_BIN := $(shell swift build --show-bin-path 2>/dev/null)/$(BIN_NAME)
RELEASE_BIN := $(shell swift build -c release --show-bin-path 2>/dev/null)/$(BIN_NAME)

# Installed layout (Linux, user-scoped — no root anywhere in this Makefile).
PREFIX ?= $(HOME)/.local
INSTALL_BIN := $(PREFIX)/bin/poketokenbar
DESKTOP_FILE := $(PREFIX)/share/applications/poketokenbar.desktop
ICON_DIR := $(PREFIX)/share/icons/hicolor
ICON_FILE := $(ICON_DIR)/512x512/apps/poketokenbar.png

# SwiftPM warns "prohibited flag(s): -pthread" once per system-library target whenever it
# regenerates the build plan. The flag reaches it transitively through glib's Requires.private, and
# SwiftPM discards it and builds fine — so it is noise, but noise that hides real warnings. The shim
# generates pthread-free .pc files under .build/ (never committed) and points pkg-config at them.
# Guarded so an empty result cannot prepend an empty PKG_CONFIG_PATH entry.
ifeq ($(UNAME_S),Linux)
PKGCONFIG_SHIM := $(shell ./scripts/pkgconfig-shim.sh 2>/dev/null)
ifneq ($(PKGCONFIG_SHIM),)
export PKG_CONFIG_PATH := $(PKGCONFIG_SHIM):$(PKG_CONFIG_PATH)
endif
endif

# The version lives in exactly one place; AppVersion.swift is generated from it.
VERSION := $(shell grep -oE 'VERSION="[0-9.]+"' scripts/build-app.sh | grep -oE '[0-9.]+')
VERSION_SWIFT := Sources/PokeTokenBar/Core/Platform/AppVersion.swift

.PHONY: help build release run stop test test-gate version-sync version-check \
        install uninstall autostart-enable autostart-disable autostart-status \
        app clean

help:   ## Show this help
	@echo "PokeTokenBar $(VERSION) — $(UNAME_S)"
	@echo
	@grep -hE '^[a-z0-9-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
ifeq ($(UNAME_S),Linux)
	@echo "  Start here:  make run"
else
	@echo "  Start here:  make app"
endif

# ---------------------------------------------------------------- build & run

build: version-check   ## Build (debug)
	swift build

release: version-check   ## Build (release, optimised)
	swift build -c release

run: build   ## Build and run the tray app in the foreground (Ctrl-C to stop)
ifneq ($(UNAME_S),Linux)
	@echo "make run is Linux-only — on macOS use 'make app'." >&2; exit 1
endif
	@# The app yields to an already-running instance, so a stale copy would make this look
	@# like it exited for no reason. Say so instead of leaving the user guessing.
	@if pgrep -x $(BIN_NAME) >/dev/null; then \
	  echo "note: an instance is already running (pid $$(pgrep -x $(BIN_NAME) | tr '\n' ' ')) — 'make stop' first"; \
	fi
	$(DEBUG_BIN)

stop:   ## Stop a running tray app
	@# -x matches the process name exactly. Matching the full command line (-f) would also match
	@# this very make invocation and kill the shell running it.
	@pkill -x $(BIN_NAME) && echo "stopped" || echo "not running"

# --------------------------------------------------------------------- tests

test:   ## Run the test suite
	swift test

test-gate:   ## Run the pre-commit gate (tests + logic-core line coverage)
	./scripts/test-gate.sh

# ------------------------------------------------------------------- version

version-sync:   ## Regenerate AppVersion.swift from scripts/build-app.sh
	@sed -i.bak -E 's/(static let compiled = )"[0-9.]+"/\1"$(VERSION)"/' $(VERSION_SWIFT) \
	  && rm -f $(VERSION_SWIFT).bak
	@echo "AppVersion.compiled = $(VERSION)"

version-check:   ## Fail if AppVersion.swift has drifted from scripts/build-app.sh
	@compiled=$$(grep -oE 'static let compiled = "[0-9.]+"' $(VERSION_SWIFT) | grep -oE '[0-9.]+'); \
	if [[ "$$compiled" != "$(VERSION)" ]]; then \
	  echo "✗ version drift: AppVersion.compiled=$$compiled but build-app.sh VERSION=$(VERSION)" >&2; \
	  echo "  fix: make version-sync" >&2; \
	  exit 1; \
	fi

# ------------------------------------------------------------- install (Linux)

install: release   ## Install to ~/.local (binary, .desktop, icon)
ifneq ($(UNAME_S),Linux)
	@echo "make install is Linux-only — on macOS use 'make app'." >&2; exit 1
endif
	install -Dm755 $(RELEASE_BIN) $(INSTALL_BIN)
	@# Icons: a scalable SVG covers every size a panel might ask for, and raster sizes are
	@# generated when ImageMagick is available because some loaders prefer PNG. Installing only a
	@# 512px PNG (as this used to) leaves a task bar wanting 32px to scale a huge bitmap — or, with
	@# no icon cache, to find nothing at all and draw a blank page.
	install -Dm644 assets/icon.svg $(ICON_DIR)/scalable/apps/poketokenbar.svg
	install -Dm644 assets/icon.png $(ICON_FILE)
	@if command -v magick >/dev/null 2>&1; then \
	  for size in 16 22 24 32 48 64 128 256; do \
	    install -d $(ICON_DIR)/$${size}x$${size}/apps; \
	    magick assets/icon_1024.png -resize $${size}x$${size} \
	      $(ICON_DIR)/$${size}x$${size}/apps/poketokenbar.png; \
	  done; \
	  echo "  rendered raster icon sizes 16-256"; \
	else \
	  echo "  note: ImageMagick not found — installed SVG + 512px PNG only"; \
	fi
	@# StartupWMClass ties the window (app id "poketokenbar") to this entry, which is what gives
	@# the task bar its icon and name. The app is listed normally: it has real windows now, so
	@# hiding it with NoDisplay would only make it unlaunchable from the menu.
	@install -d $(dir $(DESKTOP_FILE))
	@printf '%s\n' \
	  '[Desktop Entry]' \
	  'Type=Application' \
	  'Name=PokeTokenBar' \
	  'Comment=AI coding usage in your tray, with a Pokemon companion' \
	  'Exec=$(INSTALL_BIN)' \
	  'Icon=poketokenbar' \
	  'Categories=System;Monitor;' \
	  'StartupWMClass=poketokenbar' \
	  'X-GNOME-Autostart-enabled=true' \
	  > $(DESKTOP_FILE)
	@# On Wayland a client cannot set its own window icon — there is no protocol for it. The
	@# compositor resolves it from the window's app_id to this .desktop file, so the entry has to be
	@# indexed before the task bar can show anything but a blank page.
	@command -v update-desktop-database >/dev/null 2>&1 && \
	  update-desktop-database $(PREFIX)/share/applications || true
	@command -v gtk-update-icon-cache >/dev/null 2>&1 && \
	  gtk-update-icon-cache -q -f -t $(ICON_DIR) 2>/dev/null || true
	@command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
	@echo
	@echo "installed: $(INSTALL_BIN)"
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
	  *) echo "warning: $(PREFIX)/bin is not on your PATH" ;; esac
	@echo "next:      make autostart-enable   # start it at login"

uninstall:   ## Remove everything 'make install' wrote, and any autostart unit
	-@$(MAKE) --no-print-directory autostart-disable 2>/dev/null || true
	rm -f $(INSTALL_BIN) $(DESKTOP_FILE) $(ICON_FILE)
	rm -f $(ICON_DIR)/scalable/apps/poketokenbar.svg
	rm -f $(ICON_DIR)/*/apps/poketokenbar.png
	rm -f $(HOME)/.config/systemd/user/poketokenbar.service
	@systemctl --user daemon-reload 2>/dev/null || true
	@echo "uninstalled (data in ~/.local/share/PokeTokenBar was kept — delete it by hand to reset)"

# Autostart delegates to the binary, which owns the systemd unit definition (Core/LoginItem.swift).
# Writing the unit here instead would give it a second, silently diverging copy.
autostart-enable:   ## Enable launch at login (systemd --user)
	@$(or $(wildcard $(INSTALL_BIN)),$(DEBUG_BIN)) --enable-autostart

autostart-disable:   ## Disable launch at login
	@$(or $(wildcard $(INSTALL_BIN)),$(DEBUG_BIN)) --disable-autostart

autostart-status:   ## Report whether launch at login is enabled
	@$(or $(wildcard $(INSTALL_BIN)),$(DEBUG_BIN)) --autostart-status

# ------------------------------------------------------------- bundle (macOS)

# build-app.sh takes no arguments and always does both steps: assemble the bundle in build/ and
# copy it into /Applications (terminating any running copy first). There is no build-only mode, so
# this is one target rather than two.
app:   ## Build the .app bundle and install it into /Applications (macOS)
	./scripts/build-app.sh

# --------------------------------------------------------------------- misc

clean:   ## Remove build artifacts
	swift package clean
	rm -rf .build/release .build/debug
