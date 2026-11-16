#!/bin/bash
# =============================================================================
# Angie + Tongsuo (国密SSL) 自动编译脚本
# 支持 x86_64 和 aarch64 架构
# 依赖: gcc, make, perl, wget/curl
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 版本配置（可通过环境变量覆盖）
# ---------------------------------------------------------------------------
: ${ANGIE_VERSION:="Angie-1.12.4"}
: ${TONGSUO_VERSION:="8.5.0"}
: ${ZLIB_VERSION:="1.3.2"}
: ${PCRE2_VERSION:="10.47"}
: ${PREFIX:="/usr/local/angie"}

# 第三方模块版本
: ${NGINX_MODULE_VTS_VERSION:="v0.3.2"}
: ${HEADERS_MORE_VERSION:="v0.37"}
: ${NGX_CACHE_PURGE_VERSION:="v1.6.3"}
: ${LUA_NGINX_MODULE_VERSION:="v0.10.27"}
: ${STREAM_LUA_NGINX_MODULE_VERSION:="v0.0.15"}
: ${LUAJIT_BRANCH:="v2.1"}

# 架构检测
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)    PLATFORM="x86_64" ;;
    aarch64|arm64)   PLATFORM="aarch64" ;;
    *) echo "ERROR: 不支持的架构 $ARCH" >&2; exit 1 ;;
esac

echo "============================================================"
echo "  Angie + Tongsuo (国密SSL) 编译脚本"
echo "  架构      : $ARCH ($PLATFORM)"
echo "  Angie     : $ANGIE_VERSION"
echo "  Tongsuo   : $TONGSUO_VERSION"
echo "  安装路径  : $PREFIX"
echo "  并发数    : $(nproc)"
echo "============================================================"

