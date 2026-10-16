#!/bin/sh
#
# 复制 scratch-gui 的 Web 资源（scratchgui 目录整树）进 .app bundle。
#
# 为什么不用 Tuist 的 resources 字段：
#   Tuist 把普通目录当作“资源组”处理，会在打包时把子目录扁平化，
#   导致 js/、static/、images/ 等子资源丢失或塌陷，WKWebView 加载后看不到内容。
#   这里用构建期脚本把整个 scratchgui 目录按文件夹引用原样拷入
#   "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/scratchgui"，
#   Swift 侧用 subdirectory:"scratchgui" 即可正确命中 index.html 及其全部子资源。
#
set -e

SRC="$SRCROOT/SwiftUIStarter/scratchgui"
DST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/scratchgui"

if [ ! -d "$SRC" ]; then
  echo "warning: scratchgui 源目录未找到：$SRC，跳过拷贝。"
  exit 0
fi

rm -rf "$DST"
mkdir -p "$DST"
cp -R "$SRC/." "$DST/"

# 统计拷入文件数，便于 CI 日志核对资源是否真的进来
COUNT=$(find "$DST" -type f | wc -l | tr -d ' ')
echo "✅ 已拷贝 scratch-gui Web 资源：$SRC -> $DST （共 $COUNT 个文件）"

# 复制预置离线资产（default project 素材）进 .app bundle 根下 OfflineAssets/。
# 随 App 分发，启动 hydrate 即可用，免去用户手动下载离线包。
SRC2="$SRCROOT/SwiftUIStarter/OfflineAssets"
DST2="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/OfflineAssets"

if [ -d "$SRC2" ]; then
  rm -rf "$DST2"
  mkdir -p "$DST2"
  cp -R "$SRC2/." "$DST2/"
  COUNT2=$(find "$DST2" -type f | wc -l | tr -d ' ')
  echo "✅ 已拷贝预置离线资产：$SRC2 -> $DST2 （共 $COUNT2 个文件）"
else
  echo "warning: 预置离线资产目录未找到：$SRC2，跳过拷贝。"
fi
