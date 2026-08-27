TARGET = iphone:6.1:6.0
ARCHS = armv7
THEOS_BUILD_DIR = debs

# Same reasoning as the sibling osexperience/splitscreen-tweak Makefiles:
# this decade-old SDK target predates modern theos's -Werror-by-default,
# and we're calling a pile of private/undeclared SpringBoard APIs on
# purpose (SBWallpaperView, SBUIController, SBIconController).
GO_EASY_ON_ME = 1

include theos/makefiles/common.mk

export VERSION = 0.3

# Heavy NSLog trajectory/state instrumentation (heartbeat, scroll, zoom,
# re-attach) -- deliberately left in and on by default, since this device's
# environment is fragile enough (Barrel churn, etc. -- see project memory)
# that it's routinely needed again. Build a quiet release with `make SWP_LOG=0`.
#
# NOT named DEBUG -- confirmed by testing that Theos itself already reserves
# that name for its own build-type variable (common.mk defaults it to 1,
# which adds -O0/-ggdb/-DDEBUG and an unrelated "+debug" package-filename
# suffix). Reusing it here would silently also toggle Theos's own debug
# build, not just our logging.
SWP_LOG ?= 1

TWEAK_NAME = WallpaperParallax

WallpaperParallax_FILES = WallpaperParallax.xm
WallpaperParallax_CFLAGS += -fobjc-arc -DVERSION=\"$(VERSION)\" -DSWP_DEBUG_LOG=$(SWP_LOG)
WallpaperParallax_FRAMEWORKS += UIKit QuartzCore CoreGraphics
# SpringBoard-private classes (SBUIController, SBIconController,
# SBWallpaperView) are only resolvable at runtime inside the host
# process, not at link time.
WallpaperParallax_LDFLAGS += -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
