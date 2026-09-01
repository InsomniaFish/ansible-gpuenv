#!/usr/bin/env bash
#===============================================================================
# install_gpuenv.sh - GPU 环境在线安装脚本（Ubuntu 22.04）
#
# 功能：在线安装 NVIDIA 驱动 / CUDA Toolkit / fabricmanager / gpu-burn
#
# 用法：
#   bash install_gpuenv.sh start [选项]       # 执行安装
#   bash install_gpuenv.sh uninstall          # 卸载已安装组件
#
# 选项：
#   --driver <版本>   NVIDIA 驱动版本，如 550.127.05（默认 550.163.01）
#   --cuda <版本>     CUDA 版本，如 12.4（默认 12.4）
#   --fm <版本>       fabricmanager 版本（默认与驱动版本一致，必须一致）
#   --skip-gpu-burn   跳过 gpu-burn 下载编译
#   --force           忽略已安装检测，强制重新安装/编译
#   -h, --help        显示帮助
#
# 示例：
#   bash install_gpuenv.sh start
#   bash install_gpuenv.sh start --driver 550.127.05 --cuda 12.4
#===============================================================================
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive

#----------------------------- 基准路径配置 -----------------------------------
# 以脚本所在目录（即项目目录）为基准路径，所有产物均存放于此
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#===============================================================================
# 配置区：源 URL 与版本号（修改以下变量即可指定不同的源和版本）
#===============================================================================

# --- 源 URL 配置 ---
# NVIDIA CUDA 官方软件源基础地址（驱动/CUDA/fabricmanager 均来自该源）
#   - 国内加速：域名可改为 developer.download.nvidia.cn
#   - 其他系统：ubuntu2204 可改为 ubuntu2004 / ubuntu2404 等
CUDA_REPO_BASE_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64"

# cuda-keyring 软件源密钥包文件名（与 CUDA_REPO_BASE_URL 拼接为完整下载地址）
CUDA_KEYRING_DEB="cuda-keyring_1.1-1_all.deb"

# gpu-burn 源码下载地址
#   - 指定版本：将 master 改为对应 tag，例如
#     https://github.com/wilicc/gpu-burn/archive/refs/tags/v1.1.zip
GPU_BURN_URL="https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip"

# --- 版本配置（默认以 base_vesion.md 版本基线为准） ---
DRIVER_VERSION="560.35.05"      # NVIDIA 驱动版本（基线：560.35.05，560.35.03 也可）
CUDA_VERSION="12.6.2"           # CUDA Toolkit 版本（基线：12.6，建议 12.6.2）
FM_VERSION=""                   # fabricmanager 版本，留空则与驱动一致
SKIP_GPU_BURN=false             # 是否跳过 gpu-burn 下载编译
FORCE=false                     # 是否忽略已安装检测，强制重装

GPU_BURN_DIR="${SCRIPT_DIR}/gpu-burn-master"

#----------------------------- 工具函数 ---------------------------------------
log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; }

# 在 apt 源中查找软件包匹配指定版本的完整版本号
# $1: 包名  $2: 目标版本关键字
find_pkg_ver() {
    apt-cache madison "$1" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
        | grep -F "$2" | head -n 1
}

# 获取已安装软件包的版本（未安装或半安装状态返回空）
# $1: 包名
installed_ver() {
    # 仅当包状态为 ii（完全安装）才返回版本，iU/iF 等半装状态视为未安装
    local status
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | cut -c1-2)
    [[ "$status" == "ii" ]] || return 1
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# 判断已安装版本是否与目标版本匹配
# $1: 包名  $2: 目标版本关键字
is_installed_match() {
    local v
    v=$(installed_ver "$1") || return 1
    [[ -n "$v" && "$v" == *"$2"* ]]
}

