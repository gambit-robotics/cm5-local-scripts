# Gambit CM5 Local Scripts
# Run 'make' or 'make help' to see available commands

.PHONY: help install uninstall update clean image-apply image-verify image-test image-publish-r2

# Auto-detect user: use USER if set, otherwise SUDO_USER, otherwise logname
USER ?= $(or $(SUDO_USER),$(shell logname 2>/dev/null))

# Default target
help:
	@echo "Gambit CM5 Scripts - Available Commands"
	@echo ""
	@echo "On Pi - Install (after cloning repo):"
	@echo "  make install-all      Install everything"
	@echo "  make install-kiosk    Install kiosk only"
	@echo "  make install-plymouth Install boot splash only"
	@echo "  make install-config   Install boot/audio config only"
	@echo "  make install-buttons  Install volume buttons only"
	@echo "  make install-audio    Install boot chime only"
	@echo "  make install-lowpower Install low-power config (CPU + gpu_mem)"
	@echo "  make uninstall        Remove all installed components"
	@echo ""
	@echo "On Pi - Update (update + restart service):"
	@echo "  make update-kiosk    Update kiosk config"
	@echo "  make update-buttons  Update buttons script"
	@echo "  make update-plymouth Update boot splash"
	@echo ""
	@echo "Variables (USER auto-detected from sudo):"
	@echo "  USER=<username>      Override target user (default: auto-detect)"
	@echo ""
	@echo "Image tooling:"
	@echo "  make image-apply ROOTFS=/mnt/root BOOTFS=/mnt/boot IMAGE_VERSION=0.1.0-dev VIAM_DEFAULTS=image/viam-defaults.user-testing.json"
	@echo "  make image-verify ROOTFS=/mnt/root"
	@echo "  make image-test"
	@echo "  make image-publish-r2 RELEASE=2026-06-03-assembler-rc1 ARTIFACT=dist/gambit.img.xz"

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

install-audio:
	sudo ./install.sh --audio

install-lowpower:
ifeq ($(USER),)
	@echo "Installing system-level lowpower (no user → no screen dim)"
	sudo ./install.sh --lowpower
else
	@echo "Installing for user: $(USER)"
	sudo ./install.sh --lowpower $(USER)
endif

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
	sudo systemctl daemon-reload
	sudo systemctl enable --now gambit-kiosk-recovery.service
	sudo -u $(USER) XDG_RUNTIME_DIR=/run/user/$$(id -u $(USER)) systemctl --user restart kiosk.service 2>/dev/null || true
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

# ------------------------------------------------------------------------------
# Image tooling
# ------------------------------------------------------------------------------

image-apply:
ifeq ($(ROOTFS),)
	$(error ROOTFS is required)
endif
ifeq ($(BOOTFS),)
	$(error BOOTFS is required)
endif
ifeq ($(IMAGE_VERSION),)
	$(error IMAGE_VERSION is required)
endif
ifeq ($(VIAM_DEFAULTS),)
	$(error VIAM_DEFAULTS is required)
endif
	sudo image/apply-rootfs.sh --rootfs "$(ROOTFS)" --bootfs "$(BOOTFS)" --image-version "$(IMAGE_VERSION)" --viam-defaults "$(VIAM_DEFAULTS)"

image-verify:
ifeq ($(ROOTFS),)
	$(error ROOTFS is required)
endif
	image/verify-rootfs.sh --rootfs "$(ROOTFS)"

image-test:
	image/test-verify-rootfs.sh

image-publish-r2:
ifeq ($(RELEASE),)
	$(error RELEASE is required)
endif
ifeq ($(ARTIFACT),)
	$(error ARTIFACT is required)
endif
	image/publish-r2.sh --release "$(RELEASE)" --artifact "$(ARTIFACT)" $(if $(ROOTFS),--rootfs "$(ROOTFS)",) $(if $(R2_BUCKET),--bucket "$(R2_BUCKET)",) $(if $(R2_PREFIX),--prefix "$(R2_PREFIX)",) $(if $(R2_ENDPOINT_URL),--endpoint-url "$(R2_ENDPOINT_URL)",) $(if $(PRINT_URLS),--print-urls,) $(if $(ALLOW_UNVERIFIED_ROOTFS),--allow-unverified-rootfs,) $(if $(DRY_RUN),--dry-run,)
