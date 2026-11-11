# ladar

ladar tells Zig code which instruction-set extensions the CPU it runs on has, for the family's kernels that need
more than the target's baseline: checksums, regex prefilters, cryptography. A feature the target guarantees is
known at compile time and costs nothing; any other is detected once, on first use, and kept in one atomic cell per
process. It depends on aegis alone and holds no kernels: a user builds each of its own as a module with the feature
enabled (Zig sets CPU features per module) and enters it where `has` says so.

```zig
const ladar = @import("ladar");

if (comptime ladar.available(.x86_avx2)) {
    if (ladar.has(.x86_avx2)) return kernels_avx2.search(haystack);
}
return scalar.search(haystack);
```

- `has(feature)`: whether this CPU has it. Comptime-true where the target guarantees it (no check runs),
  comptime-false where it can be neither guaranteed nor detected (the kernel is never referenced), else the detected
  answer.
- `available(feature)`: comptime; whether a kernel for it is worth building on this target at all.
- `features()`: every feature this CPU has, as a `Set`. `guaranteed`: the target's, at compile time.

## Features

A closed list per architecture. NEON (AArch64) and SSE2 (x86-64) are their architectures' baselines and are not
listed.

| Feature | What | Darwin | Linux | Windows |
|---|---|---|---|---|
| `arm_crc` | CRC32 (FEAT_CRC32) | `hw.optional.armv8_crc32` | `AT_HWCAP` bit 7 | `ARM_V8_CRC32_INSTRUCTIONS_AVAILABLE` |
| `arm_pmull` | PMULL, PMULL2 (FEAT_PMULL) | `hw.optional.arm.FEAT_PMULL` | `AT_HWCAP` bit 4 | `ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE` |
| `arm_aes` | AES (FEAT_AES) | `hw.optional.arm.FEAT_AES` | `AT_HWCAP` bit 3 | `ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE` |
| `arm_sha2` | SHA-256 (FEAT_SHA256) | `hw.optional.arm.FEAT_SHA256` | `AT_HWCAP` bit 6 | `ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE` |
| `arm_sha3` | EOR3 and the rest of FEAT_SHA3 | `hw.optional.arm.FEAT_SHA3` | `AT_HWCAP` bit 17 | `ARM_SHA3_INSTRUCTIONS_AVAILABLE` |
| `arm_dotprod` | UDOT, SDOT (FEAT_DotProd) | `hw.optional.arm.FEAT_DotProd` | `AT_HWCAP` bit 20 | `ARM_V82_DP_INSTRUCTIONS_AVAILABLE` |
| `x86_ssse3` | SSSE3 (PSHUFB) | CPUID 1, ECX 9 | the same | the same |
| `x86_sse42` | SSE4.2 (CRC32) | CPUID 1, ECX 20 | the same | the same |
| `x86_pclmul` | PCLMULQDQ with SSE4.1 | CPUID 1, ECX 1 and 19 | the same | the same |
| `x86_aes` | AES-NI | CPUID 1, ECX 25 | the same | the same |
| `x86_avx2` | AVX2, YMM state saved | CPUID 7, EBX 5; OSXSAVE and XCR0 | the same | the same |
| `x86_vpclmul` | VPCLMULQDQ on 256 bits | CPUID 7, ECX 10, with AVX2 | the same | the same |
| `x86_bmi2_adx` | MULX, ADCX, ADOX | CPUID 7, EBX 8 and 19 | the same | the same |
| `x86_sha` | SHA extensions | CPUID 7, EBX 29 | the same | the same |

On any other operating system an AArch64 feature is had only where the target guarantees it. The 256-bit x86
features count as detectable only under LLVM: Zig's own x86-64 backend does not realign a frame that keeps 32-byte
vectors, so under it they are had only where the target guarantees AVX2 and every caller is built with it.

## Stability

A feature, once listed, keeps its name and meaning, and the answer for it only grows: a new operating system that
can detect it, or a target that guarantees it. Features are added, never removed or renamed, within a major version;
an addition is a minor version, so code should not switch over `Feature` exhaustively. A feature a user needs that
is not listed is added here, with its detection on each operating system (or the line saying where only the baseline
gives it), never detected by the user itself.

## Status

Unreleased; 0.1.0 is the first release. Its detection came from warp, where it served warp's checksum kernels.

## License

MIT.
