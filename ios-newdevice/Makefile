export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak daemon app

include $(THEOS_MAKE_PATH)/aggregate.mk
