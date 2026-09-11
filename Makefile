TARGET = iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = ChatGPT14

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ChatGPT14

ChatGPT14_FILES = $(wildcard Sources/*.swift)
ChatGPT14_FRAMEWORKS = UIKit Foundation Security AVFoundation Photos UniformTypeIdentifiers QuickLook
ChatGPT14_SWIFTFLAGS = -O
ChatGPT14_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
