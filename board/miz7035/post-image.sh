#!/bin/sh
# MIZ7035 post-image：产出可直接烧录到 eMMC / QSPI 的镜像集合
#
# 产物（output/images/）：
#   system.dtb      <- LINUX_DTBS 的第一个（U-Boot 按此名加载）
#   uImage          <- 内核
#   boot.bin        <- U-Boot SPL（126KB）
#   u-boot.img      <- U-Boot 主体
#   BOOT.BIN        <- SPL + U-Boot（bootgen，可直接烧 QSPI 0x0 / eMMC p1）
#   rootfs.ext4     <- 根文件系统（烧 eMMC p2）
#   boot.vfat       <- 启动分区内容（BOOT.BIN/system.bit/uImage/system.dtb）
#   rootfs.cpio.gz.u-boot <- QSPI 兜底 ramdisk（可选，若启用 CPIO）
set -eu

BOARD_DIR="$(dirname "$0")"
BUILD_DIR="$(pwd)"
BINARIES_DIR="${BINARIES_DIR:-${BUILD_DIR}/images}"

echo "[post-image] MIZ7035 images in ${BINARIES_DIR}"

# bootgen / mkimage 由 Buildroot host 或系统提供，这里补齐常见位置
for d in /home/eva/.local/bin /home/eva/software/xilinx/2025.2/Vivado/bin; do
    case ":${PATH}:" in *":${d}:"*) ;; *) [ -d "$d" ] && PATH="${d}:${PATH}" ;; esac
done
export PATH

# Buildroot 的 U-Boot 产物里是 u-boot-dtb.bin/u-boot.bin，标准 bootgen 需要 u-boot.img 形式的 payload；
# 这里统一产出 u-boot.img（mkimage 包装），缺失时回退直接用 u-boot.bin。
if [ ! -f "${BINARIES_DIR}/u-boot.img" ]; then
    if [ -f "${BINARIES_DIR}/u-boot-dtb.bin" ] && command -v mkimage >/dev/null 2>&1; then
        mkimage -A arm -O u-boot -T firmware -C none -n "U-Boot" \
            -a 0x4000000 -e 0x4000000 \
            -d "${BINARIES_DIR}/u-boot-dtb.bin" "${BINARIES_DIR}/u-boot.img" >/dev/null 2>&1 || true
    fi
    [ -f "${BINARIES_DIR}/u-boot.img" ] || cp -f "${BINARIES_DIR}/u-boot.bin" "${BINARIES_DIR}/u-boot.img" 2>/dev/null || true
fi

# ---------------------------------------------------------------- 1. system.dtb
# U-Boot 的 emmcboot 脚本按 "system.dtb" 名字从 FAT 分区加载
LINUX_DTBS="$(make --no-print-directory VARS=LINUX_DTBS printvars 2>/dev/null || true)"
if [ -n "${LINUX_DTBS}" ]; then
    FIRST_DTB="$(echo "${LINUX_DTBS}" | awk '{print $1}')"
    [ -n "${FIRST_DTB}" ] && ln -fs "$(basename "${FIRST_DTB}")" "${BINARIES_DIR}/system.dtb"
fi
# 兜底：直接把我们的板级 dtb 复制成 system.dtb
if [ ! -e "${BINARIES_DIR}/system.dtb" ]; then
    for cand in zynq-miz7035.dtb; do
        [ -f "${BINARIES_DIR}/${cand}" ] && ln -fs "${cand}" "${BINARIES_DIR}/system.dtb"
    done
fi

# ---------------------------------------------------------------- 2. BOOT.BIN（FSBL + U-Boot）
# 关键：Zynq-7000 的 BootROM 只接受 FSBL 作为第一个分区。
# 用 U-Boot SPL(boot.bin) 做 [bootloader] 时 bootgen 虽报成功，但 partition header
# 里 U-Boot 分区的 load 字段为 0，BootROM 无法定位 U-Boot，板子会卡在 BootROM。
# 因此这里用 FSBL + u-boot(ELF) + system.dtb@0x100000 的三分区方案（与 PetaLinux 一致）。
# FSBL 优先取 images 目录里的副本（已从 PetaLinux 工程迁出），可用 MIZ7035_FSBL_ELF 覆盖
FSBL_ELF="${MIZ7035_FSBL_ELF:-${BINARIES_DIR}/zynq_fsbl.elf}"
[ -f "${FSBL_ELF}" ] || FSBL_ELF="/home/eva/work/z7035/linux/build/images/zynq_fsbl.elf"

# U-Boot 必须包含板级 dtb；Buildroot 产出 u-boot-dtb.bin，bootgen 需要 ELF 才能自动取 load 地址
if [ -f "${BINARIES_DIR}/u-boot" ]; then
    UBOOT_PAYLOAD="u-boot"
elif [ -f "${BINARIES_DIR}/u-boot.elf" ]; then
    UBOOT_PAYLOAD="u-boot.elf"
