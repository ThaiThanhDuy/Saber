# Build version

`build-apk.sh` reads the APK version from the two lines below.
Only edit the values after the colon.

BUILD_NAME: 1.36.1
BUILD_NUMBER: auto

- `BUILD_NAME`: the version shown to users (versionName), e.g. `1.36.1`.
  Use `auto` to take it from `pubspec.yaml`.
- `BUILD_NUMBER`: the versionCode, a whole number.
  Use `auto` to use the minutes since 1970, which goes up with every build.
  If you set it by hand, it must be higher than the installed app's
  versionCode, otherwise Android won't install the APK over it.
