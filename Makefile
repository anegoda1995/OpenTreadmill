APP     := OpenTreadmill
ID      := io.github.anegoda1995.opentreadmill
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ARCHS   ?= arm64 x86_64
MIN_OS  := 14.0
# Ad-hoc by default. A local code-signing identity keeps the Bluetooth permission across rebuilds:
# make SIGN_ID="My Local Signing"
SIGN_ID ?= -

BUILD   := build
BUNDLE  := $(BUILD)/$(APP).app
DIST    := $(BUILD)/$(APP)-$(VERSION).zip

.PHONY: all app test icon dist install uninstall clean

all: app

app:
	@for arch in $(ARCHS); do swift build -c release --triple $$arch-apple-macosx$(MIN_OS) || exit 1; done
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	lipo -create $(foreach arch,$(ARCHS),.build/$(arch)-apple-macosx/release/$(APP)) -output $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns Resources/Menu*Template*.png $(BUNDLE)/Contents/Resources/
	codesign --force --sign "$(SIGN_ID)" --identifier $(ID) $(BUNDLE)
	@echo "built $(BUNDLE) ($(VERSION), $(ARCHS))"

test:
	swift test

# Renders assets/*.svg into Resources (committed, so normal builds do not need it; needs rsvg-convert).
# 16 and 32 px are drawings of their own; the menu bar icons are template images (black with alpha), 26 x 18 pt.
icon:
	rm -rf $(BUILD)/AppIcon.iconset && mkdir -p $(BUILD)/AppIcon.iconset
	rsvg-convert -w 16 -h 16 assets/icon-16.svg -o $(BUILD)/AppIcon.iconset/icon_16x16.png
	rsvg-convert -w 32 -h 32 assets/icon-32.svg -o $(BUILD)/AppIcon.iconset/icon_16x16@2x.png
	rsvg-convert -w 32 -h 32 assets/icon-32.svg -o $(BUILD)/AppIcon.iconset/icon_32x32.png
	rsvg-convert -w 64 -h 64 assets/icon-32.svg -o $(BUILD)/AppIcon.iconset/icon_32x32@2x.png
	for size in 128 256 512; do \
		rsvg-convert -w $$size -h $$size assets/icon.svg -o $(BUILD)/AppIcon.iconset/icon_$${size}x$${size}.png; \
		rsvg-convert -w $$((size * 2)) -h $$((size * 2)) assets/icon.svg -o $(BUILD)/AppIcon.iconset/icon_$${size}x$${size}@2x.png; \
	done
	iconutil -c icns -o Resources/AppIcon.icns $(BUILD)/AppIcon.iconset
	for state in Searching Ready Walking Paused Asleep; do \
		svg=assets/menubar-$$(echo $$state | tr A-Z a-z).svg; \
		rsvg-convert -w 26 -h 18 $$svg -o Resources/Menu$${state}Template.png; \
		rsvg-convert -w 52 -h 36 $$svg -o Resources/Menu$${state}Template@2x.png; \
	done

dist: all
	rm -rf $(BUILD)/dist && mkdir -p $(BUILD)/dist/$(APP)
	cp -R $(BUNDLE) scripts/install.sh scripts/uninstall.sh LICENSE $(BUILD)/dist/$(APP)/
	cd $(BUILD)/dist && ditto -c -k --keepParent $(APP) ../$(notdir $(DIST))
	@echo "packed $(DIST)"

install: all
	scripts/install.sh

uninstall:
	scripts/uninstall.sh

clean:
	rm -rf $(BUILD) .build
