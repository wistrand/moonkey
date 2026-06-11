# Moonkey — Connect IQ watchface build helpers
# Usage: make <target> [DEVICE=marq2aviator]

SHELL := /bin/bash

DEVICE  ?= marq2aviator
DEVICES := marq2aviator marq2 fenix843mm fenix847mm venu3 epix2pro47mm epix2 fr965

CLI      := $(HOME)/go/bin/connect-iq-sdk-manager-cli
SDK_BIN  := $(shell $(CLI) sdk current-path --bin 2>/dev/null)
KEY      := $(HOME)/.connectiq/developer_key.der
MONKEYC  := $(SDK_BIN)/monkeyc
MONKEYDO := $(SDK_BIN)/monkeydo
SIM      := $(SDK_BIN)/simulator
JUNGLE   := moonkey.jungle
DEV_JUNGLE := moonkey-dev.jungle
BETA_JUNGLE := moonkey-beta.jungle
BIN      := bin
SRC      := $(wildcard src/*.mc) manifest.xml $(JUNGLE) $(wildcard resources/*/*) $(wildcard resources-launcher/*/*/*)
PRGS     := $(addprefix $(BIN)/moonkey-,$(addsuffix .prg,$(DEVICES)))

# Moon bitmap: cropped from the lunar disc in data/moon-raw.jpg, circular-masked, 100px.
MOON_RAW  := data/moon-raw.jpg
MOON_PNG  := resources/drawables/moon.png
MOON_CROP := 1600x1600+739+1243

# Connect IQ Store assets (per Garmin brand guidelines): all built from a shared
# left-lit shaded-crescent intermediate ($(CRESCENT)) of the real Moon photo + a thin
# amber ring on a night-navy gradient. Uploaded separately in the dev portal (these are
# NOT the in-watch launcher icon). store icon 500x500; on-device icon 128x128 (full +
# 64-colour MIP variant); hero 1440x720.
CRESCENT   := $(BIN)/moon-crescent.png
STORE_ICON := docs/store-icon.png
ICON_FULL  := docs/icon-128.png
ICON_LC    := docs/icon-128-lc.png
HERO       := docs/store-hero.png
# Bolder crescent (fatter lit fraction, deeper shadow, tighter terminator) for the tiny
# per-device launcher icons, where the store crescent's thin sliver/ring turns muddy.
CRESCENT_BOLD := $(BIN)/moon-crescent-bold.png

.PHONY: all build run sim sim-restart shot install uninstall package package-beta clean moon settings-doc gallery gallery-sm store-icon on-device-icon hero store-assets launcher-icons help
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-z%-]+:.*## ' $(MAKEFILE_LIST) | sort | \
	  awk -F':.*## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo "  (override device with DEVICE=<id>; devices: $(DEVICES))"

build: $(BIN)/moonkey-$(DEVICE).prg ## Build DEVICE (default marq2aviator)

all: $(PRGS) ## Build all four device .prg files

$(BIN)/moonkey-%.prg: $(SRC)
	@mkdir -p $(BIN)
	$(MONKEYC) -d $* -f $(JUNGLE) -o $@ -y $(KEY) -w

sim: ## Start the simulator if not already running
	@pgrep -f 'bin/simulato[r]' >/dev/null && echo "simulator already running" || \
	  { setsid env GDK_BACKEND=x11 $(SIM) >/tmp/ciqsim.log 2>&1 < /dev/null & echo "simulator started"; }

sim-restart: ## Restart the simulator (needed to switch DEVICE)
	-@pkill -f 'bin/simulato[r]' 2>/dev/null; sleep 1
	@setsid env GDK_BACKEND=x11 $(SIM) >/tmp/ciqsim.log 2>&1 < /dev/null & echo "simulator restarted"

run: ## Build DEVICE + load into the sim. Override settings via env vars named after properties.xml ids, e.g. `moonImage=1 make run`, `tz=2 moonImage=2 make run`.
	@./simrun.sh $(DEVICE)

