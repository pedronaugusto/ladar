# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The `ladar` module: `Feature`, a closed list of instruction-set extensions per architecture (AArch64's CRC32,
  PMULL, AES, SHA-256, SHA3 and DotProd; x86-64's SSSE3, SSE4.2, PCLMULQDQ, AES-NI, AVX2, VPCLMULQDQ, BMI2 with ADX,
  and SHA); `guaranteed`, the target's at compile time; `has`, comptime-true where guaranteed and comptime-false where
  neither guaranteed nor detectable, else detected once per process; `available`, whether a kernel for a feature is
  worth building on the target; and `features`. Detection by `sysctlbyname` on Darwin, the auxiliary vector on Linux,
  `IsProcessorFeaturePresent` on Windows, and CPUID with XGETBV on x86-64. From warp's `cpu.zig`, which held the
  first eight features for its checksum kernels.
