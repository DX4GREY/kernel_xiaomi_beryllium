#!/usr/bin/env bash
# ==============================================================================
# Script Name   : builder.sh
# Description   : Interactive TUI Kernel Builder for Pocophone F1 (beryllium)
# Architecture  : ARM64 (Snapdragon 845 / SDM845)
# Kernel Version: Linux 4.19
# Author        : Senior Android Kernel Developer
# Standards     : Strict error handling (set -eo pipefail) & modular architecture
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# GLOBAL CONSTANTS & DIRECTORY PATHS
# ------------------------------------------------------------------------------
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="beryllium"
DEVICE_NAME="Pocophone F1"
ARCH="arm64"
SUBARCH="arm64"

OUT_DIR="${KERNEL_DIR}/out"
TOOLCHAIN_DIR="${KERNEL_DIR}/toolchain"
PATCHES_DIR="${KERNEL_DIR}/patches"
CONFIGS_DIR="${KERNEL_DIR}/configs"
ANYKERNEL_DIR="${KERNEL_DIR}/AnyKernel3"
RELEASE_DIR="${KERNEL_DIR}/build_output"
BUILD_LOG="${KERNEL_DIR}/build.log"
CONF_FILE="${KERNEL_DIR}/builder.conf"

BASE_DEFCONFIG="arch/arm64/configs/vendor/sdm845-perf_defconfig"
COMMON_CONFIG="arch/arm64/configs/vendor/xiaomi/sdm845-common.config"
BERYLLIUM_CONFIG="arch/arm64/configs/vendor/xiaomi/beryllium.config"

# ------------------------------------------------------------------------------
# COLOR PALETTE (ANSI ESCAPE SEQUENCES)
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_RED="\033[1;31m"
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_BLUE="\033[1;34m"
    C_MAGENTA="\033[1;35m"
    C_CYAN="\033[1;36m"
    C_WHITE="\033[1;37m"
    BG_BLUE="\033[44m"
    BG_CYAN="\033[46m"
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
    C_WHITE=""
    BG_BLUE=""
    BG_CYAN=""
fi

# ------------------------------------------------------------------------------
# LOGGING & UI HELPERS
# ------------------------------------------------------------------------------
log_info() {
    echo -e "${C_CYAN}[INFO]${C_RESET} $*"
}

log_success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} $*"
}

log_warn() {
    echo -e "${C_YELLOW}[WARNING]${C_RESET} $*"
}

log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $*"
}

print_header() {
    clear || true
    echo -e "${C_CYAN}${C_BOLD}"
    echo "================================================================================"
    echo "       POCOPHONE F1 (BERYLLIUM) - SDM845 LINUX 4.19 KERNEL BUILDER TUI          "
    echo "================================================================================"
    echo -e "${C_RESET}"
}

print_status_bar() {
    local tc_status="${C_RED}Not Configured${C_RESET}"
    local cfg_status="${C_RED}Missing (.config)${C_RESET}"
    local img_status="${C_RED}Not Built${C_RESET}"
    local anyk_status="${C_YELLOW}Not Ready${C_RESET}"
    local adb_status="${C_DIM}Not Connected${C_RESET}"

    if [[ -n "${ACTIVE_TOOLCHAIN_TYPE:-}" ]]; then
        tc_status="${C_GREEN}${ACTIVE_TOOLCHAIN_TYPE}${C_RESET}"
    elif [[ -f "${CONF_FILE}" ]]; then
        tc_status="${C_GREEN}Configured (conf)${C_RESET}"
    fi

    if [[ -f "${OUT_DIR}/.config" ]]; then
        cfg_status="${C_GREEN}Ready (${OUT_DIR}/.config)${C_RESET}"
    elif [[ -f "${KERNEL_DIR}/.config" ]]; then
        cfg_status="${C_YELLOW}Ready (Root .config)${C_RESET}"
    fi

    local target_img=""
    if [[ -f "${OUT_DIR}/arch/arm64/boot/Image.gz-dtb" ]]; then
        target_img="${OUT_DIR}/arch/arm64/boot/Image.gz-dtb"
    elif [[ -f "${KERNEL_DIR}/arch/arm64/boot/Image.gz-dtb" ]]; then
        target_img="${KERNEL_DIR}/arch/arm64/boot/Image.gz-dtb"
    fi

    if [[ -n "${target_img}" && -f "${target_img}" ]]; then
        local sz
        sz=$(du -h "${target_img}" | cut -f1)
        img_status="${C_GREEN}Ready (${sz})${C_RESET}"
    fi

    if [[ -d "${ANYKERNEL_DIR}" && -f "${ANYKERNEL_DIR}/anykernel.sh" ]]; then
        anyk_status="${C_GREEN}Installed${C_RESET}"
    fi

    if command -v adb >/dev/null 2>&1; then
        local dev_line
        dev_line=$(adb devices 2>/dev/null | grep -E '\b(device|recovery|sideload|unauthorized)\b' | head -n1 || true)
        if [[ -n "${dev_line}" ]]; then
            local d_ser d_st
            d_ser=$(echo "${dev_line}" | awk '{print $1}')
            d_st=$(echo "${dev_line}" | awk '{print $2}')
            case "${d_st}" in
                device)
                    adb_status="${C_GREEN}${d_ser} (online)${C_RESET}"
                    ;;
                recovery)
                    adb_status="${C_CYAN}${d_ser} (recovery)${C_RESET}"
                    ;;
                sideload)
                    adb_status="${C_YELLOW}${d_ser} (sideload)${C_RESET}"
                    ;;
                unauthorized)
                    adb_status="${C_RED}${d_ser} (unauthorized)${C_RESET}"
                    ;;
                *)
                    adb_status="${C_YELLOW}${d_ser} (${d_st})${C_RESET}"
                    ;;
            esac
        fi
    else
        adb_status="${C_RED}ADB Not Found${C_RESET}"
    fi

    echo -e "${C_WHITE}${C_BOLD}System Status:${C_RESET}"
    echo -e "  Toolchain  : ${tc_status}"
    echo -e "  Config     : ${cfg_status}"
    echo -e "  Image      : ${img_status}"
    echo -e "  AnyKernel3 : ${anyk_status}"
    echo -e "  ADB Device : ${adb_status}"
    echo -e "${C_CYAN}--------------------------------------------------------------------------------${C_RESET}"
}

press_enter() {
    echo ""
    echo -en "${C_YELLOW}Press [ENTER] to continue...${C_RESET}"
    read -r _ || true
}

prompt_confirm() {
    local prompt_msg="$1"
    local default_choice="${2:-N}"
    local ans=""

    if [[ "${default_choice}" == "Y" || "${default_choice}" == "y" ]]; then
        echo -en "${C_YELLOW}${prompt_msg} [Y/n]: ${C_RESET}"
    else
        echo -en "${C_YELLOW}${prompt_msg} [y/N]: ${C_RESET}"
    fi

    read -r ans || true
    ans="${ans:-${default_choice}}"

    if [[ "${ans}" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# ENVIRONMENT SANITY & INITIALIZATION
# ------------------------------------------------------------------------------
ensure_environment_sanity() {
    # 1. Ensure min-tool-version.sh exists if required by Kbuild scripts
    if [[ ! -f "${KERNEL_DIR}/scripts/min-tool-version.sh" ]]; then
        cat << 'EOF' > "${KERNEL_DIR}/scripts/min-tool-version.sh"
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
if [ $# -lt 1 ]; then
    echo "$0: missing argument" >&2
    exit 1
fi
case "$1" in
binutils) echo 2.23.0 ;;
gcc)      echo 4.9.0 ;;
llvm)     echo 10.0.1 ;;
rustc)    echo 1.62.0 ;;
bindgen)  echo 0.56.0 ;;
*)        echo "$1: unknown tool" >&2; exit 1 ;;
esac
EOF
        chmod +x "${KERNEL_DIR}/scripts/min-tool-version.sh" 2>/dev/null || true
    fi

    # 2. Initialize project workspace structure
    mkdir -p "${PATCHES_DIR}" "${CONFIGS_DIR}" "${RELEASE_DIR}" "${TOOLCHAIN_DIR}"

    # 3. Create brief instructional placeholder READMEs
    if [[ ! -f "${PATCHES_DIR}/README.txt" ]]; then
        cat << 'EOF' > "${PATCHES_DIR}/README.txt"
Place your patch files (*.patch or *.diff) here.
builder.sh will automatically scan and dry-run test them in Menu [4].
EOF
    fi

    if [[ ! -f "${CONFIGS_DIR}/README.txt" ]]; then
        cat << 'EOF' > "${CONFIGS_DIR}/README.txt"
Place custom kernel config fragments (*.config or *_defconfig) here.
builder.sh will merge them cleanly via merge_config.sh in Menu [3].
EOF
    fi
}

# ------------------------------------------------------------------------------
# CONFIGURATION LOADER & ENVIRONMENT SETUP
# ------------------------------------------------------------------------------
load_config() {
    ensure_environment_sanity

    # Default parameters
    TOOLCHAIN_TYPE="Neutron-Clang"
    TOOLCHAIN_PATH="${TOOLCHAIN_DIR}/neutron-clang"
    USE_LLVM=1
    CC_COMPILER="clang"
    CROSS_COMPILE_64="aarch64-linux-gnu-"
    CROSS_COMPILE_32="arm-linux-gnueabi-"
    EXTRA_MAKE_FLAGS=()

    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONF_FILE}" || true
    fi

    ACTIVE_TOOLCHAIN_TYPE="${TOOLCHAIN_TYPE}"

    # Prepend PATH if custom toolchain binary directory exists
    if [[ -d "${TOOLCHAIN_PATH}/bin" ]]; then
        if [[ ":${PATH}:" != *":${TOOLCHAIN_PATH}/bin:"* ]]; then
            export PATH="${TOOLCHAIN_PATH}/bin:${PATH}"
        fi
    fi
}

save_config() {
    cat <<EOF > "${CONF_FILE}"
# Antigravity SDM845 Kernel Builder Configuration
TOOLCHAIN_TYPE="${TOOLCHAIN_TYPE}"
TOOLCHAIN_PATH="${TOOLCHAIN_PATH}"
USE_LLVM="${USE_LLVM}"
CC_COMPILER="${CC_COMPILER}"
CROSS_COMPILE_64="${CROSS_COMPILE_64}"
CROSS_COMPILE_32="${CROSS_COMPILE_32}"
EOF
}

