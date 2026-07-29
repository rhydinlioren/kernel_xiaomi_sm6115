#!/usr/bin/env bash
set -e

# Save original command
ORIG_CMD="$0 $*"

# Variables
UPSTREAM=""
BRANCH=""
FLAVOR=""
declare -A TOOLCHAINS
CONFIG_FRAGMENTS=()
AK3_REPO=""
AK3_BRANCH="main"
DEFCONFIG=""
CLEAN=false
ROOT_DIR="$(pwd)"
WORK_DIR="$ROOT_DIR/work"
KERNEL_DIR="$WORK_DIR/kernel"
AK3_DIR="$WORK_DIR/ak3"
TOOLCHAIN_DIR="$WORK_DIR/toolchains"
OUT_DIR="$KERNEL_DIR/out"
LOG_FILE="$WORK_DIR/build.log"
FINAL_OUTPUT_DIR="$ROOT_DIR/out"
ARCH="arm64"
PATCHES_DIR="$ROOT_DIR/patches"
COMMON_PATCHES_DIR="$PATCHES_DIR/common"
FLAVOR_PATCHES_DIR="$PATCHES_DIR/$FLAVOR"

declare -A TOOLCHAIN_PATHS
MAKE_ARGS=()

usage() {
    echo "Usage:"
    echo "./build.sh \\"
    echo "  --upstream <kernel_repo> \\"
    echo "  --branch <kernel_branch> \\"
    echo "  --flavor <vanilla|ksunext|resukisu> \\"
    echo "  --toolchains <url1> <url2> ... \\"
    echo "  --configs <config1> <config2> ... \\"
    echo "  [--ak3 <anykernel3_repo>] \\"
    echo "  [--ak3-branch <branch>] \\"
    echo "  [--defconfig <defconfig_target>] \\"
    echo "  [--clean]"
    exit 1
}

log() {
    echo >&2
    echo "[*] $*" >&2
}

success() {
    echo "[✓] $*" >&2
}

warn() {
    echo "[!] $*" >&2
}

error() {
    echo "[✗] $*" >&2
    exit 1
}

find_bin_dir() {
    local dir="$1"
    if [[ -d "$dir/bin" ]]; then
        echo "$dir/bin"
    elif [[ -d "$dir/usr/bin" ]]; then
        echo "$dir/usr/bin"
    elif [[ -d "$dir" ]] && ls "$dir"/*-gcc &>/dev/null 2>&1; then
        echo "$dir"
    else
        for sub in "$dir"/*/bin; do
            if [[ -d "$sub" ]]; then
                echo "$sub"
                return 0
            fi
        done
        echo ""
    fi
}

