# Build & install the `macon` CLI locally (no Homebrew needed).
#   make            build release binary
#   make install    install to $(PREFIX)/bin  (default /usr/local, override with PREFIX=~/.local)
#   make uninstall
PREFIX ?= /usr/local

.PHONY: build install uninstall clean
build:
	swift build -c release

install: build
	install -d "$(PREFIX)/bin"
	install ".build/release/macon" "$(PREFIX)/bin/macon"
	@echo "Installed macon → $(PREFIX)/bin/macon"

uninstall:
	rm -f "$(PREFIX)/bin/macon"

clean:
	swift package clean
