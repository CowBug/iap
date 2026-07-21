# Makefile — Build IAPCrack.dylib
# Requirements: Xcode 16+, iOS 16.0 SDK
# Usage: make

TARGET      = IAPCrack.dylib
SDK         = iphoneos
ARCH        = arm64
MIN_VER     = 16.0
CC          = xcrun -sdk $(SDK) clang
CFLAGS      = -arch $(ARCH) -miphoneos-version-min=$(MIN_VER) -isysroot $$(xcrun -sdk $(SDK) --show-sdk-path) -O2 -fobjc-arc -fvisibility=hidden
LDFLAGS     = -dynamiclib -framework Foundation -current_version 1.0 -compatibility_version 1.0 -install_name @executable_path/Frameworks/IAPCrack.dylib

SRCS = IAPCrack.m
OBJS = $(SRCS:.m=.o)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^
	@echo "✅ Built $@"
	@install_name_tool -id @executable_path/Frameworks/IAPCrack.dylib $@ 2>/dev/null || true
	@lipo -info $@

%.o: %.m
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)
