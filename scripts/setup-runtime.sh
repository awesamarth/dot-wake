#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p Vendor
fetch_runtime() {
  local runtime_url="$1" runtime_sha="$2" runtime_name="$3"
  if [[ -d "Vendor/$runtime_name" ]]; then return; fi
  local runtime_temp=$(mktemp -d)
  curl --fail --location --silent --show-error "$runtime_url" -o "$runtime_temp/runtime.zip"
  local runtime_actual=$(shasum -a 256 "$runtime_temp/runtime.zip" | awk '{print $1}')
  [[ "$runtime_actual" == "$runtime_sha" ]] || { print -u2 'Runtime checksum mismatch'; return 1; }
  ditto -x -k "$runtime_temp/runtime.zip" "$runtime_temp/extracted"
  local runtime_found=$(find "$runtime_temp/extracted" -maxdepth 2 -type d -name "$runtime_name" -print -quit)
  [[ -n "$runtime_found" ]] || { print -u2 'Runtime framework missing from archive'; return 1; }
  mv "$runtime_found" "Vendor/$runtime_name"
  rm -rf "$runtime_temp"
}
fetch_runtime 'https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip' '93f7a064abe99e0d6185a88c5b36ce18c4bff35cd0d5e4e81f81151de8e3e7e5' 'sherpa-onnx.xcframework'
fetch_runtime 'https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip' 'cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0' 'onnxruntime.xcframework'
print 'Pinned native runtime dependencies ready.'