# 执行 apt-get install 并检查退出码，失败立即终止
# $@: 传给 apt-get install 的参数
apt_install() {
    if ! apt-get install -y "$@"; then
        err "apt-get install $* 执行失败，请检查上方错误（常见原因：dpkg 被其他进程锁定、依赖冲突、半安装状态）"
        err "可尝试修复: dpkg --configure -a && apt-get install -f"
        exit 1
    fi
}

#----------------------------- 参数解析 ---------------------------------------
ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        start)            ACTION="start"; shift ;;
        uninstall)        ACTION="uninstall"; shift ;;
        --driver)         DRIVER_VERSION="$2"; shift 2 ;;
        --cuda)           CUDA_VERSION="$2"; shift 2 ;;
        --fm)             FM_VERSION="$2"; shift 2 ;;
        --skip-gpu-burn)  SKIP_GPU_BURN=true; shift ;;
        --force)          FORCE=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                err "未知参数: $1"; usage; exit 1 ;;
    esac
done

[[ -z "$ACTION" ]] && { usage; exit 1; }

#----------------------------- 配置显示 ---------------------------------------
show_config() {
    echo "==================== 当前配置 ===================="
    echo "CUDA 源地址    : ${CUDA_REPO_BASE_URL}"
    echo "keyring 包     : ${CUDA_KEYRING_DEB}"
    echo "gpu-burn 源    : ${GPU_BURN_URL}"
    echo "驱动版本       : ${DRIVER_VERSION}"
    echo "CUDA 版本      : ${CUDA_VERSION}"
    echo "fabricmanager  : ${FM_VERSION:-与驱动一致}"
    echo "跳过 gpu-burn  : ${SKIP_GPU_BURN}"
    echo "强制重装       : ${FORCE}"
    echo "=================================================="
}

#----------------------------- 前置检查 ---------------------------------------
precheck() {
    [[ $EUID -ne 0 ]] && { err "请使用 root 用户执行"; exit 1; }
    if ! grep -qi ubuntu /etc/os-release; then
        err "本脚本仅支持 Ubuntu 系统"
        exit 1
    fi
    log "系统: $(. /etc/os-release && echo "$PRETTY_NAME")  主机: $(hostname)"
}

#----------------------------- 安装步骤 ---------------------------------------
# 步骤1：安装编译依赖（对应文档：二、安装 gcc 编译依赖包）
install_build_deps() {
    log "步骤1: 安装编译依赖 build-essential / linux-headers / unzip"
    apt-get update -y
    apt_install build-essential "linux-headers-$(uname -r)" unzip curl
    gcc --version | head -n 1
}

# 步骤2：配置 NVIDIA 官方 CUDA 软件源
install_cuda_repo() {
    if ! $FORCE && dpkg -l cuda-keyring >/dev/null 2>&1; then
        log "步骤2: cuda-keyring 已安装，跳过"
        return
    fi
    log "步骤2: 配置 NVIDIA CUDA 官方软件源 (cuda-keyring)"
    local deb=/tmp/cuda-keyring.deb
    curl -fsSL "${CUDA_REPO_BASE_URL}/${CUDA_KEYRING_DEB}" -o "$deb"
    apt_install "$deb"
    rm -f "$deb"
    apt-get update -y
}

