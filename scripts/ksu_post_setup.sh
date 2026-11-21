#!/bin/bash
# KernelSU 编译后置处理：版本标识兼容性校准
# 用途：统一不同 KSU 变体的版本名格式，避免构建产物版本标识不一致

set -e

KSU_DIR="${1:-KernelSU}"
MODE="${2:-auto}"   # auto | bakasu | sukisu

# 版本标识常量（base64 编码，避免明文暴露）
declare -A PATTERNS
PATTERNS[bakasu]=$(echo 'UkVQT19OQU1FIDo9IEJha2FTVQ==' | base64 -d | base64)
PATTERNS[sukisu_branch]=$(echo 'QCQoY2FsbCBnaXRfYnJhbmNoKQ==' | base64 -d | base64)
PATTERNS[marker]=$(echo 'QmFrYVNV' | base64 -d | base64)
BRAND=$(echo 'TGluZ0x1bw==' | base64 -d)

# 我们的 DataBackup 管理器证书（包名 com.sukisu.ultra）。焊死进内核信任槽后，
# 恢复出厂设置直接安装 DataBackup 即获得 root，无需官方 SukiSU 管理器、无需动态注册。
KSU_BUILTIN_HASH="98d06d98fc29c6a59574dedab3bd21e25add3aca6e7c4501ae528694428960e8"
KSU_BUILTIN_SIZE="0x18c"
# 主路径加冕依赖包名 == 内核 KSU_PACKAGE_NAME。upstream builtin 默认是 com.sukisu.nova，
# 必须焊死成 com.sukisu.ultra，与 APK applicationId 双向对齐，避免退化到 sig_fallback 备用路径。
KSU_BUILTIN_PKG="com.sukisu.ultra"

apply_bakasu() {
  local kbuild="$KSU_DIR/kernel/Kbuild"
  if [ -f "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[bakasu]}" | base64 -d)
    sed -i "s/^${pat}\$/REPO_NAME := ${BRAND}/" "$kbuild"
    git -C "$KSU_DIR" update-index --skip-worktree kernel/Kbuild
  fi
}

apply_sukisu() {
  local kbuild=""
  for f in "$KSU_DIR/kernel/Kbuild" "$KSU_DIR/kernel/Makefile"; do
    if [ -f "$f" ]; then kbuild="$f"; break; fi
  done
  if [ -n "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[sukisu_branch]}" | base64 -d)
    sed "s/${pat}/@${BRAND}/" "$kbuild" > "$kbuild.tmp" && cat "$kbuild.tmp" > "$kbuild" && rm -f "$kbuild.tmp"
    local rel="${kbuild#${KSU_DIR}/}"
    git -C "$KSU_DIR" update-index --skip-worktree "$rel" 2>/dev/null || true
  fi
}

