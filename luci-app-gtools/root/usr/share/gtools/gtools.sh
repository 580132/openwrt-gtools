#!/bin/sh
#
# gtools - update proxy cores from upstream GitHub releases
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Commands:
#   status                      print the current state as JSON
#   check                       check all enabled cores in the background
#   upgrade <core>              download and install the newest release
#   rollback <core> <file>      restore a backup created by an upgrade
#   restart <core>              restart the core service
#
# The long running commands detach a worker and return immediately. Progress
# and results are written to /tmp/gtools/job.log and /tmp/gtools/job.state.

set -u

DATA_DIR=/usr/share/gtools
RUN_DIR=/tmp/gtools
BACKUP_ROOT=/usr/share/gtools/backups
LOG=$RUN_DIR/job.log
BACKUP_FILE=""
SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

uci_get() {
	uci -q get "gtools.$1" 2>/dev/null
}

core_meta() {
	ucode "$DATA_DIR/meta.uc" "$1" "$2" 2>/dev/null
}

list_cores() {
	ucode -e 'let fs=require("fs"); let c=json(fs.readfile("/usr/share/gtools/cores.json")) || {}; let k=keys(c); for (let i=0;i<length(k);i++) print(k[i], "\n");' 2>/dev/null
}

ensure_sections() {
	local _changed=0
	local _core

	for _core in $(list_cores); do
		if ! uci -q get "gtools.$_core" >/dev/null 2>&1; then
			uci set "gtools.$_core=core" 2>/dev/null && _changed=1
		fi
	done

	if [ "$_changed" -eq 1 ]; then
		uci -q commit gtools 2>/dev/null
	fi
}

detect_arch() {
	local _a

	_a=$(uname -m 2>/dev/null)

	case "$_a" in
		amd64) _a=x86_64 ;;
		arm64) _a=aarch64 ;;
		armv7l) _a=armv7 ;;
	esac

	printf '%s' "$_a"
}

download_url() {
	local _proxy

	_proxy=$(uci_get main.download_proxy)

	if [ -n "$_proxy" ]; then
		printf '%s/%s' "${_proxy%/}" "$1"
	else
		printf '%s' "$1"
	fi
}

api_url() {
	local _proxy

	_proxy=$(uci_get main.api_proxy)

	if [ -n "$_proxy" ]; then
		printf '%s/%s' "${_proxy%/}" "$1"
	else
		printf '%s' "$1"
	fi
}

fetch() {
	local _url=$1
	local _out=$2
	local _auth=${3:-}

	if command -v curl >/dev/null 2>&1; then
		if [ -n "$_auth" ]; then
			curl -fsSL --connect-timeout 15 --max-time 300 -A gtools/1.0 \
				-H "Authorization: Bearer $_auth" -o "$_out" "$_url"
		else
			curl -fsSL --connect-timeout 15 --max-time 300 -A gtools/1.0 \
				-o "$_out" "$_url"
		fi
	elif command -v uclient-fetch >/dev/null 2>&1; then
		if [ -n "$_auth" ]; then
			uclient-fetch -q -T 300 -U gtools/1.0 \
				--header "Authorization: Bearer $_auth" -O "$_out" "$_url"
		else
			uclient-fetch -q -T 300 -U gtools/1.0 -O "$_out" "$_url"
		fi
	elif command -v wget >/dev/null 2>&1; then
		if [ -n "$_auth" ]; then
			wget -q -T 300 -U gtools/1.0 \
				--header "Authorization: Bearer $_auth" -O "$_out" "$_url"
		else
			wget -q -T 300 -U gtools/1.0 -O "$_out" "$_url"
		fi
	else
		return 127
	fi
}

tsv_get() {
	awk -F '\t' -v key="$2" 'index($0, key "\t") == 1 { print substr($0, length(key) + 2); exit }' "$1" 2>/dev/null
}

