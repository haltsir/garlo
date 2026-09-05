APP      = Garlo.app
BINARY   = .build/release/GarloApp
CLI      = .build/release/garlo
CONTENTS = $(APP)/Contents
# Garlo's own stable self-signed identity (docs/SIGNING.md) keeps privacy
# grants (removable volumes) across rebuilds; ad-hoc signatures change every
# build and macOS asks again. Falls back to ad-hoc where it is missing.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Garlo Signing"' && echo "Garlo Signing" || echo "-")

.PHONY: app build run clean icon cli test

# regenerate Resources/AppIcon.icns from the drawing script
icon:
	swift Tools/make-icon.swift .build/Garlo.iconset
	iconutil -c icns .build/Garlo.iconset -o Resources/AppIcon.icns
	rm -rf .build/Garlo.iconset

app: build
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY) $(CONTENTS)/MacOS/Garlo
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)
	@echo "Built $(APP). Run 'make run' or double-click it."

build:
	swift build -c release

cli: build
	@echo "$(CLI)"

run: app
	open $(APP)

test:
	swift test

clean:
	swift package clean
	rm -rf $(APP)