setup_make_flags() {
    MAKE_FLAGS=(
        "ARCH=${ARCH}"
        "SUBARCH=${SUBARCH}"
        "O=${OUT_DIR}"
    )

    if [[ "${USE_LLVM}" -eq 1 ]]; then
        MAKE_FLAGS+=(
            "CC=${CC_COMPILER}"
            "CLANG_TRIPLE=${CROSS_COMPILE_64}"
            "CROSS_COMPILE=${CROSS_COMPILE_64}"
            "CROSS_COMPILE_ARM32=${CROSS_COMPILE_32}"
            "LLVM=1"
            "LLVM_IAS=1"
        )
        if command -v ld.lld >/dev/null 2>&1; then
            MAKE_FLAGS+=("LD=ld.lld")
        fi
        if command -v llvm-ar >/dev/null 2>&1; then
            MAKE_FLAGS+=("AR=llvm-ar")
        fi
        if command -v llvm-nm >/dev/null 2>&1; then
            MAKE_FLAGS+=("NM=llvm-nm")
        fi
        if command -v llvm-objcopy >/dev/null 2>&1; then
            MAKE_FLAGS+=("OBJCOPY=llvm-objcopy")
        fi
        if command -v llvm-objdump >/dev/null 2>&1; then
            MAKE_FLAGS+=("OBJDUMP=llvm-objdump")
        fi
        if command -v llvm-strip >/dev/null 2>&1; then
            MAKE_FLAGS+=("STRIP=llvm-strip")
        fi
    else
        MAKE_FLAGS+=(
            "CC=${CC_COMPILER}"
            "CROSS_COMPILE=${CROSS_COMPILE_64}"
            "CROSS_COMPILE_ARM32=${CROSS_COMPILE_32}"
        )
    fi
}

# ------------------------------------------------------------------------------
# MENU 0: OPEN MENUCONFIG
# ------------------------------------------------------------------------------
menu_open_menuconfig() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== [0] Open Menuconfig ===${C_RESET}\n"

    mkdir -p "${OUT_DIR}"

    local config_path="${OUT_DIR}/.config"
    if [[ ! -f "${config_path}" ]]; then
        if [[ -f "${KERNEL_DIR}/.config" ]]; then
            log_info "Found .config in root directory, copying to ${OUT_DIR}/.config..."
            cp "${KERNEL_DIR}/.config" "${OUT_DIR}/.config"
        else
            log_warn ".config file not found!"
            echo -e "Before opening menuconfig, the kernel requires a base configuration for Pocophone F1."
            if prompt_confirm "Would you like to generate and merge default beryllium defconfig now?" "Y"; then
                apply_base_beryllium_config
            else
                log_error "Aborting menuconfig because base configuration is missing."
                press_enter
                return 0
            fi
        fi
    fi

    setup_make_flags

    echo ""
    echo -e "${C_CYAN}Select configuration interface:${C_RESET}"
    echo "  1) menuconfig (Standard ncurses TUI)"
    echo "  2) nconfig    (Modern ncurses TUI with symbol search)"
    echo "  3) Return to Main Menu"
    echo ""
    echo -en "${C_YELLOW}Select option [1-3] (default 1): ${C_RESET}"
    local ui_choice
    read -r ui_choice || true
    ui_choice="${ui_choice:-1}"

    local target_cmd="menuconfig"
    case "${ui_choice}" in
        1) target_cmd="menuconfig" ;;
        2) target_cmd="nconfig" ;;
        3) return 0 ;;
        *) target_cmd="menuconfig" ;;
    esac

    log_info "Opening ${target_cmd} with flags: ARCH=${ARCH} O=${OUT_DIR}..."
    sleep 1

    if make "${MAKE_FLAGS[@]}" "${target_cmd}"; then
        log_success "Kernel .config updated successfully!"
        if prompt_confirm "Would you like to save this configuration as a fragment in ./configs/custom_saved.config?" "N"; then
            mkdir -p "${CONFIGS_DIR}"
            make "${MAKE_FLAGS[@]}" savedefconfig
            if [[ -f "${OUT_DIR}/defconfig" ]]; then
                cp "${OUT_DIR}/defconfig" "${CONFIGS_DIR}/custom_saved.config"
                log_success "Saved to ${CONFIGS_DIR}/custom_saved.config"
            else
                cp "${OUT_DIR}/.config" "${CONFIGS_DIR}/custom_saved.config"
                log_success "Saved to ${CONFIGS_DIR}/custom_saved.config"
            fi
        fi
    else
        log_error "Failed to launch ${target_cmd}!"
        log_warn "Please ensure ncurses development libraries are installed (Menu 2: Install Dependencies)."
    fi

    press_enter
}

# ------------------------------------------------------------------------------
# MENU 1: SETUP TOOLCHAINS
# ------------------------------------------------------------------------------
menu_setup_toolchain() {
    while true; do
        print_header
        echo -e "${C_BOLD}${C_BLUE}=== [1] Setup Toolchains ===${C_RESET}\n"
        echo -e "Active Toolchain : ${C_GREEN}${TOOLCHAIN_TYPE}${C_RESET}"
        echo -e "Toolchain Path   : ${C_YELLOW}${TOOLCHAIN_PATH}${C_RESET}"
        echo ""
        echo "Toolchain Configuration Options:"
        echo "  1) Download / Update Neutron Clang (Automated via Antman - Recommended)"
        echo "  2) Download AOSP Clang (Google Android Prebuilts)"
        echo "  3) Setup GNU GCC Toolchains (AArch64 + ARM32 Cross-Compilers)"
        echo "  4) Use System Toolchain (Host Clang/LLVM or GCC)"
        echo "  5) Set Custom Toolchain Directory Manually"
        echo "  6) Verify Current Compiler Status & Version"
        echo "  0) Done / Return to Main Menu"
        echo ""
        echo -en "${C_YELLOW}Select option [0-6]: ${C_RESET}"
        local tc_choice
        read -r tc_choice || true

        case "${tc_choice}" in
            1)
                setup_neutron_clang
                ;;
            2)
                setup_aosp_clang
                ;;
            3)
                setup_gcc_cross
                ;;
            4)
                setup_system_toolchain
                ;;
            5)
                setup_custom_toolchain
                ;;
            6)
                verify_compiler_version
                press_enter
                ;;
            0)
                break
                ;;
            *)
                log_error "Invalid selection!"
                sleep 1
                ;;
        esac
    done
}

setup_neutron_clang() {
    log_info "Configuring Neutron Clang Toolchain..."
    local target_dir="${TOOLCHAIN_DIR}/neutron-clang"
    mkdir -p "${target_dir}"

    echo -e "${C_CYAN}Downloading official Antman installer (Neutron Toolchains)...${C_RESET}"
    local antman_bin="${target_dir}/antman"
    if ! curl -fsSL "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman" -o "${antman_bin}"; then
        log_error "Failed to download antman installer! Please check your network connection."
        press_enter
        return 0
    fi
    chmod +x "${antman_bin}"

    log_info "Synchronizing Neutron Clang via antman (this may take a few minutes)..."
    (
        cd "${target_dir}"
        bash ./antman -S
        # Check glibc compatibility on older host environments
        bash ./antman --patch=glibc || true
    )

    if [[ -f "${target_dir}/bin/clang" ]]; then
        TOOLCHAIN_TYPE="Neutron-Clang"
        TOOLCHAIN_PATH="${target_dir}"
        USE_LLVM=1
        CC_COMPILER="clang"
        CROSS_COMPILE_64="aarch64-linux-gnu-"
        CROSS_COMPILE_32="arm-linux-gnueabi-"
        save_config
        load_config
        log_success "Neutron Clang successfully installed and activated!"
    else
        log_error "Clang binary verification failed in ${target_dir}/bin!"
    fi
    press_enter
}

setup_aosp_clang() {
    log_info "Configuring AOSP Clang Prebuilts..."
    local target_dir="${TOOLCHAIN_DIR}/aosp-clang"
    mkdir -p "${target_dir}"

    echo -e "${C_YELLOW}Select AOSP Clang version/branch:${C_RESET}"
    echo "  1) Clang r487747c (Android 14 standard)"
    echo "  2) Clang r416183b (Android 12/13 standard)"
    echo "  3) Custom Git Clone URL"
    echo -en "${C_YELLOW}Selection [1-3]: ${C_RESET}"
    local c_opt
    read -r c_opt || true

    local clang_branch="master"
    local repo_url=""
    case "${c_opt}" in
        1)
            repo_url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
            clang_branch="clang-r487747c"
            ;;
        2)
            repo_url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
            clang_branch="clang-r416183b"
            ;;
        3)
            echo -en "${C_YELLOW}Enter Git Repository URL: ${C_RESET}"
            read -r repo_url || true
            echo -en "${C_YELLOW}Enter Branch Name: ${C_RESET}"
            read -r clang_branch || true
            ;;
        *)
            log_error "Invalid selection!"
            press_enter
            return 0
            ;;
    esac

    if prompt_confirm "Clone AOSP Clang to ${target_dir}? (Download size may exceed 1GB)" "Y"; then
        log_info "Cloning ${repo_url} branch ${clang_branch}..."
        rm -rf "${target_dir}"
        if git clone --depth=1 -b "${clang_branch}" "${repo_url}" "${target_dir}"; then
            TOOLCHAIN_TYPE="AOSP-Clang"
            TOOLCHAIN_PATH="${target_dir}"
            USE_LLVM=1
            CC_COMPILER="clang"
            CROSS_COMPILE_64="aarch64-linux-gnu-"
            CROSS_COMPILE_32="arm-linux-gnueabi-"
            save_config
            load_config
            log_success "AOSP Clang successfully configured!"
        else
            log_error "Failed to clone AOSP Clang repository!"
        fi
    fi
    press_enter
}