run_version() {
	local _bin=$1

	if command -v timeout >/dev/null 2>&1; then
		timeout 10 "$_bin" --version 2>/dev/null | head -n1
	else
		"$_bin" --version 2>/dev/null | head -n1
	fi
}

installed_version() {
	local _bin=$1
	local _raw

	[ -x "$_bin" ] || return 0

	_raw=$(run_version "$_bin")
	[ -n "$_raw" ] || return 0

	printf '%s' "$_raw" | awk '{ print $NF }' | sed 's/^v//'
}

job_running() {
	local _pid
	local _started

	[ "$(cat "$RUN_DIR/job.state" 2>/dev/null)" = "running" ] || return 1

	_pid=$(cat "$RUN_DIR/job.pid" 2>/dev/null)

	if [ -n "$_pid" ]; then
		kill -0 "$_pid" 2>/dev/null
		return $?
	fi

	# The launcher sets the state before the worker writes its pid. Treat a
	# fresh "running" state as busy even if the pid file is not populated yet.
	_started=$(cat "$RUN_DIR/job.started" 2>/dev/null)
	[ -n "$_started" ] || return 1
	[ $(( $(date +%s) - _started )) -lt 15 ]
}

acquire_lock() {
	local _lock=$RUN_DIR/lock
	local _old

	if mkdir "$_lock" 2>/dev/null; then
		printf '%s\n' "$$" > "$_lock/pid"
		return 0
	fi

	_old=$(cat "$_lock/pid" 2>/dev/null)

	if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
		return 1
	fi

	rm -rf "$_lock"

	if mkdir "$_lock" 2>/dev/null; then
		printf '%s\n' "$$" > "$_lock/pid"
		return 0
	fi

	return 1
}

release_lock() {
	rm -rf "$RUN_DIR/lock"
}

finish_job() {
	local _rc=$1
	local _msg=$2

	printf '%s\n' "$(date +%s)" > "$RUN_DIR/job.finished"
	printf '%s\n' "$_msg" > "$RUN_DIR/job.message"

	if [ "$_rc" -eq 0 ]; then
		printf 'ok\n' > "$RUN_DIR/job.state"
	else
		printf 'fail\n' > "$RUN_DIR/job.state"
	fi
}

start_job() {
	local _action=$1
	shift

	mkdir -p "$RUN_DIR" 2>/dev/null
	chmod 0700 "$RUN_DIR" 2>/dev/null

	if job_running; then
		printf 'busy\n'
		return 1
	fi

	rm -rf "$RUN_DIR/lock"
	rm -rf "$RUN_DIR"/work.* "$RUN_DIR"/rollback.* 2>/dev/null
	: > "$LOG"
	chmod 0600 "$LOG" 2>/dev/null
	: > "$RUN_DIR/job.pid"
	: > "$RUN_DIR/job.finished"
	: > "$RUN_DIR/job.message"
	printf 'running\n' > "$RUN_DIR/job.state"
	printf '%s\n' "$_action" > "$RUN_DIR/job.action"
	printf '%s\n' "$(date +%s)" > "$RUN_DIR/job.started"

	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -S -b -q -x /bin/sh -- "$SELF" _worker "$_action" "$@" \
			</dev/null >/dev/null 2>&1
		sleep 1
	fi

	if [ ! -s "$RUN_DIR/job.pid" ]; then
		( "$SELF" _worker "$_action" "$@" </dev/null >/dev/null 2>&1 & )
	fi

	printf 'started\n'
	return 0
}

wait_service() {
	local _name=$1
	local _left=${2:-20}

	while [ "$_left" -gt 0 ]; do
		if pidof "$_name" >/dev/null 2>&1; then
			return 0
		fi

		sleep 1
		_left=$((_left - 1))
	done

	return 1
}

