#!/bin/sh
# Compile the full Zsign engine to a static library OUTSIDE the Xcode project.
# (Inside the project its headers (common/fs.h, log.h, ...) collide with LiveContainer's own ZSign target
# through Xcode's shared header map.)
set -e
LC="$1"
Z="$LC/DockBoxDeps/zsign"
cd "$Z"
mkdir -p obj
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -O2 -F$LC/OpenSSL/Frameworks/iphoneos -Isrc -Isrc/common -Iswift -fobjc-arc -std=gnu++17 -w"
for f in src/*.cpp src/common/*.cpp; do
  xcrun clang++ $FLAGS -c "$f" -o "obj/$(basename "$f").o"
done
for f in swift/*.mm; do
  xcrun clang++ $FLAGS -x objective-c++ -c "$f" -o "obj/$(basename "$f").o"
done
xcrun ar rcs libzsignbundle.a obj/*.o
ls -la libzsignbundle.a
