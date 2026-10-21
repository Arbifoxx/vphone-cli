# CoreAnimation precompiled pipelines

Investigation and descriptor/reboot follow-up, 2026-10-20–21. This records analysis and isolated probes,
not a new renderer patch. Runtime scope: Lychee, iOS 27.0.1 (24A446,
iPhone17,3), cloudOS 26.4 (23E5207q), macOS 27.0.1. No iOS 18 coverage.

## Findings

CoreAnimation explicitly excludes virtualized devices before trying to load
its precompiled-pipeline archive. The virtual Metal driver nevertheless
supports binary archives. The shipped archive opens, but all 18 simple compute
descriptors tested missed its compiled entries. A newly generated archive for
`compute_clear` succeeded, including reopening it in another process and
creating the pipeline with `MTLPipelineOptionFailOnBinaryArchiveMiss`.

The follow-up captured actual CoreAnimation render descriptors and generated
an archive for them. After a full VM shutdown and boot, all 20 render requests
(10 distinct labels) used strict archive hits to draw the same four images,
with identical pixel hashes. A separately prepared compute archive also
provided 22/22 strict hits after reboot, with an important preparation-order
control described below.

This establishes guest-side preparation and cross-boot reuse for those tested
variants. It does not establish complete animation coverage, system-renderer
integration, or elimination of host-side compilation. The existing persistent
shader caches remain useful.

## Artifact and evidence identity

| Artifact | Identity |
| --- | --- |
| QuartzCore | Extracted from iPhone17,3 27.0.1 / 24A446 dyld cache; SHA-256 `1f56d2a1341b47420ced2836fab63713007d12e171a893002014723dd7298522` |
| AppleParavirtGPUMetalIOGPUFamily | Host's cached cloudOS 26.4 / 23E5207q guest driver; SHA-256 `29ba36c7bc87d82c40fa1cecdf357e7a383fa70eb46df0d75869f5ac562aedbc` |
| Shipped QuartzCore `default.metallib` | Read from Lychee, 10,961,696 bytes; SHA-256 `d3b2ed3e7546c332972b1953e0e54876cb7f8db543fed996a8f98f5eb69e9b1f` |
| Generated one-pipeline archive | 6,315 bytes; SHA-256 `53b96b6f3e99cf6599838f06f57e6f0b66cde86ab0b1aea93258e1b28d91262e` |
| Generated real-render-descriptor archive | 119,217 bytes; SHA-256 `9eb0eee60357c9b9a114915e2767f6dd07878cdd12a9bb0375024798c438c6d6` |
| Generated normal-first compute archive | 190,981 bytes; SHA-256 `79ac53f371c140a535b389c142cb0b83c8aff0a4899ebc07c945037d23c5148e` |

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
The initial standalone compute probe below does not reproduce those encoded
backdrop descriptors. The follow-up captures actual render descriptors.

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

## Exact descriptor follow-up

`get_compute_pipeline_descriptor` at `0x1845b1d64` has a 39-entry function-name
table. Only kind 10 takes the specialized backdrop branch; the other 38 use a
named `MTLFunctionDescriptor` without constants or a specialized name and a
default compute descriptor with a label and compute function. For example,
`compute_clear` is kind 38. This explains why the initial generic control also
belongs to a real CoreAnimation compute-descriptor family. It does not make
these simple descriptors inputs to the separate encoded `Kbd` backdrop loader.

Backdrop kind 10 adds four boolean constants at indices 67–70 to the fragment
constants, corresponding to its four encoded flags. The runtime library's
metadata names these `fc_debug_backdrop_magenta`, `fc_single_quad_backdrop`,
`fc_backdrop_downsample` and `fc_backdrop_edge_clear`. Its normalization and
remaining required constants need their own runtime coverage.