detect_gcc_prefix() {
    local bindir="$1"
    for f in "$bindir"/*gcc; do
        if [[ -x "$f" && ! -d "$f" ]]; then
            local base
            base="$(basename "$f")"
            echo "${base%gcc}"
            return 0
        fi
    done
    return 1
}

setup_flavor() {
    if [[ "$FLAVOR" == "vanilla" ]]; then
        return 0
    fi

    log "Setting up $FLAVOR flavor..."

    case "$FLAVOR" in
        resukisu)
            if [[ -f "$KERNEL_DIR/ReSukiSU/Kconfig" ]]; then
                success "ReSukiSU already set up."
                return 0
            fi
            log "Downloading ReSukiSU setup script..."
            if command -v curl &>/dev/null; then
                (cd "$KERNEL_DIR" && curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash) || {
         error "ReSukiSU setup failed."
     }
            elif command -v wget &>/dev/null; then
                (cd "$KERNEL_DIR" && wget -q -O - "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash) || {
                error "ReSukiSU setup failed."
    }
            else
                error "curl or wget required for ReSukiSU setup."
            fi
            if [[ ! -f "$KERNEL_DIR/KernelSU/kernel/Kconfig" ]]; then
                error "ReSukiSU setup did not complete successfully."
            fi
            success "ReSukiSU source integrated."
            ;;

        ksunext)
            if [[ -f "$KERNEL_DIR/KernelSU-Next/Kconfig" ]]; then
                success "KernelSU-Next already set up."
                return 0
            fi
            log "Downloading KernelSU-Next setup script..."
            if command -v curl &>/dev/null; then
                (cd "$KERNEL_DIR" && curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash) || {
                    error "KernelSU-Next setup failed."
                }
            elif command -v wget &>/dev/null; then
                (cd "$KERNEL_DIR" && wget -q -O - "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash) || {
                    error "KernelSU-Next setup failed."
                }
            else
                error "curl or wget required for KernelSU-Next setup."
            fi
            if [[ ! -f "$KERNEL_DIR/KernelSU-Next/Kconfig" ]]; then
                error "KernelSU-Next setup did not complete successfully."
            fi
            success "KernelSU-Next source integrated."
            ;;
    esac
}

apply_patches() {
    local patch_dir="$1"
    local label="$2"

    if [[ ! -d "$patch_dir" ]]; then
        warn "Patch directory not found: $patch_dir"
        return 0
    fi

    shopt -s nullglob
    local patches=("$patch_dir"/*.patch)
    shopt -u nullglob

    if [[ ${#patches[@]} -eq 0 ]]; then
        warn "No patches found in $label ($patch_dir)"
        return 0
    fi

    IFS=$'\n' patches=($(sort <<<"${patches[*]}")); unset IFS

    log "Applying $label patches..."

    pushd "$KERNEL_DIR" > /dev/null

    for p in "${patches[@]}"; do
        local name
        name="$(basename "$p")"
        if git am --quiet "$p" 2>/dev/null; then
            success "  Applied: $name"
        elif patch -p1 --silent < "$p" 2>/dev/null; then
            success "  Applied (patch): $name"
            git add -A 2>/dev/null || true
            git commit -m "apply: $name" --author "builder <builder>" --allow-empty > /dev/null 2>&1 || true
        else
            error "Failed to apply: $name"
        fi
    done

    popd > /dev/null
    success "$label patches applied (${#patches[@]} total)."
}

setup_build_env() {
    log "Setting up build environment..."

    MAKE_ARGS=(
        -j"$(nproc)"
        ARCH="$ARCH"
        O="$OUT_DIR"
    )

    local extra_paths=()

    if [[ -n "${TOOLCHAIN_PATHS[clang]:-}" ]]; then
        local bindir
        bindir="$(find_bin_dir "${TOOLCHAIN_PATHS[clang]}")"
        if [[ -z "$bindir" ]]; then
            error "Could not find bin/ in clang toolchain"
        fi
        extra_paths+=("$bindir")
        MAKE_ARGS+=("CC=clang")

        local triple
        triple="$("$bindir/clang" -print-target-triple 2>/dev/null || true)"
        if [[ -z "$triple" ]]; then
            triple="aarch64-linux-gnu"
        fi
        MAKE_ARGS+=("CLANG_TRIPLE=$triple")

        local llvm_bin="$bindir"
        if [[ -x "$bindir/llvm-ar" ]]; then
            extra_paths+=("$bindir")
            MAKE_ARGS+=("LLVM=1")
        fi
    fi

    local gcc64_path="${TOOLCHAIN_PATHS[gcc64]:-${TOOLCHAIN_PATHS[gcc]:-}}"
    if [[ -n "$gcc64_path" ]]; then
        local bindir64
        bindir64="$(find_bin_dir "$gcc64_path")"
        if [[ -n "$bindir64" ]]; then
            extra_paths+=("$bindir64")
            local prefix64
            prefix64="$(detect_gcc_prefix "$bindir64")"
            if [[ -n "$prefix64" ]]; then
                MAKE_ARGS+=("CROSS_COMPILE=$prefix64")
            fi
        fi
    fi

    if [[ -n "${TOOLCHAIN_PATHS[gcc32]:-}" ]]; then
        local bindir32
        bindir32="$(find_bin_dir "${TOOLCHAIN_PATHS[gcc32]}")"
        if [[ -n "$bindir32" ]]; then
            extra_paths+=("$bindir32")
            local prefix32
            prefix32="$(detect_gcc_prefix "$bindir32")"
            if [[ -n "$prefix32" ]]; then
                MAKE_ARGS+=("CROSS_COMPILE_ARM32=$prefix32")
            fi
        fi
    fi

    if [[ ${#extra_paths[@]} -gt 0 ]]; then
        local IFS=:
        export PATH="${extra_paths[*]}:$PATH"
        unset IFS
    fi

    success "Build environment ready."
}

merge_config_fragments() {
    local merge_script="$KERNEL_DIR/scripts/kconfig/merge_config.sh"

    if [[ ! -f "$merge_script" ]]; then
        warn "merge_config.sh not found in kernel source (kernel too old or missing)."
        warn "Skipping config fragment merging."
        return 0
    fi

    local defconfig="${DEFCONFIG:-defconfig}"

    log "Merging config fragments..."

    mkdir -p "$OUT_DIR"

    pushd "$KERNEL_DIR" > /dev/null

    log "Generating base config: $defconfig"
    make "${MAKE_ARGS[@]}" "$defconfig" 2>&1 | tail -3 || {
        warn "Defconfig '$defconfig' not found; trying 'defconfig'..."
        make "${MAKE_ARGS[@]}" "defconfig" 2>&1 | tail -3 || error "Could not generate base config"
    }

    local fragments=()

    local configs_dir="$ROOT_DIR/configs"
    if [[ -d "$configs_dir" ]]; then
        shopt -s nullglob
        for f in "$configs_dir"/*.config "$configs_dir"/*.fragment; do
            fragments+=("$f")
        done
        shopt -u nullglob
    fi

    local resolved
    for frag in "${CONFIG_FRAGMENTS[@]}"; do
        if [[ "$frag" == /* ]]; then
            resolved="$frag"
        else
            resolved="$ROOT_DIR/$frag"
        fi
        if [[ -f "$resolved" ]]; then
            fragments+=("$resolved")
        else
            warn "Config fragment not found: $resolved"
        fi
    done

    if [[ ${#fragments[@]} -eq 0 ]]; then
        warn "No config fragments to merge."
        make "${MAKE_ARGS[@]}" olddefconfig 2>&1 | tail -2
        popd > /dev/null
        return 0
    fi

    local merge_cmd=(
        ARCH="$ARCH"
        scripts/kconfig/merge_config.sh
        -m -O "$OUT_DIR"
        "$OUT_DIR/.config"
    )

    for f in "${fragments[@]}"; do
        log "  Fragment: $f"
        merge_cmd+=("$f")
    done

    "${merge_cmd[@]}" 2>&1 | tail -5

    make "${MAKE_ARGS[@]}" olddefconfig 2>&1 | tail -2

    popd > /dev/null
    success "Config fragments merged (${#fragments[@]} fragments)."
}

compile_kernel() {
    log "Compiling kernel..."

    pushd "$KERNEL_DIR" > /dev/null

    make "${MAKE_ARGS[@]}" 2>&1 | tail -10

    popd > /dev/null
    success "Kernel compilation completed."
}

organize_outputs() {
    log "Organizing build artifacts..."

    mkdir -p "$FINAL_OUTPUT_DIR"

    local boot_dir="$OUT_DIR/arch/$ARCH/boot"

    if [[ -f "$boot_dir/Image" ]]; then
        cp "$boot_dir/Image" "$FINAL_OUTPUT_DIR/"
        success "  Copied Image"
    fi

    if [[ -f "$boot_dir/Image.gz" ]]; then
        cp "$boot_dir/Image.gz" "$FINAL_OUTPUT_DIR/"
        success "  Copied Image.gz"
    fi

    if [[ -f "$boot_dir/Image.lz4" ]]; then
        cp "$boot_dir/Image.lz4" "$FINAL_OUTPUT_DIR/"
        success "  Copied Image.lz4"
    fi

    local dtb_dir
    dtb_dir="$boot_dir/dts"
    if [[ -d "$dtb_dir" ]]; then
        local dtb_files=()
        while IFS= read -r f; do
            dtb_files+=("$f")
        done < <(find "$dtb_dir" -name "*.dtb" -o -name "*.dtbo" 2>/dev/null)
        if [[ ${#dtb_files[@]} -gt 0 ]]; then
            mkdir -p "$FINAL_OUTPUT_DIR/dtb"
            cp "${dtb_files[@]}" "$FINAL_OUTPUT_DIR/dtb/"
            success "  Copied ${#dtb_files[@]} DTB files"
        fi
    fi

    if [[ -f "$OUT_DIR/modules.order" ]]; then
        local mod_dir="$FINAL_OUTPUT_DIR/modules"
        mkdir -p "$mod_dir"
        pushd "$KERNEL_DIR" > /dev/null
        make "${MAKE_ARGS[@]}" modules_install INSTALL_MOD_PATH="$mod_dir" 2>&1 | tail -3
        popd > /dev/null
        success "  Installed kernel modules"
    fi

    cp "$OUT_DIR/.config" "$FINAL_OUTPUT_DIR/build.config" 2>/dev/null || true
    cp "$OUT_DIR/System.map" "$FINAL_OUTPUT_DIR/" 2>/dev/null || true

    success "Artifacts organized in: $FINAL_OUTPUT_DIR"
}

package_ak3() {
    log "Packaging with AnyKernel3..."

    if [[ -d "$AK3_DIR/.git" ]]; then
        warn "Existing AnyKernel3 found."
        log " Reusing: $AK3_DIR"
    else
        log "Cloning AnyKernel3..."
        git clone --depth=1 --branch "$AK3_BRANCH" "$AK3_REPO" "$AK3_DIR"
        success "AnyKernel3 cloned."
    fi

    local boot_dir="$OUT_DIR/arch/$ARCH/boot"

    if [[ -f "$boot_dir/Image.gz" ]]; then
        cp "$boot_dir/Image.gz" "$AK3_DIR/"
        success "  Copied Image.gz"
    elif [[ -f "$boot_dir/Image" ]]; then
        cp "$boot_dir/Image" "$AK3_DIR/"
        success "  Copied Image"
    fi

    local dtb_dir
    dtb_dir="$boot_dir/dts"
    if [[ -d "$dtb_dir" ]]; then
        while IFS= read -r f; do
            cp "$f" "$AK3_DIR/" 2>/dev/null || true
        done < <(find "$dtb_dir" -name "*.dtb" -o -name "*.dtbo" 2>/dev/null)
    fi

    local zip_name="kernel-${FLAVOR}-$(date +%Y%m%d-%H%M%S).zip"

    pushd "$AK3_DIR" > /dev/null
    zip -r9 "$ROOT_DIR/$zip_name" . -x ".git/*" -x "*.zip" > /dev/null
    popd > /dev/null

    success "AnyKernel3 package created: $zip_name"
}

check_dependencies() {
    local deps=(git make patch find xargs)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ -n "$AK3_REPO" ]]; then
        if ! command -v zip &>/dev/null; then
            missing+=("zip")
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
    fi
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in

        --upstream)
            UPSTREAM="$2"
            shift 2
            ;;

        --branch)
            BRANCH="$2"
            shift 2
            ;;

        --flavor)
            FLAVOR="$2"
            shift 2
            ;;

        --toolchains)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                KEY="${1%%=*}"
                VALUE="${1#*=}"
                if [[ "$1" != *=* || -z "$KEY" || -z "$VALUE" ]]; then
                    error "Invalid toolchain format: '$1'. Expected: role=https://..."
                fi
                if [[ -n "${TOOLCHAINS[$KEY]:-}" ]]; then
                    error "Duplicate toolchain role: '$KEY'"
                fi
                TOOLCHAINS["$KEY"]="$VALUE"
                shift
            done
            ;;

        --configs)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                CONFIG_FRAGMENTS+=("$1")
                shift
            done
            ;;

        --ak3)
            AK3_REPO="$2"
            shift 2
            ;;

        --ak3-branch)
            AK3_BRANCH="$2"
            shift 2
            ;;

        --defconfig)
            DEFCONFIG="$2"
            shift 2
            ;;

        --clean)
            CLEAN=true
            shift
            ;;

        *)
            echo "Unknown argument: $1"
            usage
            ;;

    esac
done

# Clean only
if $CLEAN && [[ -z "$UPSTREAM" && -z "$BRANCH" && -z "$FLAVOR" ]]; then
    log "Cleaning workspace..."
    rm -rf "$WORK_DIR"
    success "Workspace cleaned."
    exit 0
fi

# Validation
if [[ -z "$UPSTREAM" || -z "$BRANCH" || -z "$FLAVOR" ]]; then
    echo "Missing required arguments"
    usage
fi

case "$FLAVOR" in
    vanilla|ksunext|resukisu)
        ;;
    *)
        echo "Invalid flavor: $FLAVOR"
        echo "Available:"
        echo "  vanilla"
        echo "  ksunext"
        echo "  resukisu"
        exit 1
        ;;
esac

check_dependencies

# Clean workspace before setting up log (so rm -rf doesn't break tee)
if $CLEAN; then
    echo "[*] Cleaning workspace..."
    rm -rf "$WORK_DIR"
fi

mkdir -p "$WORK_DIR"

# Redirect all output to both terminal and build.log (overwrites previous)
exec > >(tee "$LOG_FILE") 2>&1

echo "Command: $ORIG_CMD"
echo

# Summary
echo "=============================="
echo " Kernel Build Configuration"
echo "=============================="

echo
echo "Upstream:"
echo "  $UPSTREAM"

echo
echo "Branch:"
echo "  $BRANCH"

echo
echo "Flavor:"
echo "  $FLAVOR"

echo
echo "Toolchains:"
if [[ ${#TOOLCHAINS[@]} -eq 0 ]]; then
    echo "  None"
else
    for KEY in "${!TOOLCHAINS[@]}"; do
        echo "  $KEY:"
        echo "    ${TOOLCHAINS[$KEY]}"
    done
fi

echo
echo "Configs:"
if [[ ${#CONFIG_FRAGMENTS[@]} -eq 0 ]]; then
    echo "  None"
else
    printf '  - %s\n' "${CONFIG_FRAGMENTS[@]}"
fi

echo
echo "Defconfig:"
echo "  ${DEFCONFIG:-defconfig}"

echo
echo "AnyKernel3:"
if [[ -n "$AK3_REPO" ]]; then
    echo "  Enabled"
    echo "  Repo: $AK3_REPO"
    echo "  Branch: $AK3_BRANCH"
else
    echo "  Disabled"
fi
echo
echo "Clean build:"
echo "  $CLEAN"

echo
echo "=============================="

mkdir -p "$TOOLCHAIN_DIR"

# Clone upstream kernel
log "Preparing kernel source..."

if [[ -d "$KERNEL_DIR/.git" ]]; then
    warn "Existing kernel source found."
    log " Reusing: $KERNEL_DIR"
else
    log "Cloning upstream..."
    git clone --depth=1 --branch "$BRANCH" "$UPSTREAM" "$KERNEL_DIR"
    success "Kernel cloned."
fi

# Toolchains
download_toolchain() {
    local key="$1" url="$2"

    # Determine toolchain name from URL
    local base
    base="$(basename "$url")"
    base="${base%.tar.*}"
    base="${base%.tgz}"
    base="${base%.git}"
    local target="$TOOLCHAIN_DIR/$base"

    if [[ -d "$target" ]]; then
        success "$key already exists ($target)."
        echo "$target"
        return 0
    fi

    if [[ "$url" =~ \.tar\.(gz|xz|bz2)$ || "$url" =~ \.tgz$ ]]; then
        log "Downloading $key tarball..."
        local archive="$TOOLCHAIN_DIR/$base.tar.archive"
        if command -v curl &>/dev/null; then
            curl -Lso "$archive" "$url"
        elif command -v wget &>/dev/null; then
            wget -q -O "$archive" "$url"
        else
            error "curl or wget required for toolchain download."
        fi

        local tmpdir="$TOOLCHAIN_DIR/.tmp-extract-$base"
        rm -rf "$tmpdir"
        mkdir -p "$tmpdir"

        log "Extracting $key..."
        tar --hard-dereference -xf "$archive" -C "$tmpdir"
        rm -f "$archive"

        # Handle single top-level directory in tarball
        local contents=("$tmpdir"/*)
        if [[ ${#contents[@]} -eq 1 && -d "${contents[0]}" ]]; then
            mv "${contents[0]}" "$target"
        else
            mv "$tmpdir" "$target"
        fi
        rm -rf "$tmpdir"

        success "$key ready."
    else
        log "Cloning $key..."
        git clone --depth=1 "$url" "$target"
        success "$key ready."
    fi

    echo "$target"
}

log "Preparing toolchains..."

for KEY in "${!TOOLCHAINS[@]}"; do
    URL="${TOOLCHAINS[$KEY]}"
    DEST="$(download_toolchain "$KEY" "$URL")"
    TOOLCHAIN_PATHS["$KEY"]="$DEST"
done

# 1. Toolchain environment setup
setup_build_env

# 2. Apply common patches
apply_patches "$COMMON_PATCHES_DIR" "common"

# 3. Setup selected flavor (run setup script for resukisu/ksunext)
setup_flavor

# 4. Apply flavor-specific patches
if [[ "$FLAVOR" != "vanilla" ]]; then
    apply_patches "$FLAVOR_PATCHES_DIR" "$FLAVOR"
fi

# 5. Merge config fragments
merge_config_fragments

# 6. Compile kernel
compile_kernel

# 7. Organize output artifacts
organize_outputs

# 8. Optional AnyKernel3 packaging
if [[ -n "$AK3_REPO" ]]; then
    package_ak3
fi

log "Build complete!"
success "Output directory: $FINAL_OUTPUT_DIR"
