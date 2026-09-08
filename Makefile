export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = rootless
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

TWEAK_NAME = RingerGainEQ
RingerGainEQ_FILES = Tweak.xm
RingerGainEQ_CFLAGS = -fobjc-arc
# AVSystemController 在私有 Celestial 框架, 必须运行时解析 (NSClassFromString + MSHookMessageEx),
# 不要链接该框架, theos 的 iPhoneOS16.5.sdk 里也没有它。

INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