# ---------------------------------------------------------------------------
# 颜色输出
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. 安装系统依赖
# ---------------------------------------------------------------------------
install_deps() {
    # 支持两种跳过方式：
    #   a) $SKIP_SYSTEM_DEPS=1  (CI 环境已由 workflow 预装)
    #   b) $GITHUB_ACTIONS=true (GitHub Actions runner 默认跳过)
    if [ "${SKIP_SYSTEM_DEPS:-0}" = "1" ] || [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
        log_info "跳过系统依赖安装（CI/Runner 环境已预装）"
        return 0
    fi

    # 自动加 sudo（非 root 用户时）
    local SUDO=""
    [ "$(id -u)" != "0" ] && SUDO="sudo"

    log_info "安装系统编译依赖..."
    if command -v apt-get &>/dev/null; then
        $SUDO apt-get update -y
        $SUDO apt-get install -y \
            build-essential gcc g++ make perl git \
            wget curl unzip tar gzip xz-utils ca-certificates \
            libpcre3-dev zlib1g-dev libgeoip-dev libgd-dev \
            autoconf libtool pkg-config
    elif command -v yum &>/dev/null; then
        $SUDO yum groupinstall -y "Development Tools" || true
        $SUDO yum install -y \
            gcc gcc-c++ make perl git \
            wget curl unzip tar gzip \
            pcre pcre-devel zlib zlib-devel geoip-devel \
            gd-devel openssl-devel ca-certificates \
            autoconf libtool pkgconfig
    elif command -v dnf &>/dev/null; then
        $SUDO dnf groupinstall -y "Development Tools" || true
        $SUDO dnf install -y \
            gcc gcc-c++ make perl git \
            wget curl unzip tar gzip \
            pcre pcre-devel zlib zlib-devel geoip-devel \
            gd-devel openssl-devel ca-certificates \
            autoconf libtool pkg-config
    else
        log_error "不支持的包管理器，请手动安装 gcc/make/perl/wget/zlib-devel/pcre-devel"
    fi
    log_info "系统依赖安装完成"
}

# ---------------------------------------------------------------------------
# 2. 准备工作目录
# ---------------------------------------------------------------------------
prepare_workdir() {
    WORKDIR="${HOME}/angie-build"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    echo "$WORKDIR"
}

# ---------------------------------------------------------------------------
# 3. 下载所有源码
# ---------------------------------------------------------------------------
download_sources() {
    local wd=$1
    cd "$wd"

    log_info "下载 Zlib $ZLIB_VERSION..."
    wget -q "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
    tar xf "zlib-${ZLIB_VERSION}.tar.gz"

    log_info "下载 PCRE2 $PCRE2_VERSION..."
    wget -q "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
    tar xf "pcre2-${PCRE2_VERSION}.tar.gz"

    log_info "下载 Tongsuo $TONGSUO_VERSION..."
    wget -q "https://github.com/Tongsuo-Project/Tongsuo/releases/download/${TONGSUO_VERSION}/Tongsuo-${TONGSUO_VERSION}.tar.gz"
    tar xf "Tongsuo-${TONGSUO_VERSION}.tar.gz"
    # 统一目录名为 Tongsuo
    mv "Tongsuo-${TONGSUO_VERSION}" Tongsuo

    log_info "下载 Angie $ANGIE_VERSION..."
    wget -q "https://github.com/webserver-llc/angie/archive/refs/tags/${ANGIE_VERSION}.tar.gz" -O "angie-${ANGIE_VERSION}.tar.gz"
    tar xf "angie-${ANGIE_VERSION}.tar.gz"

    log_info "下载第三方 Nginx 模块..."
    # nginx-module-vts
    git clone --depth 1 --branch "$NGINX_MODULE_VTS_VERSION" https://github.com/vozlt/nginx-module-vts.git
    # headers-more-nginx-module
    git clone --depth 1 --branch "$HEADERS_MORE_VERSION" https://github.com/openresty/headers-more-nginx-module.git
    # ngx_cache_purge
    git clone --depth 1 --branch "$NGX_CACHE_PURGE_VERSION" https://github.com/nginx-modules/ngx_cache_purge.git
    # lua-nginx-module
    git clone --depth 1 --branch "$LUA_NGINX_MODULE_VERSION" https://github.com/openresty/lua-nginx-module.git
    # stream-lua-nginx-module
    git clone --depth 1 --branch "$STREAM_LUA_NGINX_MODULE_VERSION" https://github.com/openresty/stream-lua-nginx-module.git

    log_info "下载 LuaJIT..."
    git clone --depth 1 --branch "$LUAJIT_BRANCH" https://github.com/openresty/luajit2.git

    log_info "所有源码下载完成"
    ls -la "$wd"
}

# ---------------------------------------------------------------------------
# 4. 编译安装 LuaJIT
# ---------------------------------------------------------------------------
build_luajit() {
    local wd=$1
    cd "${wd}/luajit2"

    log_info "编译 LuaJIT 2.1..."
    make -j"$(nproc)"

    log_info "安装 LuaJIT 到 /usr/local/luajit..."
    make install PREFIX=/usr/local/luajit

    # 配置动态库搜索路径
    echo "/usr/local/luajit/lib" > /etc/ld.so.conf.d/luajit.conf
    ldconfig

    export LUAJIT_LIB=/usr/local/luajit/lib
    export LUAJIT_INC=/usr/local/luajit/include/luajit-2.1
    log_info "LuaJIT 安装完成: LUAJIT_LIB=$LUAJIT_LIB, LUAJIT_INC=$LUAJIT_INC"
}

# ---------------------------------------------------------------------------
# 5. 编译 PCRE2
# ---------------------------------------------------------------------------
build_pcre2() {
    local wd=$1
    cd "${wd}/pcre2-${PCRE2_VERSION}"

    log_info "编译 PCRE2..."
    ./configure --prefix=/usr/local/pcre2 --enable-jit
    make -j"$(nproc)"
    make install

    export PCRE2_LIB=/usr/local/pcre2/lib
    export PCRE2_INC=/usr/local/pcre2/include
    log_info "PCRE2 编译完成"
}

# ---------------------------------------------------------------------------
# 6. 编译 Zlib
# ---------------------------------------------------------------------------
build_zlib() {
    local wd=$1
    cd "${wd}/zlib-${ZLIB_VERSION}"

    log_info "编译 Zlib..."
    ./configure --prefix=/usr/local/zlib
    make -j"$(nproc)"
    make install

    log_info "Zlib 编译完成"
}

# ---------------------------------------------------------------------------
# 7. 配置并编译 Angie (内嵌 Tongsuo)
# ---------------------------------------------------------------------------
configure_and_build_angie() {
    local wd=$1

    # 找到 Angie 源码目录（版本号可能有差异）
    local angie_src
    angie_src=$(find "$wd" -maxdepth 1 -type d -name "angie-*" | head -n1)
    if [ -z "$angie_src" ]; then
        log_error "找不到 Angie 源码目录"
    fi
    log_info "Angie 源码目录: $angie_src"

    cd "$angie_src"

    # 设置环境变量（用于 LuaJIT）
    export LUAJIT_LIB=${LUAJIT_LIB:-/usr/local/luajit/lib}
    export LUAJIT_INC=${LUAJIT_INC:-/usr/local/luajit/include/luajit-2.1}

    log_info "执行 ./configure ..."
    ./configure \
        --prefix="$PREFIX" \
        --with-pcre="${wd}/pcre2-${PCRE2_VERSION}" \
        --with-zlib="${wd}/zlib-${ZLIB_VERSION}" \
        --with-openssl="${wd}/Tongsuo" \
        --with-openssl-opt="enable-ntls no-asm" \
        --with-ntls \
        --with-cc-opt="-I/usr/local/include -I${LUAJIT_INC} -I/usr/include" \
        --with-ld-opt="-L/usr/local/lib -L${LUAJIT_LIB} -L/usr/lib64 -Wl,-rpath,${LUAJIT_LIB} -ldl -lm" \
        --add-module="${wd}/nginx-module-vts" \
        --add-module="${wd}/headers-more-nginx-module" \
        --add-module="${wd}/ngx_cache_purge" \
        --add-module="${wd}/lua-nginx-module" \
        --add-module="${wd}/stream-lua-nginx-module" \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --with-stream_mqtt_preread_module \
        --with-stream_acme_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-http_acme_module \
        --with-threads \
        --with-file-aio \
        --with-http_stub_status_module \
        2>&1 | tee configure.log

    log_info "配置完成，开始编译（约需 5-15 分钟）..."
    echo "    [注意] Tongsuo 会被内嵌编译到 Angie 中，请耐心等待..."

    # 使用较少并发避免 OOM（GitHub Actions 可能内存有限）
    local JOBS
    JOBS=$(nproc)
    [ "$JOBS" -gt 4 ] && JOBS=4
    make -j"$JOBS" 2>&1 | tee make.log

    log_info "编译完成，安装到 $PREFIX..."
    make install 2>&1 | tee make_install.log

    log_info "Angie 安装完成！"
}

# ---------------------------------------------------------------------------
# 8. 打包产出
# ---------------------------------------------------------------------------
package_output() {
    local output_dir=$1
    mkdir -p "$output_dir"

    local angie_bin="${PREFIX}/sbin/angie"
    if [ ! -x "$angie_bin" ]; then
        log_error "找不到编译好的 Angie 二进制: $angie_bin"
    fi

    local OUTPUT_NAME="angie-${ANGIE_VERSION}_tongsuo-${TONGSUO_VERSION}_${PLATFORM}_$(date +%Y%m%d)"

    log_info "验证编译结果..."
    echo "--------------------------------------------"
    "$angie_bin" -V 2>&1
    echo "--------------------------------------------"

    # 创建安装包目录结构
    local pkg_dir="${output_dir}/${OUTPUT_NAME}"
    mkdir -p "$pkg_dir"

    # 复制二进制
    mkdir -p "${pkg_dir}/sbin"
    cp "$angie_bin" "${pkg_dir}/sbin/"

    # 复制配置和默认文件
    cp -r "${PREFIX}/conf" "${pkg_dir}/conf" 2>/dev/null || true
    cp -r "${PREFIX}/html" "${pkg_dir}/html" 2>/dev/null || true
    cp -r "${PREFIX}/logs" "${pkg_dir}/logs" 2>/dev/null || true

    # 复制动态模块（如有）
    if [ -d "${PREFIX}/modules" ]; then
        mkdir -p "${pkg_dir}/modules"
        cp -r "${PREFIX}/modules/"* "${pkg_dir}/modules/"
    fi

    # 复制 LuaJIT 库（运行时需要）
    mkdir -p "${pkg_dir}/luajit/lib"
    cp /usr/local/luajit/lib/libluajit* "${pkg_dir}/luajit/lib/" 2>/dev/null || true
    mkdir -p "${pkg_dir}/luajit/include"
    cp -r /usr/local/luajit/include/luajit-2.1 "${pkg_dir}/luajit/include/" 2>/dev/null || true

    # 创建启动脚本
    cat > "${pkg_dir}/start.sh" << 'SCRIPT'
#!/bin/bash
# Angie 启动脚本（带 Tongsuo 国密SSL）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="${SCRIPT_DIR}/luajit/lib:${LD_LIBRARY_PATH}"

ANGIE_BIN="${SCRIPT_DIR}/sbin/angie"
ANGIE_CONF="${SCRIPT_DIR}/conf/angie.conf"

case "$1" in
    start)
        echo "Starting Angie..."
        "$ANGIE_BIN" -c "$ANGIE_CONF"
        ;;
    stop)
        echo "Stopping Angie..."
        "$ANGIE_BIN" -s stop
        ;;
    reload)
        echo "Reloading Angie..."
        "$ANGIE_BIN" -s reload
        ;;
    restart)
        echo "Restarting Angie..."
        "$ANGIE_BIN" -s stop
        sleep 1
        "$ANGIE_BIN" -c "$ANGIE_CONF"
        ;;
    test)
        echo "Testing Angie configuration..."
        "$ANGIE_BIN" -t -c "$ANGIE_CONF"
        ;;
    *)
        echo "Usage: $0 {start|stop|reload|restart|test}"
        exit 1
        ;;
