export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e
# scheme 由 CI/环境变量决定（rootless 默认，roothide 构建时 CI 传 roothide）；
# 必须用 ?= 条件赋值——make 里普通赋值会覆盖环境变量，roothide job 会被打回 rootless
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

TWEAK_NAME = RingerGainEQ
RingerGainEQ_FILES = Tweak.xm
RingerGainEQ_CFLAGS = -fobjc-arc
# AVSystemController 在私有 Celestial 框架, 必须运行时解析 (NSClassFromString + MSHookMessageEx),
# 不要链接该框架, theos 的 iPhoneOS16.5.sdk 里也没有它。

INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