setup_gcc_cross() {
    log_info "Configuring GNU GCC Cross Compilers..."
    echo "Ensure GCC AArch64 & ARM32 toolchain binaries are available on your system or directory."
    echo -en "${C_YELLOW}Enter GCC AArch64 bin directory path (e.g. /opt/gcc-arm64/bin): ${C_RESET}"
    local p64
    read -r p64 || true

    if [[ -d "${p64}" ]]; then
        export PATH="${p64}:${PATH}"
        TOOLCHAIN_TYPE="GCC-Arm64"
        TOOLCHAIN_PATH="$(dirname "${p64}")"
        USE_LLVM=0
        CC_COMPILER="aarch64-linux-gnu-gcc"
        CROSS_COMPILE_64="aarch64-linux-gnu-"
        CROSS_COMPILE_32="arm-linux-gnueabi-"
        save_config
        load_config
        log_success "GCC Cross Compiler settings saved!"
    else
        log_error "Directory does not exist: ${p64}"
    fi
    press_enter
}

setup_system_toolchain() {
    log_info "Checking host system compilers..."
    if command -v clang >/dev/null 2>&1; then
        echo -e "Found host Clang: ${C_GREEN}$(clang --version | head -n1)${C_RESET}"
        TOOLCHAIN_TYPE="System-Clang"
        TOOLCHAIN_PATH="/usr"
        USE_LLVM=1
        CC_COMPILER="clang"
        CROSS_COMPILE_64="aarch64-linux-gnu-"
        CROSS_COMPILE_32="arm-linux-gnueabi-"
        save_config
        load_config
        log_success "Host system Clang/LLVM toolchain activated!"
    elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        echo -e "Found host GCC AArch64: ${C_GREEN}$(aarch64-linux-gnu-gcc --version | head -n1)${C_RESET}"
        TOOLCHAIN_TYPE="System-GCC"
        TOOLCHAIN_PATH="/usr"
        USE_LLVM=0
        CC_COMPILER="aarch64-linux-gnu-gcc"
        CROSS_COMPILE_64="aarch64-linux-gnu-"
        CROSS_COMPILE_32="arm-linux-gnueabi-"
        save_config
        load_config
        log_success "Host system GCC toolchain activated!"
    else
        log_error "Neither host Clang nor ARM64 GCC compiler detected!"
    fi
    press_enter
}

setup_custom_toolchain() {
    echo -en "${C_YELLOW}Enter absolute toolchain root path (must contain a 'bin' subdirectory): ${C_RESET}"
    local custom_path
    read -r custom_path || true

    if [[ -d "${custom_path}/bin" ]]; then
        TOOLCHAIN_TYPE="Custom-Path"
        TOOLCHAIN_PATH="${custom_path}"
        if [[ -f "${custom_path}/bin/clang" ]]; then
            USE_LLVM=1
            CC_COMPILER="clang"
        else
            USE_LLVM=0
            CC_COMPILER="aarch64-linux-gnu-gcc"
        fi
        CROSS_COMPILE_64="aarch64-linux-gnu-"
        CROSS_COMPILE_32="arm-linux-gnueabi-"
        save_config
        load_config
        log_success "Custom toolchain path configured: ${custom_path}"
    else
        log_error "Directory '${custom_path}/bin' not found!"
    fi
    press_enter
}

verify_compiler_version() {
    echo -e "\n${C_BOLD}${C_CYAN}--- Compiler Verification ---${C_RESET}"
    echo "PATH: ${PATH}"
    echo ""
    if [[ "${USE_LLVM}" -eq 1 ]]; then
        if command -v clang >/dev/null 2>&1; then
            echo -e "${C_GREEN}Clang executable found:${C_RESET}"
            clang --version | head -n 2
        else
            echo -e "${C_RED}'clang' command not found in PATH!${C_RESET}"
        fi

        if command -v ld.lld >/dev/null 2>&1; then
            echo -e "${C_GREEN}LLD Linker found:${C_RESET} $(ld.lld --version | head -n1)"
        else
            echo -e "${C_YELLOW}Notice: ld.lld not found in PATH (will fallback if needed).${C_RESET}"
        fi
    else
        if command -v "${CC_COMPILER}" >/dev/null 2>&1; then
            echo -e "${C_GREEN}GCC executable found:${C_RESET}"
            "${CC_COMPILER}" --version | head -n 1
        else
            echo -e "${C_RED}'${CC_COMPILER}' command not found in PATH!${C_RESET}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# MENU 2: INSTALL DEPENDENCIES
# ------------------------------------------------------------------------------
menu_install_dependencies() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== [2] Install Dependencies ===${C_RESET}\n"

    local pkg_manager=""
    if command -v pacman >/dev/null 2>&1; then
        pkg_manager="pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        pkg_manager="apt"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v zypper >/dev/null 2>&1; then
        pkg_manager="zypper"
    else
        pkg_manager="unknown"
    fi

    log_info "Detected Package Manager: ${C_GREEN}${pkg_manager}${C_RESET}"

    local packages=()
    local missing_pkgs=()

    case "${pkg_manager}" in
        pacman)
            packages=(
                "base-devel" "bc" "bison" "flex" "openssl" "make"
                "zip" "curl" "git" "libelf" "ncurses" "python"
                "ccache" "lld" "llvm" "clang" "aarch64-linux-gnu-binutils"
                "android-tools"
            )
            echo -e "${C_CYAN}Checking system packages (Arch Linux / Pacman)...${C_RESET}\n"
            for pkg in "${packages[@]}"; do
                if pacman -Qq "${pkg}" >/dev/null 2>&1; then
                    echo -e "  [ ${C_GREEN}INSTALLED${C_RESET} ]  ${pkg}"
                else
                    echo -e "  [ ${C_RED}MISSING  ${C_RESET} ]  ${pkg}"
                    missing_pkgs+=("${pkg}")
                fi
            done
            ;;

        apt)
            packages=(
                "build-essential" "bc" "bison" "flex" "libssl-dev" "make"
                "zip" "curl" "git" "libelf-dev" "libncurses-dev" "python3"
                "ccache" "lld" "llvm" "clang" "binutils-aarch64-linux-gnu"
                "adb"
            )
            echo -e "${C_CYAN}Checking system packages (Debian / Ubuntu / APT)...${C_RESET}\n"
            for pkg in "${packages[@]}"; do
                if dpkg -s "${pkg}" >/dev/null 2>&1; then
                    echo -e "  [ ${C_GREEN}INSTALLED${C_RESET} ]  ${pkg}"
                else
                    echo -e "  [ ${C_RED}MISSING  ${C_RESET} ]  ${pkg}"
                    missing_pkgs+=("${pkg}")
                fi
            done
            ;;

        *)
            log_warn "Package manager '${pkg_manager}' is not automatically supported."
            echo "Essential packages required for manual installation:"
            echo "build-essential/base-devel, bc, bison, flex, libssl-dev/openssl, make, zip, curl, git, libelf, ncurses, python, clang, lld"
            press_enter
            return 0
            ;;
    esac

    echo ""
    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        log_success "All essential build dependencies are already installed!"
    else
        log_warn "Found ${#missing_pkgs[@]} missing package(s): ${missing_pkgs[*]}"
        if prompt_confirm "Would you like to install missing dependencies now? (requires sudo)" "Y"; then
            case "${pkg_manager}" in
                pacman)
                    sudo pacman -Sy --needed "${missing_pkgs[@]}"
                    ;;
                apt)
                    sudo apt update && sudo apt install -y "${missing_pkgs[@]}"
                    ;;
            esac
            log_success "Package installation completed!"
        else
            log_info "Installation cancelled by user."
        fi
    fi

    press_enter
}

# ------------------------------------------------------------------------------
# MENU 3: APPLY CUSTOM CONFIGURATION
# ------------------------------------------------------------------------------
apply_base_beryllium_config() {
    mkdir -p "${OUT_DIR}"

    if [[ ! -f "${BASE_DEFCONFIG}" ]]; then
        log_error "Base defconfig file not found: ${BASE_DEFCONFIG}"
        return 1
    fi
    if [[ ! -f "${COMMON_CONFIG}" ]]; then
        log_error "Common config file not found: ${COMMON_CONFIG}"
        return 1
    fi
    if [[ ! -f "${BERYLLIUM_CONFIG}" ]]; then
        log_error "Beryllium config file not found: ${BERYLLIUM_CONFIG}"
        return 1
    fi

    log_info "Merging base defconfig for Pocophone F1 (beryllium):"
    echo "  1) ${BASE_DEFCONFIG}"
    echo "  2) ${COMMON_CONFIG}"
    echo "  3) ${BERYLLIUM_CONFIG}"

    if [[ ! -x "scripts/kconfig/merge_config.sh" ]]; then
        chmod +x scripts/kconfig/merge_config.sh || true
    fi

    setup_make_flags

    ARCH="${ARCH}" scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" \
        "${BASE_DEFCONFIG}" \
        "${COMMON_CONFIG}" \
        "${BERYLLIUM_CONFIG}"

    log_info "Executing olddefconfig for Kconfig dependency synchronization..."
    make "${MAKE_FLAGS[@]}" olddefconfig

    if [[ -f "${OUT_DIR}/.config" ]]; then
        log_success "Beryllium default defconfig successfully merged to ${OUT_DIR}/.config!"
        local check_mach
        check_mach=$(grep "CONFIG_MACH_XIAOMI_E10=y" "${OUT_DIR}/.config" || true)
        if [[ -n "${check_mach}" ]]; then
            log_info "Hardware target verified: Xiaomi E10 (Beryllium) enabled."
        fi
        return 0
    else
        log_error "Failed to generate ${OUT_DIR}/.config!"
        return 1
    fi
}

