# Gambit CM5 Local Scripts
# Run 'make' or 'make help' to see available commands

.PHONY: help bundle deploy install uninstall update clean

# Auto-detect user: use USER if set, otherwise SUDO_USER, otherwise logname
USER ?= $(or $(SUDO_USER),$(shell logname 2>/dev/null))

# Default target
help:
	@echo "Gambit CM5 Scripts - Available Commands"
	@echo ""
	@echo "Local (macOS):"
	@echo "  make bundle          Create deployment bundle (copies base64 to clipboard)"
	@echo "  make deploy          Bundle + upload to dpaste, prints URL"
	@echo ""
	@echo "On Pi - Install (after extracting bundle):"
	@echo "  make install-all DISPLAY=DSI-2    Install everything"
	@echo "  make install-kiosk                   Install kiosk only"
	@echo "  make install-plymouth                Install boot splash only"
	@echo "  make install-config                  Install boot/audio config only"
	@echo "  make uninstall                       Remove all installed components"
	@echo ""
	@echo "On Pi - Update (redeploy + restart service):"
	@echo "  make update-rotate DISPLAY=DSI-2  Update rotate script"
	@echo "  make update-kiosk                    Update kiosk config"
	@echo "  make update-buttons                  Update buttons script"
	@echo "  make update-plymouth                 Update boot splash"
	@echo ""
	@echo "Variables (USER auto-detected from sudo):"
	@echo "  USER=<username>      Override target user (default: auto-detect)"
	@echo "  DISPLAY=<output>     Display output for rotate (e.g., HDMI-A-1)"
	@echo "  TOUCH=<device>       Optional touch device for rotate"

# ------------------------------------------------------------------------------
# Local Commands (macOS)
# ------------------------------------------------------------------------------

bundle:
	@./bundle.sh --quiet

deploy: bundle
	@echo "Uploading to dpaste..."
	@pbpaste > /tmp/bundle.b64
	@URL=$$(curl -s -F 'content=<-' https://dpaste.com/api/ < /tmp/bundle.b64) && \
		echo "" && \
		echo "Deployed to: $$URL" && \
		echo "" && \
		echo "On Pi:" && \
		echo "  curl -sL $${URL}.txt | base64 -d | tar xzf - -C /tmp && cd /tmp/cm5-local-scripts"
	@rm -f /tmp/bundle.b64

# ------------------------------------------------------------------------------
# Pi Commands (run after extracting bundle)
# ------------------------------------------------------------------------------

install-all:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
ifndef DISPLAY
	$(error DISPLAY is required. Usage: make install-all DISPLAY=DSI-2)
endif
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --all $(USER) $(DISPLAY) $(TOUCH)

install-kiosk:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --no-safety --kiosk $(USER)

install-plymouth:
	sudo ./install.sh --no-safety --plymouth

install-config:
	sudo ./install.sh --no-safety --config

install-buttons:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --no-safety --buttons $(USER)

install-rotate:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
ifndef DISPLAY
	$(error DISPLAY is required. Usage: make install-rotate DISPLAY=DSI-2)
endif
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --no-safety --rotate $(USER) $(DISPLAY) $(TOUCH)

install-safety:
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh

# ------------------------------------------------------------------------------
# Update Commands (redeploy + restart)
# ------------------------------------------------------------------------------

update-rotate:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
ifndef DISPLAY
	$(error DISPLAY is required. Usage: make update-rotate DISPLAY=DSI-2)
endif
	@echo "=== Updating rotate for $(USER) ==="
	sudo ./rotate/setup-autorotate.sh $(USER) $(DISPLAY) $(TOUCH)
	sudo -u $(USER) XDG_RUNTIME_DIR=/run/user/$$(id -u $(USER)) systemctl --user restart autorotate.service
	@echo "Done. Service restarted."

update-kiosk:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "=== Updating kiosk for $(USER) ==="
	@if [ -f ./kiosk/setup-kiosk-wayland.sh ]; then \
		sudo ./kiosk/setup-kiosk-wayland.sh $(USER); \
	else \
		sudo ./kiosk/setup-kiosk-x11.sh $(USER); \
	fi
	sudo -u $(USER) XDG_RUNTIME_DIR=/run/user/$$(id -u $(USER)) systemctl --user restart chromium-kiosk.service 2>/dev/null || true
	@echo "Done. Service restarted."

update-buttons:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "=== Updating buttons for $(USER) ==="
	sudo ./buttons/setup-buttons.sh $(USER)
	sudo -u $(USER) XDG_RUNTIME_DIR=/run/user/$$(id -u $(USER)) systemctl --user restart volume-buttons.service
	@echo "Done. Service restarted."

update-plymouth:
	@echo "=== Updating plymouth ==="
	sudo ./plymouth/setup-bootsplash.sh
	@echo "Done. Reboot to see changes."

update-safety:
	@echo "=== Updating safety services ==="
	sudo ./install.sh
	sudo systemctl restart pct2075-safety ina219-safety
	@echo "Done. Services restarted."

# ------------------------------------------------------------------------------
# Development
# ------------------------------------------------------------------------------

clean:
	@echo "Nothing to clean"
