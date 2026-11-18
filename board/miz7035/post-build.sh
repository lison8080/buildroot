#!/bin/sh
# MIZ7035 post-build：把板级定制塞进 target 根文件系统
#
# 为什么在这里做而不是 overlay：
#   1) zsh 的 oh-my-zsh 与 /.oh-my-zsh 的属主必须是 root:root 且目录不能 group-writable，
#      否则 compinit 会判定 insecure 并交互式追问（overlay 复制会保留 host 属主/权限）。
#   2) /etc/passwd、/etc/shadow 需要精确改写（root shell 改成 zsh）。
#   3) 需要删除 buildroot 默认 getty 的 tty1 相关项、并统一串口 TERM=xterm，
#      避免 TERM=vt102 引发的 zsh tputs NUL 字节问题。
set -eu

TARGET_DIR="${1}"
BOARD_DIR="$(dirname "$0")"

BOARD_NAME="MIZ7035"

# ---------------------------------------------------------------- 1. 串口控制台
# buildroot 已按 defconfig 生成 inittab（ttyPS0 115200 xterm）；这里只做校验/兜底
if [ -f "${TARGET_DIR}/etc/inittab" ]; then
    if ! grep -q 'ttyPS0' "${TARGET_DIR}/etc/inittab"; then
        echo "ttyPS0:12345:respawn:/sbin/getty -L ttyPS0 115200 xterm" >> "${TARGET_DIR}/etc/inittab"
    fi
    # 统一 TERM=xterm（vt102/linux 的 padding 会让 zsh 输出 NUL 字节）
    sed -i 's|\(ttyPS0.*\)vt102|\1xterm|; s|\(ttyPS0.*\)linux|\1xterm|' "${TARGET_DIR}/etc/inittab"
fi

# ---------------------------------------------------------------- 2. 主机名与网络
echo "${BOARD_NAME}" | tr '[:upper:]' '[:lower:]' > "${TARGET_DIR}/etc/hostname" || true

mkdir -p "${TARGET_DIR}/etc/network"
cat > "${TARGET_DIR}/etc/network/interfaces" <<'EOF'
# MIZ7035 static network
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.168.3.223
    netmask 255.255.255.0
    gateway 192.168.3.1
EOF

# ---------------------------------------------------------------- 3. root 的 shell 与 home
if [ -f "${TARGET_DIR}/etc/passwd" ] && [ -x "${TARGET_DIR}/usr/bin/zsh" ] || [ -x "${TARGET_DIR}/bin/zsh" ]; then
    ZSH_PATH="/usr/bin/zsh"
    [ -x "${TARGET_DIR}${ZSH_PATH}" ] || ZSH_PATH="/bin/zsh"
    sed -i "s|^root:\(.*\):/bin/sh$|root:\1:${ZSH_PATH}|" "${TARGET_DIR}/etc/passwd"
    # 若原本就是其它 shell，也强制指向 zsh
    awk -F: 'BEGIN{OFS=":"} $1=="root"{$7="'"${ZSH_PATH}"'"} {print}' \
        "${TARGET_DIR}/etc/passwd" > "${TARGET_DIR}/etc/passwd.new" \
        && mv "${TARGET_DIR}/etc/passwd.new" "${TARGET_DIR}/etc/passwd"
fi

mkdir -p "${TARGET_DIR}/root"
chmod 700 "${TARGET_DIR}/root"

# ---------------------------------------------------------------- 4. oh-my-zsh（root 家目录）
if [ -d "${BOARD_DIR}/rootfs-overlay/root/.oh-my-zsh" ]; then
    rm -rf "${TARGET_DIR}/root/.oh-my-zsh"
    cp -a "${BOARD_DIR}/rootfs-overlay/root/.oh-my-zsh" "${TARGET_DIR}/root/.oh-my-zsh"
fi
for f in .zshrc .zshenv .profile; do
    [ -f "${BOARD_DIR}/rootfs-overlay/root/${f}" ] && \
        cp -f "${BOARD_DIR}/rootfs-overlay/root/${f}" "${TARGET_DIR}/root/${f}"
done

# 清掉可能来自缓存的 zcompdump，避免版本不匹配打印函数体
rm -f "${TARGET_DIR}"/root/.zcompdump*

# 权限：oh-my-zsh 必须 root:root 且不可 group/other 写，否则 compinit 报 insecure
chown -R 0:0 "${TARGET_DIR}/root" 2>/dev/null || true
chmod 700 "${TARGET_DIR}/root"
if [ -d "${TARGET_DIR}/root/.oh-my-zsh" ]; then
    chmod -R go-w "${TARGET_DIR}/root/.oh-my-zsh"
fi

# ---------------------------------------------------------------- 5. 服务脚本
# tdp_mem 与 z7035_app 的 init 脚本由 br2-external 里的包（tdp-mem / z7035-app）
# 各自通过 INSTALL_INIT_SYSV 安装，这里不再重复生成，避免内容被覆盖。
# 仅兜底创建 rcS.d 软链（部分 sysvinit 风格脚本会找这里）。
mkdir -p "${TARGET_DIR}/etc/rcS.d"
for n in S80tdp_mem S90z7035_app; do
    if [ -f "${TARGET_DIR}/etc/init.d/${n}" ]; then
        ln -sf "../init.d/${n}" "${TARGET_DIR}/etc/rcS.d/${n}"
    fi
done

# ---------------------------------------------------------------- 6. 其它板级文件
# app（z7035_app）装到 /root/ 下，与 root 的 home 一致（/etc/passwd 里 root:/root）。
# 不要再创建 /home/root —— 那是 PetaLinux 的惯例，Buildroot 下 root 的 home 是 /root。

# /etc/zshenv：全局 UTF-8 与 terminfo（root 与其它用户都生效）
cat > "${TARGET_DIR}/etc/zshenv" <<'EOF'
# 全局 zsh 环境：UTF-8 与 terminfo 路径（板端 rootfs 布局）
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export TERMINFO_DIRS=/usr/share/terminfo
EOF
chmod 0644 "${TARGET_DIR}/etc/zshenv"

# modprobe 依赖表（S11modules 会跑 depmod -a，这里预生成便于离线）
if [ -d "${TARGET_DIR}/lib/modules" ] && command -v depmod >/dev/null 2>&1; then
    depmod -b "${TARGET_DIR}" -a 2>/dev/null || true
fi

echo "[post-build] ${BOARD_NAME} customisation applied"
