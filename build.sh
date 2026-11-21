#!/bin/zsh
set -euo pipefail

root=${0:A:h}
app=${1:-"$root/.build/X1 Air Display Sync.app"}
contents="$app/Contents"
source="$root/Sources/Monitor"
vendor="$root/Vendor/m1ddc"
target=arm64-apple-macos14.0

mkdir -p "$root/.build" "$contents/MacOS" "$contents/Resources"
scratch="$(mktemp -d "$root/.build/build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

for file in ioregistry i2c; do
    xcrun clang -target "$target" -O2 -fmodules -I "$vendor/headers" \
        -c "$vendor/sources/$file.m" -o "$scratch/$file.o"
done
xcrun clang -target "$target" -O2 -Wall -Wextra -Werror -fmodules -I "$vendor/headers" \
    -c "$source/BrightnessDDC.m" -o "$scratch/BrightnessDDC.o"
xcrun clang -target "$target" -O2 -Wall -Wextra -Werror -fmodules -fobjc-arc \
    -c "$source/BrightnessHID.m" -o "$scratch/BrightnessHID.o"

xcrun swiftc -target "$target" -O -import-objc-header "$source/BrightnessHID.h" \
    "$root"/Sources/App/*.swift "$scratch"/*.o \
    -framework CoreDisplay -framework IOKit -framework ServiceManagement \
    -o "$contents/MacOS/X1AirDisplaySync"

xcrun swift "$root/Scripts/GenerateIcons.swift" "$scratch"
iconutil --convert icns --output "$contents/Resources/AppIcon.icns" "$scratch/AppIcon.iconset"
cp "$scratch/MenuBar.png" "$contents/Resources/"
cp "$root/Resources/Info.plist" "$contents/"
cp "$root/LICENSE" "$contents/Resources/LICENSE.txt"
cp "$vendor/LICENSE" "$contents/Resources/m1ddc-LICENSE.txt"
codesign --force --sign - "$app"
printf '%s\n' "$app"