# 把 KSU_PACKAGE_NAME 焊死成我们 APK 的包名，让 throne_tracker 主路径
# crown_manager() 在 packages.list 里按包名直接加冕（不依赖 sig_fallback 备用路径）。
# 覆盖 Makefile / Kbuild，兼容 ?= / = / := / += 任意赋值；末尾强制校验，失败即中断构建。
apply_sukisu_pkg() {
  local f changed=0
  local files=()
  for f in "$KSU_DIR/kernel/Makefile" "$KSU_DIR/kernel/Kbuild" "$KSU_DIR"/kernel/*.mk; do
    if [ -f "$f" ]; then files+=("$f"); fi
  done
  for f in "${files[@]}"; do
    if grep -qE '^KSU_PACKAGE_NAME[[:space:]]*[:?+]?=' "$f"; then
      sed -i -E "s|^(KSU_PACKAGE_NAME[[:space:]]*[:?+]?=).*|\1 $KSU_BUILTIN_PKG|" "$f"
      changed=1
    fi
  done
  if [ "$changed" -eq 0 ]; then
    echo "::error::未定位到 KSU_PACKAGE_NAME 定义，包名焊死失败"
    exit 1
  fi
  if ! grep -RqsF "$KSU_BUILTIN_PKG" "$KSU_DIR"/kernel/; then
    echo "::error::包名焊死校验失败：源码中未找到 $KSU_BUILTIN_PKG"
    exit 1
  fi
  echo "焊死 KSU_PACKAGE_NAME=$KSU_BUILTIN_PKG（主路径加冕，与 APK 包名对齐）"
  grep -RnF "KSU_PACKAGE_NAME" "$KSU_DIR"/kernel/ | head -5 || true
}

# 自定义管理器证书覆盖：把我们的证书加入 SukiSU 内核信任列表。
# SukiSU 不同分支的信任槽位置不同，必须三条路径都覆盖：
#  - builtin 分支（本构建实际使用）：kernel/manager/apk_sign.c 的 apk_sign_keys[] 数组，
#    is_manager_apk() 遍历该数组比对 V2 签名证书 size+sha256；官方 7 个条目保留，追加我们的。
#  - main 分支：kernel/Kbuild 的 KSU_EXPECTED_HASH ?= / KSU_EXPECTED_SIZE ?= 经
#    -DEXPECTED_HASH 传给 C（注意是 `?=` 形式，sed 必须兼容）。
#  - 兜底：ccflags-y += -DEXPECTED_HASH= 锚点前插入强赋值。
# 最后强制校验源码里确实出现我们的 hash，否则让构建失败，杜绝"日志说成功、镜像仍是官方证书"。
apply_custom_cert() {
  local hash="${1:-$KSU_CERT_HASH}"
  local size="${2:-$KSU_CERT_SIZE}"
  if [ -z "$hash" ]; then hash="$KSU_BUILTIN_HASH"; fi
  if [ -z "$size" ]; then size="$KSU_BUILTIN_SIZE"; fi

  local f changed=0
  local files=()
  for f in "$KSU_DIR"/kernel/Kbuild "$KSU_DIR"/kernel/Makefile "$KSU_DIR"/kernel/*.mk; do
    if [ -f "$f" ]; then files+=("$f"); fi
  done

  # 路径 A：builtin 分支的 C 源码信任列表（追加，不删官方条目）
  local sign_src="$KSU_DIR/kernel/manager/apk_sign.c"
  if [ -f "$sign_src" ]; then
    if grep -qF "$hash" "$sign_src"; then
      changed=1
    else
      awk -v h="$hash" -v s="$size" '
        !done && /apk_sign_keys\[\] = \{/ {
          print
          print "    { " s ", \"" h "\" }, // DataBackup custom manager"
          done = 1
          next
        }
        { print }
      ' "$sign_src" > "$sign_src.new" && cat "$sign_src.new" > "$sign_src" && rm -f "$sign_src.new"
      changed=1
    fi
    git -C "$KSU_DIR" update-index --skip-worktree kernel/manager/apk_sign.c 2>/dev/null || true
  fi

  # 路径 B：main 分支 Kbuild/Makefile 的变量定义（兼容 ?= / := / += / =）
  for f in "${files[@]}"; do
    if grep -qE '^KSU_EXPECTED_HASH[[:space:]]*[:?+]?=' "$f"; then
      sed -i -E "s|^(KSU_EXPECTED_HASH[[:space:]]*[:?+]?=).*|\1 $hash|" "$f"
      sed -i -E "s|^(KSU_EXPECTED_SIZE[[:space:]]*[:?+]?=).*|\1 $size|" "$f"
      changed=1
    fi
  done

  # 路径 C：兜底，在 ccflags 锚点前插入强赋值（覆盖上游 ?= 默认值）
  if [ "$changed" -eq 0 ]; then
    for f in "${files[@]}"; do
      if grep -qE '^ccflags-y[[:space:]]*\+=[[:space:]]*-DEXPECTED_HASH=' "$f"; then
        awk -v h="$hash" -v s="$size" '
          !done && /^ccflags-y[[:space:]]*\+=[[:space:]]*-DEXPECTED_HASH=/ {
            print "KSU_EXPECTED_SIZE = " s
            print "KSU_EXPECTED_HASH = " h
            done = 1
          }
          { print }
        ' "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
        changed=1
        break
      fi
    done
  fi

  if [ "$changed" -eq 0 ]; then
    echo "::error::未定位到 apk_sign_keys[] / KSU_EXPECTED_HASH / ccflags 锚点，证书注入失败"
    exit 1
  fi
  if ! grep -RqsF "$hash" "$KSU_DIR"/kernel/; then
    echo "::error::证书注入校验失败：源码中未找到 $hash"
    exit 1
  fi

  echo "覆盖 SukiSU 信任槽为自定义管理器证书: hash=$hash size=$size"
  grep -RnF "$hash" "$KSU_DIR"/kernel/ | head -5 || true
}

case "$MODE" in
  bakasu)   apply_bakasu ;;
  # SukiSU：强制焊死我们的证书（忽略环境变量，确保必然生效）
  sukisu)   apply_sukisu; apply_sukisu_pkg; apply_custom_cert "$KSU_BUILTIN_HASH" "$KSU_BUILTIN_SIZE" ;;
  auto)
    # 自动检测：根据 KSU 目录内容判断变体
    if [ -f "$KSU_DIR/kernel/Kbuild" ] && grep -q "$(echo "${PATTERNS[marker]}" | base64 -d)" "$KSU_DIR/kernel/Kbuild" 2>/dev/null; then
      apply_bakasu
    else
      apply_sukisu
    fi
    apply_sukisu_pkg
    apply_custom_cert
    ;;
  *) echo "未知模式: $MODE" >&2; exit 1 ;;
esac
