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
SRC      := $(wildcard src/*.mc) manifest.xml $(JUNGLE) $(wildcard resources/*/*)
PRGS     := $(addprefix $(BIN)/moonkey-,$(addsuffix .prg,$(DEVICES)))

# Moon bitmap: cropped from the lunar disc in data/moon-raw.jpg, circular-masked, 100px.
MOON_RAW  := data/moon-raw.jpg
MOON_PNG  := resources/drawables/moon.png
MOON_CROP := 1600x1600+739+1243

.PHONY: all build run sim sim-restart shot install uninstall package package-beta clean moon help
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

install: ## Build + sideload the DEV variant (separate app id + "Moonkey Dev"; coexists with the store/beta build)
	@mkdir -p $(BIN)
	$(MONKEYC) -d $(DEVICE) -f $(DEV_JUNGLE) -o $(BIN)/moonkey-dev-$(DEVICE).prg -y $(KEY) -w
	./install.sh $(DEVICE) $(BIN)/moonkey-dev-$(DEVICE).prg

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

clean: ## Remove build artifacts
	rm -f $(BIN)/*.prg $(BIN)/*.iq $(BIN)/*.log $(BIN)/*.debug.xml