menu_apply_config() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== [3] Apply Custom Configuration ===${C_RESET}\n"

    echo "1. Loading Beryllium Base Configuration"
    if ! apply_base_beryllium_config; then
        press_enter
        return 0
    fi

    echo ""
    echo -e "${C_CYAN}2. Scan & Apply Additional Configuration Fragments (.config / fragments)${C_RESET}"
    mkdir -p "${CONFIGS_DIR}"

    local config_fragments=()
    while IFS= read -r -d '' cfg; do
        config_fragments+=("${cfg}")
    done < <(find "${CONFIGS_DIR}" -maxdepth 2 -type f \( -name "*.config" -o -name "*_defconfig" \) -print0 2>/dev/null || true)

    if [[ ${#config_fragments[@]} -gt 0 ]]; then
        echo -e "Found ${#config_fragments[@]} custom fragment file(s) in '${CONFIGS_DIR}':"
        local i=1
        for cfg in "${config_fragments[@]}"; do
            echo "  $((i))) $(basename "${cfg}") (${cfg})"
            i=$((i + 1))
        done
        echo ""
        if prompt_confirm "Would you like to merge one of these fragments?" "Y"; then
            echo -en "${C_YELLOW}Select fragment number [1-${#config_fragments[@]}]: ${C_RESET}"
            local sel
            read -r sel || true
            if [[ "${sel}" =~ ^[0-9]+$ ]] && [[ "${sel}" -ge 1 ]] && [[ "${sel}" -le ${#config_fragments[@]} ]]; then
                local chosen_frag="${config_fragments[$((sel - 1))]}"
                log_info "Merging fragment: ${chosen_frag}..."
                ARCH="${ARCH}" scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" \
                    "${OUT_DIR}/.config" \
                    "${chosen_frag}"
                make "${MAKE_FLAGS[@]}" olddefconfig
                log_success "Fragment '${chosen_frag}' merged without damaging base configuration!"
            else
                log_error "Invalid selection!"
            fi
        fi
    else
        log_info "Directory '${CONFIGS_DIR}' is currently empty."
        echo "You can place fragment files (e.g. lxc.config, debug.config, oc.config) into '${CONFIGS_DIR}'."
        if prompt_confirm "Would you like to enter a custom config fragment path manually?" "N"; then
            echo -en "${C_YELLOW}Enter absolute/relative path to config fragment: ${C_RESET}"
            local manual_cfg
            read -r manual_cfg || true
            if [[ -f "${manual_cfg}" ]]; then
                log_info "Merging custom fragment: ${manual_cfg}..."
                ARCH="${ARCH}" scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" \
                    "${OUT_DIR}/.config" \
                    "${manual_cfg}"
                make "${MAKE_FLAGS[@]}" olddefconfig
                log_success "Fragment merged successfully!"
            else
                log_error "File not found: ${manual_cfg}"
            fi
        fi
    fi

    press_enter
}

# ------------------------------------------------------------------------------
# MENU 4: APPLY PATCH
# ------------------------------------------------------------------------------
apply_single_patch_file() {
    local target_patch="$1"
    local patch_name
    patch_name="$(basename "${target_patch}")"

    echo -e "\n${C_BOLD}${C_CYAN}--- Patch Details: ${patch_name} ---${C_RESET}"
    echo "Path: ${target_patch}"

    local status="CONFLICT"
    if git apply --check "${target_patch}" >/dev/null 2>&1; then
        status="CAN_APPLY"
    elif git apply --reverse --check "${target_patch}" >/dev/null 2>&1; then
        status="ALREADY_APPLIED"
    elif git apply --ignore-whitespace --check "${target_patch}" >/dev/null 2>&1; then
        status="CAN_APPLY_WHITESPACE"
    elif git apply --3way --check "${target_patch}" >/dev/null 2>&1; then
        status="CAN_APPLY_3WAY"
    else
        status="CONFLICT"
    fi

    echo -e "Dry-Run Status: ${C_YELLOW}${status}${C_RESET}\n"

    case "${status}" in
        CAN_APPLY)
            if prompt_confirm "Apply patch '${patch_name}'?" "Y"; then
                if git apply -v "${target_patch}"; then
                    log_success "Patch applied successfully!"
                else
                    log_error "Failed to apply patch!"
                fi
            fi
            ;;
        CAN_APPLY_WHITESPACE)
            echo -e "${C_CYAN}Notice: Patch has whitespace differences but can apply cleanly with --ignore-whitespace.${C_RESET}"
            if prompt_confirm "Apply with '--ignore-whitespace'?" "Y"; then
                if git apply --ignore-whitespace -v "${target_patch}"; then
                    log_success "Patch applied successfully!"
                else
                    log_error "Failed to apply patch!"
                fi
            fi
            ;;
        CAN_APPLY_3WAY)
            echo -e "${C_CYAN}Notice: Patch requires 3-way merge (--3way).${C_RESET}"
            if prompt_confirm "Apply with '--3way'?" "Y"; then
                if git apply --3way -v "${target_patch}"; then
                    log_success "Patch applied successfully with 3-way merge!"
                else
                    log_error "Failed to apply patch with 3-way merge!"
                fi
            fi
            ;;
        ALREADY_APPLIED)
            log_warn "This patch was detected as ALREADY APPLIED to the current working tree."
            echo "Options:"
            echo "  1) Revert patch (git apply -R)"
            echo "  2) Cancel / Do nothing"
            echo -en "${C_YELLOW}Select option [1-2, default 2]: ${C_RESET}"
            local rev_choice
            read -r rev_choice || true
            if [[ "${rev_choice}" == "1" ]]; then
                if git apply -R -v "${target_patch}"; then
                    log_success "Patch reverted successfully!"
                else
                    log_error "Failed to revert patch!"
                fi
            fi
            ;;
        CONFLICT)
            log_error "Dry-run check failed with CONFLICT!"
            echo -e "${C_CYAN}Conflict details:${C_RESET}"
            echo "--------------------------------------------------------------------------------"
            git apply --check -v "${target_patch}" 2>&1 | head -n 25 || true
            echo "--------------------------------------------------------------------------------"
            echo ""
            echo "Advanced Application Options:"
            echo "  1) Try with 3-way merge (--3way)"
            echo "  2) Try with ignore whitespace (--ignore-whitespace)"
            echo "  3) Apply and output rejects (--reject)"
            echo "  0) Cancel"
            echo -en "${C_YELLOW}Select option [0-3]: ${C_RESET}"
            local adv_choice
            read -r adv_choice || true
            case "${adv_choice}" in
                1)
                    if git apply --3way -v "${target_patch}"; then
                        log_success "Patch applied with --3way!"
                    else
                        log_error "3-way merge failed!"
                    fi
                    ;;
                2)
                    if git apply --ignore-whitespace -v "${target_patch}"; then
                        log_success "Patch applied with --ignore-whitespace!"
                    else
                        log_error "Failed with --ignore-whitespace!"
                    fi
                    ;;
                3)
                    if git apply --reject -v "${target_patch}"; then
                        log_warn "Patch applied with rejects (*.rej files created)!"
                    else
                        log_error "Failed to apply with rejects!"
                    fi
                    ;;
                *)
                    log_info "Application cancelled."
                    ;;
            esac
            ;;
    esac
}

