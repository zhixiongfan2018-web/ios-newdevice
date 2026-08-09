ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NewDevice

SHARED_FILES = $(wildcard ../shared/*.m)
NewDevice_FILES = Tweak.x DeviceIdentity.x ModelVersion.x Location.x JailbreakHide.x NDTweakState.m $(SHARED_FILES)
NewDevice_CFLAGS = -fobjc-arc -I../shared -Wno-unused-variable
NewDevice_FRAMEWORKS = Foundation UIKit CoreLocation AdSupport CoreTelephony Security
NewDevice_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