shot: ## Build DEVICE, (re)launch sim, wait for the face to render, screenshot -> bin/shot-<device>.png
	@mkdir -p $(BIN)
	./auto-shot.sh $(DEVICE) $(BIN)/shot-$(DEVICE).png

install: ## Build + sideload the DEV variant ("Moonkey Dev"; coexists with store/beta). Override settings via env, e.g. `moonImage=1 make install DEVICE=fenix843mm`.
	@./simrun.sh --install $(DEVICE)

uninstall: ## Remove sideloaded Moonkey from a connected watch (./uninstall.sh DEVICE to narrow)
	./uninstall.sh

package: ## Build the PRODUCTION .iq (manifest.xml, public store id) -> bin/moonkey.iq
	@mkdir -p $(BIN)
	$(MONKEYC) -e -f $(JUNGLE) -o $(BIN)/moonkey.iq -y $(KEY) -w -r

package-beta: ## Build the BETA .iq (manifest-beta.xml, beta id) -> bin/moonkey-beta.iq
	@mkdir -p $(BIN)
	$(MONKEYC) -e -f $(BETA_JUNGLE) -o $(BIN)/moonkey-beta.iq -y $(KEY) -w -r

moon: ## Regenerate resources/drawables/moon.png from moon-raw.jpg
	magick $(MOON_RAW) -crop $(MOON_CROP) +repage -resize 100x100 \
	  \( -size 100x100 xc:black -fill white -draw "circle 50,50 50,1" \) \
	  -compose Multiply -composite \
	  \( -size 100x100 xc:black -fill white -draw "circle 50,50 50,3" -blur 0x1.2 +level 50%,100% \) \
	  -compose Multiply -composite \
	  -colorspace sRGB -strip $(MOON_PNG)
	@echo "wrote $(MOON_PNG) ($$(stat -c%s $(MOON_PNG)) bytes)"

# Shared intermediate: the left-lit shaded crescent (transparent disc), reused by all
# three store assets. Dark disc offset right + blurred = soft terminator; circular alpha
# mask; slight tilt. Rebuilt only when moon-raw changes.
$(CRESCENT): $(MOON_RAW)
	@mkdir -p $(BIN)
	magick $(MOON_RAW) -crop $(MOON_CROP) +repage -resize 380x380 \
	  \( -size 380x380 xc:white -fill gray14 -draw "circle 260,190 450,190" -blur 0x10 \) \
	  -compose Multiply -composite \
	  \( -size 380x380 xc:black -fill white -draw "circle 190,190 380,190" \) \
	  -alpha off -compose CopyOpacity -composite \
	  -background none -virtual-pixel none -distort SRT -12 $@

store-icon: $(CRESCENT) ## Regenerate data/store-icon.png (500x500 CIQ Store listing icon)
	magick -size 500x500 radial-gradient:#1b2c48-#0a1322 \
	  $(CRESCENT) -gravity center -compose over -composite \
	  -fill none -stroke "#FFAA00" -strokewidth 4 -draw "circle 250,250 250,52" \
	  -strip -colorspace sRGB $(STORE_ICON)
	@echo "wrote $(STORE_ICON) ($$(stat -c%s $(STORE_ICON)) bytes)"

on-device-icon: $(CRESCENT) ## Regenerate the 128x128 on-device icons (full-colour + 64-colour MIP)
	magick -size 128x128 radial-gradient:#1b2c48-#0a1322 \
	  \( $(CRESCENT) -resize 98x98 \) -gravity center -compose over -composite \
	  -fill none -stroke "#FFAA00" -strokewidth 1 -draw "circle 64,64 64,13" \
	  -strip -colorspace sRGB $(ICON_FULL)
	magick $(ICON_FULL) -dither None -colors 64 -strip PNG8:$(ICON_LC)
	@echo "wrote $(ICON_FULL) + $(ICON_LC) ($$(magick identify -format '%k' $(ICON_LC)) colours)"

