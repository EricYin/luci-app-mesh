#!/bin/sh
# 校验三份文件清单完全一致：
#   ① MANIFEST（单一真相源）
#   ② Makefile 的 Package/.../install 段（随固件/包管理器安装实际落地的文件）
#   ③ mesh-install.sh 里的 BUILTIN_MANIFEST（卸载扫残留用的内置副本）
#
# 只要有人加了随包文件却只改了其中一处，这里就红 —— 那正是 install.sh 曾长期
# 漏装 rc.wps/10-mesh、uci-defaults/40-...、nginx conf 三个文件的成因。
#
# 用法: sh .github/scripts/check-manifest.sh   （在仓库根目录执行）
set -e

cd "$(dirname "$0")/../.."

# 临时目录用**相对路径**：本机安全策略会拦截带盘符路径上的 rm -rf，
# 而 CI 的工作目录本来就是仓库根，两者都适用。
tmp=".manifest-check.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

# ① MANIFEST：跳过注释行与空行，取第 2 字段（目标绝对路径）
grep -v '^#' MANIFEST | grep -v '^[[:space:]]*$' | cut -d'|' -f2 | sort -u > "$tmp/manifest"

# ② Makefile 的 install 段：只看 $(INSTALL_BIN) / $(INSTALL_DATA) 两类的行，
#    $(INSTALL_DIR) 是建目录语句，不能算文件（它们的目标同样写成 $(1)/xxx，
#    靠"结尾有没有 /"区分是不可靠的 —— $(1)/etc/config 结尾就没有 /）。
#    目标以 / 结尾时表示"拷到这个目录"，要把源路径的通配符展开成具体文件名。
sed -n '/^define Package\/.*\/install$/,/^endef$/p' Makefile \
	| grep -E '\$\(INSTALL_(BIN|DATA)\)' > "$tmp/inst_lines"

# ⚠ 写成"文件重定向喂 while"而不是"管道喂 while"：
#   管道版在部分 shell（含 Git Bash / busybox 的某些构建）下 while 跑在子 shell，
#   变量与退出码都回不来；重定向版行为一致且可移植。
: > "$tmp/makefile_raw"
while IFS= read -r line; do
	src=$(printf '%s\n' "$line" | grep -o '\$(CURDIR)/[^ ]*' | sed 's#^\$(CURDIR)/##')
	dst=$(printf '%s\n' "$line" | grep -o '\$(1)/[^ ]*' | sed 's#^\$(1)##')
	if [ -z "$src" ] || [ -z "$dst" ]; then continue; fi
	case "$dst" in
		*/)
			base=${dst%/}
			for f in $src; do
				if [ -f "$f" ]; then printf '%s/%s\n' "$base" "${f##*/}" >> "$tmp/makefile_raw"; fi
			done
			;;
		*) printf '%s\n' "$dst" >> "$tmp/makefile_raw" ;;
	esac
done < "$tmp/inst_lines"
sort -u "$tmp/makefile_raw" > "$tmp/makefile"

# ③ mesh-install.sh 的内置清单：BUILTIN_MANIFEST=' ... ' 之间的绝对路径行
sed -n "/^BUILTIN_MANIFEST='/,/^'\$/p" mesh-install.sh \
	| grep '^/' | sort -u > "$tmp/builtin"

rc=0
for pair in "manifest:makefile" "manifest:builtin"; do
	a=${pair%%:*}; b=${pair##*:}
	diff_out=$(diff "$tmp/$a" "$tmp/$b" 2>/dev/null || true)
	if [ -n "$diff_out" ]; then
		echo "✗ $a 与 $b 不一致："
		printf '%s\n' "$diff_out" | sed 's/^/    /'
		rc=1
	else
		echo "✓ $a == $b（$(wc -l < "$tmp/$a") 项）"
	fi
done

if [ "$rc" != 0 ]; then
	echo
	echo "修法：新增/删除随包文件时，MANIFEST、Makefile 的 Package/install 段、"
	echo "      mesh-install.sh 的 BUILTIN_MANIFEST 三处必须同时改。"
	exit 1
fi

# 顺带校验：MANIFEST 里声明的源文件必须真实存在（防止手滑写错路径）
missing=0
while IFS='|' read -r src dst mode; do
	case "$src" in ''|'#'*) continue ;; esac
	[ -n "$dst" ] || continue
	if [ ! -f "$src" ]; then
		echo "✗ MANIFEST 声明的源文件不存在: $src"
		missing=$((missing + 1))
	fi
	case "$mode" in
		755|644) ;;
		*) echo "✗ MANIFEST 权限字段只能是 755 或 644: $src -> $mode"; missing=$((missing + 1)) ;;
	esac
done < MANIFEST
[ "$missing" -eq 0 ] || exit 1
echo "✓ MANIFEST 源文件齐全、权限字段合法"
