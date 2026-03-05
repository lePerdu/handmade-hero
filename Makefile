WAYLAND_DATA_DIR ?= /usr/share

BUILD = build
EXEC = $(BUILD)/game
DYNLIB = $(BUILD)/game.so
WAYLAND_SCANNER = $(BUILD)/wayland-scanner

ODIN_FLAGS = -debug
# ODIN_FLAGS = -o:speed

all: game

game: reload | $(BUILD)
	odin build . $(ODIN_FLAGS) -out:$(EXEC)

reload: | $(BUILD)
	# Build into a temporary file first, then move to the final location so that
	# the final file is never incomplete. Imporant since the file is watched
	# and dynamically reloaded
	odin build game $(ODIN_FLAGS) -out:$(DYNLIB).tmp -build-mode:dynamic
	mv $(DYNLIB).tmp $(DYNLIB)

wayland-scanner: | $(BUILD)
	odin build vendor/wayland/scanner $(ODIN_FLAGS) -out:$(WAYLAND_SCANNER)

run: game
	./$(EXEC)

gen-wayland: wayland-scanner
	$(WAYLAND_SCANNER) \
	    $(WAYLAND_DATA_DIR)/wayland/wayland.xml \
	    vendor/wayland/wayland_protocol.odin
	$(WAYLAND_SCANNER) \
	    $(WAYLAND_DATA_DIR)/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
	    vendor/wayland/xdg_shell_protocol.odin

$(BUILD):
	mkdir -p $@

clean:
	$(RM) -r $(BUILD)

.PHONY: all run game reload wayland-scanner gen-wayland clean
