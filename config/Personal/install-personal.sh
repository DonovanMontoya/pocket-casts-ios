#!/bin/zsh
# Builds the personal copy ("Casts AI") and installs it on a connected iPhone,
# next to the App Store Pocket Casts.
#
# Usage: config/Personal/install-personal.sh <device id from `xcrun devicectl list devices`>
# Signing uses the App Store Connect API key in ~/.appstoreconnect/private_keys.
set -euo pipefail

device=${1:?Pass the device identifier}
key_id=6NCMFJ4H4J
repo=${0:A:h:h:h}
derived=${DERIVED_DATA:-/tmp/pc-personal-dd}

cd "$repo"
xcodebuild -project podcasts.xcodeproj -scheme pocketcasts -configuration Debug \
  -destination "id=$device" -derivedDataPath "$derived" \
  -xcconfig config/Personal/Personal.xcconfig \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8" \
  -authenticationKeyID "$key_id" \
  -authenticationKeyIssuerID bc532328-887d-4ed4-b42e-89dac5904636 \
  build

xcrun devicectl device install app --device "$device" "$derived/Build/Products/Debug-iphoneos/podcasts.app"
