# Gambit CM5 Local Scripts
# Run 'make' or 'make help' to see available commands

.PHONY: help install uninstall update clean

# Auto-detect user: use USER if set, otherwise SUDO_USER, otherwise logname
USER ?= $(or $(SUDO_USER),$(shell logname 2>/dev/null))

# Default target
help:
	@echo "Gambit CM5 Scripts - Available Commands"
	@echo ""
	@echo "On Pi - Install (after cloning repo):"
	@echo "  make install-all     Install everything"
	@echo "  make install-kiosk   Install kiosk only"
	@echo "  make install-plymouth Install boot splash only"
	@echo "  make install-config  Install boot/audio config only"
	@echo "  make install-buttons Install volume buttons only"
	@echo "  make uninstall       Remove all installed components"
	@echo ""
	@echo "On Pi - Update (update + restart service):"
	@echo "  make update-kiosk    Update kiosk config"
	@echo "  make update-buttons  Update buttons script"
	@echo "  make update-plymouth Update boot splash"
	@echo ""
	@echo "Variables (USER auto-detected from sudo):"
	@echo "  USER=<username>      Override target user (default: auto-detect)"

# ------------------------------------------------------------------------------
# Pi Commands (run after cloning repo)
# ------------------------------------------------------------------------------

install-all:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --all $(USER)

install-kiosk:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --kiosk $(USER)

install-plymouth:
	sudo ./install.sh --plymouth

install-config:
	sudo ./install.sh --config

install-buttons:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --buttons $(USER)

uninstall:
	sudo ./uninstall.sh

# ------------------------------------------------------------------------------
# Update Commands (update + restart)
# ------------------------------------------------------------------------------

update-kiosk:
ifeq ($(USER),)
	$(error USER could not be detected. Run with sudo or set USER=<username>)
endif
	@echo "=== Updating kiosk for $(USER) ==="
	sudo ./kiosk/setup-kiosk-wayland.sh $(USER)
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

# ------------------------------------------------------------------------------
# Development
# ------------------------------------------------------------------------------

clean:
	@echo "Nothing to clean"
