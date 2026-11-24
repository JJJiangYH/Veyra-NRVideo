#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

if (( $# != 1 )); then
  print -u2 'Usage: build-hdr-tools.sh OUTPUT_DIRECTORY'
  exit 2
fi

script_dir=${0:A:h}
macos_dir="${script_dir:h:h}/macos"
mkdir -p "$1"
output_dir=${1:A}

xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2 \
  -c "$macos_dir/Interpolation.m" -o "$output_dir/Interpolation.o"

media_sources=("$macos_dir/"{Video,MediaContainer,ColourGrade,PictureGraph,Metrics,Subtitles}.swift)
for tool in process-gta make-comparison; do
  if [[ "$tool" == process-gta ]]; then
    source=ProcessGTA.swift
  else
    source=MakeComparison.swift
  fi
  xcrun swiftc -target arm64-apple-macos26.0 -swift-version 5 -O \
    -import-objc-header "$macos_dir/Interpolation.h" \
    "${media_sources[@]}" "$script_dir/$source" "$output_dir/Interpolation.o" \
    -o "$output_dir/$tool"
done
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 5 -O -parse-as-library \
  "$script_dir/AuditMedia.swift" -o "$output_dir/audit-media"