`get_pipeline_descriptor` at `0x184526d1c` builds render descriptors for both
ordinary rendering and the strict precompiled loader. Its vertex layout 0
uses buffer 1, stride 48: Float4 at offset 0, Float2 at 16, Float2 at 24 and
Half4 at 32. These values agree with the captured live descriptors.

The strict render loader also requires exact membership in a shipped
607-entry name table, plus per-entry GPU-family checks. Of the 10 distinct
labels observed below, two occur in that table:

- `PBGRAXmw_A3Xhfc`, entry 40;
- `PBGRABsovXmw_A3Xhfc`, entry 28.

Both require Apple5, which this guest advertises. The name decoder reconstructs
the observed `VfxXh` vertex variant from the fragment and pipeline fields.
The `A3Xhfc` fragment selects `fixed_frag_lph_cpf`; its encoded image payloads
are empty. This supplies a static bridge between those two live descriptors
and the existing strict loader. The other eight measured labels do not occur
in that table. On the normal fallback, `create_pipeline_state` at
`0x1845263d8` passes false to the descriptor builder's archive parameter
(`0x184526490`–`0x184526498`) and does not attach the context archive before
pipeline creation. Enabling the gate and setting a context archive alone
therefore does not route those eight variants through it on this build.

Full name tables, decoders and bounded flag interpretations are retained in
`descriptor-findings-phase2.md`, `descriptor-precompiled-pipeline-table.json`
and `descriptor-runtime-precompiled-name-comparison.json` in the external
evidence directory. Some external setter names remain unresolved; encoded
flags without established semantics are recorded as raw bits.

## Real CoreAnimation rendering across a reboot

The follow-up uses a standalone Swift process with public `CARenderer` and
Metal APIs. Process-local observation of the device's pipeline-creation
methods records copies of descriptors CoreAnimation actually requests.
It does not modify SpringBoard, backboardd, the framework on disk or a global
virtual-device identity.

Four 96×96 offscreen scenes exercise solid layers, rounded translucent layers,
gradients, shadows, transforms and an image with a border. CoreAnimation emits
20 render requests with 10 distinct pipeline labels; no compute pipeline
requests were observed in these scenes. After normal rendering, the probe
adds the actual descriptors to a new archive and serializes it.

In a new process after a full shutdown and boot, the probe re-creates the same
scenes. For each pipeline request it first checks a copied descriptor against
the saved archive and an empty archive using `FailOnBinaryArchiveMiss`. In
replay mode it also returns a pipeline state created with the saved archive
and fail-on-miss enabled to CoreAnimation, rather than allowing normal
pipeline-creation fallback for that request.

| Check | Result |
| --- | --- |
| Saved render archive | 20/20 strict hits |
| Empty-archive control | 20/20 strict misses |
| Archive-derived states supplied to the renderer | 20/20 |
| GPU command buffers | All four completed without errors |
| Rendered pixels | All four SHA-256 hashes identical to normal rendering |
| Archive bytes | SHA-256 unchanged across boot and replay |

Preparation boot UUID: `0E228ECC-041D-4FED-A301-1FEFFD28DCF0`.
Replay boot UUID: `650E056C-0A32-4452-9021-0EDC34A9FC9A`.
The replay process does not harvest or rewrite the archive.

This proves that these real render descriptors can use guest-generated
archives across boots and execute correctly in this bounded scene set.
Creating specialized functions and other renderer setup still occurs; host
compiler activity and animation frame times were not measured. Existing
system and Task3 host caches were not cleared for this experiment.

## Compute preparation-order control

The expanded Swift probe tests 22 unspecialized compute functions from the
same QuartzCore library. Simply calling `addComputePipelineFunctions` returned
success for all 22, but one resulting archive provided only 1/22 strict hits
after reopening. That initially appeared after a reboot; a fresh preparation
and separate-process check reproduced it **within the same boot**, with
identical archive bytes. It must not be described as reboot invalidation.