else
    UBOOT_PAYLOAD=""
fi

if [ -n "${UBOOT_PAYLOAD}" ] && [ -f "${FSBL_ELF}" ] && [ -e "${BINARIES_DIR}/system.dtb" ]; then
    # FSBL 已在 BINARIES_DIR 时不要 cp（同文件会让 set -e 退出）
    [ "${FSBL_ELF}" -ef "${BINARIES_DIR}/zynq_fsbl.elf" ] || \
        cp -f "${FSBL_ELF}" "${BINARIES_DIR}/zynq_fsbl.elf"
    DTB_REAL="$(readlink -f "${BINARIES_DIR}/system.dtb")"
    [ "${DTB_REAL}" -ef "${BINARIES_DIR}/boot_dtb.dtb" ] || \
        cp -f "${DTB_REAL}" "${BINARIES_DIR}/boot_dtb.dtb"
    cat > "${BINARIES_DIR}/boot.bif" <<'BIFEOF'
// MIZ7035 boot image: FSBL + U-Boot + board DTB
// Zynq BootROM 要求第一分区为 FSBL；U-Boot 由 FSBL 加载到 0x04000000
the_ROM_image:
{
	[bootloader] zynq_fsbl.elf
	u-boot
	[load=0x100000] boot_dtb.dtb
}
BIFEOF
    # bif 里的 u-boot 名字按实际 payload 替换
    if [ "${UBOOT_PAYLOAD}" != "u-boot" ]; then
        sed -i "s|^\tu-boot$|\t${UBOOT_PAYLOAD}|" "${BINARIES_DIR}/boot.bif"
    fi
    if command -v bootgen >/dev/null 2>&1; then
        ( cd "${BINARIES_DIR}" && bootgen -image boot.bif -arch zynq -o BOOT.BIN -w on ) \
            && echo "[post-image] BOOT.BIN generated (FSBL + U-Boot + dtb)"
    else
        echo "[post-image] WARN: bootgen not found; BOOT.BIN 未生成"
    fi
else
    echo "[post-image] WARN: BOOT.BIN skipped (need u-boot ELF + FSBL elf + system.dtb)"
    echo "            FSBL_ELF=${FSBL_ELF}  UBOOT_PAYLOAD=${UBOOT_PAYLOAD}"
fi

# ---------------------------------------------------------------- 3. 启动分区集合
# 与现场 eMMC p1 布局一致：BOOT.BIN / uImage / system.dtb / system.bit
mkdir -p "${BINARIES_DIR}/bootfs"
for f in BOOT.BIN boot.bin u-boot.img uImage system.dtb system.bit; do
    [ -f "${BINARIES_DIR}/${f}" ] && cp -f "${BINARIES_DIR}/${f}" "${BINARIES_DIR}/bootfs/" || true
done

# system.bit：如果仓库里有最新实现结果就带上（U-Boot 会 fpga loadb）
BIT_SRC="/home/eva/work/z7035/fpga/runs/system.runs/impl_1/system_wrapper.bit"
if [ -f "${BIT_SRC}" ] && [ ! -f "${BINARIES_DIR}/bootfs/system.bit" ]; then
    cp -f "${BIT_SRC}" "${BINARIES_DIR}/bootfs/system.bit"
    echo "[post-image] system.bit 已从 FPGA 工程带入"
fi

# ---------------------------------------------------------------- 4. boot.scr（可选，兼容 distro_bootcmd）
if [ -f "${BINARIES_DIR}/bootfs/uImage" ] && command -v mkimage >/dev/null 2>&1; then
    cat > "${BINARIES_DIR}/bootfs/boot.cmd" <<'EOF'
setenv bootargs console=ttyPS0,115200 earlycon root=/dev/mmcblk0p2 rw rootwait rootfstype=ext4 net.ifnames=0
load mmc 0:1 ${kernel_addr_r} uImage
load mmc 0:1 ${fdt_addr_r} system.dtb
bootm ${kernel_addr_r} - ${fdt_addr_r}
EOF
    mkimage -A arm -O linux -T script -C none \
        -d "${BINARIES_DIR}/bootfs/boot.cmd" "${BINARIES_DIR}/bootfs/boot.scr" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 5. 清单
{
    echo "MIZ7035 build artifacts ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
    echo
    for f in BOOT.BIN boot.bin u-boot.img uImage system.dtb system.bit rootfs.ext4; do
        if [ -f "${BINARIES_DIR}/${f}" ]; then
            printf "  %-16s %10s bytes  %s\n" "${f}" "$(stat -Lc %s "${BINARIES_DIR}/${f}")" "$(md5sum "$(readlink -f "${BINARIES_DIR}/${f}")" | cut -d' ' -f1)"
        fi
    done
} > "${BINARIES_DIR}/MANIFEST.txt"
cat "${BINARIES_DIR}/MANIFEST.txt"

echo "[post-image] done"
