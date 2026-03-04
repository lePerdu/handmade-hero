WAYLAND_DATA_DIR ?= /usr/share

BUILD = build
EXEC = $(BUILD)/game
DYNLIB = $(BUILD)/game.so
WAYLAND_SCANNER = $(BUILD)/wayland-scanner

all: game

game: reload | $(BUILD)
	odin build . -out:$(EXEC) -debug

reload: | $(BUILD)
	odin build game -out:$(DYNLIB) -build-mode:dynamic -debug

wayland-scanner: | $(BUILD)
	odin build vendor/wayland/scanner -out:$(WAYLAND_SCANNER)

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
