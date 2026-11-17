APP := build/YubiWatcher.app

.PHONY: app install run clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/YubiWatcher $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)

install: app
	pkill -x YubiWatcher || true
	rm -rf ~/Applications/YubiWatcher.app
	mkdir -p ~/Applications
	cp -R $(APP) ~/Applications/
	open ~/Applications/YubiWatcher.app

run: app
	pkill -x YubiWatcher || true
	open $(APP)

clean:
	rm -rf .build build
