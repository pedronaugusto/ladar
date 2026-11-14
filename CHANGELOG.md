# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Pins aegis dc3ed602, still 0.2.4: additive commits after 3c0b13e (the role declarations a linter reads, `lint_rules`; `eql` and `compare` on the checked integers; Duration's ratio, mod, negate and abs), the aegis the development build's preflight selects. Nothing ladar calls changed.
- glint 0.8: the calls past std's checked layer (CPUID, XGETBV, sysctl, the auxiliary vector, Windows' processor features) are `src/system.zig`, ladar's one P007 seam, each with what its caller must hold; `cpu.zig` decides from their answers.

### Added

- The `ladar` module: `Feature`, a closed list of instruction-set extensions per architecture (AArch64's CRC32,
  PMULL, AES, SHA-256, SHA3 and DotProd; x86-64's SSSE3, SSE4.2, PCLMULQDQ, AES-NI, AVX2, VPCLMULQDQ, BMI2 with ADX,
  and SHA); `guaranteed`, the target's at compile time; `has`, comptime-true where guaranteed and comptime-false where
  neither guaranteed nor detectable, else detected once per process; `available`, whether a kernel for a feature is
  worth building on the target; and `features`. Detection by `sysctlbyname` on Darwin, the auxiliary vector on Linux,
  `IsProcessorFeaturePresent` on Windows, and CPUID with XGETBV on x86-64.
- CPUID's and `AT_HWCAP`'s words decoded by pure functions, tested against the README's feature table on any words
  (seeded, and a fuzz target under Zig's fuzzer); XGETBV runs only where OSXSAVE says the operating system enabled it.
- A usage example (`examples/usage.zig`), built and run with the tests, from which the README's blocks are generated.
- `docs/design.md`.
