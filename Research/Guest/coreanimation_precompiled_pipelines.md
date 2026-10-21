# CoreAnimation precompiled pipelines

Initial investigation, 2026-10-20. This records analysis and isolated probes,
not a new renderer patch. Runtime scope: Lychee, iOS 27.0.1 (24A446,
iPhone17,3), cloudOS 26.4 (23E5207q), macOS 27.0.1. No iOS 18 coverage.

## Findings

CoreAnimation explicitly excludes virtualized devices before trying to load
its precompiled-pipeline archive. The virtual Metal driver nevertheless
supports binary archives. The shipped archive opens, but all 18 simple compute
descriptors tested missed its compiled entries. A newly generated archive for
`compute_clear` succeeded, including reopening it in another process and
creating the pipeline with `MTLPipelineOptionFailOnBinaryArchiveMiss`.

That establishes a possible guest-side preparation path. It does not establish
that enabling CoreAnimation's existing path is sufficient, that all required
pipeline variants can be generated, or that host-side compilation disappears.
The existing persistent shader caches remain useful.

## Artifact and evidence identity

| Artifact | Identity |
| --- | --- |
| QuartzCore | Extracted from iPhone17,3 27.0.1 / 24A446 dyld cache; SHA-256 `1f56d2a1341b47420ced2836fab63713007d12e171a893002014723dd7298522` |
| AppleParavirtGPUMetalIOGPUFamily | Host's cached cloudOS 26.4 / 23E5207q guest driver; SHA-256 `29ba36c7bc87d82c40fa1cecdf357e7a383fa70eb46df0d75869f5ac562aedbc` |
| Shipped QuartzCore `default.metallib` | Read from Lychee, 10,961,696 bytes; SHA-256 `d3b2ed3e7546c332972b1953e0e54876cb7f8db543fed996a8f98f5eb69e9b1f` |
| Generated one-pipeline archive | 6,315 bytes; SHA-256 `53b96b6f3e99cf6599838f06f57e6f0b66cde86ab0b1aea93258e1b28d91262e` |

Local evidence, probe sources and binary copies live outside Git in
`/Users/arbifox/.vphone/research/coreanimation-precompiled-2026-10-20/`.
Do not redistribute the Apple binaries or archive with the source report.

REA opened the target identity, but its Hopper bridge twice failed to become
ready within 120 seconds. Close was requested; final REA status is `open: false`.
There is no successful new REA decompilation Evidence ID for these findings.
They come from the project's Capstone decoder through a standalone Swift
inspector, Mach-O symbol/function-start metadata, Metal tools and the runtime
probe. Historical notices and original extraction provenance were recovered
separately from the earlier session and are labeled historical in the evidence.

The extracted QuartzCore has an out-of-range `LC_FUNCTION_VARIANTS` command.
The inspector used its mapped segments, original instruction bytes, symbol
table and function-start table; it did not repair that command or infer missing
external shared-cache stubs. External call names not resolved from this image
remain unknown. Addresses below are unslid addresses in this exact artifact.

## Eligibility check

`CA::OGL::new_metal_context(...)` starts at `0x18458ec84`.

- The unsupported-hardware branch reads
  `CADeviceIsVirtualized::is_virtualized` at `0x1e701fdd9` and compares it with
  one (`0x18458f640`–`0x18458f648`). A true result reaches the notice at
  `0x18458f680`, then skips archive setup.
- Its once block, `___CADeviceIsVirtualized_block_invoke` at `0x184541f10`,
  passes the CFString `IsVirtualDevice` to an external boolean getter and
  stores the result in that byte. The CFString is at `0x1e9025680`; its data
  resolves to `0x184826c76`.
- Separate branches disable the path for `CA_DISABLE_PRECOMPILED_PIPELINES`,
  a renderer feature flag, and GPU capture. Clearing the debug option does
  not bypass the virtualization check.
- The resource selection preceding the check uses `default` / `metallib`.
  Archive construction follows the check and uses the label
  `com.apple.coreanimation.binary-archive`.

Thus the notice is an explicit virtualization exclusion, not evidence that an
attempt to use this particular archive already failed. This conclusion follows
the controlling branch and its initializer, rather than the notice alone.

The downstream loader is also identifiable:
`CA::OGL::MetalContext::load_pipeline(char const*)` at `0x1846e67b0`,
`load_compute_pipeline_state(char const*)` at `0x1845be930`, and
`load_pipeline_state(NSString*)` at `0x184525d84`. The compute loader decodes
CoreAnimation's encoded variant name, obtains its descriptor and passes option
`4` at `0x1845beb00`, consistent with the public fail-on-archive-miss option.
The standalone probe below does not reproduce those encoded descriptors.

## Driver capability and archive contents

