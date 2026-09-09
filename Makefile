APP_NAME := Hall-e
DIST := dist/$(APP_NAME).app
INSTALL_DIR := /Applications/$(APP_NAME).app

# Opt in only for the legacy broken local CLT installation.
ifeq ($(TOOLCHAIN_WORKAROUND),1)
export SWIFTPM_CUSTOM_LIBS_DIR := $(CURDIR)/.toolchain-fix
TOOLCHAIN_DEP := toolchain-fix
endif

.PHONY: build test app release install run cert toolchain-fix clean

toolchain-fix:
	./scripts/fix-toolchain.sh

build: $(TOOLCHAIN_DEP)
	swift build

test: $(TOOLCHAIN_DEP)
	swift test

app: $(TOOLCHAIN_DEP)
	./scripts/build.sh

release:
	./scripts/release.sh

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
