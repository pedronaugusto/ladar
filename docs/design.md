# Architecture

ladar answers one question: which instruction-set extensions does the CPU running this program have, for kernels
that need more than the target's baseline. Its runtime closure is ladar → aegis → std. It holds no kernels and
exports no build helper; it does no I/O beyond the operating system's own feature queries.

This describes the implementation in this repository. Change it with the code when a feature, a detection or a
rule changes.

## Module

One module, `ladar`, root `src/cpu.zig`, importing aegis alone (for `Atomic`). Every user imports this one module,
so a process has one detection cell.

- `Feature`, `Set` (an `EnumSet`); `guaranteed`, the target's set at compile time, from `builtin.cpu`.
- `has(comptime f)`: comptime-true where guaranteed (no load, no check: the caller enters the kernel directly);
  comptime-false where neither guaranteed nor detectable (the kernel is never referenced, so it need not even be
  built); else the detected answer.
- `available(comptime f)`: guaranteed or detectable on this target, so a user knows at compile time whether to build
  a kernel module at all.
- `features()`: the whole detected set.

## The detection cell

`Feature` has at most 31 cases. Detection runs on first use and stores the set's mask in one 32-bit atomic with
bit 31 set to say it ran. Threads racing on first use each detect and each store the same value, so the cell needs no
lock and monotonic ordering suffices: any thread sees either nothing (and detects) or the one answer.

## Features and their detection

A closed list per architecture; NEON and SSE2 are their architectures' baselines and are not listed.

- **AArch64**: `arm_crc`, `arm_pmull`, `arm_aes`, `arm_sha2`, `arm_sha3`, `arm_dotprod`. Darwin: `sysctlbyname`
  (`hw.optional.armv8_crc32`, `hw.optional.arm.FEAT_*`). Linux: `getauxval(AT_HWCAP)`, bits 7, 4, 3, 6, 17, 20
  (asm/hwcap.h). Windows: `IsProcessorFeaturePresent`, whose one cryptographic flag gives AES, PMULL and SHA-256
  together. Any other operating system: the target's guarantees only, no run-time check.
- **x86-64**: `x86_ssse3`, `x86_sse42`, `x86_pclmul` (with SSE4.1), `x86_aes`, `x86_avx2`, `x86_vpclmul`,
  `x86_bmi2_adx`, `x86_sha`, from CPUID on every operating system. Leaf 7 is read only where leaf 0 says it exists;
  the AVX features also need OSXSAVE and XCR0's SSE and AVX bits, and XGETBV is executed only where OSXSAVE is set
  (it is an invalid instruction otherwise).

The README's table is the specification. Decoding is pure and separate from reading the registers:
`decodeX86` takes CPUID's and XGETBV's words and `decodeHwcap` takes `AT_HWCAP`, on any target, so both are tested on
every machine and on any words, not only on the CPU the tests run on.

**256-bit kernels and Zig's own backend.** A 256-bit kernel keeps 32-byte vectors on its stack, which the x86-64 ABI
aligns only to 16 bytes. LLVM realigns such a frame; Zig's own x86-64 backend does not, and a kernel entered from
baseline code would fault on an aligned store. So `x86_avx2` and `x86_vpclmul` count as detectable only under LLVM;
under the other backend they are had only where the target guarantees AVX2, so every caller is built with it too.

## Rules

- A feature a user needs that is not listed is added here, never detected by the user: the enum case, its
  `guaranteed` mapping, its detection on each operating system (or the line saying where only the baseline gives
  it), its row in the README's table and in the tests' tables.
- Kernels stay with their users, each a module built with the feature enabled, since Zig sets CPU features per
  module. Code outside such a module is never compiled with a feature the CPU may lack.
- Choosing code by CPU model (a MIDR or family-and-model read) is not an instruction-set question and is not here.

## Validation

- The detected set holds the guaranteed one, is stable across calls, and agrees with `has` for every feature; a
  feature not available on the target is never had; each feature belongs to one architecture.
- On Apple silicon, every listed AArch64 feature is reported (Darwin's sysctl says so).
- Decoding agrees with the README's table on 20,000 seeded words each for CPUID and `AT_HWCAP`, every x86 row reached;
  real CPUID words of an AVX2 part decode with and without the operating system saving YMM state.
- The same properties are a fuzz target under `bay test --fuzz`; the release tier runs them with safety on and the
  detection cell under ThreadSanitizer.
- Native runs cover AArch64 Darwin and, under Rosetta, x86-64 Darwin; the portable matrix compiles every target.
