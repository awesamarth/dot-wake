Pinned native binaries copied from existing SwiftPM verified artifacts, not rebuilt or quantized:
- sherpa-onnx1.13.8 macOS static XCFramework, upstream SwiftPM archive checksum 93f7a064abe99e0d6185a88c5b36ce18c4bff35cd0d5e4e81f81151de8e3e7e5.
- ONNX Runtime1.28.2 macOS static XCFramework, upstream archive checksum cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0.

Every vendored file compared byte-for-byte with preserved0.4.7 artifact directory; see evidence/vendor-provenance.json. This documentation records native versions; local Package.swift uses these files without downloading replacements. Vendor contents are development dependencies, excluded from app dist.
