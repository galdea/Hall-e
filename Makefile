APP_NAME := Hall-e
DIST := dist/$(APP_NAME).app
INSTALL_DIR := /Applications/$(APP_NAME).app

# Workaround for this machine's broken CLT SwiftPM (see scripts/fix-toolchain.sh)
export SWIFTPM_CUSTOM_LIBS_DIR := $(CURDIR)/.toolchain-fix

.PHONY: build test app install run cert toolchain-fix clean

toolchain-fix:
	./scripts/fix-toolchain.sh

build: toolchain-fix
	swift build

test: toolchain-fix
	swift test

app: toolchain-fix
	./scripts/build.sh

install: app
	rm -rf "$(INSTALL_DIR)"
	ditto "$(DIST)" "$(INSTALL_DIR)"

# Always launch via LaunchServices (open) — notifications/TCC break when the
# executable is run directly.
run: install
	open "$(INSTALL_DIR)"

cert:
	./scripts/make-cert.sh

clean:
	rm -rf .build dist