prune_backups() {
	local _core=$1
	local _keep=$2
	local _protect=${3:-}
	local _dir="$BACKUP_ROOT/$_core"
	local _file

	[ -d "$_dir" ] || return 0

	ls -1t "$_dir" 2>/dev/null | tail -n +$((_keep + 1)) | while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		[ -n "$_protect" ] && [ "$_file" = "$_protect" ] && continue
		rm -f "$_dir/$_file"
	done
}

backup_current() {
	local _core=$1
	local _bin=$2
	local _keep=$3
	local _bin_name
	local _old_ver
	local _safe_ver

	_bin_name=$(basename "$_bin")
	_old_ver=$(installed_version "$_bin")
	_safe_ver=$(printf '%s' "${_old_ver:-unknown}" | tr '/@ ' '___')

	[ -f "$_bin" ] || return 0

	mkdir -p "$BACKUP_ROOT/$_core" 2>/dev/null
	chmod 0700 "$BACKUP_ROOT" "$BACKUP_ROOT/$_core" 2>/dev/null

	BACKUP_FILE="$BACKUP_ROOT/$_core/$_bin_name@$_safe_ver@$(date +%s)"

	if ! cp -f "$_bin" "$BACKUP_FILE"; then
		BACKUP_FILE=""
		log "[$_core] 备份当前核心失败"
		return 1
	fi

	chmod 0755 "$BACKUP_FILE" 2>/dev/null
	log "[$_core] 已备份当前核心: ${_old_ver:-unknown}"

	prune_backups "$_core" "$_keep" "$(basename "$BACKUP_FILE")"

	return 0
}

check_core() {
	local _core=$1
	local _arch
	local _token
	local _out
	local _json
	local _repo
	local _channel
	local _variant
	local _allocator
	local _api
	local _tag
	local _ver
	local _err

	_arch=$(detect_arch)
	_token=$(uci_get main.api_token)
	_out="$RUN_DIR/latest.$_core.tsv"
	_json="$RUN_DIR/releases.$_core.json"
	_repo=$(core_meta "$_core" repo)

	if [ -z "$_repo" ]; then
		log "[$_core] 无法读取核心元数据"
		printf 'error\t无法读取核心元数据\nchecked\t%s\n' "$(date +%s)" > "$_out"
		return 1
	fi

	_channel=$(uci_get "$_core.channel")
	[ -n "$_channel" ] || _channel=$(core_meta "$_core" defaults.channel)
	[ -n "$_channel" ] || _channel=auto

	_variant=$(uci_get "$_core.variant")
	[ -n "$_variant" ] || _variant=$(core_meta "$_core" defaults.variant)
	[ -n "$_variant" ] || _variant=full

	_allocator=$(uci_get "$_core.allocator")
	[ -n "$_allocator" ] || _allocator=$(core_meta "$_core" defaults.allocator)
	[ -n "$_allocator" ] || _allocator=mimalloc

	_api="https://api.github.com/repos/$_repo/releases?per_page=100"

	log "[$_core] 获取上游版本信息 ..."

	if ! fetch "$(api_url "$_api")" "$_json" "$_token"; then
		log "[$_core] 无法访问 GitHub API"
		rm -f "$_json"
		printf 'error\t无法访问 GitHub API，请检查网络、加速地址或 Token\nchecked\t%s\n' \
			"$(date +%s)" > "$_out"
		return 1
	fi

	if ucode "$DATA_DIR/select.uc" "$_core" "$_channel" "$_variant" "$_allocator" \
		"$_arch" "$_json" > "$_out"; then
		_tag=$(tsv_get "$_out" tag)
		_ver=$(tsv_get "$_out" version)
		log "[$_core] 最新版本: ${_ver:-未知} (${_tag:-未知})"
		rm -f "$_json"
		return 0
	fi

	if [ ! -s "$_out" ]; then
		printf 'error\t选择发布包失败\nchecked\t%s\n' "$(date +%s)" > "$_out"
	fi

	_err=$(tsv_get "$_out" error)
	log "[$_core] 检查失败: ${_err:-未知错误}"
	rm -f "$_json"
	return 1
}

