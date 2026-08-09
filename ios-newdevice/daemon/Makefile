ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = newdeviced

SHARED_FILES = $(wildcard ../shared/*.m)
newdeviced_FILES = main.m $(SHARED_FILES)
newdeviced_CFLAGS = -fobjc-arc -I../shared
newdeviced_FRAMEWORKS = Foundation CoreFoundation Security CoreTelephony
newdeviced_CODESIGN_FLAGS = -Sentitlements.plist
newdeviced_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
