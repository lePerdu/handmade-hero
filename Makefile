WAYLAND_DATA_DIR ?= /usr/share

BUILD = build
DATA = data
EXEC = $(BUILD)/game
TEST_EXEC = $(BUILD)/game-test
DYNLIB = $(BUILD)/game.so
WAYLAND_SCANNER = $(BUILD)/wayland-scanner

ODIN_FLAGS_DEBUG = -debug
ODIN_FLAGS_RELEASE = -o:speed
ODIN_FLAGS = $(ODIN_FLAGS_DEBUG)

all: game

game: reload | $(BUILD)
	odin build . $(ODIN_FLAGS) -out:$(EXEC)

# Build into a temporary file first, then move to the final location so that
# the final file is never incomplete. Imporant since the file is watched
# and dynamically reloaded
# -o:speed here even in debug mode since SW rendering is too slow without it
# TODO: Report that as a bug? Seems like the performance shouldn't be _that_
# bad in debug mode.
reload: | $(BUILD)
	odin build game $(ODIN_FLAGS) -out:$(DYNLIB).tmp -build-mode:dynamic
	mv $(DYNLIB).tmp $(DYNLIB)

wayland-scanner: | $(BUILD)
	odin build vendor/wayland/scanner $(ODIN_FLAGS) -out:$(WAYLAND_SCANNER)

run: game
	./$(EXEC)

build-test: | $(BUILD)
	odin build game $(ODIN_FLAGS) -build-mode:test -out:$(TEST_EXEC)

test: build-test
	./$(TEST_EXEC)

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

clean-data:
	$(RM) -r $(DATA)

clean-all: clean clean-data

.PHONY: all run game reload wayland-scanner gen-wayland \
	build-test test \
	clean clean-data clean-all
