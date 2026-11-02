#!/usr/bin/env bash
set -e

# Build the Android APK using the Flutter SDK pinned in submodules/flutter,
# regardless of which `flutter` (if any) is on the system PATH.
#
# Each build gets a higher versionCode than the last, so the APK can be
# installed over a previous build without uninstalling it first.
# (The APK must also be signed with the same key as the installed app,
# which it is as long as android/key.properties doesn't change.)
#
# The version is set in build-version.md (BUILD_NAME and BUILD_NUMBER).
# Environment variables take priority, e.g.
#   BUILD_NAME=1.36.2 BUILD_NUMBER=29700000 ./build-apk.sh

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION_FILE="build-version.md"

# Prints the value of "KEY: value" from $VERSION_FILE, if present.
read_version_var() {
  [ -f "$VERSION_FILE" ] || return 0
  grep -m1 -E "^$1:" "$VERSION_FILE" | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]*$//"
}

FILE_BUILD_NAME="$(read_version_var BUILD_NAME)"
FILE_BUILD_NUMBER="$(read_version_var BUILD_NUMBER)"
[ "$FILE_BUILD_NAME" = "auto" ] && FILE_BUILD_NAME=""
[ "$FILE_BUILD_NUMBER" = "auto" ] && FILE_BUILD_NUMBER=""
BUILD_NAME="${BUILD_NAME:-$FILE_BUILD_NAME}"
BUILD_NUMBER="${BUILD_NUMBER:-$FILE_BUILD_NUMBER}"

FLUTTER_BIN="submodules/flutter/bin/flutter"

if [ ! -x "$FLUTTER_BIN" ]; then
  echo "Flutter submodule not found. Initializing it now..."
  git submodule update --init submodules/flutter
fi

# versionName defaults to the one in pubspec.yaml (e.g. 1.36.1).
BUILD_NAME="${BUILD_NAME:-$(grep -m1 '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*//; s/\+.*//')}"
# versionCode defaults to minutes since the Unix epoch, which always
# increases and is higher than pubspec.yaml's build number (136010).
BUILD_NUMBER="${BUILD_NUMBER:-$(( $(date +%s) / 60 ))}"

echo "Building version $BUILD_NAME (versionCode $BUILD_NUMBER)"

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER" \
  "$@"

echo
echo "APK built at: build/app/outputs/flutter-apk/app-release.apk"
echo "Version: $BUILD_NAME (versionCode $BUILD_NUMBER)"
