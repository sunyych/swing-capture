SHELL := /bin/bash

BUILD_DATE := $(shell date +'%Y%m%d')
OUTPUT_DIR := $(HOME)/Documents/AppsBuild/SwingCapture
BUILD_SEQ := $(shell mkdir -p "$(OUTPUT_DIR)"; n=1; while printf -v seq "%02d" "$$n"; [[ -e "$(OUTPUT_DIR)/SwingCapture-$(BUILD_DATE)-$$seq.ipa" || -e "$(OUTPUT_DIR)/SwingCapture-$(BUILD_DATE)-$$seq.apk" ]]; do n=$$((n + 1)); done; printf "%02d" "$$n")
BUILD_SUFFIX := $(BUILD_DATE)-$(BUILD_SEQ)
BUILD_NUMBER := $(shell bash scripts/build_number.sh)

.PHONY: android-build ios-build ios-ipa clean

android-build:
	mkdir -p "$(OUTPUT_DIR)"
	flutter build apk --release --dart-define=ENVIRONMENT=production --build-number=$(BUILD_NUMBER)
	cp build/app/outputs/flutter-apk/app-release.apk "$(OUTPUT_DIR)/SwingCapture-Android-$(BUILD_SUFFIX).apk"

ios-build:
	OUTPUT_DIR="$(OUTPUT_DIR)" BUILD_SUFFIX="$(BUILD_SUFFIX)" BUILD_NUMBER="$(BUILD_NUMBER)" UPLOAD_TO_TESTFLIGHT=1 bash scripts/ios_release.sh

ios-ipa:
	OUTPUT_DIR="$(OUTPUT_DIR)" BUILD_SUFFIX="$(BUILD_SUFFIX)" BUILD_NUMBER="$(BUILD_NUMBER)" UPLOAD_TO_TESTFLIGHT=0 bash scripts/ios_release.sh

clean:
	rm -f "$(OUTPUT_DIR)"/SwingCapture-iOS-*.ipa
	rm -f "$(OUTPUT_DIR)"/SwingCapture-Android-*.apk
