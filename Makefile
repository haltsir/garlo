APP      = Garlo.app
BINARY   = .build/release/GarloApp
HELPER   = .build/release/GarloHelper
CLI      = .build/release/garlo
CONTENTS = $(APP)/Contents
# Garlo's own stable self-signed identity (docs/SIGNING.md) keeps privacy
# grants (removable volumes) across rebuilds; ad-hoc signatures change every
# build and macOS asks again. Falls back to ad-hoc where it is missing.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Garlo Signing"' && echo "Garlo Signing" || echo "-")

.PHONY: app build run clean icon cli test release
VERSION  = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

# regenerate Resources/AppIcon.icns from the drawing script
icon:
	swift Tools/make-icon.swift .build/Garlo.iconset
	iconutil -c icns .build/Garlo.iconset -o Resources/AppIcon.icns
	rm -rf .build/Garlo.iconset

app: build
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchDaemons
	cp $(BINARY) $(CONTENTS)/MacOS/Garlo
	cp $(HELPER) $(CONTENTS)/MacOS/GarloHelper
	cp Resources/com.strahil.garlo.helper.plist $(CONTENTS)/Library/LaunchDaemons/
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier com.strahil.garlo.helper $(CONTENTS)/MacOS/GarloHelper
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

# Build, zip, sign with the ed25519 release key and publish the GitHub
# release the app's updater installs. Tag first: git tag -a v$(VERSION).
release: app
	rm -f Garlo-$(VERSION).zip Garlo-$(VERSION).zip.sig
	ditto -c -k --keepParent $(APP) Garlo-$(VERSION).zip
	swift Tools/sign-release.swift Garlo-$(VERSION).zip
	gh release create v$(VERSION) Garlo-$(VERSION).zip Garlo-$(VERSION).zip.sig --title "Garlo $(VERSION)" --notes-file release-notes.md
	rm -f Garlo-$(VERSION).zip Garlo-$(VERSION).zip.sig

clean:
	swift package clean
	rm -rf $(APP)
