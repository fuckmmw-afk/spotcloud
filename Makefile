TARGET := iphone:clang:16.5:16.0
ARCHS := arm64
FINALPACKAGE ?= 1
SPOTCLOUD_VERSION ?= 0.3.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := SpotCloud
SpotCloud_FILES := $(shell find Sources -name '*.m' -o -name '*.c')
SpotCloud_CFLAGS := -fobjc-arc -fvisibility=hidden -ISources -ISources/JDSP \
	-Ivendor/libjamesdsp/subtree/Main/libjamesdsp/jni/jamesdsp/jdsp -Ivendor/libjamesdsp \
	-DSPOTCLOUD_VERSION='"$(SPOTCLOUD_VERSION)"' -Wno-unused-function
SpotCloud_FRAMEWORKS := Foundation UIKit AudioToolbox AVFoundation CoreMedia
# The install name stays the long Substrate path: signers like ESign rewrite it in place, and a short
# one leaves no room ("Insufficient space to update dylib path").
SpotCloud_LDFLAGS := -Wl,-headerpad_max_install_names
SpotCloud_OBJ_FILES := vendor/libjamesdsp/build/ios/libjamesdsp.a
# No Substrate: hooks are plain Objective-C runtime swaps and an import-slot rebind, which work on a
# sideloaded (ESign) app without a jailbreak.
SpotCloud_LOGOS_DEFAULT_GENERATOR := internal
SpotCloud_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

SpotCloud.all.tweak.variables: vendor/libjamesdsp/build/ios/libjamesdsp.a

vendor/libjamesdsp/build/ios/libjamesdsp.a:
	$(MAKE) --no-print-directory -C vendor/libjamesdsp JDSP_PLATFORM=ios