do_check() {
	local _arch
	local _rc=0
	local _count=0
	local _core

	_arch=$(detect_arch)

	log "开始检查更新（架构: $_arch）"

	for _core in $(list_cores); do
		[ "$(uci_get "$_core.enabled")" = "0" ] && continue

		_count=$((_count + 1))

		check_core "$_core" || _rc=1
	done

	if [ "$_count" -eq 0 ]; then
		log "没有启用的核心"
	fi

	if [ "$_rc" -eq 0 ]; then
		finish_job 0 "检查完成"
	else
		finish_job 1 "部分核心检查失败，请查看日志"
	fi
}

do_upgrade() {
	local _core=$1
	local _out="$RUN_DIR/latest.$_core.tsv"
	local _channel
	local _variant
	local _allocator
	local _stale=0
	local _url
	local _asset
	local _version
	local _sums
	local _archive
	local _bin_name
	local _bin
	local _service
	local _tmp
	local _verify
	local _expected
	local _actual
	local _new
	local _new_raw
	local _new_ver
	local _old_ver
	local _keep
	local _backup
	local _was_running=0
	local _rollback

	_channel=$(uci_get "$_core.channel")
	[ -n "$_channel" ] || _channel=$(core_meta "$_core" defaults.channel)
	[ -n "$_channel" ] || _channel=auto

	_variant=$(uci_get "$_core.variant")
	[ -n "$_variant" ] || _variant=$(core_meta "$_core" defaults.variant)
	[ -n "$_variant" ] || _variant=full

	_allocator=$(uci_get "$_core.allocator")
	[ -n "$_allocator" ] || _allocator=$(core_meta "$_core" defaults.allocator)
	[ -n "$_allocator" ] || _allocator=mimalloc

	[ -s "$_out" ] || _stale=1

	if [ "$_stale" -eq 0 ]; then
		[ -n "$(tsv_get "$_out" url)" ] || _stale=1
		[ "$(tsv_get "$_out" channel)" = "$_channel" ] || _stale=1
		[ "$(tsv_get "$_out" variant)" = "$_variant" ] || _stale=1
		[ "$(tsv_get "$_out" allocator)" = "$_allocator" ] || _stale=1
		[ "$(tsv_get "$_out" arch)" = "$(detect_arch)" ] || _stale=1
		[ "$(tsv_get "$_out" binary)" = "$(core_meta "$_core" binary)" ] || _stale=1
	fi

	if [ "$_stale" -eq 1 ]; then
		log "[$_core] 版本信息缺失或设置已变更，重新检查 ..."

		if ! check_core "$_core"; then
			finish_job 1 "无法获取最新版本"
			return
		fi
	fi

	_url=$(tsv_get "$_out" url)
	_asset=$(tsv_get "$_out" asset)
	_version=$(tsv_get "$_out" version)
	_sums=$(tsv_get "$_out" sums_url)
	_archive=$(tsv_get "$_out" archive)
	_bin_name=$(tsv_get "$_out" binary_name)
	_bin=$(tsv_get "$_out" binary)
	_service=$(tsv_get "$_out" service)

	if [ -z "$_url" ] || [ -z "$_asset" ] || [ -z "$_bin" ]; then
		finish_job 1 "无法获取下载地址"
		return
	fi

	[ -n "$_bin_name" ] || _bin_name=$(basename "$_bin")
	[ -n "$_archive" ] || _archive=tar.gz

	_tmp="$RUN_DIR/work.$_core.$$"

	rm -rf "$_tmp"
	mkdir -p "$_tmp/x"

	log "[$_core] 下载 $_asset"

	if ! fetch "$(download_url "$_url")" "$_tmp/$_asset"; then
		rm -rf "$_tmp"
		finish_job 1 "下载失败: $_asset"
		return
	fi

	_verify=$(uci_get main.verify_sha256)

	if [ "$_verify" != "0" ]; then
		if [ -n "$_sums" ]; then
			log "[$_core] 校验 SHA256 ..."

			if ! fetch "$(download_url "$_sums")" "$_tmp/SHA256SUMS"; then
				rm -rf "$_tmp"
				finish_job 1 "下载 SHA256SUMS 失败"
				return
			fi

			_expected=$(awk -v file="$_asset" '
				{
					name = $2;
					sub(/^\*/, "", name);
					sub(/^\.\//, "", name);
					if (name == file) { print $1; exit }
				}' "$_tmp/SHA256SUMS")
			_actual=$(sha256sum "$_tmp/$_asset" 2>/dev/null | awk '{ print $1 }')

			if [ -z "$_expected" ] || [ "$_expected" != "$_actual" ]; then
				log "[$_core] SHA256 校验失败"
				rm -rf "$_tmp"
				finish_job 1 "SHA256 校验失败"
				return
			fi

			log "[$_core] SHA256 校验通过"
		else
			log "[$_core] 该版本未提供 SHA256SUMS，跳过校验"
		fi
	fi

	log "[$_core] 解压安装包 ..."

	case "$_archive" in
		tar.gz|tgz)
			if ! tar -xzf "$_tmp/$_asset" -C "$_tmp/x" 2>/dev/null; then
				rm -rf "$_tmp"
				finish_job 1 "解压失败"
				return
			fi

			_new=$(find "$_tmp/x" -type f -name "$_bin_name" | head -n1)
			;;
		gz)
			if ! gzip -dc "$_tmp/$_asset" > "$_tmp/x/$_bin_name"; then
				rm -rf "$_tmp"
				finish_job 1 "解压失败"
				return
			fi

			_new="$_tmp/x/$_bin_name"
			;;
		none|binary)
			cp -f "$_tmp/$_asset" "$_tmp/x/$_bin_name"
			_new="$_tmp/x/$_bin_name"
			;;
		*)
			rm -rf "$_tmp"
			finish_job 1 "不支持的压缩格式: $_archive"
			return
			;;
	esac

	if [ -z "${_new:-}" ] || [ ! -f "$_new" ]; then
		rm -rf "$_tmp"
		finish_job 1 "安装包中没有找到 $_bin_name"
		return
	fi

	chmod 0755 "$_new"

	_new_raw=$(run_version "$_new")

	if [ -z "$_new_raw" ]; then
		log "[$_core] 新核心无法执行 --version"
		rm -rf "$_tmp"
		finish_job 1 "新核心无法执行，已放弃安装"
		return
	fi

	_new_ver=$(printf '%s' "$_new_raw" | awk '{ print $NF }' | sed 's/^v//')
	_old_ver=$(installed_version "$_bin")

	log "[$_core] 新核心版本: $_new_raw"

	if [ -n "$_version" ] && [ "$_new_ver" != "$_version" ]; then
		log "[$_core] 警告: 核心报告版本 $_new_ver，与发布标签 $_version 不一致"
	fi

	_keep=$(uci_get main.keep_backups)
	case "$_keep" in
		''|*[!0-9]*) _keep=3 ;;
	esac
	_keep=$(printf '%s' "$_keep" | sed 's/^0*//')
	[ -n "$_keep" ] || _keep=1
	[ "$_keep" -lt 1 ] && _keep=1
	[ "$_keep" -gt 10 ] && _keep=10

	_backup=""

	if [ -f "$_bin" ]; then
		if ! backup_current "$_core" "$_bin" "$_keep"; then
			rm -rf "$_tmp"
			finish_job 1 "备份当前核心失败"
			return
		fi

		_backup=$BACKUP_FILE
	fi

	log "[$_core] 安装到 $_bin ..."

	if ! cp -f "$_new" "$_bin.gtools.new" 2>/dev/null ||
	   ! chmod 0755 "$_bin.gtools.new" 2>/dev/null ||
	   ! mv -f "$_bin.gtools.new" "$_bin" 2>/dev/null; then
		rm -f "$_bin.gtools.new"
		rm -rf "$_tmp"
		finish_job 1 "写入核心文件失败"
		return
	fi

	rm -rf "$_tmp"

	log "[$_core] 核心已更新: ${_old_ver:-unknown} -> ${_new_ver:-$_version}"

	if [ -z "$_service" ] || [ ! -x "/etc/init.d/$_service" ]; then
		finish_job 0 "已更新到 ${_version:-新版本}（服务未安装，未重启）"
		return
	fi

	if pidof "$(basename "$_bin")" >/dev/null 2>&1; then
		_was_running=1
	fi

	if [ "$_was_running" -eq 0 ] && ! ls /etc/rc.d/S*"$_service" >/dev/null 2>&1; then
		log "[$_core] 服务未启用，跳过重启"
		finish_job 0 "已更新到 ${_version:-新版本}（服务未启用）"
		return
	fi

	log "[$_core] 重启 $_service 服务 ..."

	/etc/init.d/"$_service" restart 2>&1

	if wait_service "$(basename "$_bin")" 20; then
		log "[$_core] 服务已恢复运行"
		finish_job 0 "已更新到 ${_version:-新版本}"
		return
	fi

	log "[$_core] 服务未能在 20 秒内启动"

	_rollback=$(uci_get main.auto_rollback)

	if [ "$_rollback" != "0" ] && [ -n "$_backup" ] && [ -f "$_backup" ]; then
		log "[$_core] 自动回滚到 ${_old_ver:-旧版本} ..."

		if cp -f "$_backup" "$_bin.gtools.new" 2>/dev/null &&
		   chmod 0755 "$_bin.gtools.new" 2>/dev/null &&
		   mv -f "$_bin.gtools.new" "$_bin" 2>/dev/null; then
			/etc/init.d/"$_service" restart 2>&1

			if wait_service "$(basename "$_bin")" 20; then
				finish_job 1 "新核心启动失败，已自动回滚"
			else
				finish_job 1 "新核心启动失败，回滚后服务仍未运行"
			fi
		else
			finish_job 1 "新核心启动失败，自动回滚也失败"
		fi

		return
	fi

	finish_job 1 "新核心已安装，但服务未能启动"
}