esac
SCRIPT
    chmod +x "${pkg_dir}/start.sh"

    # 创建信息文件
    cat > "${pkg_dir}/build_info.txt" << EOF
Angie + Tongsuo 国密SSL 编译包
================================
编译时间: $(date '+%Y-%m-%d %H:%M:%S')
架构    : $PLATFORM
Angie   : $ANGIE_VERSION
Tongsuo : $TONGSUO_VERSION
Zlib    : $ZLIB_VERSION
PCRE2   : $PCRE2_VERSION
LuaJIT  : v2.1

国密特性:
  - --with-openssl (内嵌 Tongsuo)
  - --with-openssl-opt="enable-ntls no-asm"
  - --with-ntls (国密NTLS协议)

编译参数 (angie -V):
EOF
    "$angie_bin" -V 2>&1 >> "${pkg_dir}/build_info.txt"

    # 创建 tar.gz 安装包
    log_info "打包为 tar.gz..."
    cd "$output_dir"
    tar czf "${OUTPUT_NAME}.tar.gz" "$OUTPUT_NAME"
    local pkg_size
    pkg_size=$(du -sh "${OUTPUT_NAME}.tar.gz" | cut -f1)

    echo ""
    echo "============================================================"
    log_info "编译打包完成！"
    echo "  目录: $pkg_dir"
    echo "  包  : ${output_dir}/${OUTPUT_NAME}.tar.gz"
    echo "  大小: $pkg_size"
    echo "============================================================"

    # 在工作区根目录生成产物标识
    echo "OUTPUT_PKG=${output_dir}/${OUTPUT_NAME}.tar.gz"
    echo "OUTPUT_NAME=${OUTPUT_NAME}"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    install_deps
    local wd
    wd=$(prepare_workdir)
    download_sources "$wd"
    build_luajit "$wd"
    build_pcre2 "$wd"
    build_zlib "$wd"
    configure_and_build_angie "$wd"

    local output_dir="${OUTPUT_DIR:-${wd}/output}"
    package_output "$output_dir"
}

main "$@"
