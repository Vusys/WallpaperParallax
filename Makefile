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

TWEAK_NAME = ScrollingWallpaper

ScrollingWallpaper_FILES = ScrollingWallpaper.xm
ScrollingWallpaper_CFLAGS += -fobjc-arc -DVERSION=\"$(VERSION)\"
ScrollingWallpaper_FRAMEWORKS += UIKit QuartzCore CoreGraphics
# SpringBoard-private classes (SBUIController, SBIconController,
# SBWallpaperView) are only resolvable at runtime inside the host
# process, not at link time.
ScrollingWallpaper_LDFLAGS += -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
