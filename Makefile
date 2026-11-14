# Convenience targets. Needs Xcode 16; `make test` also needs ffmpeg (brew install ffmpeg).

DERIVED     := build/DerivedData
APP         := $(DERIVED)/Build/Products/Release/Looper.app
INSTALL_DIR ?= /Applications

.PHONY: help app install run test test-long fixtures cli clean

help:
	@echo "make app        build Looper.app (universal Release) into $(APP)"
	@echo "make install    build and copy Looper.app to $(INSTALL_DIR)"
	@echo "make run        build and open the app"
	@echo "make test       generate fixtures and run the LooperCore tests"
	@echo "make test-long  same, plus the 8 h export tests"
	@echo "make cli        build the looper command-line tool (LooperCore/.build/release/looper)"
	@echo "make clean      remove build output"

app:
	xcodebuild build -project Looper.xcodeproj -scheme Looper -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath $(DERIVED) -quiet
	@echo "Built $(APP)"

install: app
	rm -rf "$(INSTALL_DIR)/Looper.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	@echo "Installed $(INSTALL_DIR)/Looper.app"

run: app
	open "$(APP)"

fixtures:
	scripts/make-test-clip.sh

test: fixtures
	swift test --package-path LooperCore

test-long: fixtures
	LOOPER_LONG_TESTS=1 swift test --package-path LooperCore

cli:
	swift build -c release --package-path LooperCore --product looper
	@echo "Built LooperCore/.build/release/looper"

clean:
	rm -rf build LooperCore/.build