# 步骤3：安装 NVIDIA 驱动（对应文档：三、安装 NVIDIA 显卡驱动）
install_driver() {
    local major="${DRIVER_VERSION%%.*}"
    local pkg="nvidia-driver-${major}"

    log "步骤3: 安装 NVIDIA 驱动 ${DRIVER_VERSION} (系列 ${major})"

    # 驱动系列不存在时，列出源中可用的驱动系列
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        err "源中未找到驱动系列 ${major}，可用驱动系列如下："
        apt-cache search '^nvidia-driver-[0-9]+$' | awk '{print "  " $1}'
        exit 1
    fi

    # 查找源中匹配的完整版本号
    local ver
    ver=$(find_pkg_ver "$pkg" "$DRIVER_VERSION")
    if [[ -z "$ver" ]]; then
        err "源中未找到驱动版本 ${DRIVER_VERSION}，${pkg} 可用版本如下："
        apt-cache madison "$pkg" | awk -F'|' '{gsub(/ /,"",$2); print "  " $2}'
        exit 1
    fi
    log "匹配到驱动包版本: ${ver}"

    # 已安装且版本一致时跳过
    if ! $FORCE && is_installed_match "$pkg" "$DRIVER_VERSION"; then
        log "步骤3: 驱动 ${pkg} 已安装 $(installed_ver "$pkg")，与目标版本一致，跳过"
        return
    fi

    # 驱动由多个子包组成，指定版本时必须全部锁定，否则依赖解析失败
    local sub_pkgs=(
        nvidia-driver nvidia-dkms nvidia-kernel-common nvidia-kernel-source
        nvidia-utils nvidia-compute-utils
        libnvidia-compute libnvidia-extra libnvidia-gl
        libnvidia-decode libnvidia-encode libnvidia-fbc1 libnvidia-cfg1
        xserver-xorg-video-nvidia
    )
    local install_list=()
    for p in "${sub_pkgs[@]}"; do
        # 仅锁定源中真实存在的子包
        if apt-cache show "${p}-${major}" >/dev/null 2>&1; then
            install_list+=("${p}-${major}=${ver}")
        fi
    done

    apt_install "${install_list[@]}"
    log "驱动安装完成: $(dpkg -l "$pkg" | awk '/^ii/{print $2, $3}')"
}

# 步骤4：安装 CUDA Toolkit（对应文档：四、安装 CUDA Toolkit，不含驱动）
# 支持两位版本（12.6，装该系列最新）与三位版本（12.6.2，精确锁定小版本）
install_cuda_toolkit() {
    # 包名取主.次版本（如 12.6.2 -> cuda-toolkit-12-6）
    local pkg="cuda-toolkit-$(echo "$CUDA_VERSION" | cut -d. -f1)-$(echo "$CUDA_VERSION" | cut -d. -f2)"
    log "步骤4: 安装 CUDA Toolkit ${CUDA_VERSION} (${pkg})"

    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        err "源中未找到 ${pkg}，请检查 --cuda 版本参数"
        exit 1
    fi

    # 查找源中匹配的完整版本号（三位版本时精确锁定）
    local ver
    ver=$(find_pkg_ver "$pkg" "$CUDA_VERSION")
    if [[ -z "$ver" ]]; then
        err "源中未找到 ${pkg} 版本 ${CUDA_VERSION}，可用版本如下："
        apt-cache madison "$pkg" | awk -F'|' '{gsub(/ /,"",$2); print "  " $2}'
        exit 1
    fi

    # 已安装且版本一致时跳过
    if ! $FORCE && is_installed_match "$pkg" "$CUDA_VERSION"; then
        log "步骤4: ${pkg} 已安装 $(installed_ver "$pkg")，与目标版本一致，跳过"
    else
        apt_install "${pkg}=${ver}"
    fi

    # 配置环境变量（对应文档：4. 配置 CUDA 环境变量）
    cat > /etc/profile.d/cuda.sh <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib:$LD_LIBRARY_PATH
EOF
    log "环境变量已写入 /etc/profile.d/cuda.sh"
    /usr/local/cuda/bin/nvcc -V | tail -n 2
}

