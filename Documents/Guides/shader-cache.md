# Persistent shader caches

New VMs created with the Standard preset automatically enable the Task3 kernel
patch and guest Metal cache reuse. The host saves its cache in
`<machine>/ShaderCache`, for example `~/.vphone/machines/Lychee/ShaderCache`.
Animations can lag while shaders compile on the first runs; later boots reuse
the compiled shaders. A changed executable gets a new host cache identity.

## Existing VMs

Install a Core Bundle containing this feature and bind the stopped VM to it.
In Launchpad, use **Update Guest Environment** from the machine's actions menu,
then **Update Kernel** in its **Patches** inspector. Standard now selects
**GPU Task3 shader cache** automatically. An explicit per-VM opt-out is preserved;
enable that patch in the editor first if it was unchecked.

The equivalent Launchpad CLI sequence is:

```sh
# Replace <version> with the installed Core Bundle version from bundle list.
vphone-launchpad-cli vm stop Lychee
vphone-launchpad-cli vm set-bundle Lychee <version> --update-environment
vphone-launchpad-cli cfw update-kernel Lychee
vphone-launchpad-cli vm start Lychee --wait
```

`--update-environment` redeploys the guest libraries and cache-reuse marker.
`cfw update-kernel` re-patches the pristine kernel in `FirmwareOriginals` using
the current selection and replaces the kernelcache in Preboot. Both updates
keep the guest's data; no restore or `fw patch` is needed. Updating the Core
Bundle binding alone does not update the installed kernel.

Older VMs that have no pristine kernel in `FirmwareOriginals` need `fw prepare`
and `fw patch` with the new bundle first, so the fallback restore tree contains
the updated kernel. Then run `cfw update-kernel`; do not run `restore`.

Standalone CLI users run the new bundle's `vphone-cli cfw update-environment
Lychee` and `vphone-cli cfw update-kernel Lychee` with root authorization while
the VM is off. Use `vphone-cli fw patches Lychee` to inspect pending patches.
Both update commands apply the VM's current selection, including any other
pending guest or kernel changes.

## Resetting the host cache

Stop the VM, then delete its `ShaderCache` directory. The next launch starts a
fresh host cache. Guest Metal caches are separate files inside `Disk.img`, so
clearing the host cache does not necessarily reproduce all first-run lag.

Task3 applies to cloudOS 26.4 kernels only and is disabled in the tvOS presets.
On a host older than macOS 27 the guest negotiates the host's own maximum version
and keeps that version's features, so the host cache stays per-boot there.
Runtime validation covered macOS 27.0.1, cloudOS 26.4, and iOS 27.0.1 and 26.6.2
guests; older hosts were checked from their framework code, not run.