Static inspection of the cloudOS driver finds
`-[AppleParavirtDevice supportsBinaryArchives]` at `0x1f224` returning true.
Its architecture setup uses CPU type `0x01000017` (AIR64); an internal target
name is `apv`. Runtime `device.architecture.name` is **`air64_v27`**.
These are different forms of target identity, not proof that the virtual
device executes physical iPhone GPU instructions.

The isolated runtime probe observed:

- `AppleParavirtDevice`, named `Apple Paravirtual device GPU`;
- binary archive support true;
- advertised Apple families 1–5 and Common families 1–3;
- `/System/Library/Frameworks/QuartzCore.framework/default.metallib` loads as
  both `MTLLibrary` and `MTLBinaryArchive`, without error;
- the library exports 249 function names.

Metal tool fat-header inspection reports two shipped slices: AIR intermediate
code (`air64_v29`) and a native `applegpu_g17p` executable. The generated archive
is an AIR64 Mach-O bundle with subtype 11 (`air64_v27`). The fat-header tool
reports the headers but also warns that the AIR MetalLib slice is not itself a
Mach-O/archive; no complete native-pipeline inventory is claimed from that tool.

## Controlled pipeline tests

The probe loaded functions from the shipped library and examined the first 20
compute-named kernels. Two backdrop kernels require 22 function constants each
and were skipped. The other 18 have no function constants. Each was used in a
default compute descriptor, with the shipped binary archive attached and
`MTLPipelineOptionFailOnBinaryArchiveMiss` set.

All 18 returned `CompilerError`, code 1: no matching compiled pipeline functions
in the archive. Examples include `compute_clear`, `compute_sum_luma`,
`downsample_8_compute` and `narrow_blur_7_compute`.

This is bounded negative evidence. It does not cover CoreAnimation's actual
render descriptors, its specialized backdrop variants, every thread-group
configuration or the entire shipped archive. Loading the file successfully
must not be confused with finding compatible compiled pipeline entries.

For `compute_clear`, the control then:

1. Created a normal pipeline successfully, establishing a valid descriptor.
2. Created an empty archive and added that descriptor's pipeline functions.
3. Serialized the archive and reopened it successfully.
4. Created the pipeline with fail-on-miss enabled successfully.
5. In another probe process, loaded the saved file and obtained the strict hit
   before that process's normal compilation/harvesting control. The shipped
   archive still missed for the same descriptor.

This proves persisted guest archive reuse for one compute pipeline, across
processes in one boot. It does not measure compilation time, prove reuse after
a reboot, or establish zero host GPU compiler work.

Settings and Camera reached the foreground after the probes. The recorded
crash listing was unchanged from the final probe baseline, and the VM log had
zero `Trying to restart GPU` lines. The launchd job was unloaded, all five probe
files removed, and Lychee shut down; final state is stopped. Renderer checks,
guest firmware and patch selections were not modified.

## Physical devices and next questions

Physical devices still compile shaders. Apple's public explanation describes
source-to-AIR compilation, GPU-specific compilation, system caches and binary
archives. It explicitly identifies an iOS cold reboot as a case in which an
archive can help. See [Build GPU binaries with Metal, WWDC20](https://developer.apple.com/videos/play/wwdc2020/10615/).
Ahead-of-time binaries can remove work from interactive use; that is compatible
with a device still compiling new shader variants at other times. Apple's
[WWDC23 compilation session](https://developer.apple.com/videos/play/wwdc2023/10124/)
also explains GPU/OS targeting and offline preparation.

The native GPU slice in this iPhone framework and the virtualization exclusion
support the inference that physical CoreAnimation can avoid guest-like
first-use compilation for matching shipped pipelines. No physical iPhone was
profiled in this investigation; this is not a complete explanation of native
animation performance.

The initial questions now have these boundaries:

| Question | Status |
| --- | --- |
| Why is the path disabled? | Answered for this QuartzCore: explicit virtualization check, plus independent opt-outs. |
| Does the virtual driver support archives? | Answered statically and with a persisted one-pipeline control. |
| Can the shipped file load? | Yes; compatible compiled entries are a separate question. |
| Does the shipped archive supply the tested pipelines? | No for 18 default compute descriptors; actual renderer coverage remains open. |
| Can we prepare compatible replacements? | One generic compute pipeline proved; CoreAnimation's full variants remain open. |
| Does this eliminate visible cold lag or host compilation? | Unmeasured. |

Next: recover the exact render/compute descriptor variants used by the real
CoreAnimation fast path, including its encoded names and function constants;
generate a bounded matching archive; test strict hits for those descriptors
before considering a local eligibility change. Only then compare cold boots,
guest and host compilation separately, visual animation behavior and Camera.
Any future runtime patch must be declared, selectable and documented through
the normal patch-set workflow. A shared global `IsVirtualDevice` spoof would
affect unrelated framework decisions and is not an archive-compatibility fix.
