#!/bin/bash
# =============================================================================
#  在 CentOS 7 基线容器内编译 Angie + Tongsuo
#  目的：产物依赖 glibc 2.17，可运行于 CentOS/RHEL 7/8、麒麟 V10、Ubuntu 18.04+
#  用法：由 GitHub Actions 通过 docker run 调用，仓库挂载在 /src
# =============================================================================
set -euo pipefail

log() { echo -e "\033[0;32m[container]\033[0m $*"; }
warn() { echo -e "\033[1;33m[container]\033[0m $*"; }

log "系统信息: $(cat /etc/redhat-release 2>/dev/null || uname -a)"
log "glibc: $(ldd --version | head -1)"

# ---------------------------------------------------------------------------
# 1. yum 源指向 vault.centos.org（CentOS 7 已 EOL，官方源下线）
# ---------------------------------------------------------------------------
fix_repos() {
    for f in /etc/yum.repos.d/*.repo; do
        [ -f "$f" ] || continue
        sed -i 's|^mirrorlist=|#mirrorlist=|g' "$f"
        sed -i 's|^#\?baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' "$f"
        sed -i 's|^#\?baseurl=http://mirrorlist.centos.org|baseurl=http://vault.centos.org|g' "$f"
        sed -i 's|^#\?baseurl=https://mirror.centos.org|baseurl=https://vault.centos.org|g' "$f"
    done
    rm -rf /var/cache/yum/*
}

install_pkgs() {
    local pkgs="gcc gcc-c++ make perl git curl wget tar gzip unzip which autoconf libtool zlib-devel openssl-devel"
    yum clean all >/dev/null 2>&1 || true
    yum -y install $pkgs
}

log "安装编译依赖..."
if ! install_pkgs; then
    warn "yum 首次安装失败，切换到 vault 源重试"
    fix_repos
    install_pkgs || { warn "仍失败，尝试仅安装核心依赖"; yum -y install gcc gcc-c++ make perl zlib-devel || true; }
fi

# libgd 用于 image_filter 动态模块（缺失则脚本会自动跳过该模块）
yum -y install gd-devel >/dev/null 2>&1 || warn "gd-devel 不可用，将跳过 image_filter"

# GeoIP 需要 EPEL（缺失则脚本会自动跳过 geoip 模块）
yum -y install geoip-devel >/dev/null 2>&1 || warn "geoip-devel 不可用，将跳过 geoip"

# ---------------------------------------------------------------------------
# 2. 启用较新的编译器（SCL devtoolset），glibc 仍保持 2.17
# ---------------------------------------------------------------------------
for en in /opt/rh/devtoolset-*/enable /opt/rh/gcc-toolset-*/enable; do
    if [ -f "$en" ]; then . "$en"; fi
done
log "编译器: $(gcc --version 2>&1 | sed -n '1p')"

# ---------------------------------------------------------------------------
# 3. 执行主编译脚本
# ---------------------------------------------------------------------------
export SKIP_SYSTEM_DEPS=1
export OUTPUT_DIR="${OUTPUT_DIR:-/src/output}"
mkdir -p "$OUTPUT_DIR"

log "开始编译 Angie ${ANGIE_VERSION:-?} + Tongsuo ${TONGSUO_VERSION:-?} ..."
bash /src/scripts/build_angie_tongsuo.sh

log "编译完成，产物："
ls -lh "$OUTPUT_DIR"/*.tar.gz
