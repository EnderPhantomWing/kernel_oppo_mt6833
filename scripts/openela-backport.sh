#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# openela-backport.sh —— 从 OpenELA kernel-lts 的 linux-4.14.y 回移 CVE/稳定性修复
#
# 背景：
#   4.14.336 是官方 EOL 版本，之后由 OpenELA 继续维护（当前 4.14.357，
#   Makefile 里 EXTRAVERSION = -openela）。从 4.14.336 到现在约 2000 个提交，
#   绝大多数是从新内核回移的 CVE/稳定性修复。这些补丁的上下文是 4.14.357，
#   直接整包合并进 4.14.186 基线的厂商树会大面积冲突，所以按子系统分批、
#   逐个 git apply --check，通过的才落树，是最稳的做法。
#
# 用法：
#   scripts/openela-backport.sh kernel/bpf                  # 只报告，不落树
#   scripts/openela-backport.sh net/core net/ipv4 --apply   # 落树
#   scripts/openela-backport.sh fs --since 2024-01-01 --limit 300
#
# 选项：
#   --apply              真正写入工作区（默认 dry-run，只出报告）
#   --cve-only           只处理提交信息里带 CVE-YYYY-NNNN 的提交（推荐用于大范围回移）
#   --since DATE         GitHub since 参数，默认 2024-01-18（4.14.336 EOL 附近）
#   --until DATE         GitHub until 参数（配合 --since 限定区间，如 2020-06-01~2024-01-18）
#   --limit N            每个 path 最多处理 N 个提交，默认 200
#   --report DIR         报告目录，默认 .openela-backport/<UTC 时间戳>
#   --token TOKEN        GitHub token（也可用环境变量 GITHUB_TOKEN）
#   --branch NAME        默认 linux-4.14.y
#   -h, --help           显示帮助
#
# 自动跳过（这些提交即使能套用也不应该回移）：
#   * "LTS: Update to ..." / "Linux 4.14.x" 版本号提交（本项目不改版本号）
#   * merge 提交
#   * 触碰 Makefile / Kconfig / *_defconfig / arch/*/configs / .github 的提交
#     —— 避免改变 /proc/config.gz 里的 CONFIG 值，从而不会触发
#        libvintf 的内核配置校验（即"设备内部出现问题"弹窗）
#
# 输出：
#   $REPORT/report.tsv    status \t sha \t subject \t error
#   $REPORT/applied.txt   已落树的提交（便于 git revert / 复核）
#
# 依赖：bash、git、curl、jq

set -uo pipefail

UPSTREAM_REPO="openela/kernel-lts"
BRANCH="linux-4.14.y"
SINCE="2024-01-18"
UNTIL=""
LIMIT=200
APPLY=0
CVE_ONLY=0
TOKEN="${GITHUB_TOKEN:-}"
REPORT=""
PATHS=()

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--apply) APPLY=1 ;;
		--cve-only) CVE_ONLY=1 ;;
		--since) SINCE="${2:?--since needs a date}"; shift ;;
		--until) UNTIL="${2:?--until needs a date}"; shift ;;
		--limit) LIMIT="${2:?--limit needs a number}"; shift ;;
		--report) REPORT="${2:?--report needs a dir}"; shift ;;
		--token) TOKEN="${2:?--token needs a value}"; shift ;;
		--branch) BRANCH="${2:?--branch needs a value}"; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option: $1" ;;
		*) PATHS+=("$1") ;;
	esac
	shift
done

[ ${#PATHS[@]} -gt 0 ] || die "give at least one path, e.g. kernel/bpf"

for c in git curl jq; do
	command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c"
done
git rev-parse --git-dir >/dev/null 2>&1 || die "run me inside the kernel git tree"
[ -z "$(git status --porcelain)" ] && CLEAN=1 || CLEAN=0

if [ -z "$REPORT" ]; then
	REPORT=".openela-backport/$(date -u +%Y%m%d-%H%M%S)"
fi
mkdir -p "$REPORT/patches"
REPORT_TSV="$REPORT/report.tsv"
APPLIED_TXT="$REPORT/applied.txt"
: > "$REPORT_TSV"
: > "$APPLIED_TXT"

api() {
	local url="$1" out="$2"
	if [ -n "$TOKEN" ]; then
		curl -sS -m 60 -H "Authorization: token $TOKEN" "$url" -o "$out"
	else
		curl -sS -m 60 "$url" -o "$out"
	fi
}

# 跳过规则：补丁里出现的文件路径
patch_touches_forbidden() {
	local f="$1"
	grep -E '^diff --git ' "$f" | sed -E 's#^diff --git a/([^ ]+) b/.*#\1#' |
		grep -qE '(^|/)(Makefile|Kconfig|Kbuild)$|_defconfig$|^arch/[^/]+/configs/|^\.github/' 
}

skip_subject() {
	case "$1" in
		"LTS: Update to "*) return 0 ;;
		"Linux 4.14."*) return 0 ;;
		*"Merge tag"*) return 0 ;;
		*"Merge branch"*) return 0 ;;
	esac
	return 1
}

total_applied=0
total_skipped=0
total_conflict=0
total_failed=0

