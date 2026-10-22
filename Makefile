APP := build/Torie-chan.app
INSTALLED := /Applications/Torie-chan.app

.PHONY: app run install mcp-test clean icon test dmg

app:
	scripts/build-app.sh

run: app
	open "$(APP)"

# SMAppService ties the helper to the app's location, so install to /Applications for real use.
install: app
	-osascript -e 'quit app id "com.mostperfectsip.toriechan"'
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

# Smoke-test the MCP server handshake without an agent.
mcp-test: app
	printf '%s\n' \
	  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"make","version":"0"}}}' \
	  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
	  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
	  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"guard_status","arguments":{}}}' \
	  | "$(APP)/Contents/MacOS/bg-mcp"

clean:
	rm -rf .build build

# Regenerate Resources/AppIcon.icns from the app's own eye renderer.
icon:
	mkdir -p build/AppIcon.iconset
	scripts/build-icon-tool.sh
	build/make-icon build/icon-1024.png
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

test:
	swift test

# Disk image for distribution (after `make app`).
dmg: app
	scripts/make-dmg.sh