# 步骤5：安装 nvidia-fabricmanager（对应文档：五，版本必须与驱动完全一致）
install_fabricmanager() {
    local major="${DRIVER_VERSION%%.*}"
    local pkg="nvidia-fabricmanager-${major}"
    local target="${FM_VERSION:-$DRIVER_VERSION}"

    log "步骤5: 安装 ${pkg} (目标版本 ${target})"

    local ver
    ver=$(find_pkg_ver "$pkg" "$target")
    if [[ -z "$ver" ]]; then
        err "源中未找到 ${pkg} 版本 ${target}，可用版本如下："
        apt-cache madison "$pkg" | awk -F'|' '{gsub(/ /,"",$2); print "  " $2}'
        exit 1
    fi

    # 已安装且版本一致时跳过安装，仅确保服务开机自启
    if ! $FORCE && is_installed_match "$pkg" "$target"; then
        log "步骤5: ${pkg} 已安装 $(installed_ver "$pkg")，与目标版本一致，跳过安装"
    else
        apt_install "${pkg}=${ver}"
    fi

    systemctl enable nvidia-fabricmanager
    if systemctl start nvidia-fabricmanager; then
        log "fabricmanager 服务已启动"
    else
        warn "fabricmanager 启动失败（无 GPU / 无 NVLink 硬件时属正常现象）"
    fi
}

# 步骤6：编译 gpu-burn（对应文档：六、编译 gpu-burn）
install_gpu_burn() {
    $SKIP_GPU_BURN && { log "步骤6: 已跳过 gpu-burn"; return; }

    # 已编译则跳过
    if ! $FORCE && [[ -x "${GPU_BURN_DIR}/gpu_burn" ]]; then
        log "步骤6: gpu_burn 已编译 (${GPU_BURN_DIR}/gpu_burn)，跳过"
        return
    fi

    log "步骤6: 下载并编译 gpu-burn"
    local zip=/tmp/gpu-burn-master.zip
    curl -fsSL "$GPU_BURN_URL" -o "$zip"
    rm -rf "$GPU_BURN_DIR"
    unzip -oq "$zip" -d "$SCRIPT_DIR"
    rm -f "$zip"

    make -C "$GPU_BURN_DIR"
    if [[ -x "${GPU_BURN_DIR}/gpu_burn" ]]; then
        log "gpu_burn 编译成功: ${GPU_BURN_DIR}/gpu_burn"
    else
        err "gpu_burn 编译失败"
        exit 1
    fi
}

#----------------------------- 结果汇总 ---------------------------------------
summary() {
    echo
    log "========== 安装结果汇总 =========="
    echo "--- 驱动 ---"
    dpkg -l | grep -E "^ii  nvidia-driver-" | awk '{print $2, $3}' || warn "未检测到驱动包"
    echo "--- CUDA ---"
    dpkg -l | grep -E "^ii  cuda-toolkit-" | awk '{print $2, $3}' || warn "未检测到 CUDA 包"
    echo "--- fabricmanager ---"
    dpkg -l | grep -E "^ii  nvidia-fabricmanager-" | awk '{print $2, $3}' || warn "未检测到 fabricmanager 包"
    echo "--- gpu_burn ---"
    [[ -x "${GPU_BURN_DIR}/gpu_burn" ]] && echo "${GPU_BURN_DIR}/gpu_burn" || warn "gpu_burn 未编译"
    echo "--- nvidia-smi ---"
    nvidia-smi 2>&1 | head -n 5 || warn "nvidia-smi 不可用（无 GPU 时属正常现象）"
    echo "=================================="
    log "全部步骤执行完成"
}

#----------------------------- 卸载 -------------------------------------------
do_uninstall() {
    precheck
    log "开始卸载 GPU 环境组件"
    systemctl stop nvidia-fabricmanager 2>/dev/null
    systemctl disable nvidia-fabricmanager 2>/dev/null
    apt-get remove -y --purge 'nvidia-*' 'libnvidia-*' 'cuda*' || true
    apt-get autoremove -y --purge
    rm -f /etc/profile.d/cuda.sh
    rm -rf "$GPU_BURN_DIR"
    log "卸载完成（如需彻底清理可重启服务器）"
}

#----------------------------- 主流程 -----------------------------------------
main() {
    case "$ACTION" in
        start)
            precheck
            show_config
            install_build_deps
            install_cuda_repo
            install_driver
            install_cuda_toolkit
            install_fabricmanager
            install_gpu_burn
            summary
            ;;
        uninstall)
            do_uninstall
            ;;
    esac
}

main