do_rollback() {
	local _core=$1
	local _file=$2
	local _bin
	local _service
	local _src
	local _keep
	local _tmp

	_bin=$(core_meta "$_core" binary)
	_service=$(core_meta "$_core" service)

	if [ -z "$_bin" ] || [ -z "$_file" ]; then
		finish_job 1 "参数错误"
		return
	fi

	case "$_file" in
		*/*|.*)
			finish_job 1 "非法的备份文件名"
			return
			;;
	esac

	_src="$BACKUP_ROOT/$_core/$_file"

	if [ ! -f "$_src" ]; then
		finish_job 1 "备份不存在"
		return
	fi

	_keep=$(uci_get main.keep_backups)
	case "$_keep" in
		''|*[!0-9]*) _keep=3 ;;
	esac
	_keep=$(printf '%s' "$_keep" | sed 's/^0*//')
	[ -n "$_keep" ] || _keep=1
	[ "$_keep" -lt 1 ] && _keep=1
	[ "$_keep" -gt 10 ] && _keep=10

	# Keep a copy outside the backup directory: backing up the current binary
	# below prunes old backups and could otherwise remove the selected one.
	_tmp="$RUN_DIR/rollback.$_core.$$"

	if ! cp -f "$_src" "$_tmp"; then
		rm -f "$_tmp"
		finish_job 1 "读取备份失败"
		return
	fi

	log "[$_core] 从备份恢复: $_file"

	if [ -f "$_bin" ]; then
		backup_current "$_core" "$_bin" "$_keep" || {
			rm -f "$_tmp"
			finish_job 1 "备份当前核心失败"
			return
		}
	fi

	if ! cp -f "$_tmp" "$_bin.gtools.new" 2>/dev/null ||
	   ! chmod 0755 "$_bin.gtools.new" 2>/dev/null ||
	   ! mv -f "$_bin.gtools.new" "$_bin" 2>/dev/null; then
		rm -f "$_bin.gtools.new" "$_tmp"
		finish_job 1 "恢复备份失败"
		return
	fi

	rm -f "$_tmp"

	log "[$_core] 已恢复核心文件"

	if [ -z "$_service" ] || [ ! -x "/etc/init.d/$_service" ]; then
		finish_job 0 "已恢复备份（服务未安装，未重启）"
		return
	fi

	if ! ls /etc/rc.d/S*"$_service" >/dev/null 2>&1 &&
	   ! pidof "$(basename "$_bin")" >/dev/null 2>&1; then
		finish_job 0 "已恢复备份（服务未启用）"
		return
	fi

	/etc/init.d/"$_service" restart 2>&1

	if wait_service "$(basename "$_bin")" 20; then
		finish_job 0 "已恢复备份并重启服务"
	else
		finish_job 1 "已恢复备份，但服务未能启动"
	fi
}