import_nethunter_patches() {
    local nh_dir="${KERNEL_DIR}/kali-nethunter-kernel-builder/patches/4.19"
    if [[ ! -d "${nh_dir}" ]]; then
        log_warn "Directory not found: ${nh_dir}"
        return 0
    fi

    echo -e "\n${C_BOLD}${C_CYAN}--- Available Kali NetHunter 4.19 Patches ---${C_RESET}"
    local nh_patches=()
    while IFS= read -r -d '' f; do
        nh_patches+=("${f}")
    done < <(find "${nh_dir}" -maxdepth 1 -type f -name "*.patch" -print0 2>/dev/null | sort -z)

    if [[ ${#nh_patches[@]} -eq 0 ]]; then
        log_warn "No patch files found in ${nh_dir}"
        return 0
    fi

    local i=1
    for p in "${nh_patches[@]}"; do
        printf "  %2d) %s\n" "${i}" "$(basename "${p}")"
        i=$((i + 1))
    done
    echo "   a) Import ALL patches to ./patches/"
    echo "   0) Cancel"
    echo ""
    echo -en "${C_YELLOW}Select patch to copy to ./patches/ [1-${#nh_patches[@]}, a, 0]: ${C_RESET}"
    local c_sel
    read -r c_sel || true

    if [[ "${c_sel}" =~ ^[0-9]+$ ]] && [[ "${c_sel}" -ge 1 ]] && [[ "${c_sel}" -le ${#nh_patches[@]} ]]; then
        local chosen_nh="${nh_patches[$((c_sel - 1))]}"
        cp -v "${chosen_nh}" "${PATCHES_DIR}/"
        log_success "Imported $(basename "${chosen_nh}") to ${PATCHES_DIR}/"
    elif [[ "${c_sel}" =~ ^[aA]$ ]]; then
        cp -v "${nh_patches[@]}" "${PATCHES_DIR}/"
        log_success "Imported all ${#nh_patches[@]} NetHunter patches to ${PATCHES_DIR}/"
    fi
}

menu_apply_patch() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== [4] Apply Patch ===${C_RESET}\n"

    mkdir -p "${PATCHES_DIR}"

    local raw_patches=()
    while IFS= read -r -d '' p; do
        raw_patches+=("${p}")
    done < <(find "${PATCHES_DIR}" -type f \( -name "*.patch" -o -name "*.diff" \) -print0 2>/dev/null || true)

    # Sort patches by file modification time (newest first)
    local patch_files=()
    if [[ ${#raw_patches[@]} -gt 0 ]]; then
        while IFS= read -r file; do
            [[ -n "${file}" && -f "${file}" ]] && patch_files+=("${file}")
        done < <(stat -c "%Y %n" "${raw_patches[@]}" 2>/dev/null | sort -k1 -n -r | cut -d' ' -f2- || true)
    fi

    declare -a patch_status

    if [[ ${#patch_files[@]} -gt 0 ]]; then
        echo -e "Scanning patch files in '${PATCHES_DIR}' (Newest first)...\n"
        printf "${C_BOLD}%-4s %-40s %-12s %-22s${C_RESET}\n" "NO" "PATCH NAME" "DATE" "STATUS"
        echo "--------------------------------------------------------------------------------"

        local idx=0
        for patch in "${patch_files[@]}"; do
            local patch_name
            patch_name="$(basename "${patch}")"
            local mod_date
            mod_date=$(date -r "${patch}" "+%m-%d %H:%M" 2>/dev/null || echo "N/A")
            local status_str=""

            if git apply --check "${patch}" >/dev/null 2>&1; then
                status_str="${C_GREEN}[ CAN APPLY ]${C_RESET}"
                patch_status[idx]="CAN_APPLY"
            elif git apply --reverse --check "${patch}" >/dev/null 2>&1; then
                status_str="${C_YELLOW}[ ALREADY APPLIED ]${C_RESET}"
                patch_status[idx]="ALREADY_APPLIED"
            elif git apply --ignore-whitespace --check "${patch}" >/dev/null 2>&1; then
                status_str="${C_CYAN}[ CAN APPLY (WS) ]${C_RESET}"
                patch_status[idx]="CAN_APPLY_WHITESPACE"
            elif git apply --3way --check "${patch}" >/dev/null 2>&1; then
                status_str="${C_CYAN}[ CAN APPLY (3WAY) ]${C_RESET}"
                patch_status[idx]="CAN_APPLY_3WAY"
            else
                status_str="${C_RED}[ CONFLICT / FAILED ]${C_RESET}"
                patch_status[idx]="CONFLICT"
            fi

            local tag=""
            if [[ ${idx} -eq 0 ]]; then
                tag=" ${C_GREEN}*NEW*${C_RESET}"
            fi

            printf "%-4d %-40s %-12s %b%b\n" "$((idx + 1))" "${patch_name:0:38}" "${mod_date}" "${status_str}" "${tag}"
            idx=$((idx + 1))
        done
        echo "--------------------------------------------------------------------------------"
    else
        log_warn "No *.patch or *.diff files found in '${PATCHES_DIR}'!"
        echo -e "Place your patches in '${PATCHES_DIR}' or use manual entry below."
        echo "--------------------------------------------------------------------------------"
    fi

    echo ""
    echo "Action Options:"
    if [[ ${#patch_files[@]} -gt 0 ]]; then
        echo "  1) Apply All 'CAN APPLY' Patches"
        echo "  2) Selectively Apply / Inspect a Specific Patch [1-${#patch_files[@]}]"
        echo "  3) Revert a Specific Patch (git apply -R)"
    fi
    echo "  4) Apply Custom Patch from Manual File Path"
    if [[ -d "${KERNEL_DIR}/kali-nethunter-kernel-builder/patches/4.19" ]]; then
        echo "  5) Browse & Import Patches from Kali NetHunter (4.19)"
    fi
    echo "  0) Return to Main Menu"
    echo ""
    echo -en "${C_YELLOW}Select option: ${C_RESET}"
    local patch_choice
    read -r patch_choice || true

    case "${patch_choice}" in
        1)
            if [[ ${#patch_files[@]} -eq 0 ]]; then
                log_error "No patches available to apply!"
            else
                local applied_count=0
                for i in "${!patch_files[@]}"; do
                    local st="${patch_status[i]}"
                    local p_file="${patch_files[i]}"
                    if [[ "${st}" == "CAN_APPLY" ]]; then
                        log_info "Applying: $(basename "${p_file}")..."
                        if git apply -v "${p_file}"; then
                            log_success "Applied: $(basename "${p_file}")"
                            applied_count=$((applied_count + 1))
                        else
                            log_error "Failed to apply: $(basename "${p_file}")"
                        fi
                    elif [[ "${st}" == "CAN_APPLY_WHITESPACE" ]]; then
                        log_info "Applying (ignore whitespace): $(basename "${p_file}")..."
                        if git apply --ignore-whitespace -v "${p_file}"; then
                            log_success "Applied: $(basename "${p_file}")"
                            applied_count=$((applied_count + 1))
                        fi
                    elif [[ "${st}" == "CAN_APPLY_3WAY" ]]; then
                        log_info "Applying (3-way merge): $(basename "${p_file}")..."
                        if git apply --3way -v "${p_file}"; then
                            log_success "Applied: $(basename "${p_file}")"
                            applied_count=$((applied_count + 1))
                        fi
                    fi
                done
                log_success "Complete! Total ${applied_count} patch(es) applied."
            fi
            ;;
        2)
            echo -en "${C_YELLOW}Enter patch number to apply/inspect [1-${#patch_files[@]}]: ${C_RESET}"
            local p_idx
            read -r p_idx || true
            if [[ "${p_idx}" =~ ^[0-9]+$ ]] && [[ "${p_idx}" -ge 1 ]] && [[ "${p_idx}" -le ${#patch_files[@]} ]]; then
                apply_single_patch_file "${patch_files[$((p_idx - 1))]}"
            else
                log_error "Invalid patch number!"
            fi
            ;;
        3)
            echo -en "${C_YELLOW}Enter patch number to revert [1-${#patch_files[@]}]: ${C_RESET}"
            local rev_idx
            read -r rev_idx || true
            if [[ "${rev_idx}" =~ ^[0-9]+$ ]] && [[ "${rev_idx}" -ge 1 ]] && [[ "${rev_idx}" -le ${#patch_files[@]} ]]; then
                local rev_patch="${patch_files[$((rev_idx - 1))]}"
                if prompt_confirm "Revert patch $(basename "${rev_patch}")?" "N"; then
                    if git apply -R -v "${rev_patch}"; then
                        log_success "Patch reverted successfully!"
                    else
                        log_error "Failed to revert patch!"
                    fi
                fi
            else
                log_error "Invalid patch number!"
            fi
            ;;
        4)
            echo -en "${C_YELLOW}Enter absolute/relative path to patch file: ${C_RESET}"
            local manual_p
            read -r manual_p || true
            if [[ -f "${manual_p}" ]]; then
                local real_p
                real_p="$(realpath "${manual_p}")"
                if prompt_confirm "Copy this patch to ${PATCHES_DIR}/ for future runs?" "Y"; then
                    cp "${real_p}" "${PATCHES_DIR}/"
                    log_success "Copied to ${PATCHES_DIR}/$(basename "${real_p}")"
                fi
                apply_single_patch_file "${real_p}"
            else
                log_error "File not found: ${manual_p}"
            fi
            ;;
        5)
            import_nethunter_patches
            ;;
        0)
            return 0
            ;;
        *)
            log_error "Invalid selection!"
            ;;
    esac

    press_enter
}

# ------------------------------------------------------------------------------
# MENU 5: BUILD KERNEL
# ------------------------------------------------------------------------------
menu_build_kernel() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== [5] Build Kernel ===${C_RESET}\n"

    # Toolchain verification
    setup_make_flags
    if [[ "${USE_LLVM}" -eq 1 ]]; then
        if ! command -v clang >/dev/null 2>&1; then
            log_error "Clang toolchain not installed or missing from PATH!"
            log_warn "Please run Menu [1] Setup Toolchains first."
            press_enter
            return 0
        fi
    else
        if ! command -v "${CC_COMPILER}" >/dev/null 2>&1; then
            log_error "Compiler ${CC_COMPILER} not found!"
            log_warn "Please run Menu [1] Setup Toolchains first."
            press_enter
            return 0
        fi
    fi

    # Config verification
    if [[ ! -f "${OUT_DIR}/.config" ]]; then
        log_error "Kernel configuration (${OUT_DIR}/.config) not found!"
        log_warn "Please run Menu [3] Apply Custom Configuration first."
        press_enter
        return 0
    fi

    # Clean build option
    if prompt_confirm "Do you want to perform a Clean Build (wipe previous compilation artifacts)?" "N"; then
        log_info "Cleaning build directory (${OUT_DIR})..."
        make "${MAKE_FLAGS[@]}" mrproper || true
        # Re-apply base configuration
        apply_base_beryllium_config
    fi

    local cores
    cores="$(nproc --all 2>/dev/null || echo 4)"
    echo -e "Detected CPU Cores: ${C_GREEN}${cores} Cores${C_RESET}"
    echo -en "${C_YELLOW}Number of parallel threads to use? (default: ${cores}): ${C_RESET}"
    local user_cores
    read -r user_cores || true
    user_cores="${user_cores:-${cores}}"

    local build_target="Image.gz-dtb"
    echo ""
    log_info "Compilation Target : ${C_GREEN}${build_target} dtbs${C_RESET}"
    log_info "Build Log File     : ${C_YELLOW}${BUILD_LOG}${C_RESET}"
    log_info "Output Directory   : ${C_CYAN}${OUT_DIR}${C_RESET}"
    echo ""

    if ! prompt_confirm "Start kernel compilation now?" "Y"; then
        log_info "Build cancelled by user."
        press_enter
        return 0
    fi

    # Initialize log file
    {
        echo "================================================================================"
        echo "BUILD STARTED: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "DEVICE       : ${DEVICE} (${DEVICE_NAME})"
        echo "BRANCH/COMMIT: $(git rev-parse --short HEAD 2>/dev/null || echo 'Unknown')"
        echo "COMPILER     : $(${CC_COMPILER} --version 2>/dev/null | head -n1 || echo 'Clang/GCC')"
        echo "THREADS      : ${user_cores}"
        echo "================================================================================"
    } > "${BUILD_LOG}"

    local start_time
    start_time=$(date +%s)

    echo -e "${C_CYAN}Compilation in progress... Monitor output below or run 'tail -f ${BUILD_LOG}'${C_RESET}\n"

    local build_success=0
    # Execute make piping to tee with set -o pipefail
    if make -j"${user_cores}" "${MAKE_FLAGS[@]}" "${build_target}" dtbs 2>&1 | tee -a "${BUILD_LOG}"; then
        build_success=1
    else
        build_success=0
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local el_min=$((elapsed / 60))
    local el_sec=$((elapsed % 60))

    echo ""
    echo "================================================================================"
    if [[ ${build_success} -eq 1 ]]; then
        local target_image="${OUT_DIR}/arch/arm64/boot/Image.gz-dtb"
        if [[ ! -f "${target_image}" ]]; then
            # Fallback if Image.gz and dtb were built separately
            if [[ -f "${OUT_DIR}/arch/arm64/boot/Image.gz" ]]; then
                target_image="${OUT_DIR}/arch/arm64/boot/Image.gz"
            elif [[ -f "${OUT_DIR}/arch/arm64/boot/Image" ]]; then
                target_image="${OUT_DIR}/arch/arm64/boot/Image"
            fi
        fi

        if [[ -f "${target_image}" ]]; then
            local file_size
            file_size=$(du -h "${target_image}" | cut -f1)
            local sha256_hash
            sha256_hash=$(sha256sum "${target_image}" | cut -d' ' -f1)

            log_success "Kernel Compilation Succeeded!"
            echo -e "  Output File  : ${C_GREEN}${target_image}${C_RESET}"
            echo -e "  File Size    : ${C_WHITE}${file_size}${C_RESET}"
            echo -e "  SHA256 Hash  : ${C_DIM}${sha256_hash}${C_RESET}"
            echo -e "  Build Time   : ${C_YELLOW}${el_min}m ${el_sec}s${C_RESET}"
        else
            log_error "Compilation succeeded but kernel image was not found in ${OUT_DIR}/arch/arm64/boot/!"
        fi
    else
        log_error "Kernel Compilation Failed! (Duration: ${el_min}m ${el_sec}s)"
        echo -e "Please inspect the last 25 lines of '${BUILD_LOG}':"
        echo "--------------------------------------------------------------------------------"
        tail -n 25 "${BUILD_LOG}" || true
        echo "--------------------------------------------------------------------------------"
    fi

    press_enter
}

# ------------------------------------------------------------------------------
# MENU 6: SETUP AND PACK TO ANYKERNEL
# ------------------------------------------------------------------------------
menu_setup_anykernel() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== [6] Setup and Pack to AnyKernel ===${C_RESET}\n"

    # Validate compiled kernel image
    local kernel_image=""
    if [[ -f "${OUT_DIR}/arch/arm64/boot/Image.gz-dtb" ]]; then
        kernel_image="${OUT_DIR}/arch/arm64/boot/Image.gz-dtb"
    elif [[ -f "${KERNEL_DIR}/arch/arm64/boot/Image.gz-dtb" ]]; then
        kernel_image="${KERNEL_DIR}/arch/arm64/boot/Image.gz-dtb"
    fi

    if [[ -z "${kernel_image}" || ! -f "${kernel_image}" ]]; then
        log_error "Kernel image (Image.gz-dtb) not found!"
        echo -e "${C_YELLOW}This menu requires a verified successful kernel compilation.${C_RESET}"
        echo "Please execute Menu [5] Build Kernel first."
        press_enter
        return 0
    fi

    log_success "Verified Kernel Image: ${kernel_image} ($(du -h "${kernel_image}" | cut -f1))"

    # Setup AnyKernel3 workspace
    if [[ ! -d "${ANYKERNEL_DIR}" || ! -f "${ANYKERNEL_DIR}/anykernel.sh" ]]; then
        log_warn "AnyKernel3 not found in ${ANYKERNEL_DIR}."
        if prompt_confirm "Would you like to clone official AnyKernel3 (osm0sis/AnyKernel3) now?" "Y"; then
            log_info "Cloning AnyKernel3 repository..."
            rm -rf "${ANYKERNEL_DIR}"
            if ! git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "${ANYKERNEL_DIR}"; then
                log_error "Failed to clone AnyKernel3! Please check your network connection."
                press_enter
                return 0
            fi
            log_success "AnyKernel3 cloned successfully!"
        else
            log_error "Packing cancelled by user."
            press_enter
            return 0
        fi
    fi

    # Automatic configuration of anykernel.sh for Pocophone F1 (beryllium)
    log_info "Configuring anykernel.sh for Pocophone F1 (beryllium)..."
    local anyk_script="${ANYKERNEL_DIR}/anykernel.sh"

    # Backup original anykernel.sh if present and not yet backed up
    if [[ -f "${anyk_script}" && ! -f "${anyk_script}.orig" ]]; then
        cp "${anyk_script}" "${anyk_script}.orig"
    fi

    # Generate dedicated beryllium AnyKernel3 configuration
    cat << 'EOF' > "${anyk_script}"
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Custom configuration for Xiaomi Pocophone F1 (beryllium)

### AnyKernel setup
# global properties
properties() { '
kernel.string=Kernel for POCO F1 (beryllium)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=beryllium
device.name2=Beryllium
device.name3=POCO F1
device.name4=Pocophone F1
device.name5=Poco F1
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;

# write new boot image
write_boot;
## end boot install
EOF
    chmod +x "${anyk_script}"

    # Clean old artifacts in AnyKernel directory
    rm -f "${ANYKERNEL_DIR}/Image.gz-dtb" "${ANYKERNEL_DIR}/Image.gz" "${ANYKERNEL_DIR}/Image" "${ANYKERNEL_DIR}/dtbo.img" "${ANYKERNEL_DIR}"/*.zip

    # Inject Image.gz-dtb
    log_info "Injecting Image.gz-dtb into AnyKernel3..."
    cp -v "${kernel_image}" "${ANYKERNEL_DIR}/Image.gz-dtb"

    # Inject dtbo.img if present
    if [[ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]]; then
        log_info "Injecting dtbo.img..."
        cp -v "${OUT_DIR}/arch/arm64/boot/dtbo.img" "${ANYKERNEL_DIR}/dtbo.img"
    fi

    # Prepare release output directory
    mkdir -p "${RELEASE_DIR}"

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local zip_name="Kernel-${DEVICE}-${timestamp}.zip"
    local zip_target="${RELEASE_DIR}/${zip_name}"

    log_info "Packaging AnyKernel3 flashable zip archive..."
    (
        cd "${ANYKERNEL_DIR}"
        zip -r9 "${zip_target}" ./* -x .git .gitignore "*.zip" "anykernel.sh.orig" "README.md"
    )

    if [[ -f "${zip_target}" ]]; then
        # Verify zip archive integrity
        if command -v unzip >/dev/null 2>&1; then
            unzip -tq "${zip_target}" >/dev/null 2>&1 || {
                log_error "Zip file integrity validation failed! Archive may be corrupted."
                press_enter
                return 0
            }
        fi

        local zip_sz
        zip_sz=$(du -h "${zip_target}" | cut -f1)
        local zip_sha
        zip_sha=$(sha256sum "${zip_target}" | cut -d' ' -f1)

        echo ""
        echo "================================================================================"
        log_success "Flashable AnyKernel3 Zip Created Successfully!"
        echo -e "  Output Package : ${C_GREEN}${zip_target}${C_RESET}"
        echo -e "  Package Size   : ${C_WHITE}${zip_sz}${C_RESET}"
        echo -e "  SHA256 Hash    : ${C_DIM}${zip_sha}${C_RESET}"
        echo "================================================================================"
        echo -e "${C_CYAN}This flashable zip is ready to be flashed via TWRP / OrangeFox Recovery on Pocophone F1.${C_RESET}"

        echo ""
        if prompt_confirm "Would you like to flash this AnyKernel package now via ADB?" "Y"; then
            flash_anykernel_package "${zip_target}"
            return 0
        fi
    else
        log_error "Failed to create flashable zip archive!"
    fi

    press_enter
}

# ------------------------------------------------------------------------------
# MENU 7: FLASH ANYKERNEL VIA ADB (LIVE ANDROID / RECOVERY)
# ------------------------------------------------------------------------------
SELECTED_ADB_SERIAL=""
SELECTED_ADB_STATE=""
SELECTED_ADB_MODEL=""
SELECTED_ADB_CODENAME=""
SELECTED_ANYKERNEL_ZIP=""

detect_adb_device() {
    SELECTED_ADB_SERIAL=""
    SELECTED_ADB_STATE=""
    SELECTED_ADB_MODEL=""
    SELECTED_ADB_CODENAME=""

    if ! command -v adb >/dev/null 2>&1; then
        log_error "ADB command not found on this system!"
        log_warn "Please install 'android-tools' (Arch) or 'adb' (Debian/Ubuntu) in Menu [2]."
        return 1
    fi

    log_info "Scanning for connected ADB devices..."
    adb start-server >/dev/null 2>&1 || true

    local raw_devs=()
    while IFS= read -r line; do
        if [[ -n "${line}" && ! "${line}" =~ ^List ]]; then
            raw_devs+=("${line}")
        fi
    done < <(adb devices 2>/dev/null || true)

    if [[ ${#raw_devs[@]} -eq 0 ]]; then
        log_warn "No ADB devices detected!"
        echo -e "${C_YELLOW}Please connect your Pocophone F1 via USB with 'USB Debugging' enabled.${C_RESET}"
        echo ""
        echo "  1) Retry ADB detection"
        echo "  2) Wait for device to connect (adb wait-for-device)"
        echo "  0) Cancel and return"
        echo ""
        echo -en "${C_YELLOW}Select option [0-2]: ${C_RESET}"
        local retry_choice
        read -r retry_choice || true
        case "${retry_choice}" in
            1)
                detect_adb_device
                return $?
                ;;
            2)
                log_info "Waiting for device to connect... (Press Ctrl+C to abort)"
                if adb wait-for-device; then
                    detect_adb_device
                    return $?
                else
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    fi

    local chosen_entry=""
    if [[ ${#raw_devs[@]} -eq 1 ]]; then
        chosen_entry="${raw_devs[0]}"
    else
        echo -e "\n${C_CYAN}Multiple ADB devices detected. Select target device:${C_RESET}"
        local idx=1
        for dev in "${raw_devs[@]}"; do
            echo "  ${idx}) ${dev}"
            idx=$((idx + 1))
        done
        echo "  0) Cancel"
        echo ""
        echo -en "${C_YELLOW}Select device [1-${#raw_devs[@]}]: ${C_RESET}"
        local sel
        read -r sel || true
        if [[ "${sel}" =~ ^[0-9]+$ ]] && [[ "${sel}" -ge 1 ]] && [[ "${sel}" -le ${#raw_devs[@]} ]]; then
            chosen_entry="${raw_devs[$((sel - 1))]}"
        else
            log_error "Invalid device selection!"
            return 1
        fi
    fi

    SELECTED_ADB_SERIAL=$(echo "${chosen_entry}" | awk '{print $1}')
    SELECTED_ADB_STATE=$(echo "${chosen_entry}" | awk '{print $2}')

    if [[ "${SELECTED_ADB_STATE}" == "unauthorized" ]]; then
        log_error "Device '${SELECTED_ADB_SERIAL}' is UNAUTHORIZED!"
        echo -e "${C_YELLOW}Please check your phone screen and allow USB debugging (check 'Always allow').${C_RESET}"
        if prompt_confirm "Retry connection after authorizing on phone?" "Y"; then
            detect_adb_device
            return $?
        else
            return 1
        fi
    fi

    if [[ "${SELECTED_ADB_STATE}" == "offline" ]]; then
        log_error "Device '${SELECTED_ADB_SERIAL}' is OFFLINE!"
        log_warn "Please reconnect the USB cable or run 'adb kill-server'."
        return 1
    fi

    if [[ "${SELECTED_ADB_STATE}" == "device" ]]; then
        SELECTED_ADB_MODEL=$(adb -s "${SELECTED_ADB_SERIAL}" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n' || true)
        SELECTED_ADB_CODENAME=$(adb -s "${SELECTED_ADB_SERIAL}" shell getprop ro.product.device 2>/dev/null | tr -d '\r\n' || true)
        if [[ -z "${SELECTED_ADB_CODENAME}" ]]; then
            SELECTED_ADB_CODENAME=$(adb -s "${SELECTED_ADB_SERIAL}" shell getprop ro.build.product 2>/dev/null | tr -d '\r\n' || true)
        fi
    fi

    log_success "ADB Device Connected: ${C_GREEN}${SELECTED_ADB_SERIAL}${C_RESET} [State: ${SELECTED_ADB_STATE}]"
    if [[ -n "${SELECTED_ADB_MODEL}" ]]; then
        echo -e "  Device Model   : ${C_GREEN}${SELECTED_ADB_MODEL}${C_RESET} (${SELECTED_ADB_CODENAME:-unknown})"
    fi

    return 0
}

select_anykernel_zip() {
    SELECTED_ANYKERNEL_ZIP=""

    local zip_candidates=()
    while IFS= read -r -d '' z; do
        zip_candidates+=("${z}")
    done < <(find "${RELEASE_DIR}" "${ANYKERNEL_DIR}" -maxdepth 1 -type f -name "*.zip" -print0 2>/dev/null || true)

    local sorted_zips=()
    if [[ ${#zip_candidates[@]} -gt 0 ]]; then
        while IFS= read -r file; do
            [[ -n "${file}" && -f "${file}" ]] && sorted_zips+=("${file}")
        done < <(stat -c "%Y %n" "${zip_candidates[@]}" 2>/dev/null | sort -k1 -n -r | cut -d' ' -f2- || true)
    fi

    if [[ ${#sorted_zips[@]} -eq 0 ]]; then
        log_warn "No AnyKernel zip archives found in '${RELEASE_DIR}' or '${ANYKERNEL_DIR}'!"
        echo ""
        echo "Options:"
        echo "  1) Package current build to AnyKernel now (Menu [6])"
        echo "  2) Specify custom zip file path manually"
        echo "  0) Cancel / Return to Main Menu"
        echo ""
        echo -en "${C_YELLOW}Select option [0-2]: ${C_RESET}"
        local no_z_choice
        read -r no_z_choice || true
        case "${no_z_choice}" in
            1)
                menu_setup_anykernel
                select_anykernel_zip
                return $?
                ;;
            2)
                echo -en "${C_YELLOW}Enter path to AnyKernel zip: ${C_RESET}"
                local manual_zip
                read -r manual_zip || true
                if [[ -f "${manual_zip}" ]]; then
                    SELECTED_ANYKERNEL_ZIP="$(realpath "${manual_zip}")"
                    return 0
                else
                    log_error "File not found: ${manual_zip}"
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    fi

    echo -e "${C_CYAN}Select AnyKernel Package to Flash:${C_RESET}"
    local idx=1
    for z in "${sorted_zips[@]}"; do
        local sz mod_time
        sz=$(du -h "${z}" | cut -f1)
        mod_time=$(date -r "${z}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")
        local tag=""
        if [[ ${idx} -eq 1 ]]; then
            tag=" ${C_GREEN}[LATEST]${C_RESET}"
        fi
        printf "  %2d) %-42s (%6s) [%s]%b\n" "${idx}" "$(basename "${z}")" "${sz}" "${mod_time}" "${tag}"
        idx=$((idx + 1))
    done
    echo "   m) Enter custom zip path manually"
    echo "   0) Cancel / Return"
    echo ""
    echo -en "${C_YELLOW}Select package [1-${#sorted_zips[@]}, default: 1]: ${C_RESET}"
    local zip_choice
    read -r zip_choice || true
    zip_choice="${zip_choice:-1}"

    if [[ "${zip_choice}" =~ ^[0-9]+$ ]] && [[ "${zip_choice}" -ge 1 ]] && [[ "${zip_choice}" -le ${#sorted_zips[@]} ]]; then
        SELECTED_ANYKERNEL_ZIP="${sorted_zips[$((zip_choice - 1))]}"
    elif [[ "${zip_choice}" =~ ^[mM]$ ]]; then
        echo -en "${C_YELLOW}Enter path to AnyKernel zip: ${C_RESET}"
        local manual_zip
        read -r manual_zip || true
        if [[ -f "${manual_zip}" ]]; then
            SELECTED_ANYKERNEL_ZIP="$(realpath "${manual_zip}")"
        else
            log_error "File not found: ${manual_zip}"
            return 1
        fi
    elif [[ "${zip_choice}" == "0" ]]; then
        return 1
    else
        log_error "Invalid selection!"
        return 1
    fi

    if command -v unzip >/dev/null 2>&1; then
        if ! unzip -tq "${SELECTED_ANYKERNEL_ZIP}" >/dev/null 2>&1; then
            log_error "Zip archive validation failed: '${SELECTED_ANYKERNEL_ZIP}' is corrupted!"
            return 1
        fi
    fi

    log_success "Selected Zip: $(basename "${SELECTED_ANYKERNEL_ZIP}")"
    return 0
}

flash_via_adb_shell() {
    local serial="$1"
    local zip_path="$2"

    echo -e "\n${C_BOLD}${C_CYAN}=== Automated Live Android Flash (ADB Shell) ===${C_RESET}\n"

    local android_ver curr_kernel codename model
    android_ver=$(adb -s "${serial}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r\n' || echo "Unknown")
    curr_kernel=$(adb -s "${serial}" shell uname -r 2>/dev/null | tr -d '\r\n' || echo "Unknown")
    codename=$(adb -s "${serial}" shell getprop ro.product.device 2>/dev/null | tr -d '\r\n' || true)
    [[ -z "${codename}" ]] && codename=$(adb -s "${serial}" shell getprop ro.build.product 2>/dev/null | tr -d '\r\n' || echo "Unknown")
    model=$(adb -s "${serial}" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n' || echo "Unknown")

    echo -e "Device Environment:"
    echo -e "  Device Model       : ${C_GREEN}${model}${C_RESET} (${codename})"
    echo -e "  Android Version    : ${C_GREEN}Android ${android_ver}${C_RESET}"
    echo -e "  Current Kernel     : ${C_YELLOW}${curr_kernel}${C_RESET}"
    echo -e "  Target Package     : ${C_WHITE}$(basename "${zip_path}")${C_RESET}"
    echo ""

    if [[ "${codename}" != "Unknown" && "${codename}" != "beryllium" && "${codename}" != "Beryllium" ]]; then
        log_warn "Detected device codename '${codename}' does not match '${DEVICE}'!"
        if ! prompt_confirm "Flashing the wrong kernel can softbrick the device. Continue anyway?" "N"; then
            log_info "Flashing cancelled by user."
            return 1
        fi
    fi

    log_info "Verifying root access for live kernel flashing..."
    local use_su=0
    local root_ok=0

    adb -s "${serial}" root 2>/dev/null || true
    sleep 1
    local uid_check
    uid_check=$(adb -s "${serial}" shell id -u 2>/dev/null | tr -d '\r\n' || echo "2000")
    if [[ "${uid_check}" == "0" ]]; then
        log_success "Root access granted via adbd root (uid 0)!"
        use_su=0
        root_ok=1
    else
        log_info "Testing Superuser ('su') access..."
        echo -e "${C_DIM}If prompted on your phone, please GRANT root permission to Shell.${C_RESET}"
        local su_check
        su_check=$(adb -s "${serial}" shell "su -c 'id -u'" 2>/dev/null | tr -d '\r\n' || echo "fail")
        if [[ "${su_check}" == "0" ]]; then
            log_success "Root access granted via 'su' (Magisk / KernelSU / APatch)!"
            use_su=1
            root_ok=1
        fi
    fi

    if [[ "${root_ok}" -ne 1 ]]; then
        log_error "Root permissions (su or adb root) could not be obtained!"
        echo -e "${C_YELLOW}Direct live flashing while Android is running requires root access to write /dev/block/bootdevice/by-name/boot.${C_RESET}"
        echo ""
        echo "Options:"
        echo "  1) Reboot device to Recovery (TWRP / OrangeFox) and flash there (Recommended without root)"
        echo "  2) Retry root check (if you just approved the prompt on your phone)"
        echo "  0) Cancel"
        echo ""
        echo -en "${C_YELLOW}Select option [0-2]: ${C_RESET}"
        local no_root_choice
        read -r no_root_choice || true
        case "${no_root_choice}" in
            1)
                log_info "Rebooting device to Recovery mode..."
                adb -s "${serial}" reboot recovery
                log_info "Waiting for device to enter recovery mode..."
                adb -s "${serial}" wait-for-recovery 2>/dev/null || sleep 12
                flash_via_recovery "${serial}" "${zip_path}"
                return $?
                ;;
            2)
                flash_via_adb_shell "${serial}" "${zip_path}"
                return $?
                ;;
            *)
                return 1
                ;;
        esac
    fi

    if ! prompt_confirm "Ready to flash kernel to boot partition via ADB shell. Proceed?" "Y"; then
        log_info "Flash aborted by user."
        return 1
    fi

    local host_tmp dev_tmp dev_ws dev_bin
    host_tmp=$(mktemp -d /tmp/ak3_live_flash_XXXXXX)
    dev_tmp="/data/local/tmp/ak3_flash"
    dev_ws="/data/local/tmp/ak3_workspace"
    dev_bin="/data/local/tmp/ak3_bin"

    log_info "Unpacking AnyKernel package on host..."
    unzip -q "${zip_path}" -d "${host_tmp}"

    # Patch live installer on host:
    # 1. Remove version constraint so Android 9 - 17+ are fully supported
    sed -i 's/^supported.versions=.*/supported.versions=/' "${host_tmp}/anykernel.sh" 2>/dev/null || true
    # 2. Fix /proc/self/fd/1 error when running via su / adb shell by removing >> /proc/self/fd/$OUTFD
    sed -i 's/>> \/proc\/self\/fd\/$OUTFD//g' "${host_tmp}/META-INF/com/google/android/update-binary" 2>/dev/null || true
    sed -i 's/>> \/proc\/self\/fd\/$OUTFD//g' "${host_tmp}/tools/ak3-core.sh" 2>/dev/null || true

    # Create temporary live-flash zip so AnyKernel's internal unzip also receives the patched files
    (
        cd "${host_tmp}"
        zip -q -r "${host_tmp}/anykernel_live.zip" ./* -x "anykernel_live.zip" "run_flash.sh"
    )

    log_info "Preparing temporary workspaces on device..."
    adb -s "${serial}" shell "rm -rf ${dev_tmp} ${dev_ws} ${dev_bin} 2>/dev/null || true"
    adb -s "${serial}" shell "mkdir -p ${dev_tmp} ${dev_ws} ${dev_bin}"

    log_info "Pushing AnyKernel archive to device (${dev_tmp}/anykernel.zip)..."
    adb -s "${serial}" push "${host_tmp}/anykernel_live.zip" "${dev_tmp}/anykernel.zip"

    log_info "Pushing installer files to device workspace (${dev_ws}/)..."
    adb -s "${serial}" push "${host_tmp}/." "${dev_ws}/" >/dev/null 2>&1

    log_info "Configuring execution permissions & standalone tools..."
    adb -s "${serial}" shell "chmod -R 755 ${dev_ws}/tools ${dev_ws}/anykernel.sh ${dev_ws}/META-INF/com/google/android/update-binary 2>/dev/null || true"
    adb -s "${serial}" shell "cp ${dev_ws}/tools/busybox ${dev_bin}/busybox 2>/dev/null && chmod 755 ${dev_bin}/busybox && ln -sf ${dev_bin}/busybox ${dev_bin}/unzip 2>/dev/null || true"

    cat << 'EOF' > "${host_tmp}/run_flash.sh"
#!/system/bin/sh
set -e
export AKHOME="/data/local/tmp/ak3_workspace"
export ZIPFILE="/data/local/tmp/ak3_flash/anykernel.zip"
export PATH="/data/local/tmp/ak3_bin:$AKHOME/tools:$AKHOME/bin:/system/bin:/vendor/bin:$PATH"

cd "$AKHOME"
chmod 755 tools/* 2>/dev/null || true
chmod 755 anykernel.sh 2>/dev/null || true

if [ -f "META-INF/com/google/android/update-binary" ]; then
    chmod 755 META-INF/com/google/android/update-binary 2>/dev/null || true
    sh META-INF/com/google/android/update-binary 3 1 "$ZIPFILE"
elif [ -f "anykernel.sh" ]; then
    ash anykernel.sh
else
    echo "Error: AnyKernel installer script not found!"
    exit 1
fi
EOF

    adb -s "${serial}" push "${host_tmp}/run_flash.sh" "${dev_tmp}/run_flash.sh" >/dev/null 2>&1
    adb -s "${serial}" shell "chmod 755 ${dev_tmp}/run_flash.sh"

    local exec_cmd="sh ${dev_tmp}/run_flash.sh"
    if [[ "${use_su}" -eq 1 ]]; then
        exec_cmd="su -c 'sh ${dev_tmp}/run_flash.sh'"
    fi

    log_info "Executing AnyKernel3 installer in ADB Shell..."
    echo -e "${C_CYAN}------------------------ [ ADB Flasher Output ] ------------------------${C_RESET}"

    local flash_log="${host_tmp}/flash_exec.log"
    local flash_failed=0

    adb -s "${serial}" shell "${exec_cmd}" 2>&1 | tee "${flash_log}" | while IFS= read -r raw_line; do
        local line
        line=$(echo "${raw_line}" | sed -e 's/^ui_print //' -e 's/^ui_print$//' -e $'s/\r$//')
        if [[ -n "${line}" ]]; then
            echo -e "  ${C_CYAN}│${C_RESET} ${line}"
        fi
    done || flash_failed=1

    echo -e "${C_CYAN}------------------------------------------------------------------------${C_RESET}\n"

    adb -s "${serial}" shell "rm -rf ${dev_tmp} ${dev_ws} ${dev_bin} 2>/dev/null || true"
    rm -rf "${host_tmp}"

    if grep -qi "abort" "${flash_log}" 2>/dev/null || [[ ${flash_failed} -ne 0 ]]; then
        log_error "Flashing process encountered errors or was aborted!"
        return 1
    fi

    log_success "Kernel successfully installed to boot partition via ADB Shell!"
    echo -e "${C_GREEN}${C_BOLD}Flashing Complete!${C_RESET}\n"

    if prompt_confirm "Would you like to reboot the device now to activate the new kernel?" "Y"; then
        log_info "Rebooting device..."
        adb -s "${serial}" reboot
        log_success "Device reboot command sent. Your Pocophone F1 is restarting!"
    fi

    return 0
}

flash_via_recovery() {
    local serial="$1"
    local zip_path="$2"

    echo -e "\n${C_BOLD}${C_CYAN}=== Recovery Flashing (TWRP / OrangeFox) ===${C_RESET}\n"
    log_info "Target Zip: $(basename "${zip_path}")"

    local rec_zip="/tmp/anykernel.zip"
    log_info "Pushing AnyKernel package to recovery (${rec_zip})..."
    adb -s "${serial}" push "${zip_path}" "${rec_zip}"

    log_info "Triggering installation in recovery..."
    if adb -s "${serial}" shell "command -v twrp >/dev/null 2>&1"; then
        echo -e "${C_CYAN}Running: twrp install ${rec_zip}...${C_RESET}"
        adb -s "${serial}" shell "twrp install ${rec_zip}" 2>&1 | while IFS= read -r l; do
            echo -e "  ${C_CYAN}│${C_RESET} $(echo "${l}" | tr -d '\r')"
        done
    else
        log_info "TWRP CLI command not found, using OpenRecoveryScript fallback..."
        adb -s "${serial}" shell "echo 'install ${rec_zip}' > /cache/recovery/openrecoveryscript 2>/dev/null || echo 'install ${rec_zip}' > /tmp/openrecoveryscript"
        log_info "Queued installation via OpenRecoveryScript."
    fi

    log_success "Recovery flash instructions dispatched!"
    if prompt_confirm "Reboot device to System now?" "Y"; then
        adb -s "${serial}" reboot
        log_success "Rebooting to system..."
    fi
    return 0
}

flash_via_sideload() {
    local serial="$1"
    local zip_path="$2"

    echo -e "\n${C_BOLD}${C_CYAN}=== ADB Sideload Mode ===${C_RESET}\n"
    log_info "Sending AnyKernel package via ADB sideload..."
    if adb -s "${serial}" sideload "${zip_path}"; then
        log_success "ADB sideload completed successfully!"
        if prompt_confirm "Reboot system now?" "Y"; then
            adb -s "${serial}" reboot
        fi
        return 0
    else
        log_error "ADB sideload failed!"
        return 1
    fi
}

flash_anykernel_package() {
    local preselected_zip="${1:-}"

    if ! detect_adb_device; then
        press_enter
        return 0
    fi

    local target_zip=""
    if [[ -n "${preselected_zip}" && -f "${preselected_zip}" ]]; then
        target_zip="${preselected_zip}"
    else
        if ! select_anykernel_zip; then
            press_enter
            return 0
        fi
        target_zip="${SELECTED_ANYKERNEL_ZIP}"
    fi

    case "${SELECTED_ADB_STATE}" in
        device)
            flash_via_adb_shell "${SELECTED_ADB_SERIAL}" "${target_zip}"
            ;;
        recovery)
            flash_via_recovery "${SELECTED_ADB_SERIAL}" "${target_zip}"
            ;;
        sideload)
            flash_via_sideload "${SELECTED_ADB_SERIAL}" "${target_zip}"
            ;;
        *)
            log_error "Unsupported device state: ${SELECTED_ADB_STATE}"
            ;;
    esac

    press_enter
}

menu_flash_anykernel() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== [7] Flash AnyKernel via ADB (Live Android / Recovery) ===${C_RESET}\n"
    flash_anykernel_package
}

# ------------------------------------------------------------------------------
# EXTRA UTILITY: CLEAN ARTIFACTS
# ------------------------------------------------------------------------------
clean_artifacts() {
    print_header
    echo -e "${C_BOLD}${C_BLUE}=== Clean Build Directory & Artifacts ===${C_RESET}\n"
    echo -e "Directories and files to be removed:"
    echo "  - ${OUT_DIR}"
    echo "  - ${BUILD_LOG}"
    echo ""
    if prompt_confirm "Confirmation: Are you sure you want to clean all build artifacts?" "N"; then
        log_info "Removing build output directory..."
        rm -rf "${OUT_DIR}"
        rm -f "${BUILD_LOG}"
        log_success "Cleanup complete!"
    else
        log_info "Cleanup cancelled by user."
    fi
    press_enter
}

# ------------------------------------------------------------------------------
# MAIN INTERACTIVE TUI LOOP
# ------------------------------------------------------------------------------
main_menu() {
    load_config

    while true; do
        print_header
        print_status_bar

        echo -e "${C_BOLD}Navigation Menu:${C_RESET}"
        echo -e "  ${C_CYAN}0.${C_RESET} Open Menuconfig"
        echo -e "  ${C_CYAN}1.${C_RESET} Setup Toolchains"
        echo -e "  ${C_CYAN}2.${C_RESET} Install Dependencies"
        echo -e "  ${C_CYAN}3.${C_RESET} Apply Custom Configuration"
        echo -e "  ${C_CYAN}4.${C_RESET} Apply Patch"
        echo -e "  ${C_CYAN}5.${C_RESET} Build Kernel"
        echo -e "  ${C_CYAN}6.${C_RESET} Setup and Pack to AnyKernel"
        echo -e "  ${C_CYAN}7.${C_RESET} Flash AnyKernel via ADB (Live Android / Recovery)"
        echo ""
        echo -e "  ${C_DIM}c. Clean Build Artifacts (out / log)${C_RESET}"
        echo -e "  ${C_DIM}q. Exit${C_RESET}"
        echo ""
        echo -en "${C_YELLOW}Select menu option [0-7, c, q]: ${C_RESET}"

        local main_choice
        read -r main_choice || true

        case "${main_choice}" in
            0)
                menu_open_menuconfig
                ;;
            1)
                menu_setup_toolchain
                ;;
            2)
                menu_install_dependencies
                ;;
            3)
                menu_apply_config
                ;;
            4)
                menu_apply_patch
                ;;
            5)
                menu_build_kernel
                ;;
            6)
                menu_setup_anykernel
                ;;
            7)
                menu_flash_anykernel
                ;;
            c|C)
                clean_artifacts
                ;;
            q|Q|exit)
                print_header
                log_success "Thank you for using the SDM845 Kernel Builder!"
                echo -e "${C_DIM}Happy flashing & custom kernel development!${C_RESET}\n"
                exit 0
                ;;
            *)
                log_error "Invalid selection! Please enter a number 0-7, c, or q."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# ENTRY POINT
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu "$@"
fi
