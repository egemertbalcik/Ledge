BUNDLE_ID := com.egemert.ledge
CONFIG    ?= debug

# The .app is built OUTSIDE the project directory on purpose. This project lives
# under ~/Desktop, which is iCloud-synced, and the file provider re-applies
# com.apple.FinderInfo to any .app bundle there faster than `xattr -c` can strip
# it — codesign then refuses with "resource fork, Finder information, or similar
# detritus not allowed". A non-synced path avoids the whole problem, and keeping
# the app at a *stable* path also matters for TCC.
BUILD_ROOT ?= $(HOME)/Library/Developer/Ledge
APP        := $(BUILD_ROOT)/Ledge.app

# Prefer a real Apple Development identity: TCC keys permission grants to the
# code signature, so ad-hoc signing re-prompts for Accessibility, Calendar and
# Bluetooth on every single rebuild. Falls back to ad-hoc with a warning.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
             grep -m1 "Apple Development" | awk '{print $$2}')
SIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

# Distribution wants a Developer ID Application identity — the only kind
# Gatekeeper accepts on other people's Macs and the only kind Apple notarizes.
# Falls back to the development identity so the release pipeline stays
# testable before enrollment; notarize.sh refuses the fallback explicitly.
DIST_SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
                  grep -m1 "Developer ID Application" | awk '{print $$2}')
DIST_SIGN_ID := $(if $(DIST_SIGN_ID),$(DIST_SIGN_ID),$(SIGN_ID))

DIST_DIR    := $(BUILD_ROOT)/dist
RELEASE_APP := $(DIST_DIR)/Ledge.app
VERSION     := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Bundle/Info.plist)
DMG         := $(DIST_DIR)/Ledge-$(VERSION).dmg
# The unnotarized test image lives OUTSIDE dist/ under a distinct name: dist/
# holds only shippable artifacts, so `make dmg` can never clobber the stapled
# DMG that `make notarize` produced, and `make appcast` never feeds it into
# the update feed.
TEST_DMG    := $(BUILD_ROOT)/Ledge-$(VERSION)-unnotarized.dmg

XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# `swift build` alone emits a native-arch (arm64) binary under .build/release.
# A universal build needs the Xcode toolchain, and SwiftPM lands its products
# somewhere else entirely — every piece bundle.sh copies must come from here.
RELEASE_ARCHS     := --arch arm64 --arch x86_64
RELEASE_BUILD_DIR := .build/apple/Products/Release

# Every GitHub release uploads the DMG, appcast.xml and any .delta files under
# this exact tag, so enclosure URLs stay valid after later releases. The feed
# URL itself (in Info.plist) points at latest/download/appcast.xml.
RELEASE_URL_PREFIX := https://github.com/egemertbalcik/Ledge/releases/download/v$(VERSION)/

.PHONY: build bundle sign run open test preview lint tail clean identity install icon release dmg notarize appcast

build:
	swift build -c $(CONFIG)

bundle: build
	@./Scripts/bundle.sh $(CONFIG) $(APP)

sign: bundle
	@./Scripts/sign.sh $(APP) $(SIGN_ID)

## Rebuild, re-sign, kill the old copy, relaunch with logs in this terminal.
run: sign
	@./Scripts/run.sh $(APP)

## Launch detached via Finder, the way the app will normally start.
open: sign
	@pkill -x Ledge 2>/dev/null || true
	@open $(APP)

## swift-testing ships with Xcode, not with the Command Line Tools toolchain,
## so tests need DEVELOPER_DIR even though the app itself builds fine on CLT.
## Render the app icon to build/AppIcon.icns.
icon:
	@swift Scripts/makeicon.swift

test:
	DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) swift test

## Card gallery in a plain window — stands in for Xcode previews.
preview: build
	@pkill -x LedgePreview 2>/dev/null || true
	@.build/$(CONFIG)/LedgePreview

lint:
	@./Scripts/lint-imports.sh

## Stream the app's own log output.
tail:
	log stream --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

## Show which identity the build will use, and what the signed app claims.
identity:
	@security find-identity -v -p codesigning || true
	@echo "selected: $(SIGN_ID)"
	@test -d $(APP) && codesign -dvvv $(APP) 2>&1 | grep -E 'Identifier|Authority|Signature' || true

## Distribution build: universal (arm64 + x86_64), optimized, no dev fixtures,
## hardened runtime, secure timestamps. Signed with Developer ID when one
## exists. bundle.sh refuses a non-universal result under LEDGE_DIST=1; the
## lipo lines below just make the arches visible in the build log.
release:
	@test -f build/AppIcon.icns || swift Scripts/makeicon.swift
	DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) swift build -c release $(RELEASE_ARCHS)
	@LEDGE_DIST=1 ./Scripts/bundle.sh release $(RELEASE_APP) $(RELEASE_BUILD_DIR)
	@LEDGE_DIST=1 ./Scripts/sign.sh $(RELEASE_APP) $(DIST_SIGN_ID)
	@echo "archs: $$(lipo -archs $(RELEASE_APP)/Contents/MacOS/Ledge) (Ledge)"
	@for dylib in $(RELEASE_APP)/Contents/Frameworks/*.dylib; do \
	    echo "archs: $$(lipo -archs $$dylib) ($$(basename $$dylib))"; done
	@echo "release $(VERSION) at $(RELEASE_APP)"

## Unnotarized DMG — for local testing of the disk image itself. Written next
## to dist/, not into it (see TEST_DMG).
dmg: release
	@./Scripts/dmg.sh $(RELEASE_APP) $(TEST_DMG) $(DIST_SIGN_ID)

## The shippable artifact: notarized, stapled DMG. Needs Developer ID +
## stored notarytool credentials (see Scripts/notarize.sh header).
notarize: release
	@./Scripts/notarize.sh $(RELEASE_APP) $(DMG) $(DIST_SIGN_ID)

## Sparkle appcast for the DMGs in dist/, EdDSA-signed with the keychain key.
## Only stapled (notarized) images may go in: a DMG that fails `stapler
## validate` here is a test artifact that would otherwise be served to users.
## Enclosure URLs are pinned to this version's release tag (RELEASE_URL_PREFIX),
## so upload the DMG, appcast.xml AND any .delta files to that GitHub release
## — the app's feed URL reads latest/download/appcast.xml, which GitHub
## redirects to whichever release is newest. CFBundleVersion is stamped from
## the git commit count by bundle.sh, so it rises on its own.
appcast:
	@for dmg in $(DIST_DIR)/*.dmg; do \
	    xcrun stapler validate -q "$$dmg" >/dev/null 2>&1 || \
	        { echo "error: $$dmg is not notarized — run 'make notarize' first" >&2; exit 1; }; done
	@./.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
	    --download-url-prefix $(RELEASE_URL_PREFIX) $(DIST_DIR)
	@echo "appcast at $(DIST_DIR)/appcast.xml"

install: sign
	@rm -rf ~/Applications/Ledge.app
	@mkdir -p ~/Applications
	@cp -R $(APP) ~/Applications/
	@echo "installed to ~/Applications/Ledge.app"

clean:
	rm -rf .build "$(BUILD_ROOT)"