do_restart() {
	local _core=$1
	local _bin
	local _service

	_bin=$(core_meta "$_core" binary)
	_service=$(core_meta "$_core" service)

	if [ -z "$_bin" ] || [ -z "$_service" ] || [ ! -x "/etc/init.d/$_service" ]; then
		finish_job 1 "服务不存在"
		return
	fi

	log "[$_core] 重启 $_service 服务 ..."
	/etc/init.d/"$_service" restart 2>&1

	if wait_service "$(basename "$_bin")" 20; then
		finish_job 0 "服务已重启"
	else
		finish_job 1 "服务重启后未运行"
	fi
}

cmd_status() {
	ucode "$DATA_DIR/status.uc" || printf '{"error":"status.uc 执行失败"}\n'
}

_worker() {
	local _action=$1
	shift

	mkdir -p "$RUN_DIR" 2>/dev/null
	chmod 0700 "$RUN_DIR" 2>/dev/null

	exec >>"$LOG" 2>&1

	printf '%s\n' "$$" > "$RUN_DIR/job.pid"

	if ! acquire_lock; then
		log "已有任务正在运行"
		exit 1
	fi

	trap 'release_lock' EXIT INT TERM

	case "$_action" in
		check) do_check ;;
		upgrade) do_upgrade "$@" ;;
		rollback) do_rollback "$@" ;;
		restart) do_restart "$@" ;;
		*) finish_job 1 "未知操作: $_action" ;;
	esac

	release_lock
	trap - EXIT INT TERM
}

mkdir -p "$RUN_DIR" 2>/dev/null
chmod 0700 "$RUN_DIR" 2>/dev/null

ensure_sections

case "${1:-}" in
	status)
		cmd_status
		;;
	check)
		start_job check
		;;
	upgrade)
		[ -n "${2:-}" ] || { echo "usage: $0 upgrade <core>" >&2; exit 1; }
		start_job upgrade "$2"
		;;
	rollback)
		[ -n "${2:-}" ] && [ -n "${3:-}" ] || {
			echo "usage: $0 rollback <core> <file>" >&2
			exit 1
		}
		start_job rollback "$2" "$3"
		;;
	restart)
		[ -n "${2:-}" ] || { echo "usage: $0 restart <core>" >&2; exit 1; }
		start_job restart "$2"
		;;
	_worker)
		shift
		_worker "$@"
		;;
	*)
		echo "usage: $0 {status|check|upgrade|rollback|restart}" >&2
		exit 1
		;;
esac