Calling ordinary compute-pipeline creation immediately before adding each
unchanged descriptor produced a different archive. That preparation provided
22/22 strict hits in another process and again after a full shutdown and boot.
Both verification runs obtained 22/22 empty-archive misses and 22/22 shipped
archive misses. The saved file's SHA-256 was unchanged.

Preparation boot UUID: `650E056C-0A32-4452-9021-0EDC34A9FC9A`.
Reopening boot UUID: `3E9E5A77-5F10-4E66-A0C0-4AFC4E055E67`.

Static Metal inspection corroborates that harvesting and ordinary PSO creation
take different finalization paths. The harvest wrapper reports success based
on absence of an error, without requiring a returned pipeline object. This
supports testing actual saved-archive hits rather than relying on the add
method's boolean alone. It does not establish the internal cause of the
function-key discrepancy or a general driver fix. See the retained
`driver-compute-harvest-findings.md` and supporting disassembly.

## Follow-up evidence and test hygiene

Swift probe sources are `phase2/archive-reboot-probe.swift` and
`phase2/renderer-archive-probe.swift` under the external evidence directory.
They were compiled with `xcrun --sdk iphoneos swiftc -target
arm64-apple-ios18.0 -O` and signed ad hoc. The deployment target is a compiler
setting, not evidence of iOS 18 runtime compatibility. The local test runner
uploads and loads a temporary launchd job through Launchpad's guest RPC.

The decisive outputs are:

- `phase2/bootB-persistent-renderer-prepare-output.json`;
- `phase2/bootC-renderer-replay-output.json`;
- `phase2/bootC-compute-control-prepare-output.json` and its same-boot verify;
- `phase2/bootC-compute-warm-prepare-output.json` and its same-boot verify;
- `phase2/bootD-compute-warm-verify-output.json`;
- `phase2/verification-summary.json`: 20 cross-file assertions passed,
  including negative controls, boot identities, archive hashes and pixels.

The first reboot attempt used `/var/tmp`; both archives were absent afterward,
so that attempt supplied no archive-compatibility evidence. The successful
tests used a dedicated directory under `/var/mobile/Library`. An initial
render-result read was also truncated by the probe runner's 256 KiB limit;
the completed output was recovered with a larger read, without rerunning the
producer, and later reads used the corrected limit.

Settings and Camera both reached the foreground after the final test. No new
crash-report paths appeared relative to that boot's probe baseline; an existing
Passbook widget report's modification time changed. The final VM log contained
zero `Trying to restart GPU` lines. Known probe jobs were unloaded, temporary
executables/plists/output files and the dedicated archive directory removed.
Generated archives and raw evidence remain only in the host research folder.
The machine's kernel, guest environment, bundle binding and patch selections
were not changed. Lychee was shut down and confirmed stopped after cleanup.

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
| Does the virtual driver support archives? | Yes, including strict hits and real rendering after a VM reboot. |
| Can the shipped file load? | Yes; compatible compiled entries are a separate question. |
| Does the shipped archive supply the tested pipelines? | No for the 22 compute descriptors in the follow-up; shipped render coverage remains open. |
| Can we prepare compatible replacements? | Yes for 20 actual render requests/10 labels and 22 compute descriptors across boots; full coverage remains open. |
| Does this eliminate visible cold lag or host compilation? | Unmeasured. |

Next: determine how the system renderer should attach the generated archive,
including dynamic variants outside the shipped strict-loader table. Prepare
and strictly validate the required variants before interactive use; key archive
invalidation to the guest OS/framework and virtual-driver target. Add coverage
for specialized backdrop/blur paths and real Settings/SpringBoard workloads,
then measure guest and host compilation separately and animation frame times.
An independent preparation process must not seed a different program's host
Task3 cache; the earlier cross-process cache-mixing restriction still applies.
Any future runtime patch must be declared, selectable and documented through
the normal patch-set workflow. A shared global `IsVirtualDevice` spoof would
affect unrelated framework decisions and is not an archive-compatibility fix.