hero: $(CRESCENT) ## Regenerate data/store-hero.png (1440x720 listing hero)
	magick -size 1440x720 radial-gradient:#1b2c48-#0a1322 \
	  \( $(CRESCENT) -resize 480x480 \) -gravity center -compose over -composite \
	  -fill none -stroke "#FFAA00" -strokewidth 5 -draw "circle 720,360 720,108" \
	  -strip -colorspace sRGB $(HERO)
	@echo "wrote $(HERO) ($$(stat -c%s $(HERO)) bytes)"

store-assets: store-icon on-device-icon hero ## Regenerate all store-listing assets (icon + on-device + hero)

$(CRESCENT_BOLD): $(MOON_RAW)
	@mkdir -p $(BIN)
	magick $(MOON_RAW) -crop $(MOON_CROP) +repage -resize 380x380 \
	  \( -size 380x380 xc:white -fill gray10 -draw "circle 310,190 500,190" -blur 0x8 \) \
	  -compose Multiply -composite \
	  \( -size 380x380 xc:black -fill white -draw "circle 190,190 380,190" \) \
	  -alpha off -compose CopyOpacity -composite \
	  -background none -virtual-pixel none -distort SRT -12 $@

launcher-icons: $(CRESCENT_BOLD) ## Regenerate per-device launcher icons (60/65/70 px) in resources-launcher/
	@for sz in 60 65 70; do \
	  d=resources-launcher/$$sz/drawables; mkdir -p $$d; \
	  magick -size 256x256 radial-gradient:#1b2c48-#0a1322 \
	    \( $(CRESCENT_BOLD) -resize 212x212 \) -gravity center -compose over -composite \
	    -fill none -stroke "#FFAA00" -strokewidth 8 -draw "circle 128,128 128,15" \
	    -resize $${sz}x$${sz} -alpha remove -strip -colorspace sRGB $$d/launcher_icon.png; \
	  echo "wrote $$d/launcher_icon.png"; \
	done

settings-doc: ## Regenerate agent_docs/settings.md from resources/settings/*.xml
	@./gen-settings-doc.py

gallery: ## Regenerate the docs/ landing-page screenshots (fenix843mm, transparent) -> docs/cfg-*.png
	@# Each is a representative settings combo (see docs/index.html). auto-shot honours
	@# env-var overrides named after properties.xml ids. The default shot passes a no-op
	@# moonImage=0 so auto-shot clears the sim's stored .SET (otherwise it reuses the
	@# previous run's settings and the "default" comes out as whatever ran last).
	moonImage=0 ./auto-shot.sh -t marq2aviator docs/cfg-default.png
	nsMarkers=true skipLabels=true compN=102 compS=100 compW=104 compE=103 moonImage=1 compNW=-2 compNE=-2 compSE=-2 tz=-2 accentColor=16755200 secTickColor=0x777777 radialGradient=false smallValuesN=true smallValuesS=true smallValuesE=true smallValuesW=true metalHands=true ./auto-shot.sh -t fenix843mm docs/cfg-loaded.png
	moonImage=2 nsMarkers=true accentColor=0x00DDFF metalHands=true smallValuesN=true smallValuesS=true smallValuesE=true smallValuesW=true radialGradient=false secTickColor=-2 ./auto-shot.sh -t fenix843mm docs/cfg-fox.png
	moonImage=3 nsMarkers=true accentColor=0xFFFFFF secTickColor=0xFFFFFF radialGradient=false compNE=-2 compSE=-2 compNW=-2 tz=-2 compN=-2 compS=-2 ./auto-shot.sh -t fenix843mm docs/cfg-minimal.png
	@$(MAKE) --no-print-directory gallery-sm

gallery-sm: ## Re-derive the small docs/cfg-*-sm.png (480px, 256-colour, <150KB) from the full cfg-*.png (no sim)
	@for f in default loaded fox minimal; do \
	  magick docs/cfg-$$f.png -resize 480x -strip -colors 256 -define png:compression-level=9 docs/cfg-$$f-sm.png; \
	  echo "wrote docs/cfg-$$f-sm.png ($$(stat -c%s docs/cfg-$$f-sm.png) bytes)"; \
	done

clean: ## Remove build artifacts
	rm -f $(BIN)/*.prg $(BIN)/*.iq $(BIN)/*.log $(BIN)/*.debug.xml
