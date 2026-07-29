# Roadmap

A modular Android kernel build framework that automates fetching sources, applying patches, configuring the kernel, compiling, and optionally packaging it into an AnyKernel3 flashable ZIP.

## Current Progress

- [x] Build CLI (`build.sh`)
- [x] Argument parsing & validation
- [x] Workspace management
- [x] `--clean` support
- [x] Kernel source cloning
- [x] Toolchain role mapping (`clang`, `gcc64`, `gcc32`, ...)
- [x] Toolchain download & reuse
- [x] Logging helpers
- [x] Toolchain environment setup (`PATH`, `CC`, `CROSS_COMPILE`, `CROSS_COMPILE_ARM32`)
- [x] Common patch application
- [x] Flavor setup (`vanilla`, `ksunext`, `resukisu`)
- [x] Flavor-specific patch application
- [x] Config fragment merging
- [x] Kernel compilation
- [x] Optional AnyKernel3 packaging
- [x] Output directory & artifact organization

## Next Up

- [ ] Dependency checking at startup
- [ ] `.github/workflows/` CI pipeline
- [ ] Populate `patches/` and `configs/` with actual content
- [ ] Flavor-specific defconfig detection (auto-select based on device)
- [ ] Incremental build support (detect source/toolchain changes)
- [ ] Device/variant selection argument (`--device`)
- [ ] Prebuilt dtbo/dtboimg handling

## Build Flow

```text
Parse arguments
        ↓
Check dependencies
        ↓
Prepare workspace
        ↓
Clone kernel source
        ↓
Download / reuse toolchains
        ↓
Setup toolchain environment
        ↓
Apply common patches
        ↓
Apply flavor patches
        ↓
Merge config fragments
        ↓
Compile kernel
        ↓
Organize output artifacts
        ↓
(Optional) Package with AnyKernel3
```

## Design Goals

- Simple, argument-driven workflow.
- Reusable workspace and toolchains.
- Modular patches and config fragments.
- Support multiple root flavors without manual source edits.
- Optional AnyKernel3 packaging.
- Easy to extend for new toolchains, flavors, and build profiles.
```
