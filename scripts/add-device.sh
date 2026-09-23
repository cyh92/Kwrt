#!/bin/bash
#=================================================
# add-device.sh — 把自定义 dts 注入 openwrt 源码并注册为可编译设备
# 用法:
#   bash add-device.sh <TARGET> <DEVICE> <OPENWRT_DIR> [IMAGE_SIZE]
#   TARGET     : devices 下的 target 名, 如 mediatek_filogic
#   DEVICE     : dts 基名(不带 .dts), 如 mt7981b-cmcc-rax3000m-nand
#   OPENWRT_DIR: 已克隆并配置好的 openwrt 源码根目录
#   IMAGE_SIZE : 可选, 固件分区大小, 默认 65536k (16MB)
#
# 作用:
#   1. 把 devices/<TARGET>/.../dts/<DEVICE>.dts(.dtsi) 复制进 openwrt 源码
#      (保持与原结构一致的相对路径: dts/ 或 files/arch/... 两种机制都支持)
#   2. 在对应平台 image/*.mk 中注册 Device/<DEVICE> 块 + TARGET_DEVICES
#      → make menuconfig / defconfig 的 Target Devices 即可识别该设备
#=================================================
set -e

TARGET="$1"
DEVICE="$2"
OPENWRT="$3"
IMAGE_SIZE="${4:-65536k}"

[ -z "$TARGET" ] && { echo "错误: 缺少 TARGET"; exit 1; }
[ -z "$DEVICE" ] && { echo "错误: 缺少 DEVICE"; exit 1; }
[ -z "$OPENWRT" ] && { echo "错误: 缺少 OPENWRT_DIR"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/scripts/devices.conf"

# 从映射表取该 target 的信息: platform | dts源目录 | image mk | subtarget
LINE=$(grep -E "^$TARGET\|" "$CONF" || true)
if [ -z "$LINE" ]; then
  echo "错误: devices.conf 中没有 $TARGET 的映射, 请先添加"; exit 1
fi
PLATFORM=$(echo "$LINE" | cut -d'|' -f2)
DTS_SRC=$(echo "$LINE" | cut -d'|' -f3)
IMG_MK=$(echo "$LINE" | cut -d'|' -f4)
SUBTARGET=$(echo "$LINE" | cut -d'|' -f5)

echo "==> TARGET=$TARGET PLATFORM=$PLATFORM SUBTARGET=$SUBTARGET DEVICE=$DEVICE"

# ---------- 1. 定位并复制 dts ----------
DTS_FILE=$(find "$ROOT/$DTS_SRC" -maxdepth 3 -name "$DEVICE.dts" -print -quit)
DTSI_FILE=$(find "$ROOT/$DTS_SRC" -maxdepth 3 -name "$DEVICE.dtsi" -print -quit)

if [ -z "$DTS_FILE" ] && [ -z "$DTSI_FILE" ]; then
  echo "错误: devices 下找不到 $DEVICE.dts/.dtsi (搜索目录: $DTS_SRC)"; exit 1
fi

# 目标目录: 去掉 "devices/<TARGET>/diy" 前缀, 保持与原结构一致的相对路径
REL="${DTS_SRC#devices/$TARGET/diy}"
DST_DIR="$OPENWRT$REL"
mkdir -p "$DST_DIR"

if [ -n "$DTS_FILE" ]; then
  cp -f "$DTS_FILE" "$DST_DIR/"
  echo "==> 复制 $DEVICE.dts → $DST_DIR/"
fi
if [ -n "$DTSI_FILE" ]; then
  cp -f "$DTSI_FILE" "$DST_DIR/"
  echo "==> 复制 $DEVICE.dtsi → $DST_DIR/"
fi
# 若 dts 中 include 了同目录其他 .dtsi(公共头), 一并复制
if [ -n "$DTS_FILE" ]; then
  for inc in $(grep -oE '^#include [<"]?[^>"]+\.dtsi[>"]?' "$DTS_FILE" | grep -oE '[^/<>"]+\.dtsi' || true); do
    if [ -f "$ROOT/$DTS_SRC/$inc" ] && [ ! -f "$DST_DIR/$inc" ]; then
      cp -f "$ROOT/$DTS_SRC/$inc" "$DST_DIR/"
      echo "==> 复制依赖头 $inc → $DST_DIR/"
    fi
  done
fi

# ---------- 2. 在 image Makefile 注册 Device 块 ----------
IMG_MK_FULL="$OPENWRT/$IMG_MK"
if [ ! -f "$IMG_MK_FULL" ]; then
  echo "警告: 源码中不存在 $IMG_MK, 将创建空文件"
  mkdir -p "$(dirname "$IMG_MK_FULL")"
  : > "$IMG_MK_FULL"
fi

if grep -q "define Device/$DEVICE\b" "$IMG_MK_FULL"; then
  echo "==> $IMG_MK 已存在 Device/$DEVICE 定义, 跳过注册"
else
  {
    echo ""
    echo "# ===== Kwrt 自定义设备 $DEVICE (由 add-device.sh 自动注入) ====="
    echo "define Device/$DEVICE"
    echo "  DEVICE_TITLE := $DEVICE"
    echo "  DEVICE_DTS := $DEVICE"
    echo "  IMAGE_SIZE := $IMAGE_SIZE"
    echo "  DEVICE_PACKAGES := "
    echo "endef"
    echo "TARGET_DEVICES += $DEVICE"
  } >> "$IMG_MK_FULL"
  echo "==> 已注册 Device/$DEVICE → $IMG_MK"
fi

# ---------- 3. 输出 .config 追加片段(供 defconfig 启用该设备) ----------
CFG_DEVICE=$(echo "$DEVICE" | tr '.-' '__')
echo ""
echo "==> 请在 .config 中追加以下行以启用该设备:"
echo "CONFIG_TARGET_${PLATFORM}=y"
echo "CONFIG_TARGET_${PLATFORM}_${SUBTARGET}=y"
echo "CONFIG_TARGET_${PLATFORM}_${SUBTARGET}_DEVICE_${CFG_DEVICE}=y"
echo "CONFIG_TARGET_ALL_PROFILES=n"
echo ""
echo "完成: $DEVICE 已注入 $OPENWRT 并可被 menuconfig 识别"
