#!/usr/bin/env bash
set -e

# Variables
UPSTREAM=""
BRANCH=""
FLAVOR=""
TOOLCHAINS=()
CONFIG_FRAGMENTS=()
AK3_REPO=""
AK3_BRANCH="main"
CLEAN=false
ROOT_DIR="$(pwd)"
WORK_DIR="$ROOT_DIR/work"
KERNEL_DIR="$WORK_DIR/kernel"
AK3_DIR="$WORK_DIR/ak3"
TOOLCHAIN_DIR="$ROOT_DIR/toolchains"

# Usage
usage() {
    echo "Usage:"
    echo "./build.sh \\"
    echo "  --upstream <kernel_repo> \\"
    echo "  --branch <kernel_branch> \\"
    echo "  --flavor <vanilla|ksunext|resukisu> \\"
    echo "  --toolchains <url1> <url2> ... \\"
    echo "  --configs <config1> <config2> ... \\"
    echo "  [--ak3 <anykernel3_repo>] \\"
    echo "  [--ak3-branch <branch>]"
    echo "  [--clean]"
    exit 1
}

log() {
    echo
    echo "[*] $*"
}

success() {
    echo "[✓] $*"
}

warn() {
    echo "[!] $*"
}

error() {
    echo "[✗] $*"
    exit 1
}

# Arguments
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
                TOOLCHAINS+=("$1")
                shift
            done
            ;;

        --configs)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                CONFIGS+=("$1")
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
    printf '  - %s\n' "${TOOLCHAINS[@]}"
fi

echo
echo "Configs:"
if [[ ${#CONFIGS[@]} -eq 0 ]]; then
    echo "  None"
else
    printf '  - %s\n' "${CONFIGS[@]}"
fi

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

# Workspace
if $CLEAN; then
    log "Cleaning workspace..."
    rm -rf "$WORK_DIR"
fi

mkdir -p "$WORK_DIR"
mkdir -p "$TOOLCHAIN_DIR"

# Clone upstream kernel
log "Preparing kernel source..."

if [[ -d "$KERNEL_DIR/.git" ]]; then
    warn "Existing kernel source found."
    log " Reusing: $KERNEL_DIR"
else
    log "Cloning upstream..."

    git clone \
        --depth=1 \
        --branch "$BRANCH" \
        "$UPSTREAM" \
        "$KERNEL_DIR"

    success "Kernel cloned."
fi
