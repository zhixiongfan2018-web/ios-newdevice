ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = NewDevice

SHARED_FILES = $(wildcard ../shared/*.m)
NewDevice_FILES = Sources/main.m Sources/AppDelegate.m Sources/NDTheme.m Sources/NDAPIClient.m Sources/HomeViewController.m Sources/RecordsViewController.m Sources/AppsViewController.m Sources/ToolsViewController.m Sources/SettingsViewController.m Sources/ProfileDetailViewController.m Sources/ProbeViewController.m Sources/CatalogPickerViewController.m Sources/ExportPickerViewController.m $(SHARED_FILES)
NewDevice_CFLAGS = -fobjc-arc -I../shared -ISources -Wno-deprecated-declarations
NewDevice_FRAMEWORKS = UIKit Foundation CoreGraphics CoreLocation AdSupport Security CoreTelephony
NewDevice_LIBRARIES = z
NewDevice_CODESIGN_FLAGS = -Sentitlements.plist
NewDevice_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
