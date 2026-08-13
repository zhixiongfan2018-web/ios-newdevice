ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NewDevice

SHARED_FILES = $(wildcard ../shared/*.m)
NewDevice_FILES = Tweak.x DeviceIdentity.x ModelVersion.x Location.x JailbreakHide.x NetworkInfo.x TimeBoot.x URLSchemeHide.x ScreenMetrics.x DiskCapacity.x DNSSpoof.x IMEIBaseband.x Locale.x DeviceToken.x OpenUDID.x Battery.x KeychainRestore.x NDTweakState.m $(SHARED_FILES)
NewDevice_CFLAGS = -fobjc-arc -I../shared -Wno-unused-variable
NewDevice_FRAMEWORKS = Foundation UIKit CoreLocation AdSupport CoreTelephony Security SystemConfiguration NetworkExtension
NewDevice_LIBRARIES = substrate resolv z

include $(THEOS_MAKE_PATH)/tweak.mk
