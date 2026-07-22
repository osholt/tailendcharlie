FLUTTER ?= flutter
MOBILE_DIR := apps/mobile
RIDE_RELAY_API_BASE_URL ?= https://relay.tailendcharlie.app/api
IOS_SIMULATOR_LOCATION ?= 51.457750,-2.462319
IOS_SIMULATOR_DEVICE ?= $(shell xcrun simctl list devices booted | awk -F '[()]' '/Booted/ { print $$2; exit }')

.PHONY: setup format check test android ios ios-simulator

setup:
	cd $(MOBILE_DIR) && $(FLUTTER) pub get

format:
	cd $(MOBILE_DIR) && dart format lib test

check:
	cd $(MOBILE_DIR) && $(FLUTTER) analyze
	cd $(MOBILE_DIR) && $(FLUTTER) test

test:
	cd $(MOBILE_DIR) && $(FLUTTER) test --coverage

android:
	cd $(MOBILE_DIR) && $(FLUTTER) build apk --debug

ios:
	cd $(MOBILE_DIR) && $(FLUTTER) build ios --debug --no-codesign

ios-simulator:
	@test -n "$(IOS_SIMULATOR_DEVICE)" || (echo "No booted iOS Simulator found." >&2; exit 1)
	xcrun simctl location "$(IOS_SIMULATOR_DEVICE)" set "$(IOS_SIMULATOR_LOCATION)"
	cd $(MOBILE_DIR) && $(FLUTTER) run -d "$(IOS_SIMULATOR_DEVICE)" \
		--dart-define=RIDE_RELAY_API_BASE_URL="$(RIDE_RELAY_API_BASE_URL)"
