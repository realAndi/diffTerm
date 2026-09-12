# diffTerm — built on-device with the Procursus toolchain.
#
# There is no Xcode here, so this drives clang/swiftc directly and assembles
# the .app bundle by hand.

# The rootless bootstrap has no /bin/sh, so make needs to be told.
SHELL        := /var/jb/bin/sh

# Overridable so a second copy can be installed alongside the first:
#   make install APP_NAME=diffTermDev BUNDLE_ID=dev.diffterm.appdev DISPLAY_NAME="diffTerm (dev)"
APP_NAME     ?= diffTerm
BUNDLE_ID    ?= dev.diffterm.app
DISPLAY_NAME ?= $(APP_NAME)
VERSION      ?= 2.0

# Only the primary install owns the pbcopy/pbpaste links.
PRIMARY_ID   := dev.diffterm.app

SDK          := /var/jb/usr/share/SDKs/iPhoneOS.sdk
# One definition. Building for ios16.0 while Info.plist claimed 15.0 meant the
# binary refused to launch on the very systems the plist invited it onto.
DEPLOY_MIN   := 14.0
TARGET       := arm64-apple-ios$(DEPLOY_MIN)

BUILD        := build
OBJ          := $(BUILD)/obj
APP          := $(BUILD)/$(APP_NAME).app
BINARY       := $(APP)/$(APP_NAME)

# $(SUDO) always goes through an askpass helper and never prompts on the tty,
# so without SUDO_ASKPASS set it just fails. Fall back to a normal prompt,
# which is what `make install` from a terminal on the device wants anyway.
SUDO         := $(if $(SUDO_ASKPASS),sudo -A,sudo)

INSTALL_DIR  := /var/jb/Applications
INSTALLED    := $(INSTALL_DIR)/$(APP_NAME).app

# Where pbcopy/pbpaste are linked from. /var/jb/etc/zprofile replaces PATH
# outright for login shells, but its standard PATH puts /var/jb/usr/local/bin
# ahead of /var/jb/usr/bin, so a link here wins either way and leaves the
# bootstrap's own package untouched.
LOCAL_BIN    := /var/jb/usr/local/bin