for path in "${PATHS[@]}"; do
	printf '\n== %s ==\n' "$path"
	page=1
	seen=0
	while [ "$seen" -lt "$LIMIT" ]; do
		url="https://api.github.com/repos/$UPSTREAM_REPO/commits?sha=$BRANCH&path=$path&since=$SINCE&per_page=50&page=$page"
		[ -n "$UNTIL" ] && url="$url&until=$UNTIL"
		attempt=0
		while :; do
			attempt=$((attempt + 1))
			api "$url" "$REPORT/list.json" || die "API request failed"
			if jq -e 'type == "object" and has("message")' "$REPORT/list.json" >/dev/null 2>&1; then
				msg=$(jq -r '.message' "$REPORT/list.json")
				# GitHub 对超大 path 查询偶尔返回 500，重试即可
				if [ "$msg" = "Server Error" ] && [ "$attempt" -lt 3 ]; then
					sleep $((attempt * 3))
					continue
				fi
				die "GitHub API error: $msg（设置 GITHUB_TOKEN 可提高限额）"
			fi
			break
		done

		n=$(jq 'length' "$REPORT/list.json")
		[ "$n" -eq 0 ] && break

		# 最旧的先处理，尽量满足提交之间的依赖顺序
		while IFS=$'\t' read -r sha subject parents; do
			[ "$seen" -ge "$LIMIT" ] && break
			seen=$((seen + 1))

			if [ "$parents" -gt 1 ] || skip_subject "$subject"; then
				printf 'SKIP     %s  %s\n' "${sha:0:10}" "$subject"
				printf 'SKIP\t%s\t%s\tmerge/version\n' "$sha" "$subject" >> "$REPORT_TSV"
				total_skipped=$((total_skipped + 1))
				continue
			fi

			pf="$REPORT/patches/$sha.patch"
			[ -s "$pf" ] || curl -sS -m 60 -L "https://github.com/$UPSTREAM_REPO/commit/$sha.patch" -o "$pf"

			# 厂商树里部分文件带可执行位（100755），与上游 100644 不一致；
			# 补丁里的 mode 变更行会让 git apply 直接拒绝，去掉即可（不影响内容）。
			sed -i -E '/^(old mode|new mode) /d' "$pf" 2>/dev/null || true

			if [ ! -s "$pf" ] || ! grep -q '^diff --git' "$pf"; then
				printf 'FAILED   %s  %s（补丁下载/格式异常）\n' "${sha:0:10}" "$subject"
				printf 'FAILED\t%s\t%s\tdownload\n' "$sha" "$subject" >> "$REPORT_TSV"
				total_failed=$((total_failed + 1))
				continue
			fi

			if patch_touches_forbidden "$pf"; then
				printf 'SKIP     %s  %s（触碰 Makefile/Kconfig/configs）\n' "${sha:0:10}" "$subject"
				printf 'SKIP\t%s\t%s\tmakefile/kconfig\n' "$sha" "$subject" >> "$REPORT_TSV"
				total_skipped=$((total_skipped + 1))
				continue
			fi

			if git apply --check "$pf" 2>"$REPORT/err.txt"; then
				if [ "$APPLY" -eq 1 ]; then
					git apply "$pf" || {
						printf 'FAILED   %s  %s（apply 阶段失败）\n' "${sha:0:10}" "$subject"
						printf 'FAILED\t%s\t%s\tapply\n' "$sha" "$subject" >> "$REPORT_TSV"
						total_failed=$((total_failed + 1))
						continue
					}
					printf 'APPLIED  %s  %s\n' "${sha:0:10}" "$subject"
					printf '%s\t%s\n' "$sha" "$subject" >> "$APPLIED_TXT"
				else
					printf 'CLEAN    %s  %s（--apply 未指定，未写入）\n' "${sha:0:10}" "$subject"
				fi
				printf 'CLEAN\t%s\t%s\t-\n' "$sha" "$subject" >> "$REPORT_TSV"
				total_applied=$((total_applied + 1))
			else
				err=$(grep -v '^warning:' "$REPORT/err.txt" | head -1 | cut -c1-160)
				[ -n "$err" ] || err=$(head -1 "$REPORT/err.txt" | cut -c1-160)
				printf 'CONFLICT %s  %s  [%s]\n' "${sha:0:10}" "$subject" "$err"
				printf 'CONFLICT\t%s\t%s\t%s\n' "$sha" "$subject" "$err" >> "$REPORT_TSV"
				total_conflict=$((total_conflict + 1))
			fi
		done < <(jq -r --argjson cve "$CVE_ONLY" '.[] | select($cve == 0 or (.commit.message | test("CVE-[0-9]{4}-[0-9]+"))) | [.sha, (.commit.message | split("\n")[0]), (.parents | length)] | @tsv' "$REPORT/list.json" | tac)

		page=$((page + 1))
	done
done

printf '\n===== 汇总 =====\n'
printf 'clean/applied : %d\n' "$total_applied"
printf 'skipped       : %d\n' "$total_skipped"
printf 'conflict      : %d\n' "$total_conflict"
printf 'failed        : %d\n' "$total_failed"
printf 'report        : %s\n' "$REPORT_TSV"
[ "$APPLY" -eq 1 ] && printf 'applied list  : %s\n' "$APPLIED_TXT"

if [ "$APPLY" -eq 1 ]; then
	printf '\n提示：落树后请检查 git diff，确认没有 Makefile/Kconfig 变更，并编译验证。\n'
	git diff --name-only | grep -qE '(^|/)(Makefile|Kconfig)$' &&
		printf 'WARNING: 本次改动里出现了 Makefile/Kconfig，请人工复核！\n'
	if [ "$CLEAN" -eq 0 ]; then
		printf '注意：开工前工作区并不干净，diff 里可能混有其它改动。\n'
	fi
fi