SWIFT_SRC    := $(wildcard Sources/Core/*.swift) \
                $(wildcard Sources/Settings/*.swift) \
                $(wildcard Sources/UI/*.swift) \
                $(wildcard Sources/App/*.swift)
C_SRC        := Sources/CBridge/DTPty.c
C_OBJ        := $(OBJ)/DTPty.o
BRIDGE       := Sources/CBridge/Bridging.h

# pbcopy and pbpaste. One source, two names: the program looks at argv[0].
# They live inside the bundle rather than in /var/jb/usr/bin so that installing
# diffTerm never fights the bootstrap's own copies, and removing the app takes
# them with it.
HELPER_SRC   := Sources/Helpers/dtclip.c
HELPER_DIR   := $(APP)/helpers
HELPERS      := $(HELPER_DIR)/pbcopy $(HELPER_DIR)/pbpaste

# The session daemon: launchd starts it, so shells it owns outlive the app
# being backgrounded or killed. Built into the bundle; a LaunchDaemon plist
# points here. See Sources/Daemon/sessiond.c.
SESSIOND_SRC := Sources/Daemon/sessiond.c
SESSIOND     := $(APP)/sessiond
DAEMON_PLIST := Resources/LaunchDaemon/dev.diffterm.sessiond.plist
DAEMON_DEST  := /var/jb/Library/LaunchDaemons/dev.diffterm.sessiond.plist

ICONS        := $(wildcard Resources/Icons/*.png)
FONTS        := $(wildcard Resources/Fonts/*.ttf)
# Shell integration. Without these the OSC 133 marks never arrive, and blocks
# and next-command suggestions have nothing to work from.
SHELL_INT    := $(wildcard Resources/Shell/diffterm.*)
# Completion specs, converted from Fig's (MIT) by `make specs` and checked in.
SPECS        := $(wildcard Resources/Specs/packed/*.z)

# -Ounchecked would drop the bounds checks that keep a malformed escape
# sequence from turning into memory corruption; -O is the right trade here.
# `if #available` compiles to a real runtime check once the deployment target
# is older than the version being asked about, and that check lives in clang's
# builtins archive. Apple's toolchain links it for you; this one does not.
CLANG_RT     := $(shell clang -print-resource-dir)/lib/darwin/libclang_rt.ios.a

SWIFT_FLAGS  := -sdk $(SDK) -target $(TARGET) -parse-as-library \
                -import-objc-header $(BRIDGE) \
                -swift-version 5 -O -wmo \
                -Xlinker $(CLANG_RT) \
                -Xcc -isysroot -Xcc $(SDK) \
                -Xlinker -rpath -Xlinker /usr/lib/swift \
                -lcompression \
                -Xlinker $(C_OBJ)

CFLAGS       := -isysroot $(SDK) -target $(TARGET) -O2 -Wall -Wextra

LDID         := ldid

.PHONY: all clean install uninstall reinstall run package check test icons \
        link-helpers unlink-helpers load-daemon unload-daemon

all: $(BINARY)

# The helpers are plain command-line tools: no entitlements, just a signature,
# because an unsigned binary will not execute here at all.
$(HELPERS): $(HELPER_SRC) Makefile
	@echo "  CC    $(HELPER_SRC) -> pbcopy, pbpaste"
	@mkdir -p $(HELPER_DIR)
	@clang $(CFLAGS) $(HELPER_SRC) -o $(HELPER_DIR)/pbcopy
	@cp $(HELPER_DIR)/pbcopy $(HELPER_DIR)/pbpaste
	@$(LDID) -S $(HELPER_DIR)/pbcopy
	@$(LDID) -S $(HELPER_DIR)/pbpaste

$(SESSIOND): $(SESSIOND_SRC) $(C_SRC) Sources/CBridge/DTPty.h Makefile
	@echo "  CC    $(SESSIOND_SRC) -> sessiond"
	@mkdir -p $(APP)
	@clang $(CFLAGS) $(SESSIOND_SRC) $(C_SRC) -o $(SESSIOND)
	@$(LDID) -S $(SESSIOND)

$(OBJ):
	@mkdir -p $(OBJ)

$(C_OBJ): $(C_SRC) Sources/CBridge/DTPty.h | $(OBJ)
	@echo "  CC    $<"
	@clang $(CFLAGS) -c $< -o $@

$(BINARY): $(SWIFT_SRC) $(C_OBJ) $(BRIDGE) Resources/Info.plist Resources/Entitlements.plist $(ICONS) $(FONTS) $(SHELL_INT) $(SPECS) $(HELPERS) $(SESSIOND) Makefile
	@echo "  SWIFT $(words $(SWIFT_SRC)) files"
	@mkdir -p $(APP)
	@swiftc $(SWIFT_FLAGS) -o $(BINARY) $(SWIFT_SRC)
	@echo "  BUNDLE $(APP)"
	@cp Resources/Info.plist $(APP)/Info.plist
	@# Identity comes from the variables, so a second build is a separate app.
	@# Not plutil: the one in the bootstrap takes -key/-value, not -replace,
	@# and exits 0 while printing "File not found" for the argument it did
	@# not understand, so a wrong bundle id would ship silently.
	@python3 -c "import plistlib; f='$(APP)/Info.plist'; p=plistlib.load(open(f,'rb')); p['CFBundleIdentifier']='$(BUNDLE_ID)'; p['CFBundleExecutable']='$(APP_NAME)'; p['CFBundleName']='$(APP_NAME)'; p['CFBundleDisplayName']='$(DISPLAY_NAME)'; plistlib.dump(p, open(f,'wb'))"
	@# Clear stale resources first: the bundle is assembled in place, so a
	@# file deleted from Resources would otherwise linger in the app forever.
	@rm -f $(APP)/*.png $(APP)/*.ttf
	@cp Resources/Icons/*.png $(APP)/
	@cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt $(APP)/
	@rm -rf $(APP)/shell
	@mkdir -p $(APP)/shell
	@cp Resources/Shell/diffterm.* $(APP)/shell/
	@rm -rf $(APP)/specs
	@if [ -n "$(SPECS)" ]; then \
	   mkdir -p $(APP)/specs; \
	   cp Resources/Specs/packed/*.z Resources/Specs/LICENSE $(APP)/specs/; \
	 fi
	@printf 'APPL????' > $(APP)/PkgInfo
	@# The plist decides which systems will install it; the Mach-O decides
	@# which will run it. They have drifted apart once already.
	@plist_min=$$(sed -n '/MinimumOSVersion/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist); \
	 if [ "$$plist_min" != "$(DEPLOY_MIN)" ]; then \
	   echo "  ERROR MinimumOSVersion is $$plist_min, DEPLOY_MIN is $(DEPLOY_MIN)"; exit 1; \
	 fi
	@echo "  SIGN  $(BINARY)"
	@$(LDID) -SResources/Entitlements.plist $(BINARY)
	@echo "  ==> $(APP)"

HARNESS      := $(BUILD)/harness
# Everything the app links except its @main, which the harness supplies.
APP_SRC_NOMAIN := $(filter-out Sources/App/AppDelegate.swift, $(wildcard Sources/App/*.swift))
HARNESS_SRC  := $(wildcard Sources/Core/*.swift) \
                $(wildcard Sources/Settings/*.swift) \
                $(wildcard Sources/UI/*.swift) \
                $(APP_SRC_NOMAIN) \
                Tools/IconRenderer.swift \
                Tools/SpecConverter.swift \
                Tests/Harness.swift

# The harness links the same code as the app minus its @main, so the checks
# run against exactly what ships.
test: $(C_OBJ)
	@echo "  SWIFT harness"
	@mkdir -p $(BUILD)
	@swiftc $(SWIFT_FLAGS) -o $(HARNESS) $(HARNESS_SRC)
	@$(LDID) -SResources/Entitlements.plist $(HARNESS)
	@echo ""
	@$(HARNESS)

# Regenerates every icon from the theme table and rewrites Info.plist.
icons: $(C_OBJ)
	@mkdir -p $(BUILD)
	@swiftc $(SWIFT_FLAGS) -o $(HARNESS) $(HARNESS_SRC)
	@$(LDID) -SResources/Entitlements.plist $(HARNESS)
	@$(HARNESS) --icons

check:
	@swiftc $(SWIFT_FLAGS) -typecheck $(SWIFT_SRC) && echo "typecheck OK"

install: $(BINARY)
	@echo "  INSTALL $(INSTALLED)"
	@$(SUDO) rm -rf $(INSTALLED)
	@$(SUDO) cp -R $(APP) $(INSTALL_DIR)/
	@$(SUDO) chown -R root:wheel $(INSTALLED)
	@$(SUDO) chmod 755 $(INSTALLED)/$(APP_NAME)
	@$(SUDO) uicache -p $(INSTALLED)
	@if [ "$(BUNDLE_ID)" = "$(PRIMARY_ID)" ]; then \
	   $(MAKE) --no-print-directory link-helpers; \
	 else \
	   echo "  SKIP  helper links belong to $(PRIMARY_ID)"; \
	 fi
	@echo "  ==> installed"

# Only ever replaces a link that already points into our bundle, so someone
# else's pbcopy is left where it is and reported instead.
link-helpers:
	@for name in pbcopy pbpaste; do \
	  target=$(LOCAL_BIN)/$$name; \
	  if [ -e "$$target" ] || [ -L "$$target" ]; then \
	    case "$$(readlink "$$target" 2>/dev/null)" in \
	      $(INSTALLED)/helpers/*) ;; \
	      *) echo "  SKIP  $$target already exists, not replacing it"; continue ;; \
	    esac; \
	  fi; \
	  $(SUDO) ln -sf $(INSTALLED)/helpers/$$name "$$target"; \
	  echo "  LINK  $$target"; \
	done

unlink-helpers:
	@for name in pbcopy pbpaste; do \
	  target=$(LOCAL_BIN)/$$name; \
	  case "$$(readlink "$$target" 2>/dev/null)" in \
	    $(INSTALLED)/helpers/*) $(SUDO) rm -f "$$target"; echo "  UNLINK $$target" ;; \
	  esac; \
	done

# Installs and starts the session daemon under launchd, so shells survive the
# app. Safe to run repeatedly.
load-daemon:
	@echo "  DAEMON $(DAEMON_DEST)"
	@$(SUDO) cp $(DAEMON_PLIST) $(DAEMON_DEST)
	@$(SUDO) chown root:wheel $(DAEMON_DEST)
	@$(SUDO) chmod 644 $(DAEMON_DEST)
	@$(SUDO) launchctl bootstrap system $(DAEMON_DEST) 2>/dev/null || $(SUDO) launchctl load $(DAEMON_DEST)
	@echo "  ==> sessiond loaded"

unload-daemon:
	@$(SUDO) launchctl bootout system $(DAEMON_DEST) 2>/dev/null || $(SUDO) launchctl unload $(DAEMON_DEST) 2>/dev/null || true
	@$(SUDO) rm -f $(DAEMON_DEST)
	@echo "  ==> sessiond unloaded"

uninstall: unlink-helpers
	@$(SUDO) uicache -u $(INSTALLED) || true
	@$(SUDO) rm -rf $(INSTALLED)

reinstall: install

run: install
	@killall -9 $(APP_NAME) 2>/dev/null || true
	@uiopen --bundleid $(BUNDLE_ID)

package: $(BINARY)
	@echo "  DEB   $(BUILD)/$(APP_NAME)_$(VERSION).deb"
	@rm -rf $(BUILD)/deb
	@mkdir -p $(BUILD)/deb/DEBIAN $(BUILD)/deb/var/jb/Applications
	@cp -R $(APP) $(BUILD)/deb/var/jb/Applications/
	@printf 'Package: %s\nName: %s\nVersion: %s\nArchitecture: iphoneos-arm64\nDescription: A modern terminal emulator for jailbroken iOS.\nMaintainer: diffTerm\nAuthor: diffTerm\nSection: Terminal_Support\nDepends: firmware (>= $(DEPLOY_MIN))\nTag: role::hacker\n' \
		"$(BUNDLE_ID)" "$(APP_NAME)" "$(VERSION)" > $(BUILD)/deb/DEBIAN/control
	@printf '#!/bin/sh\nuicache -p /var/jb/Applications/$(APP_NAME).app\nexit 0\n' > $(BUILD)/deb/DEBIAN/postinst
	@printf '#!/bin/sh\nuicache -u /var/jb/Applications/$(APP_NAME).app\nexit 0\n' > $(BUILD)/deb/DEBIAN/prerm
	@chmod 755 $(BUILD)/deb/DEBIAN/postinst $(BUILD)/deb/DEBIAN/prerm
	@dpkg-deb -Zgzip -b $(BUILD)/deb $(BUILD)/$(APP_NAME)_$(VERSION).deb

clean:
	@rm -rf $(BUILD)
