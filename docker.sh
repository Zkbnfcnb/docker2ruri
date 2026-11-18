#!/usr/bin/env bash
set -euo pipefail

# ====================== 配置 ======================
DATA_DIR="${DOCKER_DATA_DIR:-$HOME/.local/share/docker-sh}"
RUNTIME="${RURI_BIN:-/root/ruri/ruri}"
DOCKER_REGISTRY_MIRROR="${DOCKER_REGISTRY_MIRROR:-ghcr.io}"
WAIT_TIMEOUT_TICKS="${WAIT_TIMEOUT_TICKS:-30}"
WAIT_INTERVAL="${WAIT_INTERVAL:-0.2}"
# 1=启动容器时额外加 ruri -S（bind 宿主 /dev /sys /proc，隔离性差）
# 0=ruri 自己创建容器内 /dev /proc /sys（与 docker 默认一致）
USE_HOST_RUNTIME="${RURI_HOST_RUNTIME:-0}"
# 跨架构运行（--platform）所需的 QEMU 路径，未设置则忽略 --platform
RURI_QEMU_PATH="${RURI_QEMU_PATH:-}"
VERSION="1.5.0"

# 清理注入型动态链接器变量
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT 2>/dev/null || true

# 参数解析失败时用于回滚刚创建的容器目录（docker create 失败不会留下容器）
_CLEANUP_CTR_DIR=""
die() {
    if [[ -n "$_CLEANUP_CTR_DIR" && -d "$_CLEANUP_CTR_DIR" ]]; then
        rm -rf "$_CLEANUP_CTR_DIR" 2>/dev/null || true
    fi
    echo "错误: $*" >&2
    exit 1
}
info() { echo "[docker-to-ruri] $*"; }
warn() { echo "[docker-to-ruri][警告] $*" >&2; }

ensure_data_dir() {
    mkdir -p "$DATA_DIR"/{images,containers} || die "无法创建数据目录 $DATA_DIR"
}

# 数据目录级锁（pull/load/rmi 等跨容器操作）
lock_data_dir() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 200>"${DATA_DIR}/.lock" || die "无法创建锁文件 ${DATA_DIR}/.lock"
    flock -w 30 200 || die "等待数据目录锁超时（另一个实例正在操作）"
}

# 容器级锁（start/stop/rm/commit 等）
lock_ctr() {
    local ctr_dir="$1"
    local purpose="${2:-update}"
    command -v flock >/dev/null 2>&1 || return 0
    [[ -d "$ctr_dir" ]] || die "容器目录不存在: $ctr_dir"
    exec 200>"${ctr_dir}/.lock" || die "无法创建锁文件 ${ctr_dir}/.lock"
    local wait="${DOCKER_LOCK_WAIT:-10}"
    if flock -w "$wait" 200; then
        return 0
    fi
    # 旧版本启动的容器进程会继承锁 fd，导致 stop/rm 永远等不到锁。
    # 停止/删除是用户明确意图且幂等，降级继续并提示。
    case "$purpose" in
        stop|rm)
            warn "容器锁被占用（可能是旧版本启动的容器进程继承了锁 fd），继续执行 $purpose"
            return 0
            ;;
        *)
            die "等待容器锁超时（另一个操作正在进行；可调大 DOCKER_LOCK_WAIT，当前 ${wait}s）"
            ;;
    esac
}

# 在 fork 出容器进程前关闭锁 fd。
# 否则 ruri/容器内进程会继承 flock 的打开文件描述，脚本退出后锁仍被容器持有，
# 后续 stop/rm 会一直等待（openlist2 现象）。
_close_lock_fd() {
    if [[ -e "/proc/self/fd/200" ]]; then
        exec 200>&-
    fi
    return 0
}

# 校验容器名并返回容器目录；只做名字校验，不检查存在性
ctr_dir_of() {
    local name="$1"
    validate_ctr_name "$name"
    echo "${DATA_DIR}/containers/${name}"
}

# 删除/写入前确认路径确实位于 DATA_DIR/containers 下（防符号链接/穿越）
assert_under_containers() {
    local path="$1"
    local real base
    real=$(realpath -m "$path" 2>/dev/null || true)
    base=$(realpath -m "${DATA_DIR}/containers" 2>/dev/null || true)
    [[ -n "$real" && -n "$base" && "$real" == "$base"/* ]] || die "非法容器路径: $path"
}

# ====================== 依赖检查 ======================
check_deps() {
    for bin in skopeo umoci jq tar; do
        command -v "$bin" >/dev/null 2>&1 || die "缺少依赖工具：$bin"
    done
    [[ -x "$RUNTIME" ]] || die "找不到 ruri 运行时：$RUNTIME"
}

# 探测 ruri 是否支持某选项（缓存结果）
declare -A _RURI_FEAT_CACHE=()
_has_ruri_opt() {
    local opt="$1"
    if [[ -z "${_RURI_FEAT_CACHE[$opt]+x}" ]]; then
        if "$RUNTIME" --help 2>&1 | grep -q -- "$opt"; then
            _RURI_FEAT_CACHE[$opt]=1
        else
            _RURI_FEAT_CACHE[$opt]=0
        fi
    fi
    [[ "${_RURI_FEAT_CACHE[$opt]}" == "1" ]]
}
_has_ruri_pidfile() { _has_ruri_opt --pid-file; }

# ruri 某些版本 --help 列了 -R，但内部 feature flag 未实现（运行才报 Unknown flag）。
# 用一次无副作用探测决定是否传 -R，避免 docker run --read-only 直接失败。
_ruri_supports_readonly() {
    if [[ -z "${_RURI_FEAT_CACHE[read_only_root]+x}" ]]; then
        local out
        out=$("$RUNTIME" -R /nonexistent-ruri-probe 2>&1 || true)
        if [[ "$out" == *"Unknown flag"* ]]; then
            _RURI_FEAT_CACHE[read_only_root]=0
        else
            _RURI_FEAT_CACHE[read_only_root]=1
        fi
    fi
    [[ "${_RURI_FEAT_CACHE[read_only_root]}" == "1" ]]
}

# ====================== 名称与引用解析 ======================
# docker 选项中需要独立取值的选项。
# run/create 预解析时用它判断是否跳过下一个参数，避免把选项值当成镜像名或命令。
DOCKER_VALUE_OPTS=(
    -e --env -v --volume -w --workdir -u --user -h --hostname
    --cap-add --cap-drop --net --network -m --memory --cpus --pids-limit
    --device --security-opt --platform --mount --env-file --entrypoint
    --add-host --dns --ulimit --label --label-file --restart --log-driver --log-opt
    --cidfile --cgroupns --ipc --pid --userns --uts --sysctl --group-add
    --expose --link --mac-address --ip --dns-search --dns-option --tmpfs
    --stop-signal --stop-timeout --health-cmd --health-interval
    --health-retries --health-timeout --health-start-period --oom-score-adj
    --shm-size --memory-swap --memory-reservation --cpu-shares --cpu-quota
    --cpu-period --cpuset-cpus --cpuset-mems --blkio-weight --volumes-from
    --network-alias
)
DOCKER_FLAG_OPTS=(
    --privileged --read-only --init --no-healthcheck
    --oom-kill-disable --disable-content-trust
)

_is_docker_value_opt() {
    local o="$1" x
    for x in "${DOCKER_VALUE_OPTS[@]}"; do
        [[ "$o" == "$x" ]] && return 0
    done
    return 1
}

_is_docker_flag_opt() {
    local o="$1" x
    for x in "${DOCKER_FLAG_OPTS[@]}"; do
        [[ "$o" == "$x" ]] && return 0
    done
    return 1
}

parse_image_ref() {
    local ref="$1"
    if [[ "$ref" == *"@"* ]]; then
        die "不支持 digest 引用（$ref），请使用 tag 形式（如 nginx:latest）"
    fi
    local repo tag
    local last="${ref##*:}"
    if [[ "$ref" == *:* && "$last" != */* ]]; then
        repo="${ref%:*}"
        tag="$last"
    else
        repo="$ref"
        tag="latest"
    fi
    [[ "$repo" == */* ]] || repo="library/$repo"
    # 拒绝空段、"."、".." 与非法字符，避免镜像名参与路径拼接时逃逸
    local seg
    local IFS='/'
    for seg in $repo; do
        [[ -n "$seg" && "$seg" != "." && "$seg" != ".." ]] || die "非法镜像名: $ref"
    done
    [[ "$repo" =~ ^[A-Za-z0-9._:/@-]+$ ]] || die "镜像名含非法字符: $ref"
    [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "非法镜像 tag: $ref"
    echo "$repo" "$tag"
}

safe_img_name() {
    local repo="$1" tag="$2"
    # registry 端口里的 ':' 和 repo 里的 '/' 都替换成 '_'
    echo "${repo//[:\/]/_}_${tag}"
}

validate_ctr_name() {
    local name="$1"
    [[ -n "$name" ]] || die "容器名不能为空"
    [[ "$name" != "." && "$name" != ".." ]] || die "非法容器名: $name"
    [[ "$name" != */* ]] || die "容器名不能包含 /"
    [[ ${#name} -le 128 ]] || die "容器名过长"
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "容器名只能包含字母数字 _ . -，且以字母数字开头"
}

# ====================== 进程信息 ======================
# 读取 /proc/PID/stat，把 comm 之后的字段放入 PROC_FIELDS。
# comm 可能含空格/括号，直接按空格切分会错位，先去掉到最后一个 ") " 之前的内容。
# 全部使用 bash 内置读取，避免在高频扫描（stop_all_ctr_procs）中 fork 外部命令。
PROC_STATE=""
PROC_FIELDS=()
_proc_fields() {
    local pid="$1" stat
    read -r stat < "/proc/$pid/stat" 2>/dev/null || return 1
    local rest="${stat##*) }"
    PROC_STATE="${rest%% *}"
    read -r -a PROC_FIELDS <<< "$rest"
    return 0
}

get_starttime() {
    _proc_fields "$1" || return 1
    echo "${PROC_FIELDS[19]}"
}

# 进程状态：R/S/D/Z/T/I/X
get_proc_state() {
    _proc_fields "$1" || return 1
    echo "$PROC_STATE"
}

# 存活且非僵尸；僵尸进程 kill -0 仍成功，必须排除
_proc_alive() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    _proc_fields "$pid" || return 1
    [[ -n "$PROC_STATE" && "$PROC_STATE" != "Z" && "$PROC_STATE" != "X" ]]
}

# 解析 ruri 的 pidfile。格式随 ruri 版本/阶段变化：
#   纯数字 | RURI_WAIT_EXEC_<pid> | RURI_EXITED_<code> | RURI_SIGNALED_<sig> | RURI_PANIC_<reason>
# 解析结果写入全局变量（调用方按需读取）。
_pidfile_parse() {
    local f="$1" line
    PIDFILE_PID=""
    PIDFILE_EXIT=""
    PIDFILE_SIGNAL=""
    PIDFILE_PANIC=""
    [[ -r "$f" ]] || return 1
    while IFS= read -r line; do
        case "$line" in
        RURI_EXITED_*)   PIDFILE_EXIT="${line#RURI_EXITED_}" ;;
        RURI_SIGNALED_*) PIDFILE_SIGNAL="${line#RURI_SIGNALED_}" ;;
        RURI_WAIT_EXEC_*) PIDFILE_PID="${line#RURI_WAIT_EXEC_}" ;;
        RURI_PANIC*)     PIDFILE_PANIC="$line" ;;
        ''|*[!0-9]*)     : ;;
        *)               PIDFILE_PID="$line" ;;
        esac
    done < "$f"
    [[ -n "$PIDFILE_PID$PIDFILE_EXIT$PIDFILE_SIGNAL$PIDFILE_PANIC" ]]
}

# 取容器 init pid：优先 pidfile，失效时扫描 /proc
_ctr_pid() {
    local ctr_dir="$1" pid=""
    if _pidfile_parse "${ctr_dir}/.pid"; then
        pid="$PIDFILE_PID"
    fi
    if [[ -z "$pid" ]] || ! _proc_alive "$pid" 2>/dev/null; then
        pid=$(_find_ctr_init_pid "$ctr_dir" || true)
    fi
    printf '%s
' "$pid"
}

refresh_ctr_state() {
    local ctr_dir="$1"
    local pidfile="$ctr_dir/.pid"
    local startfile="$ctr_dir/.pid_start"
    local statefile="$ctr_dir/.state"
    local pid=""

    if [[ -f "$pidfile" ]]; then
        _pidfile_parse "$pidfile" || true
        pid="$PIDFILE_PID"
        if _proc_alive "$pid" 2>/dev/null; then
            local cur_st saved_st
            cur_st=$(get_starttime "$pid" 2>/dev/null || echo "")
            saved_st=$(cat "$startfile" 2>/dev/null || echo "")
            if [[ -z "$saved_st" || ( -n "$cur_st" && "$cur_st" == "$saved_st" ) ]]; then
                # paused 由 docker pause 标记；进程仍在，但被 cgroup freezer 冻结
                if [[ -f "${ctr_dir}/.paused" ]]; then
                    echo "paused" > "$statefile"
                else
                    echo "running" > "$statefile"
                fi
                return 0
            fi
        fi
        # 进程已退出：保留 ruri 写下的退出码/信号，供 wait/ps/inspect 使用
        [[ -n "$PIDFILE_EXIT" ]] && echo "$PIDFILE_EXIT" > "${ctr_dir}/.exit_code"
        [[ -n "$PIDFILE_SIGNAL" ]] && echo "$PIDFILE_SIGNAL" > "${ctr_dir}/.exit_signal"
    fi

    rm -f "$pidfile" "$startfile" "${ctr_dir}/.paused"
    local prev=""
    if [[ -f "$statefile" ]]; then
        prev=$(cat "$statefile" 2>/dev/null || true)
    fi
    if [[ "$prev" == "running" || "$prev" == "paused" ]]; then
        # 记录退出时间，供 ps/inspect 计算 STATUS
        date +%s > "${ctr_dir}/.exited_at"
        echo "exited" > "$statefile"
    elif [[ -z "$prev" ]]; then
        echo "created" > "$statefile"
    fi
}

wait_running() {
    local ctr_dir="$1"
    local i
    for ((i = 0; i < WAIT_TIMEOUT_TICKS; i++)); do
        refresh_ctr_state "$ctr_dir"
        local st
        st=$(cat "${ctr_dir}/.state" 2>/dev/null || echo "")
        if [[ "$st" == "running" ]]; then
            return 0
        fi
        if [[ ! -f "${ctr_dir}/.pid" ]]; then
            return 1
        fi
        sleep "$WAIT_INTERVAL"
    done
    return 1
}

# ====================== 挂载清理 ======================
# /proc/mounts 中的挂载点转义（\040 空格、\011 tab、\012 换行、\134 反斜杠）
_unescape_mount() {
    local s="$1"
    s="${s//\\040/ }"
    s="${s//\\011/$'\t'}"
    s="${s//\\012/$'\n'}"
    s="${s//\\134/\\}"
    printf '%s' "$s"
}

cleanup_mounts() {
    local rootfs="$1"
    [[ -d "$rootfs" ]] || return 0
    local real
    real=$(realpath -m "$rootfs" 2>/dev/null || true)
    [[ -n "$real" ]] || return 0

    local -a mounts=()
    if command -v findmnt >/dev/null 2>&1; then
        mapfile -t mounts < <(findmnt -Rrn -o TARGET -- "$real" 2>/dev/null || true)
    fi
    if [[ ${#mounts[@]} -eq 0 ]]; then
        local line target
        while IFS= read -r line; do
            target="${line#* }"
            target="${target%% *}"
            target=$(_unescape_mount "$target")
            if [[ "$target" == "$real" || "$target" == "$real"/* ]]; then
                mounts+=("$target")
            fi
        done < /proc/mounts
    fi

    # 深度优先卸载，避免父挂载点先消失
    if [[ ${#mounts[@]} -gt 0 ]]; then
        local m
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            umount -l "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || true
        done < <(printf '%s\n' "${mounts[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
    fi

    # 注意：ruri -U 在仍有 bind 挂载时会连挂载点文件一起删除（实测），
    # 因此必须放在 umount 之后，仅用于清理 ruri 运行时目录。
    if [[ -x "$RUNTIME" ]]; then
        "$RUNTIME" -U "$(dirname "$real")" >/dev/null 2>&1 || true
        "$RUNTIME" -U "$real" >/dev/null 2>&1 || true
    fi
}

stop_all_ctr_procs() {
    local ctr_dir="$1"
    local target_root
    target_root=$(realpath -m "$ctr_dir/rootfs" 2>/dev/null || true)
    [[ -n "$target_root" ]] || return 0

    # 用 -ef 比较设备号+inode，纯 bash 内置，避免逐个进程 fork stat/readlink
    local -a pids=()
    local pid_dir pid
    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir##*/}"
        if [[ "$pid" == "$$" || "$pid" == "$PPID" ]]; then
            continue
        fi
        _proc_alive "$pid" 2>/dev/null || continue
        if [[ "$pid_dir/root" -ef "$target_root" ]]; then
            pids+=("$pid")
        fi
    done

    [[ ${#pids[@]} -gt 0 ]] || return 0

    info "兜底终止容器内进程: ${pids[*]}"
    kill -TERM "${pids[@]}" 2>/dev/null || true
    local i
    for ((i = 0; i < 10; i++)); do
        local alive=0
        for pid in "${pids[@]}"; do
            _proc_alive "$pid" 2>/dev/null && alive=1
        done
        [[ "$alive" -eq 0 ]] && return 0
        sleep 0.1
    done
    for pid in "${pids[@]}"; do
        _proc_alive "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    done
    return 0
}

# 在 /proc 中查找 rootfs 对应的容器 init 进程（用于 pid 文件丢失时恢复）
_find_ctr_init_pid() {
    local ctr_dir="$1"
    local target
    target=$(realpath -m "$ctr_dir/rootfs" 2>/dev/null || true)
    [[ -n "$target" ]] || return 1
    local pid_dir pid
    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir##*/}"
        _proc_alive "$pid" 2>/dev/null || continue
        if [[ "$pid_dir/root" -ef "$target" ]]; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

# ====================== 参数序列化 ======================
save_args() {
    local file="$1"; shift
    if [[ $# -eq 0 ]]; then : > "$file"; else printf '%s\0' "$@" > "$file"; fi
}

load_args() {
    local file="$1"
    local -n out_arr="$2"
    out_arr=()
    if [[ -s "$file" ]]; then
        # shellcheck disable=SC2034
        mapfile -d '' -t out_arr < "$file"
    fi
}

# ruri: -m, --mount [dir/dev/img/file] [target]
#       -M, --ro-mount [dir/dev/img/file] [target]
# docker: -v SRC:DST[:ro] / --mount type=bind,source=SRC,target=DST[,readonly]
_append_mount() {
    local v="$1"
    # shellcheck disable=SC2178
    local -n arr="$2"
    local ctr_dir="${3:-}"
    if [[ "$v" != *:* ]]; then
        warn "无效的 volume 格式 '$v'（应为 SRC:DST[:ro]），已忽略"
        return 0
    fi
    local src="${v%%:*}"
    local rest="${v#*:}"
    local dst="${rest%%:*}"
    local opts=""
    [[ "$rest" == *:* ]] && opts="${rest#*:}"

    [[ -n "$src" && -n "$dst" ]] || die "无效的 volume 格式 '$v'"
    if [[ "$src" != /* ]]; then
        warn "bind 源 $src 是相对路径，按当前目录解析"
        src=$(realpath -m "$src" 2>/dev/null || echo "${PWD}/${src}")
    fi
    case "$dst" in
        /*) ;;
        *) die "卷目标必须是绝对路径: $dst" ;;
    esac
    if [[ "$dst" == *"/../"* || "$dst" == */.. || "$dst" == *"/./"* || "$dst" == "/." ]]; then
        die "卷目标不能包含 . 或 ..: $dst"
    fi

    if [[ -n "$ctr_dir" ]]; then
        _ensure_mount_target "$ctr_dir" "$src" "$dst"
    fi

    local mflag="-m"
    [[ ",$opts," == *",ro,"* ]] && mflag="-M"
    # ruri 对普通文件源会先按镜像文件处理（losetup 失败即返回，不回退 bind），
    # 必须加 BIND: 前缀强制走 bind mount。
    if [[ -f "$src" ]]; then
        src="BIND:${src}"
    fi
    arr+=("$mflag" "$src" "$dst")
}

# 在容器 rootfs 内准备挂载目标（docker 会自动创建目标）
_ensure_mount_target() {
    local ctr_dir="$1" src="$2" dst="$3"
    local root="${ctr_dir}/rootfs"
    local real_root real_target
    real_root=$(realpath -m "$root" 2>/dev/null || true)
    real_target=$(realpath -m "${root}${dst}" 2>/dev/null || true)
    [[ -n "$real_root" && -n "$real_target" ]] || return 0
    [[ "$real_target" == "$real_root"/* ]] || die "挂载目标越界: $dst"

    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$real_target")" 2>/dev/null || true
        if [[ -d "$real_target" ]]; then
            rmdir "$real_target" 2>/dev/null || warn "挂载目标 $dst 是非空目录，文件挂载可能失败"
        fi
        [[ -e "$real_target" ]] || : > "$real_target" 2>/dev/null || true
    else
        mkdir -p "$real_target" 2>/dev/null || true
        if [[ -e "$real_target" && ! -d "$real_target" ]]; then
            warn "挂载目标 $dst 已是文件，目录挂载可能失败"
        fi
    fi
}

# docker --mount type=bind,source=/host,target=/ctr[,readonly]
#       type=volume 不支持（ruri 无卷管理）；type=tmpfs 不支持
# docker --mount 的字段白名单（与 docker CLI 对齐）
_MOUNT_KEYS=" type source src target dst destination readonly ro bind-propagation consistency volume-driver volume-subpath volume-nocopy tmpfs-size tmpfs-mode "
_MOUNT_FLAGS=" readonly ro volume-nocopy "

_is_mount_key() { [[ "$_MOUNT_KEYS" == *" $1 "* ]]; }
_is_mount_flag() { [[ "$_MOUNT_FLAGS" == *" $1 "* ]]; }

# 去掉成对的首尾引号（--mount 的扩展语法，docker 本身不支持）
_strip_quotes() {
    local -n _sq="$1"
    if [[ ${#_sq} -ge 2 ]]; then
        if [[ "${_sq:0:1}" == '"' && "${_sq: -1}" == '"' ]] ||
            [[ "${_sq:0:1}" == "'" && "${_sq: -1}" == "'" ]]; then
            _sq="${_sq:1:${#_sq}-2}"
        fi
    fi
    return 0
}

# 按逗号拆分 --mount，支持：
#   - 反斜杠转义: \,   \\
#   - 单/双引号包裹的值（引号内逗号不拆分，引号在解析字段时去掉）
_split_mount_segments() {
    local spec="$1"
    local -n _segs="$2"
    _segs=()
    local cur="" i ch nxt
    local in_s=false in_d=false
    for ((i = 0; i < ${#spec}; i++)); do
        ch="${spec:i:1}"
        if [[ "$ch" == '\' ]] && (( i + 1 < ${#spec} )); then
            nxt="${spec:i+1:1}"
            if [[ "$nxt" == ',' || "$nxt" == '\' ]]; then
                cur+="$nxt"
                i=$((i + 1))
                continue
            fi
            cur+="$ch"
            continue
        fi
        if [[ "$ch" == "'" && "$in_d" == false ]]; then
            if [[ "$in_s" == true ]]; then in_s=false; else in_s=true; fi
            cur+="$ch"
            continue
        fi
        if [[ "$ch" == '"' && "$in_s" == false ]]; then
            if [[ "$in_d" == true ]]; then in_d=false; else in_d=true; fi
            cur+="$ch"
            continue
        fi
        if [[ "$ch" == ',' && "$in_s" == false && "$in_d" == false ]]; then
            _segs+=("$cur")
            cur=""
            continue
        fi
        cur+="$ch"
    done
    _segs+=("$cur")
    return 0
}

# docker --mount type=bind,source=/host,target=/ctr[,readonly]
#   type=bind    → ruri -m/-M（source 为文件时加 BIND:）
#   type=volume  → 报错（ruri 无卷管理）
#   type=tmpfs   → 警告并忽略
# 路径含逗号时可用反斜杠转义（source=/a\,b）或引号（source="/a,b"）。
# 为了兼容 docker 的宽松写法，不含 '=' 的片段会并入上一个字段的值。
_append_mount_spec() {
    local spec="$1"
    # 注意：nameref 名不要与 _append_mount 内的 nameref 同名，
    # 否则 bash 动态作用域会解析到自身，报“循环的名称引用”。
    local -n spec_out="$2"
    local ctr_dir="${3:-}"
    [[ -n "$spec" ]] || die "--mount 需要参数（如 type=bind,source=/host,target=/ctr）"

    local -a segs=()
    _split_mount_segments "$spec" segs

    local -A kv=()
    local -a mount_flags=()
    local cur_key="" seg k v
    for seg in "${segs[@]}"; do
        [[ -z "$seg" ]] && continue
        if [[ "$seg" == *=* ]]; then
            k="${seg%%=*}"
            v="${seg#*=}"
            if _is_mount_key "$k"; then
                _strip_quotes v
                kv["$k"]="$v"
                cur_key="$k"
                continue
            fi
            # 含 '=' 的未知字段一律报错（路径含逗号+等号时请用引号/转义）
            die "--mount 未知字段: $k"
        fi
        if _is_mount_flag "$seg"; then
            mount_flags+=("$seg")
            cur_key=""
            continue
        fi
        if [[ -n "$cur_key" ]]; then
            kv["$cur_key"]+=",${seg}"
            continue
        fi
        die "--mount 无法解析的片段: $seg（路径含逗号时请用引号或反斜杠转义）"
    done

    # docker 的 --mount 省略 type 时默认是 volume（ruri 不支持卷，会明确报错）
    local type="${kv[type]:-volume}"
    local src="${kv[source]:-${kv[src]:-}}"
    local dst="${kv[target]:-${kv[dst]:-${kv[destination]:-}}}"
    local ro=false f
    for f in ${mount_flags[@]+"${mount_flags[@]}"}; do
        if [[ "$f" == "readonly" || "$f" == "ro" ]]; then
            ro=true
        fi
    done
    # readonly=false / ro=false 明确关闭只读
    if [[ "${kv[readonly]:-}" == "false" || "${kv[ro]:-}" == "false" ]]; then
        ro=false
    elif [[ "${kv[readonly]:-}" == "true" || "${kv[ro]:-}" == "true" ]]; then
        ro=true
    fi

    case "$type" in
    bind)
        [[ -n "$src" ]] || die "--mount type=bind 缺少 source"
        [[ -n "$dst" ]] || die "--mount 缺少 target"
        [[ "$dst" == /* ]] || die "--mount target 必须是绝对路径: $dst"
        if [[ "$dst" == *"/../"* || "$dst" == */.. || "$dst" == *"/./"* || "$dst" == "/." ]]; then
            die "--mount target 不能包含 . 或 ..: $dst"
        fi
        if [[ -n "${kv[bind-propagation]:-}" ]]; then
            warn "--mount bind-propagation=${kv[bind-propagation]} 不受 ruri 支持，已忽略"
        fi
        if [[ -n "${kv[consistency]:-}" ]]; then
            warn "--mount consistency=${kv[consistency]} 不受支持，已忽略"
        fi
        if [[ -n "$ctr_dir" ]]; then
            _ensure_mount_target "$ctr_dir" "$src" "$dst"
        fi
        local mflag="-m"
        if $ro; then
            mflag="-M"
        fi
        # ruri 对普通文件源会先按镜像文件处理，必须用 BIND: 前缀
        if [[ -f "$src" ]]; then
            src="BIND:${src}"
        fi
        spec_out+=("$mflag" "$src" "$dst")
        ;;
    volume)
        die "--mount type=volume 不支持（ruri 无卷管理），请改用 type=bind 并指定宿主路径"
        ;;
    tmpfs)
        warn "--mount type=tmpfs 不受 ruri 支持，已忽略 target=${dst:-?}"
        ;;
    *)
        die "--mount type=$type 不支持（仅支持 bind）"
        ;;
    esac
}

# docker --add-host HOST:IP -> 追加到容器 hosts
_append_add_host() {
    local spec="$1" ctr_dir="$2"
    local host ip
    case "$spec" in
        *:*)
            host="${spec%%:*}"
            ip="${spec#*:}"
            ;;
        *=*)
            host="${spec%%=*}"
            ip="${spec#*=}"
            ;;
        *)
            die "无效的 --add-host '$spec'（应为 host:ip 或 host=ip）"
            ;;
    esac
    [[ -n "$host" && -n "$ip" ]] || die "无效的 --add-host '$spec'"
    printf '%s %s\n' "$ip" "$host" >> "${ctr_dir}/.add_hosts"
}

# ruri: -e, --env [env] [value]
# docker: -e KEY=VALUE | -e KEY（继承宿主）
_append_env() {
    local kv="$1"
    # shellcheck disable=SC2178
    local -n arr="$2"
    if [[ "$kv" == *=* ]]; then
        arr+=("-e" "${kv%%=*}" "${kv#*=}")
    else
        if [[ -v "$kv" ]]; then
            arr+=("-e" "$kv" "${!kv}")
        else
            warn "环境变量 $kv 未在当前 shell 中定义，已忽略"
        fi
    fi
}

_append_env_file() {
    local file="$1"
    # shellcheck disable=SC2178
    local -n arr="$2"
    [[ -r "$file" ]] || die "--env-file 不可读: $file"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        if [[ "$line" == *=* ]]; then
            arr+=("-e" "${line%%=*}" "${line#*=}")
        else
            warn "--env-file 忽略无 '=' 行: $line"
        fi
    done < "$file"
}

# docker --oom-score-adj -> ruri -O（范围 [-1000,1000]）
_append_oom_score() {
    local v="$1"
    # shellcheck disable=SC2178
    local -n arr="$2"
    [[ "$v" =~ ^-?[0-9]+$ ]] || die "--oom-score-adj 需要整数: $v"
    (( v >= -1000 && v <= 1000 )) || die "--oom-score-adj 超出范围 [-1000,1000]: $v"
    if _has_ruri_opt "-O"; then
        arr+=("-O" "$v")
    else
        warn "当前 ruri 不支持 -O/--oom-score-adj，已忽略"
    fi
}

# docker --label K=V（无 = 时从宿主环境取）；记录到 .labels 供 inspect 使用
_append_label() {
    local kv="$1" ctr_dir="$2"
    if [[ "$kv" == *=* ]]; then
        printf '%s=%s\n' "${kv%%=*}" "${kv#*=}" >> "${ctr_dir}/.labels"
    elif [[ -v "$kv" ]]; then
        printf '%s=%s\n' "$kv" "${!kv}" >> "${ctr_dir}/.labels"
    else
        warn "--label $kv 在当前 shell 中未定义，已忽略"
    fi
}

_append_label_file() {
    local file="$1" ctr_dir="$2"
    [[ -r "$file" ]] || die "--label-file 不可读: $file"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] && printf '%s\n' "$line" >> "${ctr_dir}/.labels"
    done < "$file"
}

# docker --restart：记录策略；本脚本无守护进程，不自动重启（inspect 可见）
_save_restart_policy() {
    local policy="$1" ctr_dir="$2"
    case "$policy" in
        no|always|unless-stopped) ;;
        on-failure|on-failure:*) ;;
        *) die "无效的 --restart 策略: $policy（no|always|on-failure[:N]|unless-stopped）" ;;
    esac
    printf '%s\n' "$policy" > "${ctr_dir}/.restart_policy"
    [[ "$policy" == "no" ]] || warn "本脚本无守护进程，--restart $policy 只记录不自动重启（inspect 可查）"
}

# docker --memory 512m/1g -> ruri -l memory=512M/1G
_normalize_mem() {
    local v="$1"
    local num="${v%[kKmMgG]}"
    local unit="${v#"$num"}"
    if [[ -z "$unit" ]]; then
        printf '%s\n' "$v"
    else
        printf '%s%s\n' "$num" "${unit^^}"
    fi
}

# ruri: -I, --char-dev [device] [major] [minor]
# docker: --device SRC[:DST[:PERM]]；DST 必须在 /dev 下，major/minor 从宿主设备读取
_append_device() {
    local v="$1"
    # shellcheck disable=SC2178
    local -n arr="$2"
    local src="" dst="" perm=""
    IFS=':' read -r src dst perm <<< "$v"
    if [[ -z "$src" ]]; then
        warn "无效的 --device '$v'，已忽略"
        return
    fi
    [[ -n "$dst" ]] || dst="$src"
    if [[ "$dst" != /dev/* ]]; then
        warn "--device 目标必须在 /dev 下: $dst，已忽略"
        return
    fi
    if [[ ! -e "$src" ]]; then
        warn "--device 源设备不存在: $src，已忽略"
        return
    fi
    local mm
    if ! mm=$(stat -Lc '%t:%T' "$src" 2>/dev/null); then
        warn "无法获取设备号: $src，已忽略"
        return
    fi
    local maj_hex="${mm%%:*}" min_hex="${mm##*:}"
    local maj=$((16#$maj_hex)) min=$((16#$min_hex))
    if [[ -n "$perm" && "$perm" != *r* ]]; then
        warn "--device 权限 '$perm' 不受 ruri 支持，仅按字符设备挂入"
    fi
    arr+=("-I" "${dst#/dev/}" "$maj" "$min")
}

# docker --security-opt -> ruri seccomp / no-new-privs
_append_security_opt() {
    local v="$1"
    # shellcheck disable=SC2178
    local -n arr="$2"
    case "$v" in
        seccomp=unconfined)
            : ;;  # ruri 默认无 seccomp
        seccomp=default|seccomp)
            if _has_ruri_opt --enable-seccomp; then
                arr+=("-s")
            else
                warn "ruri 不支持内置 seccomp，已忽略 --security-opt $v"
            fi ;;
        seccomp=*)
            warn "自定义 seccomp profile 不受支持，已忽略: $v" ;;
        no-new-privileges|no-new-privileges=*)
            arr+=("-n") ;;
        *)
            warn "不支持的 --security-opt '$v'，已忽略" ;;
    esac
}

# docker --platform linux/arm64 -> ruri -a arm64 -q $RURI_QEMU_PATH
_append_platform() {
    local plat="$1"
    # shellcheck disable=SC2178
    local -n arr="$2"
    local arch="${plat##*/}"
    if [[ -z "${RURI_QEMU_PATH:-}" ]]; then
        warn "跨架构 --platform $plat 需要 QEMU，请设置 RURI_QEMU_PATH=/path/to/qemu-${arch}"
        return
    fi
    if [[ ! -x "$RURI_QEMU_PATH" ]]; then
        warn "QEMU 不可执行: $RURI_QEMU_PATH，已忽略 --platform $plat"
        return
    fi
    arr+=("-a" "$arch" "-q" "$RURI_QEMU_PATH")
}

parse_docker_args_to_files() {
    local ctr_dir="$1"
    shift
    local ruri_args=()

    # 只解析“镜像之前”的 docker 选项；命令由调用方（cmd_run/cmd_create）单独保存，
    # 避免容器命令以 - 开头时被误当成 docker 选项吞掉。
    while [[ $# -gt 0 ]]; do
        case "$1" in
        # ---- 环境变量 ----
        -e|--env)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_env "$2" ruri_args; shift 2 ;;
        --env=*)
            _append_env "${1#*=}" ruri_args; shift ;;
        -e?*)
            _append_env "${1#-e}" ruri_args; shift ;;
        --env-file)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_env_file "$2" ruri_args; shift 2 ;;
        --env-file=*)
            _append_env_file "${1#*=}" ruri_args; shift ;;

        # ---- 挂载 ----
        -v|--volume)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_mount "$2" ruri_args "$ctr_dir"; shift 2 ;;
        --volume=*)
            _append_mount "${1#*=}" ruri_args "$ctr_dir"; shift ;;
        -v?*)
            _append_mount "${1#-v}" ruri_args "$ctr_dir"; shift ;;
        --mount)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_mount_spec "$2" ruri_args "$ctr_dir"; shift 2 ;;
        --mount=*)
            _append_mount_spec "${1#*=}" ruri_args "$ctr_dir"; shift ;;

        # ---- 工作目录：ruri 是 -W/--work-dir（-w 是 no-warnings） ----
        -w|--workdir)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            ruri_args+=("-W" "$2"); shift 2 ;;
        --workdir=*)
            ruri_args+=("-W" "${1#*=}"); shift ;;
        -w?*)
            ruri_args+=("-W" "${1#-w}"); shift ;;

        # ---- 用户：ruri 用 -E/--user ----
        -u|--user)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            ruri_args+=("-E" "$2"); shift 2 ;;
        --user=*)
            ruri_args+=("-E" "${1#*=}"); shift ;;
        -u?*)
            ruri_args+=("-E" "${1#-u}"); shift ;;

        # ---- hostname：ruri -t 仅在 unshare 模式生效 ----
        -h|--hostname)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            warn "ruri -t/--hostname 仅在 unshare 模式生效；当前共享主机 UTS 命名空间，内核 hostname 不变（/etc/hostname 已注入）"
            ruri_args+=("-t" "$2"); shift 2 ;;
        --hostname=*)
            warn "ruri -t/--hostname 仅在 unshare 模式生效；当前共享主机 UTS 命名空间，内核 hostname 不变（/etc/hostname 已注入）"
            ruri_args+=("-t" "${1#*=}"); shift ;;
        -h?*)
            warn "ruri -t/--hostname 仅在 unshare 模式生效；当前共享主机 UTS 命名空间，内核 hostname 不变（/etc/hostname 已注入）"
            ruri_args+=("-t" "${1#-h}"); shift ;;

        # ---- 特权 / 能力 / 只读 ----
        --privileged)
            ruri_args+=("-p"); shift ;;
        --cap-add)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            ruri_args+=("-k" "$2"); shift 2 ;;
        --cap-add=*)
            ruri_args+=("-k" "${1#*=}"); shift ;;
        --cap-drop)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            ruri_args+=("-d" "$2"); shift 2 ;;
        --cap-drop=*)
            ruri_args+=("-d" "${1#*=}"); shift ;;
        --read-only)
            if _ruri_supports_readonly; then
                ruri_args+=("-R")
            else
                warn "当前 ruri 不支持只读根（-R 未实现），已忽略 --read-only"
            fi
            shift ;;

        # ---- 资源限制：docker -> ruri -l ----
        -m|--memory)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            ruri_args+=("-l" "memory=$(_normalize_mem "$2")"); shift 2 ;;
        --memory=*)
            ruri_args+=("-l" "memory=$(_normalize_mem "${1#*=}")"); shift ;;
        -m?*)
            ruri_args+=("-l" "memory=$(_normalize_mem "${1#-m}")"); shift ;;
        --cpus)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            local pct
            pct=$(awk -v c="$2" 'BEGIN { printf "%.0f", c*100 }')
            ruri_args+=("-l" "cpupercent=$pct"); shift 2 ;;
        --cpus=*)
            local pct
            pct=$(awk -v c="${1#*=}" 'BEGIN { printf "%.0f", c*100 }')
            ruri_args+=("-l" "cpupercent=$pct"); shift ;;
        --pids-limit)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            if [[ "$2" != "-1" ]]; then ruri_args+=("-l" "pids=$2"); fi
            shift 2 ;;
        --pids-limit=*)
            local pl="${1#*=}"
            if [[ "$pl" != "-1" ]]; then ruri_args+=("-l" "pids=$pl"); fi
            shift ;;

        # ---- 设备 / 安全 / 跨架构 / init ----
        --device)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_device "$2" ruri_args; shift 2 ;;
        --device=*)
            _append_device "${1#*=}" ruri_args; shift ;;
        --security-opt)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_security_opt "$2" ruri_args; shift 2 ;;
        --security-opt=*)
            _append_security_opt "${1#*=}" ruri_args; shift ;;
        --platform)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_platform "$2" ruri_args; shift 2 ;;
        --platform=*)
            _append_platform "${1#*=}" ruri_args; shift ;;
        --init)
            if _has_ruri_opt --fork-as-init; then
                ruri_args+=("--fork-as-init")
            else
                warn "ruri 不支持 --fork-as-init，已忽略 --init"
            fi
            shift ;;

        # ---- 网络：ruri 只支持关闭（-x） ----
        --net|--network)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            case "$2" in
            none) ruri_args+=("-x") ;;      # 断网
            host) : ;;                       # ruri 默认共享主机网络，等价
            *)    warn "不支持网络模式 $2（ruri 共享主机网络），已忽略" ;;
            esac
            shift 2 ;;
        --net=*|--network=*)
            if [[ "${1#*=}" == "none" ]]; then
                ruri_args+=("-x")
            else
                warn "不支持网络模式 ${1#*=}，已忽略"
            fi
            shift ;;

        # ---- 端口映射：ruri 共享主机网络，无 NAT 语义 ----
        -p|--publish)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            warn "ruri 共享主机网络：容器监听 0.0.0.0:C 即等价主机 C 端口；端口转发 $1 $2 不适用，已忽略"
            shift 2 ;;
        --publish=*)
            warn "ruri 共享主机网络：端口转发 $1 不适用，已忽略"
            shift ;;
        -p?*)
            warn "ruri 共享主机网络：端口转发 ${1#-p} 不适用，已忽略"
            shift ;;

        # ---- entrypoint / hosts / dns（脚本自己处理，不传给 ruri） ----
        --entrypoint)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            save_args "$ctr_dir/.entrypoint_override" "$2"
            : > "$ctr_dir/.entrypoint_set"
            shift 2 ;;
        --entrypoint=*)
            save_args "$ctr_dir/.entrypoint_override" "${1#*=}"
            : > "$ctr_dir/.entrypoint_set"
            shift ;;
        --stop-signal)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            printf '%s\n' "$2" > "$ctr_dir/.stop_signal"
            shift 2 ;;
        --stop-signal=*)
            printf '%s\n' "${1#*=}" > "$ctr_dir/.stop_signal"
            shift ;;
        --add-host)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_add_host "$2" "$ctr_dir"; shift 2 ;;
        --add-host=*)
            _append_add_host "${1#*=}" "$ctr_dir"; shift ;;
        --dns)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            printf '%s\n' "$2" >> "${ctr_dir}/.dns"; shift 2 ;;
        --dns=*)
            printf '%s\n' "${1#*=}" >> "${ctr_dir}/.dns"; shift ;;
        --dns-search)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            printf '%s\n' "$2" >> "${ctr_dir}/.dns_search"; shift 2 ;;
        --dns-search=*)
            printf '%s\n' "${1#*=}" >> "${ctr_dir}/.dns_search"; shift ;;
        --dns-option)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            printf '%s\n' "$2" >> "${ctr_dir}/.dns_option"; shift 2 ;;
        --dns-option=*)
            printf '%s\n' "${1#*=}" >> "${ctr_dir}/.dns_option"; shift ;;
        --oom-score-adj)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _append_oom_score "$2" ruri_args; shift 2 ;;
        --oom-score-adj=*)
            _append_oom_score "${1#*=}" ruri_args; shift ;;
        --stop-timeout)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            [[ "$2" =~ ^[0-9]+$ ]] || die "--stop-timeout 需要秒数: $2"
            printf '%s\n' "$2" > "${ctr_dir}/.stop_timeout"; shift 2 ;;
        --stop-timeout=*)
            [[ "${1#*=}" =~ ^[0-9]+$ ]] || die "--stop-timeout 需要秒数: ${1#*=}"
            printf '%s\n' "${1#*=}" > "${ctr_dir}/.stop_timeout"; shift ;;
        --label|--label-file)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            if [[ "$1" == "--label" ]]; then
                _append_label "$2" "$ctr_dir"
            else
                _append_label_file "$2" "$ctr_dir"
            fi
            shift 2 ;;
        --label=*)
            _append_label "${1#*=}" "$ctr_dir"; shift ;;
        --label-file=*)
            _append_label_file "${1#*=}" "$ctr_dir"; shift ;;
        --cidfile)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            printf '%s\n' "$2" > "${ctr_dir}/.cidfile_path"; shift 2 ;;
        --cidfile=*)
            printf '%s\n' "${1#*=}" > "${ctr_dir}/.cidfile_path"; shift ;;
        --restart)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            _save_restart_policy "$2" "$ctr_dir"; shift 2 ;;
        --restart=*)
            _save_restart_policy "${1#*=}" "$ctr_dir"; shift ;;
        --expose)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            printf '%s\n' "$2" >> "${ctr_dir}/.expose"; shift 2 ;;
        --expose=*)
            printf '%s\n' "${1#*=}" >> "${ctr_dir}/.expose"; shift ;;

        # ---- 容器生命周期由脚本管理 ----
        --rm)
            shift ;;

        # ---- 明确不支持的带值选项：必须消费其值，避免错位 ----
        --ulimit|--log-driver|--log-opt|--cgroupns|--ipc|--pid|--userns|--uts|--sysctl|--group-add|--link|--mac-address|--ip|--tmpfs|--health-cmd|--health-interval|--health-retries|--health-timeout|--health-start-period|--shm-size|--memory-swap|--memory-reservation|--cpu-shares|--cpu-quota|--cpu-period|--cpuset-cpus|--cpuset-mems|--blkio-weight|--volumes-from|--network-alias)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            warn "不支持参数 $1 $2，已忽略"
            shift 2 ;;

        # ---- 明确不支持的无值选项 ----
        --no-healthcheck|--oom-kill-disable|--disable-content-trust)
            warn "不支持参数 $1，已忽略"
            shift ;;

        # ---- 结束选项解析（命令由调用方保存） ----
        --)
            shift
            break ;;

        # ---- 未知选项 / 非选项 ----
        -*)
            die "不支持的参数 $1（容器命令以 - 开头时请用 -- 分隔，例如: run IMAGE -- -x）" ;;
        *)
            die "内部错误：选项解析遇到非选项参数 '$1'" ;;
        esac
    done

    # 只落盘用户显式参数；镜像 Env/WorkingDir/User 由 _sync_runtime_config 每次重算
    save_args "$ctr_dir/.user_args" ${ruri_args[@]+"${ruri_args[@]}"}
}

# ====================== 镜像配置同步（对齐 docker） ======================
# 运行配置的权威来源与 docker 一致：镜像 config（OCI image config 的 .config 段）。
# 创建容器时快照到 .image_config.json；每次 start 从这里重新同步，
# 因此镜像被重新 pull 覆盖也不会改变已有容器（等价 docker 的 image ID 固定语义）。

# 从 OCI layout 定位镜像 config blob
_oci_config_blob() {
    local img_dir="$1"
    local idx="${img_dir}/oci/index.json"
    [[ -f "$idx" ]] || return 1
    local mf_digest mf cfg_digest cfg
    mf_digest=$(jq -r '.manifests[0].digest // empty' "$idx" 2>/dev/null) || return 1
    [[ -n "$mf_digest" ]] || return 1
    mf="${img_dir}/oci/blobs/sha256/${mf_digest#sha256:}"
    [[ -f "$mf" ]] || return 1
    cfg_digest=$(jq -r '.config.digest // empty' "$mf" 2>/dev/null) || return 1
    [[ -n "$cfg_digest" ]] || return 1
    cfg="${img_dir}/oci/blobs/sha256/${cfg_digest#sha256:}"
    [[ -f "$cfg" ]] || return 1
    printf '%s\n' "$cfg"
}

# 生成/复用容器的镜像配置快照（等价 docker inspect 的 Config 段）
_ensure_image_config() {
    local ctr_dir="$1"
    local out="${ctr_dir}/.image_config.json"
    [[ -s "$out" ]] && return 0
    local img_dir
    img_dir=$(cat "${ctr_dir}/.image_dir" 2>/dev/null || true)
    [[ -n "$img_dir" && -d "$img_dir" ]] || return 1

    local blob uid_num=""
    if blob=$(_oci_config_blob "$img_dir"); then
        # docker 把镜像的 User 解析成数字 uid 放进 runtime spec；
        # umoci 解包时已解析好，优先用它，避免 ruri 再按用户名查 /etc/passwd
        local bcfg="${img_dir}/bundle/config.json"
        if [[ -f "$bcfg" ]]; then
            uid_num=$(jq -r '.process.user.uid // empty' "$bcfg" 2>/dev/null || true)
        fi
        jq -S --arg uid "$uid_num" '{
            Env: (.config.Env // []),
            Cmd: (.config.Cmd // []),
            Entrypoint: (.config.Entrypoint // []),
            WorkingDir: (.config.WorkingDir // ""),
            User: (if ($uid != "" and $uid != "0") then $uid else (.config.User // "") end),
            StopSignal: (.config.StopSignal // ""),
            Volumes: (.config.Volumes // {}),
            ExposedPorts: (.config.ExposedPorts // {}),
            Labels: (.config.Labels // {}),
            Healthcheck: (.config.Healthcheck // null)
        }' "$blob" > "$out" 2>/dev/null && return 0
        rm -f "$out"
    fi

    # 回退：umoci 解包后的 runtime spec 里 args 已是 ENTRYPOINT+CMD 合并结果，
    # 无法再拆分，只能整体当作 Cmd（与旧版本行为一致）。
    local bcfg="${img_dir}/bundle/config.json"
    [[ -f "$bcfg" ]] || return 1
    jq -S '{
        Env: (.process.env // []),
        Cmd: (.process.args // []),
        Entrypoint: [],
        WorkingDir: (.process.cwd // ""),
        User: (if ((.process.user.uid // 0) == 0) then "" else (.process.user.uid | tostring) end),
        StopSignal: (.annotations["org.opencontainers.image.stopSignal"] // ""),
        Volumes: {},
        ExposedPorts: {},
        Labels: {},
        Healthcheck: null
    }' "$bcfg" > "$out" 2>/dev/null || { rm -f "$out"; return 1; }
    return 0
}

# 把参数列表转成 JSON 数组（空列表输出 []）
_json_array() {
    if [[ $# -eq 0 ]]; then
        printf '[]\n'
    else
        printf '%s\n' "$@" | jq -Rn '[inputs]'
    fi
}

# 从参数数组里取选项的第一个值：_arg_value <数组变量名> <选项>
_arg_value() {
    local -n _av_arr="$1"
    local opt="$2"
    local i=0
    while (( i < ${#_av_arr[@]} )); do
        if [[ "${_av_arr[$i]}" == "$opt" ]] && (( i + 1 < ${#_av_arr[@]} )); then
            printf '%s\n' "${_av_arr[$((i + 1))]}"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# 读取容器当前 .ruri_args 里某个选项的值
_ctr_ruri_value() {
    local ctr_dir="$1" opt="$2"
    local -a ra=()
    load_args "${ctr_dir}/.ruri_args" ra
    _arg_value ra "$opt"
}

# 从 ruri 参数数组提取 hostname（-t）
_hostname_from_args() {
    local -n _ha_arr="$1"
    _arg_value _ha_arr "-t"
}

# 按 docker 语义重算容器的运行配置，幂等：
#   命令     = [--entrypoint 或镜像 Entrypoint] + [容器命令 或 镜像 Cmd]
#   环境     = 镜像 Env（被 -e/--env-file 同名覆盖）+ 用户 env + HOSTNAME
#   工作目录 = -w（用户）> 镜像 WorkingDir
#   用户     = -u（用户）> 镜像 User
# 每次 run/create/start 调用；来自镜像的部分每次重算，
# 用户显式参数保存在 .user_args，不会被镜像配置覆盖。
_sync_runtime_config() {
    local ctr_dir="$1" ctr_name="$2"
    local cfg="${ctr_dir}/.image_config.json"
    local have_cfg=false
    if _ensure_image_config "$ctr_dir"; then
        have_cfg=true
    else
        warn "无法读取镜像配置，跳过镜像 Env/WorkingDir/User 同步（容器 $ctr_name）"
    fi

    # ---- 拆解用户参数：-e/-W/-E 由本函数统一重算 ----
    [[ -f "${ctr_dir}/.user_args" ]] \
        || die "容器配置不完整（缺少 .user_args）：$ctr_name，请删除后重新创建"
    local -a user_args=()
    load_args "${ctr_dir}/.user_args" user_args
    local -a base=() user_env=()
    local user_workdir="" user_user=""
    local have_workdir=false have_user=false
    local i=0 a
    while (( i < ${#user_args[@]} )); do
        a="${user_args[$i]}"
        case "$a" in
        -e)
            if (( i + 2 < ${#user_args[@]} )); then
                user_env+=("${user_args[$((i + 1))]}" "${user_args[$((i + 2))]}")
                i=$((i + 3)); continue
            fi ;;
        -W)
            if (( i + 1 < ${#user_args[@]} )); then
                user_workdir="${user_args[$((i + 1))]}"
                have_workdir=true
                i=$((i + 2)); continue
            fi ;;
        -E)
            if (( i + 1 < ${#user_args[@]} )); then
                user_user="${user_args[$((i + 1))]}"
                have_user=true
                i=$((i + 2)); continue
            fi ;;
        esac
        base+=("$a")
        i=$((i + 1))
    done

    # ---- 镜像配置 ----
    local -a img_env=() img_cmd=() img_ep=()
    local img_workdir="" img_user=""
    if $have_cfg; then
        mapfile -t img_env < <(jq -r '.Env[]? // empty' "$cfg" 2>/dev/null || true)
        mapfile -t img_cmd < <(jq -r '.Cmd[]? // empty' "$cfg" 2>/dev/null || true)
        mapfile -t img_ep < <(jq -r '.Entrypoint[]? // empty' "$cfg" 2>/dev/null || true)
        img_workdir=$(jq -r '.WorkingDir // empty' "$cfg" 2>/dev/null || true)
        img_user=$(jq -r '.User // empty' "$cfg" 2>/dev/null || true)
    fi

    # ---- 环境变量：镜像在前、用户同名覆盖 ----
    local -A user_env_key=()
    local j
    for ((j = 0; j < ${#user_env[@]}; j += 2)); do
        user_env_key["${user_env[$j]}"]=1
    done
    local -a env_args=()
    local -A emitted=()
    local kv k
    for kv in ${img_env[@]+"${img_env[@]}"}; do
        [[ "$kv" == *=* ]] || continue
        k="${kv%%=*}"
        [[ -n "${user_env_key[$k]+x}" ]] && continue
        [[ -n "${emitted[$k]+x}" ]] && continue
        env_args+=("-e" "$k" "${kv#*=}")
        emitted[$k]=1
    done
    for ((j = 0; j < ${#user_env[@]}; j += 2)); do
        k="${user_env[$j]}"
        env_args+=("-e" "$k" "${user_env[$((j + 1))]}")
        emitted[$k]=1
    done

    # docker 会为容器注入 HOSTNAME
    local hostname
    hostname=$(_hostname_from_args base || true)
    [[ -n "$hostname" ]] || hostname="$ctr_name"
    hostname=$(_normalize_hostname "$hostname")
    if [[ -z "${emitted[HOSTNAME]+x}" ]]; then
        env_args+=("-e" "HOSTNAME" "$hostname")
    fi

    # ---- ruri 参数：镜像 env + 工作目录/用户（用户优先）+ 其余用户参数 ----
    local -a rt_args=()
    rt_args+=(${env_args[@]+"${env_args[@]}"})
    if $have_workdir; then
        rt_args+=("-W" "$user_workdir")
    elif [[ -n "$img_workdir" ]]; then
        rt_args+=("-W" "$img_workdir")
    fi
    if $have_user; then
        rt_args+=("-E" "$user_user")
    elif [[ -n "$img_user" ]]; then
        rt_args+=("-E" "$img_user")
    fi
    # 镜像声明的 VOLUME：docker 会创建匿名卷并挂载，数据不落入 rootfs（commit 不带卷数据）
    local -a vol_args=()
    if $have_cfg; then
        local -a vol_paths=()
        mapfile -t vol_paths < <(jq -r '(.Volumes // {}) | keys[]?' "$cfg" 2>/dev/null || true)
        if [[ ${#vol_paths[@]} -gt 0 ]]; then
            local -A mount_targets=()
            local bi=0
            while (( bi < ${#base[@]} )); do
                case "${base[$bi]}" in
                -m|-M)
                    if (( bi + 2 < ${#base[@]} )); then
                        mount_targets["${base[$((bi + 2))]}"]=1
                    fi
                    bi=$((bi + 3)); continue ;;
                esac
                bi=$((bi + 1))
            done
            # 最终运行用户（用于匿名卷属主；只处理数字 uid，用户名交给 ruri 解析）
            local final_user=""
            if $have_user; then
                final_user="$user_user"
            elif [[ -n "$img_user" ]]; then
                final_user="$img_user"
            fi

            local vp vname vol_dir init_mark
            mkdir -p "${ctr_dir}/.volume_init" 2>/dev/null || true
            for vp in ${vol_paths[@]+"${vol_paths[@]}"}; do
                # 用户显式挂载同一目标时以用户为准（docker 语义）
                [[ -n "${mount_targets[$vp]+x}" ]] && continue
                vname=$(printf '%s' "$vp" | tr -c 'a-zA-Z0-9._-' '_')
                vol_dir="${ctr_dir}/volumes/${vname}"
                init_mark="${ctr_dir}/.volume_init/${vname}"
                mkdir -p "$vol_dir" 2>/dev/null || continue
                # docker 语义：匿名卷首次创建时把镜像目录的内容复制进卷
                if [[ ! -e "$init_mark" ]]; then
                    if [[ -d "${ctr_dir}/rootfs${vp}" ]]; then
                        if [[ -n "$(ls -A "${ctr_dir}/rootfs${vp}" 2>/dev/null)" ]]; then
                            cp -a "${ctr_dir}/rootfs${vp}/." "$vol_dir/" 2>/dev/null \
                                || warn "复制镜像目录到匿名卷失败: $vp"
                        fi
                        chown --reference="${ctr_dir}/rootfs${vp}" "$vol_dir" 2>/dev/null || true
                        chmod --reference="${ctr_dir}/rootfs${vp}" "$vol_dir" 2>/dev/null || true
                    fi
                    # 匿名卷是脚本创建的，按容器最终运行用户设置属主，避免非 root
                    # 用户启动时对卷无写权限（宿主目录 -v 挂载不碰，仍由用户负责）
                    if [[ "$final_user" =~ ^[0-9]+$ ]] && (( final_user > 0 )); then
                        chown "$final_user" "$vol_dir" 2>/dev/null || true
                    fi
                    : > "$init_mark" 2>/dev/null || true
                fi
                mkdir -p "${ctr_dir}/rootfs${vp}" 2>/dev/null || true
                vol_args+=("-m" "$vol_dir" "$vp")
            done
        fi
    fi
    save_args "${ctr_dir}/.ruri_args" ${rt_args[@]+"${rt_args[@]}"} ${vol_args[@]+"${vol_args[@]}"} ${base[@]+"${base[@]}"}

    # ---- 命令：[entrypoint] + [用户命令 或 镜像 Cmd] ----
    local -a ep=() cmd=() argv=()
    if [[ -f "${ctr_dir}/.entrypoint_set" ]]; then
        load_args "${ctr_dir}/.entrypoint_override" ep
    else
        ep=(${img_ep[@]+"${img_ep[@]}"})
    fi
    # --entrypoint "" 表示清空 entrypoint，过滤掉空元素
    local -a ep_clean=()
    local e
    for e in ${ep[@]+"${ep[@]}"}; do
        [[ -n "$e" ]] && ep_clean+=("$e")
    done
    ep=(${ep_clean[@]+"${ep_clean[@]}"})
    load_args "${ctr_dir}/.user_cmd" cmd
    if [[ ${#cmd[@]} -eq 0 ]]; then
        cmd=(${img_cmd[@]+"${img_cmd[@]}"})
    fi
    argv=(${ep[@]+"${ep[@]}"} ${cmd[@]+"${cmd[@]}"})
    [[ ${#argv[@]} -gt 0 ]] || die "镜像未指定命令，请在 IMAGE 之后显式给出命令"
    save_args "${ctr_dir}/.cmd_args" ${argv[@]+"${argv[@]}"}

    # /etc 注入与挂载（start 时也刷新，对齐 docker 每次 start 的网络初始化）
    _setup_etc_and_rebuild_args "$ctr_dir" "$ctr_name"
}

# docker --cidfile：容器创建后把标识写入文件
_write_cidfile() {
    local ctr_dir="$1" ctr_name="$2"
    local path
    path=$(cat "${ctr_dir}/.cidfile_path" 2>/dev/null || true)
    [[ -n "$path" ]] || return 0
    printf '%s\n' "$ctr_name" > "$path" 2>/dev/null || warn "无法写入 --cidfile: $path"
}

# 后台 --rm：容器退出后删除容器目录（docker run -d --rm 语义）
_watch_rm_bg() {
    local ctr_dir="$1" pid="$2"
    (
        _close_lock_fd
        while _proc_alive "$pid" 2>/dev/null; do sleep 0.2; done
        cleanup_mounts "${ctr_dir}/rootfs" 2>/dev/null || true
        rm -rf "$ctr_dir"
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# ====================== /etc 注入 ======================
_extract_hostname_from_ruri_args() {
    local ctr_dir="$1"
    local -a ra=()
    load_args "${ctr_dir}/.ruri_args" ra
    local i
    for ((i=0; i<${#ra[@]}; i++)); do
        if [[ "${ra[$i]}" == "-t" || "${ra[$i]}" == "--hostname" ]] && (( i+1 < ${#ra[@]} )); then
            echo "${ra[$((i+1))]}"
            return 0
        fi
    done
    return 0
}

_normalize_hostname() {
    local h="$1"
    [[ -z "$h" ]] && h="localhost"
    h=$(printf '%s' "$h" | tr -c 'a-zA-Z0-9.-' '-' | cut -c1-63)
    [[ "$h" == -* ]] && h="h${h}"
    echo "$h"
}

_set_resolv_line() {
    local file="$1" key="$2" line="$3"
    local tmp="${file}.tmp.$$"
    { grep -v "^${key}[[:space:]]" "$file" 2>/dev/null || true; printf '%s\n' "$line"; } > "$tmp"
    mv "$tmp" "$file"
}

# 为容器生成 .etc/{hosts,hostname,resolv.conf}，并把 -m 挂载追加到 .ruri_args 最前面
# 用户后续的 -v /etc/hosts:... 会覆盖这些默认挂载
_setup_etc_and_rebuild_args() {
    local ctr_dir="$1" ctr_name="$2"
    local hostname
    hostname=$(_extract_hostname_from_ruri_args "$ctr_dir")
    [[ -z "$hostname" ]] && hostname="$ctr_name"
    hostname=$(_normalize_hostname "$hostname")

    local etc_dir="${ctr_dir}/.etc"
    mkdir -p "$etc_dir"

    printf '%s\n' "$hostname" > "${etc_dir}/hostname"
    # 与 docker 的默认 /etc/hosts 保持一致（共享主机网络，容器地址即 127.0.0.1）
    {
        echo "127.0.0.1 localhost"
        echo "::1 localhost ip6-localhost ip6-loopback"
        echo "fe00::0 ip6-localnet"
        echo "ff00::0 ip6-mcastprefix"
        echo "ff02::1 ip6-allnodes"
        echo "ff02::2 ip6-allrouters"
        echo "127.0.0.1 ${hostname}"
        if [[ -s "${ctr_dir}/.add_hosts" ]]; then
            cat "${ctr_dir}/.add_hosts"
        fi
    } > "${etc_dir}/hosts"

    # --dns 优先；否则沿用宿主 resolv.conf
    if [[ -s "${ctr_dir}/.dns" ]]; then
        local d
        : > "${etc_dir}/resolv.conf"
        while IFS= read -r d; do
            [[ -n "$d" ]] && printf 'nameserver %s\n' "$d" >> "${etc_dir}/resolv.conf"
        done < "${ctr_dir}/.dns"
    elif [[ -r /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf "${etc_dir}/resolv.conf" 2>/dev/null || :
    fi
    # --dns-search / --dns-option 覆盖同名行（docker 会把它们写进容器 resolv.conf）
    if [[ -s "${ctr_dir}/.dns_search" ]]; then
        _set_resolv_line "${etc_dir}/resolv.conf" "search" "search $(paste -sd' ' "${ctr_dir}/.dns_search")"
    fi
    if [[ -s "${ctr_dir}/.dns_option" ]]; then
        _set_resolv_line "${etc_dir}/resolv.conf" "options" "options $(paste -sd' ' "${ctr_dir}/.dns_option")"
    fi

    mkdir -p "${ctr_dir}/rootfs/etc" 2>/dev/null || true
    local f
    for f in hosts hostname; do
        [[ -e "${ctr_dir}/rootfs/etc/$f" ]] || : > "${ctr_dir}/rootfs/etc/$f" 2>/dev/null || true
    done
    if [[ -f "${etc_dir}/resolv.conf" ]]; then
        [[ -e "${ctr_dir}/rootfs/etc/resolv.conf" ]] || : > "${ctr_dir}/rootfs/etc/resolv.conf" 2>/dev/null || true
    fi

    # .ruri_args 每次都由 _sync_runtime_config 从 .user_args 重建，不含 /etc 挂载，
    # 这里直接在最前面插入默认挂载；用户的 -v /etc/hosts:... 会覆盖它们（docker 语义）
    local -a user_args=()
    load_args "${ctr_dir}/.ruri_args" user_args

    local -a setup_args=(
        -m "BIND:${etc_dir}/hosts" /etc/hosts
        -m "BIND:${etc_dir}/hostname" /etc/hostname
    )
    [[ -f "${etc_dir}/resolv.conf" ]] && setup_args+=(-m "BIND:${etc_dir}/resolv.conf" /etc/resolv.conf)

    save_args "${ctr_dir}/.ruri_args" "${setup_args[@]}" ${user_args[@]+"${user_args[@]}"}
}

# ====================== 运行时封装 ======================
# 后台启动：优先 ruri -b -L <log> --pid-file，pid 由 ruri 自己写；
# 若 ruri 不支持则回退到 shell job control。
# 返回：容器 init 的 pid（同时写入 .pid）
# 说明：后台模式不加 --auto-umount（ruri 父进程 fork 后即退出，语义不可靠），
#       挂载清理由 cleanup_mounts 兜底。
runtime_run_bg() {
    local ctr_dir="$1"
    local logfile="$2"
    local pidfile="${ctr_dir}/.pid"

    # 已有实例在跑时直接复用，避免重复启动同一个 rootfs
    refresh_ctr_state "$ctr_dir"
    case "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" in
    running|paused)
        local cur
        cur=$(_ctr_pid "$ctr_dir")
        [[ -n "$cur" ]] && echo "$cur"
        return 0
        ;;
    esac
    rm -f "$pidfile"

    local ruri_args=()
    local cmd_args=()
    load_args "$ctr_dir/.ruri_args" ruri_args
    load_args "$ctr_dir/.cmd_args" cmd_args

    local -a host_rt=()
    if [[ "$USE_HOST_RUNTIME" == "1" ]]; then
        host_rt+=("-S")
        # -S 只 bind /dev 本身，不是递归 bind；/dev/pts、/dev/shm 是独立挂载，
        # 必须单独挂入，否则容器内 tty/script 等无法识别 PTY。
        if [[ -d /dev/pts ]]; then
            host_rt+=("-m" "/dev/pts" "/dev/pts")
        fi
        if [[ -d /dev/shm ]]; then
            host_rt+=("-m" "/dev/shm" "/dev/shm")
        fi
    fi

    if _has_ruri_pidfile; then
        (
            _close_lock_fd
            exec env -u LD_PRELOAD -u LD_LIBRARY_PATH -u LD_AUDIT \
                "$RUNTIME" -b -L "$logfile" --pid-file "$pidfile" \
                ${host_rt[@]+"${host_rt[@]}"} \
                ${ruri_args[@]+"${ruri_args[@]}"} \
                "${ctr_dir}/rootfs" ${cmd_args[@]+"${cmd_args[@]}"}
        ) </dev/null >/dev/null 2>&1 || true
        local i
        for ((i=0; i<50; i++)); do
            if _pidfile_parse "$pidfile" && [[ -n "$PIDFILE_PID" ]]; then
                echo "$PIDFILE_PID"
                return 0
            fi
            sleep 0.05
        done
        # ruri 可能已经 fork 成功，只是 pid 文件写得慢；先确认再回退，避免双启动
        local existing
        existing=$(_find_ctr_init_pid "$ctr_dir" || true)
        if [[ -n "$existing" ]]; then
            warn "ruri -b 已启动但 pid 文件未及时生成，复用已有进程"
            echo "$existing" > "$pidfile"
            echo "$existing"
            return 0
        fi
        warn "ruri -b --pid-file 未生成 pid 文件，回退到 shell job control"
    fi

    set -m 2>/dev/null || true
    (
        _close_lock_fd
        exec env -u LD_PRELOAD -u LD_LIBRARY_PATH -u LD_AUDIT \
            "$RUNTIME" ${host_rt[@]+"${host_rt[@]}"} \
            ${ruri_args[@]+"${ruri_args[@]}"} \
            "${ctr_dir}/rootfs" ${cmd_args[@]+"${cmd_args[@]}"}
    ) </dev/null >> "$logfile" 2>&1 &
    local pid=$!
    set +m 2>/dev/null || true
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$pidfile"
    echo "$pid"
}

# 前台运行：-t 才加 -z；输出同时写 run.log；pid 即容器 init
# 前台模式若 ruri 支持 --auto-umount 则附加，退出即卸载，减少挂载泄漏。
runtime_run_fg_attach() {
    local ctr_dir="$1"
    local logfile="${ctr_dir}/run.log"
    local ruri_args=()
    local cmd_args=()
    load_args "$ctr_dir/.ruri_args" ruri_args
    load_args "$ctr_dir/.cmd_args" cmd_args

    local -a extra=()
    if [[ -f "${ctr_dir}/.tty" ]]; then
        extra+=("-z")
    fi
    local -a host_rt=()
    if [[ "$USE_HOST_RUNTIME" == "1" ]]; then
        host_rt+=("-S")
        # -S 只 bind /dev 本身，不是递归 bind；/dev/pts、/dev/shm 是独立挂载，
        # 必须单独挂入，否则容器内 tty/script 等无法识别 PTY。
        if [[ -d /dev/pts ]]; then
            host_rt+=("-m" "/dev/pts" "/dev/pts")
        fi
        if [[ -d /dev/shm ]]; then
            host_rt+=("-m" "/dev/shm" "/dev/shm")
        fi
    fi
    local -a auto_umount=()
    _has_ruri_opt --auto-umount && auto_umount+=("--auto-umount")

    touch "$logfile"

    # 前台：输出经 tee 同时写 run.log 与终端。
    # tee 用进程替换启动，pid 记到 .tee_pid，ruri 退出后再 wait tee，
    # 避免日志尾部还没刷完脚本就返回。
    local tee_pidfile="${ctr_dir}/.tee_pid"
    rm -f "$tee_pidfile"
    exec 3> >(printf '%s\n' "$BASHPID" > "$tee_pidfile"; exec tee -a "$logfile")

    local pid
    if [[ -f "${ctr_dir}/.interactive" ]]; then
        # 非交互 shell 中 `cmd &` 会把后台进程的 stdin 指向 /dev/null，
        # 先用 fd 9 备份 stdin，再显式 0<&9 恢复，-i 才真正生效。
        exec 9<&0
        (
            _close_lock_fd
            exec env -u LD_PRELOAD -u LD_LIBRARY_PATH -u LD_AUDIT \
                "$RUNTIME" ${extra[@]+"${extra[@]}"} ${auto_umount[@]+"${auto_umount[@]}"} \
                ${host_rt[@]+"${host_rt[@]}"} \
                ${ruri_args[@]+"${ruri_args[@]}"} \
                "${ctr_dir}/rootfs" ${cmd_args[@]+"${cmd_args[@]}"}
        ) 0<&9 >&3 2>&3 &
        pid=$!
        exec 9<&-
    else
        (
            _close_lock_fd
            exec env -u LD_PRELOAD -u LD_LIBRARY_PATH -u LD_AUDIT \
                "$RUNTIME" ${extra[@]+"${extra[@]}"} ${auto_umount[@]+"${auto_umount[@]}"} \
                ${host_rt[@]+"${host_rt[@]}"} \
                ${ruri_args[@]+"${ruri_args[@]}"} \
                "${ctr_dir}/rootfs" ${cmd_args[@]+"${cmd_args[@]}"}
        ) </dev/null >&3 2>&3 &
        pid=$!
    fi
    exec 3>&-

    # 前台模式由脚本自己维护 pidfile（ruri 前台不加 --pid-file），
    # 这样 ps/stop/wait 与 Ctrl+C 后的状态判定才准确
    echo "$pid" > "${ctr_dir}/.pid"
    get_starttime "$pid" > "${ctr_dir}/.pid_start" 2>/dev/null || : > "${ctr_dir}/.pid_start"
    date -Iseconds > "${ctr_dir}/.started_at"
    echo "running" > "${ctr_dir}/.state"
    rm -f "${ctr_dir}/.exited_at" "${ctr_dir}/.exit_code" "${ctr_dir}/.exit_signal" "${ctr_dir}/.paused"

    # ruri 通过 & 启动在后台进程组，Ctrl+C 只会发给脚本自身。
    # 必须捕获信号并转发给 ruri，否则脚本退出后容器进程会变成孤儿（nginx 残留）。
    local rc=0 interrupted=0
    trap 'interrupted=1; kill -INT "$pid" 2>/dev/null || true' INT
    trap 'interrupted=1; kill -TERM "$pid" 2>/dev/null || true' TERM
    trap 'interrupted=1; kill -HUP "$pid" 2>/dev/null || true' HUP
    wait "$pid" || rc=$?
    trap - INT TERM HUP

    # 转发后 ruri 若没退出，升级为 TERM/KILL，避免留下孤儿
    if (( interrupted )) && _proc_alive "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for ((j = 0; j < 20; j++)); do
            _proc_alive "$pid" 2>/dev/null || break
            sleep 0.1
        done
        _proc_alive "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi

    local tee_pid="" j
    for ((j = 0; j < 50; j++)); do
        [[ -s "$tee_pidfile" ]] && break
        sleep 0.01
    done
    tee_pid=$(cat "$tee_pidfile" 2>/dev/null || true)
    [[ -n "$tee_pid" ]] && wait "$tee_pid" 2>/dev/null || true
    rm -f "$tee_pidfile"
    return "$rc"
}

# ====================== 镜像命令 ======================
cmd_pull() {
    local platform=""
    local ref=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --platform)  [[ $# -ge 2 ]] || die "$1 缺少参数"; platform="$2"; shift 2 ;;
        --platform=*) platform="${1#*=}"; shift ;;
        --)          shift; break ;;
        -*)          die "pull: 未知参数 $1" ;;
        *)
            if [[ -z "$ref" ]]; then
                ref="$1"
            else
                die "pull 只接受一个镜像名"
            fi
            shift ;;
        esac
    done
    [[ -n "$ref" ]] || die "用法: docker pull [--platform OS/ARCH] <镜像>[:tag]"
    local repo tag
    read -r repo tag < <(parse_image_ref "$ref")
    local safe_name
    safe_name=$(safe_img_name "$repo" "$tag")
    local img_root="${DATA_DIR}/images/${safe_name}"
    local tmp_root="${img_root}.tmp.$$"
    lock_data_dir

    info "拉取镜像 ${repo}:${tag}"
    info "镜像源: ${DOCKER_REGISTRY_MIRROR}"
    rm -rf "$tmp_root"
    mkdir -p "$tmp_root"
    local tmp_oci="${tmp_root}/oci"
    local tmp_bundle="${tmp_root}/bundle"

    local src_url="docker://${DOCKER_REGISTRY_MIRROR}/${repo}:${tag}"
    info "源地址: ${src_url}"

    local -a skopeo_extra=()
    if [[ -n "$platform" ]]; then
        if [[ "$platform" == */* ]]; then
            skopeo_extra+=(--override-os "${platform%%/*}" --override-arch "${platform#*/}")
        else
            skopeo_extra+=(--override-arch "$platform")
        fi
    fi

    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=20 600 skopeo copy --retry-times=2 ${skopeo_extra[@]+"${skopeo_extra[@]}"} \
            "${src_url}" "oci:${tmp_oci}:${tag}" \
            || { rm -rf "$tmp_root"; die "skopeo 拉取失败（超时/网络错误）"; }
    else
        warn "系统缺少 timeout，无超时保护"
        skopeo copy --retry-times=2 ${skopeo_extra[@]+"${skopeo_extra[@]}"} \
            "${src_url}" "oci:${tmp_oci}:${tag}" \
            || { rm -rf "$tmp_root"; die "skopeo 拉取失败"; }
    fi

    umoci unpack --image "${tmp_oci}:${tag}" "$tmp_bundle" \
        || { rm -rf "$tmp_root"; die "umoci 解包失败"; }

    echo "${repo}:${tag}" > "${tmp_root}/.ref"
    date -Iseconds > "${tmp_root}/.pulled_at"

    rm -rf "$img_root"
    mv "$tmp_root" "$img_root"
    info "镜像拉取完成 ${repo}:${tag}"
}

# ====================== images / ps / inspect ======================
_image_full_id() {
    local img_dir="$1"
    local idx="${img_dir}/oci/index.json"
    if [[ -f "$idx" ]]; then
        local d
        d=$(jq -r '.manifests[0].digest // empty' "$idx" 2>/dev/null || true)
        if [[ -n "$d" ]]; then
            printf '%s\n' "${d#sha256:}"
            return 0
        fi
    fi
    # commit 生成的镜像没有 OCI layout，用 ref 派生稳定 ID
    local ref
    ref=$(cat "${img_dir}/.ref" 2>/dev/null || echo "-")
    printf '%s' "$ref" | sha256sum | cut -d' ' -f1
}

_image_id() {
    _image_full_id "$1" | cut -c1-12
}

# 容器 ID：docker 用 64 位 sha256，这里用随机 hex；创建后固定
_ensure_ctr_id() {
    local ctr_dir="$1"
    local f="${ctr_dir}/.id"
    if [[ ! -s "$f" ]]; then
        od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' > "$f" || :
        [[ -s "$f" ]] || printf '%064d\n' 0 > "$f"
    fi
    cat "$f"
}

_human_duration() {
    local s="${1:-0}"
    if (( s < 60 )); then
        printf '%ds' "$s"
    elif (( s < 3600 )); then
        printf '%dm%ds' $((s / 60)) $((s % 60))
    elif (( s < 86400 )); then
        printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60))
    else
        printf '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
    fi
}

_rel_time_from_iso() {
    local ts="$1" epoch
    [[ -n "$ts" ]] || { printf '%s' "-"; return; }
    epoch=$(date -d "$ts" +%s 2>/dev/null || true)
    [[ -n "$epoch" ]] || { printf '%s' "$ts"; return; }
    printf '%s ago' "$(_human_duration $(( $(date +%s) - epoch )))"
}

_pid_age() {
    local pid="$1" st ticks up
    st=$(get_starttime "$pid") || return 1
    ticks=$(getconf CLK_TCK 2>/dev/null || echo 100)
    up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
    echo $((up - st / ticks))
}

_ctr_created_ago() {
    local ts epoch
    ts=$(cat "$1/.created_at" 2>/dev/null || true)
    [[ -n "$ts" ]] || { printf '%s' "-"; return; }
    epoch=$(date -d "$ts" +%s 2>/dev/null || true)
    [[ -n "$epoch" ]] || { printf '%s' "-"; return; }
    printf '%s ago' "$(_human_duration $(( $(date +%s) - epoch )))"
}

_ctr_status() {
    local ctr_dir="$1" state="$2"
    case "$state" in
    running|paused)
        local pid age suffix=""
        pid=$(_ctr_pid "$ctr_dir")
        age=$(_pid_age "$pid" 2>/dev/null || echo 0)
        [[ "$state" == "paused" ]] && suffix=" (Paused)"
        printf 'Up %s%s' "$(_human_duration "$age")" "$suffix"
        ;;
    exited)
        local ts age code sig note="Exited"
        ts=$(cat "${ctr_dir}/.exited_at" 2>/dev/null || true)
        code=$(cat "${ctr_dir}/.exit_code" 2>/dev/null || true)
        sig=$(cat "${ctr_dir}/.exit_signal" 2>/dev/null || true)
        if [[ -n "$sig" ]]; then
            note="Exited ($((128 + sig)))"
        elif [[ -n "$code" ]]; then
            note="Exited ($code)"
        fi
        if [[ -n "$ts" ]]; then
            age=$(( $(date +%s) - ts ))
            printf '%s %s ago' "$note" "$(_human_duration "$age")"
        else
            printf '%s' "$note"
        fi
        ;;
    *)
        printf 'Created'
        ;;
    esac
}

cmd_images() {
    local quiet=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -q|--quiet) quiet=true; shift ;;
        -a|--all)   shift ;;
        --no-trunc) shift ;;
        *) die "images: 未知参数 $1" ;;
        esac
    done
    local d ref repo tag
    if $quiet; then
        for d in "$DATA_DIR"/images/*/; do
            [[ -f "${d}/.ref" ]] || continue
            _image_id "$d"
        done
        return 0
    fi
    printf "%-32s %-14s %-14s %-22s %s\n" "REPOSITORY" "TAG" "IMAGE ID" "CREATED" "SIZE"
    for d in "$DATA_DIR"/images/*/; do
        [[ -f "${d}/.ref" ]] || continue
        ref=$(cat "${d}/.ref")
        read -r repo tag < <(parse_image_ref "$ref")
        printf "%-32s %-14s %-14s %-22s %s\n" \
            "$repo" "$tag" "$(_image_id "$d")" \
            "$(_rel_time_from_iso "$(cat "${d}/.pulled_at" 2>/dev/null || true)")" \
            "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
}

cmd_rmi() {
    local force=false
    local ref=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -f|--force) force=true; shift ;;
        --)         shift; break ;;
        -*)         die "rmi: 未知参数 $1" ;;
        *)          ref="$1"; shift ;;
        esac
    done
    [[ -n "$ref" ]] || die "用法: docker rmi [-f] <镜像>[:tag]"
    local repo tag
    read -r repo tag < <(parse_image_ref "$ref")
    local img_dir
    img_dir="${DATA_DIR}/images/$(safe_img_name "$repo" "$tag")"
    [[ -d "$img_dir" ]] || die "镜像不存在 $ref"
    lock_data_dir

    if ! $force; then
        for ctr in "$DATA_DIR"/containers/*/; do
            [[ -f "${ctr}/.image_dir" ]] || continue
            local ctr_img
            ctr_img=$(cat "${ctr}/.image_dir")
            if [[ "$ctr_img" == "$img_dir" ]]; then
                die "镜像正在被容器 $(basename "$ctr") 使用，不能删除（或用 docker rmi -f）"
            fi
        done
    fi
    rm -rf "$img_dir"
    info "已删除镜像 $ref"
}

cmd_save() {
    local outtar=""
    local ref=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -o|--output) [[ $# -ge 2 ]] || die "$1 缺少参数"; outtar="$2"; shift 2 ;;
        --output=*)  outtar="${1#*=}"; shift ;;
        --)          shift; break ;;
        -*)          die "save: 未知参数 $1" ;;
        *)
            if [[ -z "$ref" ]]; then
                ref="$1"
            elif [[ -z "$outtar" ]]; then
                outtar="$1"
            else
                die "save 参数过多"
            fi
            shift ;;
        esac
    done
    [[ -n "$ref" && -n "$outtar" ]] || die "用法: docker save [-o FILE] <镜像>[:tag] [FILE]"
    local repo tag
    read -r repo tag < <(parse_image_ref "$ref")
    local img_dir
    img_dir="${DATA_DIR}/images/$(safe_img_name "$repo" "$tag")"
    [[ -d "$img_dir" ]] || die "镜像不存在 $ref"
    if [[ -e "$outtar" ]]; then
        die "输出文件已存在 $outtar"
    fi
    tar -cf "$outtar" -C "$img_dir" .
    info "已保存镜像到 $outtar"
}

cmd_load() {
    local tarfile=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -i|--input) [[ $# -ge 2 ]] || die "$1 缺少参数"; tarfile="$2"; shift 2 ;;
        --input=*)  tarfile="${1#*=}"; shift ;;
        --)         shift; break ;;
        -*)         die "load: 未知参数 $1" ;;
        *)          tarfile="$1"; shift ;;
        esac
    done
    [[ -n "$tarfile" ]] || die "用法: docker load [-i FILE] [FILE.tar]"
    [[ -f "$tarfile" ]] || die "文件不存在 $tarfile"
    lock_data_dir
    local tmpdir
    tmpdir=$(mktemp -d)
    if ! tar -xf "$tarfile" -C "$tmpdir" 2>/dev/null; then
        rm -rf "$tmpdir"
        die "解压失败: $tarfile"
    fi

    if [[ -d "$tmpdir/bundle/rootfs" && ! -L "$tmpdir/bundle/rootfs" ]]; then
        :
    elif [[ -d "$tmpdir/rootfs" && ! -L "$tmpdir/rootfs" ]]; then
        mkdir -p "$tmpdir/bundle"
        mv "$tmpdir/rootfs" "$tmpdir/bundle/rootfs"
        [[ -f "$tmpdir/config.json" ]] && mv "$tmpdir/config.json" "$tmpdir/bundle/config.json"
    else
        rm -rf "$tmpdir"
        die "tar 内容不是合法镜像包（缺少 bundle/rootfs 或 rootfs）"
    fi

    if [[ ! -f "$tmpdir/bundle/config.json" ]]; then
        rm -rf "$tmpdir"
        die "镜像包缺少 bundle/config.json"
    fi

    local ref
    if [[ -f "${tmpdir}/.ref" ]]; then
        ref=$(cat "${tmpdir}/.ref")
    else
        read -rp "输入镜像名(alpine:latest): " ref
        [[ -n "$ref" ]] || { rm -rf "$tmpdir"; die "镜像名不能为空"; }
        echo "$ref" > "${tmpdir}/.ref"
    fi
    local repo tag
    read -r repo tag < <(parse_image_ref "$ref")
    local img_dir
    img_dir="${DATA_DIR}/images/$(safe_img_name "$repo" "$tag")"
    if [[ -e "$img_dir" ]]; then
        rm -rf "$tmpdir"
        die "镜像已存在 $ref"
    fi
    [[ -f "${tmpdir}/.pulled_at" ]] || date -Iseconds > "${tmpdir}/.pulled_at"
    mv "$tmpdir" "$img_dir"
    info "已加载镜像 $ref"
}

# ====================== 容器通用 ======================
prepare_ctr_from_image() {
    local ctr_name="$1" ref="$2"
    validate_ctr_name "$ctr_name"
    local repo tag
    read -r repo tag < <(parse_image_ref "$ref")
    local img_dir
    img_dir="${DATA_DIR}/images/$(safe_img_name "$repo" "$tag")"
    [[ -d "${img_dir}/bundle/rootfs" ]] || die "镜像未拉取或损坏，请先 docker pull $ref"
    [[ -f "${img_dir}/bundle/config.json" ]] || die "镜像 bundle 损坏: 缺少 config.json"
    local ctr_dir="${DATA_DIR}/containers/${ctr_name}"
    assert_under_containers "$ctr_dir"
    # 非 -p 的 mkdir 是原子的：并发创建同名容器时只有一个能成功
    if ! mkdir "$ctr_dir" 2>/dev/null; then
        if [[ -d "$ctr_dir" ]]; then
            die "容器名已存在 $ctr_name"
        fi
        die "无法创建容器目录: $ctr_dir"
    fi
    if ! cp -a "${img_dir}/bundle/." "$ctr_dir/"; then
        rm -rf "$ctr_dir"
        die "复制镜像 rootfs 失败: $ref"
    fi
    echo "$img_dir" > "${ctr_dir}/.image_dir"
    echo "$ref"     > "${ctr_dir}/.image_ref"
    echo "created"  > "${ctr_dir}/.state"
    date -Iseconds > "${ctr_dir}/.created_at"
    _ensure_ctr_id "$ctr_dir" >/dev/null
    echo "$ctr_dir"
}

_start_ctr() {
    local ctr_dir="$1" ctr_name="$2"
    local logfile="${ctr_dir}/run.log"
    local pid
    pid=$(runtime_run_bg "$ctr_dir" "$logfile")
    if [[ -z "$pid" ]]; then
        warn "容器启动失败，查看日志: $logfile"
        return 1
    fi
    get_starttime "$pid" > "${ctr_dir}/.pid_start" 2>/dev/null || : > "${ctr_dir}/.pid_start"
    date -Iseconds > "${ctr_dir}/.started_at"
    rm -f "${ctr_dir}/.exited_at" "${ctr_dir}/.exit_code" "${ctr_dir}/.exit_signal" "${ctr_dir}/.paused"

    if wait_running "$ctr_dir"; then
        return 0
    fi
    warn "容器启动异常，查看日志: $logfile"
    return 1
}

# ====================== create / run ======================
cmd_create() {
    [[ $# -ge 1 ]] || die "用法: docker create [--name NAME] [选项...] <镜像> [命令...]"
    local ctr_name=""
    local interactive=false tty=false
    local rm_flag=false
    local -a pass_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --name)           [[ $# -ge 2 ]] || die "--name 缺少参数"; ctr_name="$2"; shift 2 ;;
        --name=*)         ctr_name="${1#*=}"; shift ;;
        -i|--interactive) interactive=true; shift ;;
        -t|--tty)         tty=true; shift ;;
        -it|-ti)          interactive=true; tty=true; shift ;;
        -[dit]*)
            local short_opts="${1#-}" k ok=true
            for ((k = 0; k < ${#short_opts}; k++)); do
                case "${short_opts:k:1}" in
                d) warn "create 不支持 -d，已忽略" ;;
                i) interactive=true ;;
                t) tty=true ;;
                *) ok=false ;;
                esac
            done
            $ok || die "未知参数: $1"
            shift ;;
        -d|--detach)      warn "create 不支持 -d，已忽略"; shift ;;
        --rm)             rm_flag=true; shift ;;
        -p|--publish)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            warn "ruri 共享主机网络：端口转发 $1 $2 不适用，已忽略"; shift 2 ;;
        --publish=*)
            warn "ruri 共享主机网络：端口转发 $1 不适用，已忽略"; shift ;;
        -p?*)
            warn "ruri 共享主机网络：端口转发 ${1#-p} 不适用，已忽略"; shift ;;
        --)
            shift; break ;;
        -*)
            if _is_docker_value_opt "$1"; then
                [[ $# -ge 2 ]] || die "$1 缺少参数"
                pass_args+=("$1" "$2"); shift 2
            elif [[ "$1" == *=* ]]; then
                pass_args+=("$1"); shift
            elif _is_docker_flag_opt "$1"; then
                pass_args+=("$1"); shift
            elif [[ "$1" == -e?* || "$1" == -v?* || "$1" == -w?* || "$1" == -u?* || "$1" == -h?* || "$1" == -m?* ]]; then
                pass_args+=("$1"); shift
            else
                die "不支持的参数 $1（容器命令以 - 开头时请用 -- 分隔，例如: create IMAGE -- -x）"
            fi ;;
        *)
            break ;;
        esac
    done

    [[ $# -ge 1 ]] || die "用法: docker create [--name NAME] [选项...] <镜像> [命令...]"
    local ref="$1"; shift
    [[ -n "$ctr_name" ]] || ctr_name="ctr_$(date +%s)_$RANDOM"

    local ctr_dir
    ctr_dir=$(prepare_ctr_from_image "$ctr_name" "$ref")
    _CLEANUP_CTR_DIR="$ctr_dir"
    parse_docker_args_to_files "$ctr_dir" ${pass_args[@]+"${pass_args[@]}"}
    save_args "$ctr_dir/.user_cmd" ${@+"$@"}
    _sync_runtime_config "$ctr_dir" "$ctr_name"
    _write_cidfile "$ctr_dir" "$ctr_name"
    _CLEANUP_CTR_DIR=""
    if $rm_flag; then : > "${ctr_dir}/.rm_flag"; fi

    if $tty; then : > "${ctr_dir}/.tty"; else rm -f "${ctr_dir}/.tty"; fi
    if $interactive; then : > "${ctr_dir}/.interactive"; else rm -f "${ctr_dir}/.interactive"; fi
    info "容器已创建 $ctr_name"
}

cmd_run() {
    local detach=false
    local ctr_name=""
    local rm_flag=false
    local interactive=false
    local tty=false
    local -a pass_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -d|--detach)      detach=true; shift ;;
        -i|--interactive) interactive=true; shift ;;
        -t|--tty)         tty=true; shift ;;
        -it|-ti)          interactive=true; tty=true; shift ;;
        -[dit]*)
            local short_opts="${1#-}" k ok=true
            for ((k = 0; k < ${#short_opts}; k++)); do
                case "${short_opts:k:1}" in
                d) detach=true ;;
                i) interactive=true ;;
                t) tty=true ;;
                *) ok=false ;;
                esac
            done
            $ok || die "不支持的短选项组合: $1"
            shift ;;
        --name)           [[ $# -ge 2 ]] || die "--name 缺少参数"; ctr_name="$2"; shift 2 ;;
        --name=*)         ctr_name="${1#*=}"; shift ;;
        --rm)             rm_flag=true; shift ;;
        -p|--publish)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            warn "ruri 共享主机网络：容器监听 0.0.0.0:C 即等价主机 C 端口；端口转发 $1 $2 不适用，已忽略"; shift 2 ;;
        --publish=*)
            warn "ruri 共享主机网络：端口转发 $1 不适用，已忽略"; shift ;;
        -p?*)
            warn "ruri 共享主机网络：端口转发 ${1#-p} 不适用，已忽略"; shift ;;
        --)
            shift; break ;;
        -*)
            if _is_docker_value_opt "$1"; then
                [[ $# -ge 2 ]] || die "$1 缺少参数"
                pass_args+=("$1" "$2"); shift 2
            elif [[ "$1" == *=* ]]; then
                pass_args+=("$1"); shift
            elif _is_docker_flag_opt "$1"; then
                pass_args+=("$1"); shift
            elif [[ "$1" == -e?* || "$1" == -v?* || "$1" == -w?* || "$1" == -u?* || "$1" == -h?* || "$1" == -m?* ]]; then
                pass_args+=("$1"); shift
            else
                die "不支持的参数 $1（容器命令以 - 开头时请用 -- 分隔，例如: run IMAGE -- -x）"
            fi ;;
        *)
            break ;;
        esac
    done

    [[ $# -ge 1 ]] || die "用法: docker run [-d] [--name NAME] [选项...] <镜像> [命令...]"
    local ref="$1"; shift
    [[ -n "$ctr_name" ]] || ctr_name="ctr_$(date +%s)_$RANDOM"

    local ctr_dir
    ctr_dir=$(prepare_ctr_from_image "$ctr_name" "$ref")
    _CLEANUP_CTR_DIR="$ctr_dir"
    parse_docker_args_to_files "$ctr_dir" ${pass_args[@]+"${pass_args[@]}"}
    save_args "$ctr_dir/.user_cmd" ${@+"$@"}
    _sync_runtime_config "$ctr_dir" "$ctr_name"
    _write_cidfile "$ctr_dir" "$ctr_name"
    _CLEANUP_CTR_DIR=""

    if $tty; then : > "${ctr_dir}/.tty"; else rm -f "${ctr_dir}/.tty"; fi
    if $interactive; then : > "${ctr_dir}/.interactive"; else rm -f "${ctr_dir}/.interactive"; fi

    local logfile="${ctr_dir}/run.log"
    if $detach; then
        if $tty || $interactive; then
            warn "后台模式忽略 -i/-t"
            rm -f "${ctr_dir}/.tty" "${ctr_dir}/.interactive"
        fi
        info "后台运行容器 $ctr_name"
        if _start_ctr "$ctr_dir" "$ctr_name"; then
            # docker run -d --rm：容器退出后自动删除
            if $rm_flag; then
                _watch_rm_bg "$ctr_dir" "$(cat "${ctr_dir}/.pid" 2>/dev/null || true)"
            fi
            info "已启动 $ctr_name 日志:$logfile"
            return 0
        fi
        info "容器记录保留，可查看日志: $logfile"
        return 1
    fi

    info "前台运行容器 $ctr_name"
    local rc=0
    runtime_run_fg_attach "$ctr_dir" || rc=$?
    refresh_ctr_state "$ctr_dir"
    if [[ "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" == "running" ]]; then
        # Ctrl+C 后 ruri 未及时退出：走完整 stop，避免容器进程残留
        cmd_stop "$ctr_name" || true
    else
        stop_all_ctr_procs "$ctr_dir" || true
    fi
    if $rm_flag; then
        cmd_rm "$ctr_name" || true
    fi
    return "$rc"
}

# ====================== start / stop / restart ======================
cmd_start() {
    local attach=false
    local interactive=false
    local ctr_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -a|--attach)       attach=true; shift ;;
        -i|--interactive)  interactive=true; shift ;;
        -[ai]*)
            local short_opts="${1#-}" k ok=true
            for ((k = 0; k < ${#short_opts}; k++)); do
                case "${short_opts:k:1}" in
                a) attach=true ;;
                i) interactive=true ;;
                *) ok=false ;;
                esac
            done
            $ok || die "未知参数: $1"
            shift ;;
        --)                shift; break ;;
        -*)                die "未知参数: $1" ;;
        *)                 ctr_name="$1"; shift ;;
        esac
    done

    [[ -n "$ctr_name" ]] || die "用法: docker start [-a] [-i] <容器名>"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    assert_under_containers "$ctr_dir"
    [[ -d "$ctr_dir/rootfs" ]] || die "容器 rootfs 损坏: $ctr_dir/rootfs"
    refresh_ctr_state "$ctr_dir"
    # docker start 对已运行/已暂停的容器是幂等的（直接返回，不报错）
    case "$(cat "${ctr_dir}/.state")" in
    running|paused)
        info "容器已在运行 $ctr_name"
        return 0
        ;;
    esac
    lock_ctr "$ctr_dir" start
    # 加锁后复查，避免与并发 start 竞争
    refresh_ctr_state "$ctr_dir"
    case "$(cat "${ctr_dir}/.state")" in
    running|paused)
        info "容器已在运行 $ctr_name"
        return 0
        ;;
    esac

    cleanup_mounts "$ctr_dir/rootfs"
    # 每次 start 都按容器快照的镜像配置重新同步 Env/WorkingDir/User/命令，
    # 并刷新 .etc/{hosts,hostname,resolv.conf}（对齐 docker 的 start 行为）
    _sync_runtime_config "$ctr_dir" "$ctr_name"

    if $interactive; then
        # docker start -i 隐含 attach
        : > "${ctr_dir}/.interactive"
        attach=true
    fi

    if $attach; then
        # 前台运行期间不持锁，否则另一终端的 stop/rm 会被阻塞
        exec 200>&- 2>/dev/null || true
        info "前台启动容器 $ctr_name"
        local rc=0
        runtime_run_fg_attach "$ctr_dir" || rc=$?
        refresh_ctr_state "$ctr_dir"
        if [[ "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" == "running" ]]; then
            # Ctrl+C 后 ruri 未及时退出：走完整 stop（信号升级 + pidfile/退出码记录）
            cmd_stop "$ctr_name" || true
        else
            stop_all_ctr_procs "$ctr_dir" || true
        fi
        info "容器已退出 $ctr_name"
        if [[ -f "${ctr_dir}/.rm_flag" ]]; then
            cmd_rm "$ctr_name" || true
        fi
        return "$rc"
    fi

    info "启动容器 $ctr_name"
    if _start_ctr "$ctr_dir" "$ctr_name"; then
        if [[ -f "${ctr_dir}/.rm_flag" ]]; then
            _watch_rm_bg "$ctr_dir" "$(cat "${ctr_dir}/.pid" 2>/dev/null || true)"
        fi
        info "容器已启动 $ctr_name"
        return 0
    fi
    return 1
}

# docker stop 的 -t/--time 与镜像 STOPSIGNAL 都要生效
_normalize_signal() {
    local s="${1#SIG}"
    s="${s^^}"
    printf '%s\n' "${s:-TERM}"
}

cmd_stop() {
    local timeout_s=""
    local ctr_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -t|--time|--timeout)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            timeout_s="$2"; shift 2 ;;
        --time=*|--timeout=*)
            timeout_s="${1#*=}"; shift ;;
        --)
            shift; break ;;
        -*)
            die "未知参数: $1" ;;
        *)
            ctr_name="$1"; shift ;;
        esac
    done
    [[ -n "$ctr_name" ]] || die "用法: docker stop [-t 秒] <容器名>"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    # 超时优先级：stop -t > 创建时 --stop-timeout > 默认 10s（docker 语义）
    if [[ -z "$timeout_s" && -s "${ctr_dir}/.stop_timeout" ]]; then
        timeout_s=$(cat "${ctr_dir}/.stop_timeout")
    fi
    timeout_s="${timeout_s:-10}"
    [[ "$timeout_s" =~ ^[0-9]+$ ]] || die "stop 超时必须是秒数: $timeout_s"
    assert_under_containers "$ctr_dir"
    lock_ctr "$ctr_dir" stop

    refresh_ctr_state "$ctr_dir"
    if [[ "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" == "paused" ]]; then
        die "容器已暂停 $ctr_name，请先 docker unpause"
    fi
    local pid
    pid=$(_ctr_pid "$ctr_dir")
    if [[ -z "$pid" ]] || ! _proc_alive "$pid" 2>/dev/null; then
        info "容器未运行"
        rm -f "${ctr_dir}/.pid" "${ctr_dir}/.pid_start"
        echo "exited" > "${ctr_dir}/.state"
        return 0
    fi

    # 信号优先级：--stop-signal > 镜像 StopSignal > SIGTERM（与 docker 一致）
    local sig=""
    if [[ -s "${ctr_dir}/.stop_signal" ]]; then
        sig=$(cat "${ctr_dir}/.stop_signal")
    elif [[ -s "${ctr_dir}/.image_config.json" ]]; then
        sig=$(jq -r '.StopSignal // empty' "${ctr_dir}/.image_config.json" 2>/dev/null || true)
    fi
    sig=$(_normalize_signal "${sig:-TERM}")
    if [[ ! "$sig" =~ ^[A-Z0-9]+$ ]]; then
        warn "无效的停止信号 $sig，回退 SIGTERM"
        sig=TERM
    fi

    info "停止容器 $ctr_name (pid=$pid, signal=$sig)"
    # pid 即容器 init：前台运行时就是 ruri 自身，后台 -b 时是 ruri 写出的子进程
    kill -"$sig" "$pid" 2>/dev/null || true
    local i
    for ((i = 0; i < timeout_s * 10; i++)); do
        _proc_alive "$pid" 2>/dev/null || break
        sleep 0.1
    done
    _proc_alive "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true

    # ruri 退出后会往 pidfile 写 RURI_EXITED_<code>/RURI_SIGNALED_<sig>，
    # 必须在删除 pidfile 前记录，供 wait/ps/inspect 使用
    if _pidfile_parse "${ctr_dir}/.pid"; then
        [[ -n "$PIDFILE_EXIT" ]] && echo "$PIDFILE_EXIT" > "${ctr_dir}/.exit_code"
        [[ -n "$PIDFILE_SIGNAL" ]] && echo "$PIDFILE_SIGNAL" > "${ctr_dir}/.exit_signal"
    fi

    stop_all_ctr_procs "$ctr_dir"

    rm -f "${ctr_dir}/.pid" "${ctr_dir}/.pid_start"
    echo "exited" > "${ctr_dir}/.state"
    info "容器已停止 $ctr_name"
}

cmd_restart() {
    local timeout_s=""
    local ctr_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -t|--time|--timeout) [[ $# -ge 2 ]] || die "$1 缺少参数"; timeout_s="$2"; shift 2 ;;
        --time=*|--timeout=*) timeout_s="${1#*=}"; shift ;;
        --) shift; break ;;
        -*) die "restart: 未知参数 $1" ;;
        *)  ctr_name="$1"; shift ;;
        esac
    done
    [[ -n "$ctr_name" ]] || die "用法: docker restart [-t 秒] <容器名>"
    if [[ -n "$timeout_s" ]]; then
        cmd_stop -t "$timeout_s" "$ctr_name"
    else
        cmd_stop "$ctr_name"
    fi
    cmd_start "$ctr_name"
}

# docker kill [-s SIGNAL] NAME：向容器 init 发信号（默认 KILL）
cmd_kill() {
    local sig="KILL"
    local ctr_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -s|--signal) [[ $# -ge 2 ]] || die "-s 缺少参数"; sig="$2"; shift 2 ;;
        --signal=*)  sig="${1#*=}"; shift ;;
        --)          shift; break ;;
        -*)          die "kill: 未知参数 $1" ;;
        *)           ctr_name="$1"; shift ;;
        esac
    done
    [[ -n "$ctr_name" ]] || die "用法: docker kill [-s SIGNAL] <容器名>"
    sig=$(_normalize_signal "$sig")
    [[ "$sig" =~ ^[A-Z0-9]+$ ]] || die "无效信号: $sig"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    refresh_ctr_state "$ctr_dir"
    if [[ "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" == "paused" ]]; then
        die "容器已暂停 $ctr_name，请先 docker unpause"
    fi
    local pid
    pid=$(_ctr_pid "$ctr_dir")
    if [[ -z "$pid" ]] || ! _proc_alive "$pid" 2>/dev/null; then
        die "容器未运行 $ctr_name"
    fi
    kill -"$sig" "$pid" 2>/dev/null || true
    info "已向容器 $ctr_name 发送 SIG$sig"
}

# docker pause/unpause -> ruri --freeze/--thaw（需要 cgroup v2）
cmd_pause() {
    [[ $# -ge 1 ]] || die "用法: docker pause <容器名>"
    local ctr_name="$1"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    refresh_ctr_state "$ctr_dir"
    if [[ "$(cat "${ctr_dir}/.state")" == "paused" ]]; then
        info "容器已暂停 $ctr_name"
        return 0
    fi
    [[ "$(cat "${ctr_dir}/.state")" == "running" ]] || die "容器未运行 $ctr_name"
    _has_ruri_opt --freeze || die "当前 ruri 不支持 --freeze，无法暂停"
    "$RUNTIME" --freeze "$ctr_dir" \
        || die "暂停失败（需要 cgroup v2，且容器未使用不支持的 unshare 配置）"
    : > "${ctr_dir}/.paused"
    echo "paused" > "${ctr_dir}/.state"
    info "容器已暂停 $ctr_name"
}

cmd_unpause() {
    [[ $# -ge 1 ]] || die "用法: docker unpause <容器名>"
    local ctr_name="$1"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    if [[ ! -f "${ctr_dir}/.paused" ]]; then
        info "容器未暂停 $ctr_name"
        return 0
    fi
    _has_ruri_opt --thaw || die "当前 ruri 不支持 --thaw，无法恢复"
    "$RUNTIME" --thaw "$ctr_dir" || die "恢复失败"
    rm -f "${ctr_dir}/.paused"
    echo "running" > "${ctr_dir}/.state"
    info "容器已恢复 $ctr_name"
}

# ====================== ps / logs / exec ======================
cmd_ps() {
    local all=false quiet=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -a|--all)   all=true; shift ;;
        -q|--quiet) quiet=true; shift ;;
        --no-trunc) shift ;;
        -f|--filter) [[ $# -ge 2 ]] || die "$1 缺少参数"; shift 2 ;;
        --filter=*) shift ;;
        *) die "ps: 未知参数 $1" ;;
        esac
    done
    local fmt="%-14s %-26s %-22s %-22s %-20s %s\n"
    $quiet || printf "$fmt" "CONTAINER ID" "IMAGE" "COMMAND" "CREATED" "STATUS" "NAMES"
    local ctr name state id img cmd status
    for ctr in "$DATA_DIR"/containers/*/; do
        [[ -d "$ctr" ]] || continue
        refresh_ctr_state "$ctr"
        state=$(cat "${ctr}/.state" 2>/dev/null || echo "created")
        if ! $all; then
            case "$state" in
            running|paused) ;;
            *) continue ;;
            esac
        fi
        id=$(_ensure_ctr_id "$ctr" | cut -c1-12)
        if $quiet; then
            printf '%s\n' "$id"
            continue
        fi
        name=$(basename "$ctr")
        img=$(cat "${ctr}/.image_ref" 2>/dev/null || echo "-")
        cmd=""
        if [[ -f "${ctr}/.cmd_args" ]]; then
            cmd=$(tr '\0' ' ' < "${ctr}/.cmd_args" | sed 's/[[:space:]]*$//' || true)
        fi
        [[ -z "$cmd" ]] && cmd="-"
        [[ ${#cmd} -gt 20 ]] && cmd="${cmd:0:17}..."
        status=$(_ctr_status "$ctr" "$state")
        printf "$fmt" "$id" "$img" "$cmd" "$(_ctr_created_ago "$ctr")" "$status" "$name"
    done
}

cmd_logs() {
    local follow=false
    local lines=""
    local ctr_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -f|--follow) follow=true; shift ;;
        -n|--tail)   [[ $# -ge 2 ]] || die "-n 缺少参数"; lines="$2"; shift 2 ;;
        --tail=*)    lines="${1#*=}"; shift ;;
        -n[0-9]*)    lines="${1#-n}"; shift ;;
        -t|--timestamps) warn "本脚本日志无时间戳，-t 已忽略"; shift ;;
        --since|--until) [[ $# -ge 2 ]] || die "$1 缺少参数"; warn "$1 不受支持，已忽略"; shift 2 ;;
        --since=*|--until=*) warn "$1 不受支持，已忽略"; shift ;;
        -*)          die "logs: 未知参数 $1" ;;
        *)
            [[ -z "$ctr_name" ]] || die "logs 只接受一个容器名"
            ctr_name="$1"; shift ;;
        esac
    done
    [[ -n "$ctr_name" ]] || die "用法: docker logs [-f] [-n N] <容器名>"
    [[ "$lines" == "all" ]] && lines=""
    [[ -z "$lines" || "$lines" =~ ^[0-9]+$ ]] || die "-n 需要非负整数或 all"

    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    local log="${ctr_dir}/run.log"
    [[ -f "$log" ]] || die "日志不存在 $log"
    if $follow; then
        if [[ -n "$lines" ]]; then
            tail -f -n "$lines" "$log"
        else
            tail -f "$log"
        fi
    elif [[ -n "$lines" ]]; then
        tail -n "$lines" "$log"
    else
        cat "$log"
    fi
}

# docker exec [-it] [-u USER] [-w DIR] <容器名> <命令...>
# ruri 没有 "enter" 子命令。优先用 -N -J <init_pid> 加入已有命名空间
#   （-N 是 ruri 的 --no-rurienv：加入已有容器时不再生成 .rurienv）
# 若 init pid 已失效，退化为「针对同一 rootfs 启动新进程」。
# -t 时在容器内执行 script 分配 PTY；命令用 POSIX 单引号转义，
# 避免 bash 专属的 $'...' 在 dash/ash 镜像里失效。
# 加入已有命名空间时继承容器 init 的环境变量（贴近 docker exec 语义）。
_sh_quote() {
    local s="$1"
    if [[ -z "$s" ]]; then
        printf "''"
        return 0
    fi
    if [[ "$s" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then
        printf '%s' "$s"
        return 0
    fi
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

cmd_exec() {
    local interactive=false
    local tty=false
    local user=""
    local workdir=""
    local -a exec_env=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -i|--interactive)  interactive=true; shift ;;
        -t|--tty)          tty=true; shift ;;
        -it|-ti)           interactive=true; tty=true; shift ;;
        -u|--user)         [[ $# -ge 2 ]] || die "-u 缺少参数"; user="$2"; shift 2 ;;
        --user=*)          user="${1#*=}"; shift ;;
        -w|--workdir)      [[ $# -ge 2 ]] || die "-w 缺少参数"; workdir="$2"; shift 2 ;;
        --workdir=*)       workdir="${1#*=}"; shift ;;
        -e|--env)          [[ $# -ge 2 ]] || die "-e 缺少参数"; _append_env "$2" exec_env; shift 2 ;;
        --env=*)           _append_env "${1#*=}" exec_env; shift ;;
        -e?*)              _append_env "${1#-e}" exec_env; shift ;;
        --env-file)        [[ $# -ge 2 ]] || die "--env-file 缺少参数"; _append_env_file "$2" exec_env; shift 2 ;;
        --env-file=*)      _append_env_file "${1#*=}" exec_env; shift ;;
        --)                shift; break ;;
        -*)                die "exec: 未知参数 $1" ;;
        *)                 break ;;
        esac
    done

    [[ $# -ge 2 ]] || die "用法: docker exec [-it] [-u USER] [-w DIR] <容器名> <命令...>"
    local ctr_name="$1"; shift
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    refresh_ctr_state "$ctr_dir"
    [[ "$(cat "${ctr_dir}/.state")" != "running" ]] && die "exec 仅支持运行中容器"

    local -a ruri_cmd=("$RUNTIME")
    local used_join=false

    # docker exec 未指定 -u/-w 时继承容器配置（与 docker 一致）
    [[ -n "$user" ]] || user=$(_ctr_ruri_value "$ctr_dir" "-E" || true)
    [[ -n "$workdir" ]] || workdir=$(_ctr_ruri_value "$ctr_dir" "-W" || true)
    [[ -n "$user" ]] && ruri_cmd+=("-E" "$user")
    [[ -n "$workdir" ]] && ruri_cmd+=("-W" "$workdir")

    local init_pid
    init_pid=$(_ctr_pid "$ctr_dir")
    if _proc_alive "$init_pid" 2>/dev/null; then
        # ruri 要求 -J 与 -N 同时使用
        ruri_cmd+=("-N" "-J" "$init_pid")
        used_join=true
    fi

    # docker exec 继承容器 Env（不是宿主环境），用户 -e 覆盖同名
    local -a ra=() ctr_env=()
    load_args "${ctr_dir}/.ruri_args" ra
    local ri=0
    while (( ri < ${#ra[@]} )); do
        if [[ "${ra[$ri]}" == "-e" ]] && (( ri + 2 < ${#ra[@]} )); then
            ctr_env+=("-e" "${ra[$((ri + 1))]}" "${ra[$((ri + 2))]}")
            ri=$((ri + 3)); continue
        fi
        ri=$((ri + 1))
    done
    ruri_cmd+=(${ctr_env[@]+"${ctr_env[@]}"})
    ruri_cmd+=(${exec_env[@]+"${exec_env[@]}"})

    if $tty; then
        ruri_cmd+=("-z")
    fi

    # 注意：exec 用来加入已运行容器，不能加 --auto-umount，
    # 也不能临时 bind /dev/pts（ruri 的自动卸载会把容器自身挂载一起清掉，
    # 导致容器 init 退出）。/dev/pts 由容器启动时的 -S + 挂载提供。
    ruri_cmd+=("${ctr_dir}/rootfs")
    ruri_cmd+=("$@")

    $used_join || warn "init pid 已失效，退化为针对同一 rootfs 启动新进程（非同一命名空间）"

    if $tty; then
        # script 依赖宿主 devpts 分配 PTY；/dev/pts 未挂载时 openpty 会 ENOENT
        if [[ ! -c /dev/pts/ptmx ]] && [[ "$(id -u)" == "0" ]] && command -v mount >/dev/null 2>&1; then
            if mount -t devpts devpts /dev/pts 2>/dev/null; then
                info "宿主 /dev/pts 未挂载 devpts，已自动挂载以支持 -t"
            fi
        fi
        # 在宿主侧用 script 分配 PTY，不再依赖容器内的 script
        # （Debian-slim / Alpine 等镜像常缺 util-linux，容器内执行会报
        #  "Failed to execute script / Not a tty"）。
        if command -v script >/dev/null 2>&1 && [[ -c /dev/pts/ptmx ]]; then
            local quoted="" a
            for a in "${ruri_cmd[@]}"; do
                quoted+="$(_sh_quote "$a") "
            done
            _close_lock_fd
            exec script -q -e -c "$quoted" /dev/null
        fi
        if [[ -c /dev/pts/ptmx ]]; then
            warn "宿主缺少 script（util-linux），无法分配 PTY，退化为直接执行"
        else
            warn "宿主 /dev/pts 未挂载 devpts，无法分配 PTY，退化为直接执行；修复: mount -t devpts devpts /dev/pts"
        fi
    fi

    _close_lock_fd
    exec env -u LD_PRELOAD -u LD_LIBRARY_PATH -u LD_AUDIT "${ruri_cmd[@]}"
}

# ====================== rm / commit ======================
cmd_rm() {
    local force=false
    local ctr_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -f|--force)   force=true; shift ;;
        -v|--volumes) shift ;;  # 无独立卷管理，匿名卷随容器目录一起删除
        --)           shift; break ;;
        -*)           die "rm: 未知参数 $1" ;;
        *)            ctr_name="$1"; shift ;;
        esac
    done
    [[ -n "$ctr_name" ]] || die "用法: docker rm [-f] [-v] <容器名>"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    assert_under_containers "$ctr_dir"
    refresh_ctr_state "$ctr_dir"
    if [[ "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" == "paused" ]]; then
        # docker rm -f 会先解冻再删除
        $force || die "容器已暂停 $ctr_name，请先 unpause 或使用 docker rm -f"
        "$RUNTIME" --thaw "$ctr_dir" >/dev/null 2>&1 || true
        rm -f "${ctr_dir}/.paused"
        echo "running" > "${ctr_dir}/.state"
    fi
    if [[ "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" == "running" ]]; then
        # docker 语义：运行中的容器默认拒绝删除，-f 才强制停止后删除
        $force || die "容器正在运行 $ctr_name，请先 stop 或使用 docker rm -f"
        cmd_stop "$ctr_name"
    else
        lock_ctr "$ctr_dir" rm
        stop_all_ctr_procs "$ctr_dir"
    fi

    cleanup_mounts "${ctr_dir}/rootfs"

    if ! rm -rf "$ctr_dir" 2>/dev/null; then
        cleanup_mounts "${ctr_dir}/rootfs"
        if ! rm -rf "$ctr_dir"; then
            die "删除失败：$ctr_dir（可能仍有挂载，请检查: mount | grep '${ctr_dir}'）"
        fi
    fi
    info "已删除容器 $ctr_name"
}

cmd_commit() {
    local force=false
    if [[ "${1:-}" == "-f" || "${1:-}" == "--force" ]]; then
        force=true
        shift
    fi

    [[ $# -ge 2 ]] || die "用法: docker commit [-f|--force] <容器名> <新镜像>[:tag]"

    local ctr_name="$1"
    local new_ref="$2"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")

    [[ -d "$ctr_dir" ]] || die "容器不存在: $ctr_name"
    assert_under_containers "$ctr_dir"
    lock_ctr "$ctr_dir" commit
    refresh_ctr_state "$ctr_dir"

    local state_val
    state_val=$(cat "${ctr_dir}/.state" 2>/dev/null || echo "")
    [[ -n "$state_val" ]] || die "缺少容器状态文件: ${ctr_dir}/.state"
    [[ "$state_val" == "running" ]] && die "容器正在运行，请先 stop 后再 commit"

    local rootfs_dir="${ctr_dir}/rootfs"
    [[ -d "$rootfs_dir" ]] || die "容器 rootfs 缺失: $rootfs_dir"

    cleanup_mounts "$rootfs_dir"
    stop_all_ctr_procs "$ctr_dir" || true

    local cfg_src="${ctr_dir}/config.json"
    [[ -f "$cfg_src" ]] || die "容器配置 config.json 不存在: $cfg_src"

    local repo tag
    read -r repo tag < <(parse_image_ref "$new_ref")

    local img_out
    img_out="${DATA_DIR}/images/$(safe_img_name "$repo" "$tag")"

    if [[ -e "$img_out" ]] && ! $force; then
        die "目标镜像已存在: $new_ref，增加 -f 强制覆盖"
    fi

    # 先写临时目录，成功后再整体替换，避免中途失败留下半成品镜像
    local tmp_out="${img_out}.tmp.$$"
    local bundle_dir="${tmp_out}/bundle"
    local rootfs_out="${bundle_dir}/rootfs"
    rm -rf "$tmp_out"
    mkdir -p "$rootfs_out" || { rm -rf "$tmp_out"; die "无法创建临时目录: $tmp_out"; }

    local -a exclude_list=(
        "/proc"
        "/sys"
        "/dev"
        "/dev/pts"
        "/run"
        "/tmp"
        # ruri 的运行时状态，不属于镜像内容
        "/.rurienv"
        "/.ruri_umounted"
    )

    info "正在复制 rootfs 快照，跳过虚拟系统目录..."

    if command -v rsync >/dev/null 2>&1; then
        local -a rsync_args=(-aHAX --delete)
        local ex
        for ex in "${exclude_list[@]}"; do
            rsync_args+=("--exclude=${ex}")
        done
        rsync "${rsync_args[@]}" "${rootfs_dir}/" "${rootfs_out}/" \
            || { rm -rf "$tmp_out"; die "rsync 复制失败"; }
    else
        info "警告: 未找到 rsync，降级使用 cp；虚拟目录过滤能力有限"
        cp -a "${rootfs_dir}/." "${rootfs_out}/" \
            || { rm -rf "$tmp_out"; die "cp 复制失败"; }
        local ex p
        for ex in "${exclude_list[@]}"; do
            p="${rootfs_out}${ex}"
            if [[ -d "$p" ]]; then
                rm -rf "$p"
            fi
        done
        rm -f "${rootfs_out}/.rurienv" "${rootfs_out}/.ruri_umounted"
    fi

    cp "$cfg_src" "${bundle_dir}/config.json" \
        || { rm -rf "$tmp_out"; die "写入 config.json 失败"; }

    # 把容器实际运行配置写回镜像 config（等价 docker commit 带上容器 Config）：
    # args 用最终 argv，env 用 .ruri_args 里的环境变量（排除运行时注入的 HOSTNAME），
    # cwd 跟随 -W。StopSignal 与 user 沿用原 config，避免猜错 gid。
    local -a ctr_rargs=() ctr_argv=() ctr_env=()
    load_args "${ctr_dir}/.ruri_args" ctr_rargs
    load_args "${ctr_dir}/.cmd_args" ctr_argv
    local ci=0 cwd_out=""
    while (( ci < ${#ctr_rargs[@]} )); do
        case "${ctr_rargs[$ci]}" in
        -e)
            if (( ci + 2 < ${#ctr_rargs[@]} )); then
                if [[ "${ctr_rargs[$((ci + 1))]}" != "HOSTNAME" ]]; then
                    ctr_env+=("${ctr_rargs[$((ci + 1))]}=${ctr_rargs[$((ci + 2))]}")
                fi
                ci=$((ci + 3)); continue
            fi ;;
        -W)
            if (( ci + 1 < ${#ctr_rargs[@]} )); then
                cwd_out="${ctr_rargs[$((ci + 1))]}"
            fi
            ci=$((ci + 2)); continue ;;
        esac
        ci=$((ci + 1))
    done
    local cfg_dst="${bundle_dir}/config.json" cfg_tmp="${bundle_dir}/config.json.tmp.$$"
    if jq --argjson args "$(_json_array ${ctr_argv[@]+"${ctr_argv[@]}"})" \
          --argjson env "$(_json_array ${ctr_env[@]+"${ctr_env[@]}"})" \
          --arg cwd "$cwd_out" \
          '.process.args = $args
           | .process.env = $env
           | (if $cwd != "" then .process.cwd = $cwd else . end)' \
          "$cfg_dst" > "$cfg_tmp" 2>/dev/null; then
        mv "$cfg_tmp" "$cfg_dst"
    else
        rm -f "$cfg_tmp"
        warn "更新 commit 镜像的 process 配置失败，沿用容器原 config.json"
    fi

    echo "$new_ref" > "${tmp_out}/.ref"
    date -Iseconds > "${tmp_out}/.pulled_at"

    if [[ -e "$img_out" ]]; then
        info "强制覆盖，替换旧镜像目录: $img_out"
        rm -rf "$img_out"
    fi
    mv "$tmp_out" "$img_out" || { rm -rf "$tmp_out"; die "替换镜像目录失败"; }

    info "commit 完成: $new_ref"
    info "快照目录: $img_out"
    info "提示：该镜像是扁平化全量快照，非 OCI 分层镜像"
}

# ====================== tag / rename / wait / top / cp / export / port ======================
cmd_tag() {
    [[ $# -ge 2 ]] || die "用法: docker tag SOURCE[:TAG] TARGET[:TAG]"
    local src="$1" dst="$2"
    local srepo stag drepo dtag
    read -r srepo stag < <(parse_image_ref "$src")
    read -r drepo dtag < <(parse_image_ref "$dst")
    local sdir ddir
    sdir="${DATA_DIR}/images/$(safe_img_name "$srepo" "$stag")"
    ddir="${DATA_DIR}/images/$(safe_img_name "$drepo" "$dtag")"
    [[ -d "$sdir" ]] || die "镜像不存在 $src"
    if [[ -e "$ddir" ]]; then
        die "目标镜像已存在 $dst"
    fi
    lock_data_dir
    # 镜像目录共享只读内容，优先硬链接
    cp -al "$sdir" "$ddir" 2>/dev/null || cp -a "$sdir" "$ddir" \
        || die "创建镜像标签失败"
    # 硬链接会让 .ref/.pulled_at 与源镜像共享 inode，必须先断开再写
    rm -f "${ddir}/.ref" "${ddir}/.pulled_at"
    echo "${drepo}:${dtag}" > "${ddir}/.ref"
    date -Iseconds > "${ddir}/.pulled_at"
    info "已创建镜像标签 ${drepo}:${dtag}"
}

cmd_rename() {
    [[ $# -ge 2 ]] || die "用法: docker rename OLD NEW"
    local old="$1" new="$2"
    validate_ctr_name "$new"
    local old_dir new_dir
    old_dir=$(ctr_dir_of "$old")
    new_dir="${DATA_DIR}/containers/${new}"
    [[ -d "$old_dir" ]] || die "容器不存在 $old"
    assert_under_containers "$new_dir"
    if [[ -e "$new_dir" ]]; then
        die "目标容器名已存在 $new"
    fi
    lock_data_dir
    mv "$old_dir" "$new_dir" || die "重命名容器失败"
    info "已将容器 $old 重命名为 $new"
}

cmd_wait() {
    [[ $# -ge 1 ]] || die "用法: docker wait <容器名>"
    local ctr_name="$1"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    while :; do
        refresh_ctr_state "$ctr_dir"
        case "$(cat "${ctr_dir}/.state" 2>/dev/null || true)" in
        running|paused) sleep 0.2 ;;
        *) break ;;
        esac
    done
    # ruri 的 pidfile 会写 RURI_EXITED_<code> / RURI_SIGNALED_<sig>，与 docker wait 一致
    if [[ -s "${ctr_dir}/.exit_code" ]]; then
        cat "${ctr_dir}/.exit_code"
    elif [[ -s "${ctr_dir}/.exit_signal" ]]; then
        local sig
        sig=$(cat "${ctr_dir}/.exit_signal")
        echo $((128 + sig))
    else
        echo 0
    fi
}

cmd_top() {
    [[ $# -ge 1 ]] || die "用法: docker top <容器名>"
    local ctr_name="$1"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    refresh_ctr_state "$ctr_dir"
    [[ "$(cat "${ctr_dir}/.state")" == "running" ]] || die "容器未运行 $ctr_name"
    local target_root
    target_root=$(realpath -m "${ctr_dir}/rootfs" 2>/dev/null || true)
    [[ -n "$target_root" ]] || return 0
    printf "%-8s %s\n" "PID" "CMD"
    local pid_dir pid
    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir##*/}"
        _proc_alive "$pid" 2>/dev/null || continue
        [[ "$pid_dir/root" -ef "$target_root" ]] || continue
        printf "%-8s %s\n" "$pid" "$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//')"
    done
}

_assert_under_rootfs() {
    local rootfs="$1" p="$2"
    [[ "$p" == /* ]] || die "容器内路径必须是绝对路径: $p"
    local resolved
    resolved=$(realpath -m "${rootfs}${p}")
    [[ "$resolved" == "$rootfs" || "$resolved" == "$rootfs"/* ]] || die "容器内路径越界: $p"
}

cmd_cp() {
    [[ $# -ge 2 ]] || die "用法: docker cp <容器>:<路径> <宿主路径> | docker cp <宿主路径> <容器>:<路径>"
    local src="$1" dst="$2"
    local src_ctr="" src_path="" dst_ctr="" dst_path=""
    if [[ "$src" == *:* ]]; then
        src_ctr="${src%%:*}"
        src_path="${src#*:}"
        [[ -d "${DATA_DIR}/containers/${src_ctr}" ]] || src_ctr=""
    fi
    if [[ "$dst" == *:* ]]; then
        dst_ctr="${dst%%:*}"
        dst_path="${dst#*:}"
        [[ -d "${DATA_DIR}/containers/${dst_ctr}" ]] || dst_ctr=""
    fi
    if [[ -n "$src_ctr" && -z "$dst_ctr" ]]; then
        local rootfs="${DATA_DIR}/containers/${src_ctr}/rootfs"
        _assert_under_rootfs "$rootfs" "$src_path"
        [[ -e "${rootfs}${src_path}" ]] || die "容器内路径不存在: $src_path"
        cp -a "${rootfs}${src_path}" "$dst" || die "复制失败"
    elif [[ -z "$src_ctr" && -n "$dst_ctr" ]]; then
        local rootfs="${DATA_DIR}/containers/${dst_ctr}/rootfs"
        _assert_under_rootfs "$rootfs" "$dst_path"
        [[ -e "$src" ]] || die "宿主路径不存在: $src"
        mkdir -p "$(dirname "${rootfs}${dst_path}")" || die "创建目标目录失败"
        cp -a "$src" "${rootfs}${dst_path}" || die "复制失败"
    else
        die "docker cp 仅支持容器与宿主之间的复制"
    fi
    info "已复制 $src → $dst"
}

cmd_export() {
    local out=""
    local ctr_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -o|--output) [[ $# -ge 2 ]] || die "$1 缺少参数"; out="$2"; shift 2 ;;
        --output=*)  out="${1#*=}"; shift ;;
        --)          shift; break ;;
        -*)          die "export: 未知参数 $1" ;;
        *)           ctr_name="$1"; shift ;;
        esac
    done
    [[ -n "$ctr_name" ]] || die "用法: docker export [-o FILE] <容器名>"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir/rootfs" ]] || die "容器不存在 $ctr_name"
    refresh_ctr_state "$ctr_dir"
    [[ "$(cat "${ctr_dir}/.state")" == "running" ]] && warn "容器运行中，export 的内容可能不一致"
    if [[ -n "$out" ]]; then
        [[ -e "$out" ]] && die "输出文件已存在 $out"
        tar -C "${ctr_dir}/rootfs" -cf "$out" . || die "导出失败"
        info "已导出容器 $ctr_name 到 $out"
    else
        tar -C "${ctr_dir}/rootfs" -cf - .
    fi
}

cmd_port() {
    [[ $# -ge 1 ]] || die "用法: docker port <容器名> [PRIVATE_PORT[/PROTO]]"
    local ctr_name="$1"
    local ctr_dir
    ctr_dir=$(ctr_dir_of "$ctr_name")
    [[ -d "$ctr_dir" ]] || die "容器不存在 $ctr_name"
    # ruri 共享主机网络，没有端口映射
    return 0
}

# ====================== inspect / info / version ======================
_inspect_container() {
    local ctr_dir="$1" name="$2"
    refresh_ctr_state "$ctr_dir"
    local id state pid img
    id=$(_ensure_ctr_id "$ctr_dir")
    state=$(cat "${ctr_dir}/.state" 2>/dev/null || echo "created")
    pid=$(cat "${ctr_dir}/.pid" 2>/dev/null || true)
    img=$(cat "${ctr_dir}/.image_ref" 2>/dev/null || true)
    local cfg="${ctr_dir}/.image_config.json"
    if [[ ! -s "$cfg" ]]; then
        _ensure_image_config "$ctr_dir" >/dev/null 2>&1 || true
    fi

    local -a ra=() env_pairs=() mounts=() binds=() user_cmd=() ep=()
    load_args "${ctr_dir}/.ruri_args" ra
    local i=0 workdir="" user="" start_sig=""
    while (( i < ${#ra[@]} )); do
        case "${ra[$i]}" in
        -e)
            if (( i + 2 < ${#ra[@]} )); then
                # HOSTNAME 是 start 时注入的运行时变量，不属于镜像 Config.Env
                [[ "${ra[$((i + 1))]}" == "HOSTNAME" ]] || \
                    env_pairs+=("${ra[$((i + 1))]}=${ra[$((i + 2))]}")
                i=$((i + 3)); continue
            fi ;;
        -m|-M)
            if (( i + 2 < ${#ra[@]} )); then
                local src="${ra[$((i + 1))]}" dst="${ra[$((i + 2))]}"
                src="${src#BIND:}"
                mounts+=("$(jq -n --arg s "$src" --arg d "$dst" --arg m "$([[ "${ra[$i]}" == "-M" ]] && echo ro || echo rw)" \
                    '{Type:"bind",Source:$s,Destination:$d,Mode:$m}')")
                binds+=("${src}:${dst}")
                i=$((i + 3)); continue
            fi ;;
        -W)
            (( i + 1 < ${#ra[@]} )) && workdir="${ra[$((i + 1))]}"
            i=$((i + 2)); continue ;;
        -E)
            (( i + 1 < ${#ra[@]} )) && user="${ra[$((i + 1))]}"
            i=$((i + 2)); continue ;;
        esac
        i=$((i + 1))
    done

    if [[ -f "${ctr_dir}/.entrypoint_set" ]]; then
        load_args "${ctr_dir}/.entrypoint_override" ep
    elif [[ -s "$cfg" ]]; then
        while IFS= read -r line; do ep+=("$line"); done \
            < <(jq -r '.Entrypoint[]? // empty' "$cfg" 2>/dev/null || true)
    fi
    if [[ -f "${ctr_dir}/.user_cmd" ]]; then
        load_args "${ctr_dir}/.user_cmd" user_cmd
    fi
    if [[ ${#user_cmd[@]} -eq 0 && -s "$cfg" ]]; then
        while IFS= read -r line; do user_cmd+=("$line"); done \
            < <(jq -r '.Cmd[]? // empty' "$cfg" 2>/dev/null || true)
    fi

    local labels_json='{}' expose_json='{}' volumes_json='{}'
    if [[ -s "$cfg" ]]; then
        labels_json=$(jq -c '.Labels // {}' "$cfg" 2>/dev/null || echo '{}')
        expose_json=$(jq -c '.ExposedPorts // {}' "$cfg" 2>/dev/null || echo '{}')
        volumes_json=$(jq -c '.Volumes // {}' "$cfg" 2>/dev/null || echo '{}')
        [[ -z "${workdir}" ]] && workdir=$(jq -r '.WorkingDir // empty' "$cfg" 2>/dev/null || true)
        [[ -z "${user}" ]] && user=$(jq -r '.User // empty' "$cfg" 2>/dev/null || true)
        local cfg_stop
        cfg_stop=$(jq -r '.StopSignal // empty' "$cfg" 2>/dev/null || true)
        [[ -n "$cfg_stop" ]] && start_sig="$cfg_stop"
    fi
    if [[ -s "${ctr_dir}/.labels" ]]; then
        local lk lv
        while IFS='=' read -r lk lv; do
            [[ -n "$lk" ]] || continue
            labels_json=$(printf '%s' "$labels_json" | jq -c --arg k "$lk" --arg v "$lv" '.[$k]=$v')
        done < "${ctr_dir}/.labels"
    fi
    if [[ -s "${ctr_dir}/.expose" ]]; then
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            expose_json=$(printf '%s' "$expose_json" | jq -c --arg p "$p" '.[$p]={}')
        done < "${ctr_dir}/.expose"
    fi
    if [[ -s "${ctr_dir}/.stop_signal" ]]; then
        start_sig=$(cat "${ctr_dir}/.stop_signal")
    fi

    local running=false paused=false exit_code=0
    case "$state" in
    running|paused) running=true ;;
    esac
    [[ -f "${ctr_dir}/.paused" ]] && paused=true
    if [[ -s "${ctr_dir}/.exit_code" ]]; then
        exit_code=$(cat "${ctr_dir}/.exit_code")
    elif [[ -s "${ctr_dir}/.exit_signal" ]]; then
        exit_code=$((128 + $(cat "${ctr_dir}/.exit_signal")))
    fi
    local started_at="" finished_at="" ets=""
    started_at=$(cat "${ctr_dir}/.started_at" 2>/dev/null || true)
    ets=$(cat "${ctr_dir}/.exited_at" 2>/dev/null || true)
    if [[ -n "$ets" ]]; then
        finished_at=$(date -Iseconds -d "@$ets" 2>/dev/null || true)
    fi

    local mounts_json='[]'
    if [[ ${#mounts[@]} -gt 0 ]]; then
        mounts_json=$(printf '%s\n' "${mounts[@]}" | jq -s '.')
    fi
    local restart_policy
    restart_policy=$(cat "${ctr_dir}/.restart_policy" 2>/dev/null || echo "no")

    jq -n \
        --arg id "$id" --arg name "$name" --arg image "$img" \
        --arg status "$state" --argjson running "$running" --argjson paused "$paused" \
        --argjson exitcode "$exit_code" --argjson pid "${pid:-0}" \
        --arg started "$started_at" --arg finished "$finished_at" \
        --argjson env "$(_json_array ${env_pairs[@]+"${env_pairs[@]}"})" \
        --argjson cmd "$(_json_array ${user_cmd[@]+"${user_cmd[@]}"})" \
        --argjson ep "$(_json_array ${ep[@]+"${ep[@]}"})" \
        --arg cwd "$workdir" --arg user "$user" \
        --argjson labels "$labels_json" --argjson expose "$expose_json" \
        --argjson volumes "$volumes_json" --arg stop "$start_sig" \
        --argjson mounts "$mounts_json" \
        --argjson binds "$(_json_array ${binds[@]+"${binds[@]}"})" \
        --arg restart "$restart_policy" \
        '{
            Id: $id,
            Name: ("/" + $name),
            Image: $image,
            State: {Status: $status, Running: $running, Paused: $paused, Pid: $pid,
                    ExitCode: $exitcode, StartedAt: $started, FinishedAt: $finished},
            Config: {Env: $env, Cmd: $cmd, Entrypoint: $ep, WorkingDir: $cwd, User: $user,
                     Labels: $labels, ExposedPorts: $expose, Volumes: $volumes, StopSignal: $stop},
            Mounts: $mounts,
            HostConfig: {Binds: $binds, RestartPolicy: {Name: $restart}, NetworkMode: "host"}
        }'
}

_inspect_image() {
    local img_dir="$1" ref="$2"
    local cfg_json='{}'
    local blob
    if blob=$(_oci_config_blob "$img_dir"); then
        cfg_json=$(jq -c '.config // {}' "$blob" 2>/dev/null || echo '{}')
    elif [[ -f "${img_dir}/bundle/config.json" ]]; then
        cfg_json=$(jq -c '{Env:(.process.env // []), Cmd:(.process.args // []), Entrypoint:[],
                           WorkingDir:(.process.cwd // ""), User:""}' \
            "${img_dir}/bundle/config.json" 2>/dev/null || echo '{}')
    fi
    local size=0
    [[ -d "$img_dir" ]] && size=$(du -sb "$img_dir" 2>/dev/null | cut -f1 || echo 0)
    jq -n --arg id "$(_image_full_id "$img_dir")" --arg ref "$ref" \
        --arg created "$(cat "${img_dir}/.pulled_at" 2>/dev/null || echo "")" \
        --argjson size "${size:-0}" --argjson cfg "$cfg_json" \
        '{Id: $id, RepoTags: [$ref], Created: $created, Size: $size, Config: $cfg}'
}

_docker_format_to_jq() {
    local f="$1"
    if [[ "$f" =~ ^\{\{[[:space:]]*\.([A-Za-z0-9_.]+)[[:space:]]*\}\}$ ]]; then
        printf '.%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$f"
    fi
}

cmd_inspect() {
    local format=""
    local -a targets=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -f|--format) [[ $# -ge 2 ]] || die "$1 缺少参数"; format="$2"; shift 2 ;;
        --format=*)  format="${1#*=}"; shift ;;
        --type)      [[ $# -ge 2 ]] || die "$1 缺少参数"; shift 2 ;;
        --type=*)    shift ;;
        --)          shift; break ;;
        -*)          die "inspect: 未知参数 $1" ;;
        *)           targets+=("$1"); shift ;;
        esac
    done
    [[ ${#targets[@]} -gt 0 ]] || die "用法: docker inspect [-f FORMAT] <镜像名|容器名>"
    local -a objs=()
    local t
    for t in "${targets[@]}"; do
        local ctr_dir=""
        if [[ "$t" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
            ctr_dir="${DATA_DIR}/containers/${t}"
            [[ -d "$ctr_dir" ]] || ctr_dir=""
        fi
        if [[ -n "$ctr_dir" ]]; then
            objs+=("$(_inspect_container "$ctr_dir" "$t")")
        else
            local repo tag img_dir
            read -r repo tag < <(parse_image_ref "$t")
            img_dir="${DATA_DIR}/images/$(safe_img_name "$repo" "$tag")"
            [[ -d "$img_dir" ]] || die "找不到镜像或容器: $t"
            objs+=("$(_inspect_image "$img_dir" "${repo}:${tag}")")
        fi
    done
    local json
    json=$(printf '%s\n' "${objs[@]}" | jq -s '.')
    if [[ -n "$format" ]]; then
        local expr
        expr=$(_docker_format_to_jq "$format")
        printf '%s\n' "$json" | jq -r ".[] | ${expr}"
    else
        printf '%s\n' "$json"
    fi
}

cmd_info() {
    echo "数据目录: $DATA_DIR"
    echo "运行时: $RUNTIME"
    echo "自动 -S: $([[ "$USE_HOST_RUNTIME" == "1" ]] && echo yes || echo no)"
    echo "auto-umount(前台): $(_has_ruri_opt --auto-umount && echo yes || echo no)"
    echo "QEMU 路径: ${RURI_QEMU_PATH:-<未设置>}"
    echo "镜像数: $(find "$DATA_DIR/images" -maxdepth 1 -mindepth 1 -type d ! -name '*.tmp.*' 2>/dev/null | wc -l)"
    echo "容器数: $(find "$DATA_DIR/containers" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
    echo "网络: 共享主机网络；--net none 映射为 ruri -x"
}

cmd_version() {
    echo "docker2ruri v${VERSION}"
    echo "RUNTIME: $RUNTIME"
    if [[ -x "$RUNTIME" ]]; then
        "$RUNTIME" --version 2>&1 | head -1 || true
    fi
}

# ====================== 帮助 ======================
# 帮助按「命令组 → 命令 → 该命令自己的选项」组织，不再把所有选项堆在一起：
#   docker help               总览：命令分组，每个命令只列它自己的选项
#   docker help <命令>        单命令：用法 / 选项 / 示例 / 注意
#   docker help options       create、run 可用的 docker 选项与映射
#   docker help env           环境变量
#   docker help limits        已知差异与限制
#   docker help all           以上全部
# 新增命令时：在 _HELP_ROWS 加一行，并在 _help_detail 里补对应分支。
_HELP_GROUPS=(镜像 容器 容器内 观测 其他)

# 字段用 TAB 分隔：命令 / 分组 / 说明 / 该命令专属选项（可为空）
_HELP_ROWS=(
    $'pull\t镜像\t拉取镜像到本地数据目录\t--platform OS/ARCH'
    $'images\t镜像\t列出本地镜像\t-q/--quiet'
    $'rmi\t镜像\t删除镜像\t-f/--force'
    $'tag\t镜像\t为镜像增加标签\t'
    $'save\t镜像\t导出镜像为 tar\t-o/--output FILE'
    $'load\t镜像\t从 tar 导入镜像\t-i/--input FILE'
    $'create\t容器\t创建容器，不启动\t--name；-i/-t/-it；--rm；-p（仅告警）；镜像选项'
    $'run\t容器\t创建并启动容器\t-d/--detach；--name；-i/-t/-it；--rm；-p（仅告警）；镜像选项'
    $'start\t容器\t启动已有容器\t-a/--attach；-i/--interactive'
    $'stop\t容器\t停止容器\t-t/--timeout 秒'
    $'restart\t容器\t重启容器\t-t/--timeout 秒'
    $'kill\t容器\t向容器 init 发信号\t-s/--signal'
    $'pause\t容器\t冻结容器（需 cgroup v2）\t'
    $'unpause\t容器\t解冻容器\t'
    $'rm\t容器\t删除容器\t-f/--force；-v'
    $'rename\t容器\t重命名容器\t'
    $'commit\t容器\t提交容器为新镜像\t-f/--force'
    $'exec\t容器内\t在运行中的容器里执行命令\t-i/-t/-it；-u/--user；-w/--workdir；-e/--env；--env-file'
    $'cp\t容器内\t宿主与容器之间复制文件\t'
    $'export\t容器内\t导出容器 rootfs 为 tar\t-o/--output FILE'
    $'ps\t观测\t列出容器\t-a/--all；-q/--quiet'
    $'logs\t观测\t查看容器日志\t-f/--follow；-n/--tail N'
    $'top\t观测\t列出容器内进程\t'
    $'wait\t观测\t等待容器退出并输出退出码\t'
    $'port\t观测\t端口映射（共享主机网络，无输出）\t'
    $'inspect\t观测\t输出镜像/容器的 docker 风格 JSON\t-f/--format'
    $'info\t观测\t打印数据目录与运行时信息\t'
    $'help\t其他\t显示帮助\t<命令> | options | env | limits | all'
    $'version\t其他\t打印版本\t'
)

_help_has_cmd() {
    local want="$1" row
    for row in "${_HELP_ROWS[@]}"; do
        [[ "${row%%$'\t'*}" == "$want" ]] && return 0
    done
    return 1
}

_help_overview() {
    cat <<EOF
docker2ruri v${VERSION} — 用 ruri 直接运行 OCI 镜像的 docker CLI 兼容层（无需 dockerd）
数据目录: ${DATA_DIR}

用法
  docker <命令> [选项...]
  docker help [<命令>|options|env|limits|all]
  docker <命令> --help

选项归属
  选项按命令划分，互不共享，用在别的命令上会直接报「未知参数」，不会静默忽略：
    create / run   镜像选项（-e/-v/-w/-u/...）以及 --name/--rm
    start          只有 -a / -i
    stop、restart  只有 -t 秒
    exec           只有 -i/-t/-u/-w/-e/--env-file
  镜像选项必须写在 IMAGE 之前；IMAGE 之后的参数一律作为容器命令。
  容器命令本身以 - 开头时用 -- 交给 ruri：
    docker run alpine -- sh -c 'ls -l'

EOF
    local group row cmd grp desc opts
    for group in "${_HELP_GROUPS[@]}"; do
        printf '%s\n' "$group"
        for row in "${_HELP_ROWS[@]}"; do
            IFS=$'\t' read -r cmd grp desc opts <<< "$row"
            [[ "$grp" == "$group" ]] || continue
            printf '  %-9s %s\n' "$cmd" "$desc"
            if [[ -n "$opts" ]]; then
                printf '  %-9s   选项: %s\n' "" "$opts"
            fi
        done
        printf '\n'
    done
    cat <<'EOF'
  单个命令的完整用法与示例: docker help <命令>

数据与状态
  镜像、容器、日志都在数据目录下（容器日志为 containers/<名>/run.log）。
  查看当前路径与运行时: docker info

更多主题
  docker help options   create/run 可用的 docker 选项：映射与忽略
  docker help env       环境变量
  docker help limits    已知差异与限制
EOF
}

_help_options() {
    cat <<'EOF'
docker 选项（仅 create 与 run 接受；必须写在 IMAGE 之前）

环境
  -e, --env K=V            映射为 ruri -e K V
  -e K                     取当前 shell 里的 K；未定义则告警忽略
  --env-file FILE          逐行 K=V 转为 -e

挂载（只有 bind）
  -v, --volume SRC:DST          读写 bind → ruri -m SRC DST
  -v SRC:DST:ro                 只读 bind → ruri -M SRC DST
  --mount type=bind,source=S,target=T[,readonly][,bind-propagation=...]
                                → ruri -m/-M S DST
  --mount type=volume|tmpfs      告警忽略（无卷管理）

运行身份与目录
  -w, --workdir DIR        映射为 -W（ruri 的 -w 是 no-warnings）
  -u, --user USER          映射为 -E
  -h, --hostname H         映射为 -t；ruri 的 -t 仅在 unshare 模式生效，
                           默认只注入 /etc/hostname，内核 hostname 不变

资源限制
  -m, --memory 512m        映射为 -l memory=512M（单位自动转大写）
  --cpus 1.5               映射为 -l cpupercent=150
  --pids-limit N           映射为 -l pids=N；-1 表示不限，直接忽略

设备 / 权限 / 安全
  --privileged             映射为 -p
  --cap-add CAP            映射为 -k CAP
  --cap-drop CAP           映射为 -d CAP
  --device SRC[:DST[:PERM]]  映射为 -I DST名 MAJOR MINOR；DST 必须在 /dev 下，
                             权限位不受支持（告警后仍按字符设备挂入）
  --security-opt seccomp=unconfined  不传（ruri 默认无 seccomp）
  --security-opt seccomp=default     映射为 -s（ruri 支持 --enable-seccomp 时）
  --security-opt no-new-privileges   映射为 -n
  --security-opt 其它                 告警忽略
  --read-only              映射为 -R；ruri 未实现 -R 时告警忽略
  --init                   映射为 --fork-as-init；不支持时告警忽略

网络（共享主机网络，无 NAT）
  --net/--network none     → ruri -x（断网）
  --net/--network host     → 无操作（就是默认行为）
  --net/--network 其它      告警忽略
  -p, --publish            接受但忽略：容器监听 0.0.0.0:C 即等于宿主 C 端口

跨架构
  --platform OS/ARCH       → ruri -a ARCH -q $RURI_QEMU_PATH
                           未设置 RURI_QEMU_PATH 时告警忽略

生命周期与元数据（脚本自行保存，start 时使用，inspect 可查）
  --entrypoint CMD         覆盖镜像 Entrypoint；--entrypoint "" 清空
  --stop-signal SIG        停止容器时先发的信号（默认取镜像 StopSignal，否则 TERM）
  --stop-timeout N         停止超时秒数（stop -t 优先）
  --add-host H:I           写入容器 /etc/hosts
  --dns/--dns-search/--dns-option  写入容器 resolv.conf
  --label/--label-file     标签
  --cidfile FILE           把容器 ID 写入文件
  --restart POLICY         no|always|on-failure[:N]|unless-stopped；只记录，
                           本脚本无守护进程，不会自动重启
  --expose PORT            仅记录（共享主机网络，无需暴露）
  --oom-score-adj N        映射为 -O N（范围 [-1000,1000]）
  --rm                     容器退出后自动删除（后台模式由看护进程完成）

接受但忽略（会消费参数并告警，避免后续参数错位）
  --ulimit --log-driver --log-opt --cgroupns --ipc --pid --userns --uts
  --sysctl --group-add --link --mac-address --ip --tmpfs
  --health-cmd --health-interval --health-retries --health-timeout
  --health-start-period --shm-size --memory-swap --memory-reservation
  --cpu-shares --cpu-quota --cpu-period --cpuset-cpus --cpuset-mems
  --blkio-weight --volumes-from --network-alias
  --no-healthcheck --oom-kill-disable --disable-content-trust

不支持的选项
  上述清单之外的 - 开头参数会让命令直接失败，并提示用 -- 分隔容器命令。
EOF
}

_help_env() {
    cat <<'EOF'
环境变量

  DOCKER_DATA_DIR        数据目录，默认 $HOME/.local/share/docker-sh
  RURI_BIN               ruri 可执行文件，默认 /root/ruri/ruri
  DOCKER_REGISTRY_MIRROR 镜像源前缀，默认 ghcr.io（pull 使用）
  RURI_QEMU_PATH         跨架构 --platform 使用的 QEMU 路径，未设置则忽略 --platform
  RURI_HOST_RUNTIME      1=启动时给 ruri 加 -S（bind 宿主 /dev /sys /proc，隔离性差）
                         0=由 ruri 创建容器内 /dev /proc /sys（默认，与 docker 一致）
  DOCKER_LOCK_WAIT       容器级锁等待秒数，默认 10
  WAIT_TIMEOUT_TICKS     等待容器进入 running 的轮询次数，默认 30
  WAIT_INTERVAL          轮询间隔秒数，默认 0.2

运行时依赖
  必需  bash >= 4.4、root 权限、Linux、ruri、skopeo、umoci、jq、tar
  可选  timeout（拉取超时保护）、rsync（commit 更快）、flock（并发锁）
  安装: apt install util-linux skopeo umoci jq tar
        apk add util-linux skopeo umoci jq tar

容器内 /dev /proc /sys
  RURI_HOST_RUNTIME=0（默认）由 ruri 自建，与 docker 默认一致，不暴露宿主设备。
  RURI_HOST_RUNTIME=1 时 ruri 加 -S，并把宿主 /dev/pts、/dev/shm 单独挂入；
  隔离性变差，仅在需要宿主设备时使用。单个宿主设备优先用 --device。
EOF
}

_help_limits() {
    cat <<'EOF'
已知差异与限制

  1. 不是 dockerd：没有镜像分层、没有守护进程、没有 build/push/login/
     network/volume/system 子命令；容器就是 ruri 进程 + 一个 rootfs 目录。
  2. 共享主机网络：--net none 映射为 ruri -x；其它网络模式与 -p 端口映射
     不支持。容器监听 0.0.0.0:PORT 即等于宿主监听该端口。
  3. 无卷管理：--mount type=volume/tmpfs 不支持，-v 只做 bind 挂载。
  4. 无健康检查；--ulimit/--sysctl/--ipc/--pid/--uts/--userns/--cgroupns
     等选项被接受但忽略（会告警）。
  5. save/load 是本脚本自有目录 tar，不是 docker save 格式；import 亦不支持。
  6. 不支持 digest 引用（IMG@sha256:...），请用 tag。
  7. commit 生成的是扁平化全量快照，不是 OCI 分层镜像。
  8. pause/unpause 依赖 ruri --freeze/--thaw 与 cgroup v2；暂停期间不响应
     stop/kill，需先 unpause（rm -f 会先自动解冻）。
  9. exec 只能进入运行中的容器；优先加入容器已有命名空间，失败时退化为
     针对同一 rootfs 启动新进程。
 10. 容器内 /dev /proc /sys 默认由 ruri 自建，与 docker 默认一致；需要宿主
     设备时用 --device 逐个添加，或设置 RURI_HOST_RUNTIME=1。
 11. --hostname 只做文件级注入（默认共享主机 UTS 命名空间）。
 12. 前台 attach（start -a / run 不加 -d）时 Ctrl-C 会转发给容器；若容器
     未退出，脚本会走完整 stop（信号升级），容器因此被终止。
 13. 容器 ID 是随机 hex（首次访问时生成），不是 docker 的 sha256；rename 后不变。
 14. 无守护进程：--restart 只记录策略，不会自动重启；后台容器退出后保持 exited。
 15. 前台运行若 ruri 支持 --auto-umount 会自动附加，退出即卸载；后台 -b 模式不加，
     挂载清理由 stop/rm/commit 兜底。文件级 bind mount 统一加 ruri 的 BIND: 前缀。

ruri 相关
  -w 在 ruri 里是 no-warnings，因此 docker 的 -w 映射为 -W。

实现要点（排障时会用到）
  1. 数据目录与单容器操作用 flock 加锁；前台运行不持容器锁，stop/rm 仍可执行；
     启动容器前会关闭锁 fd，避免容器进程继承 flock。
  2. 后台启动优先用 ruri -b -L <log> --pid-file，不支持时回退 shell job control。
  3. 前台运行与 exec -t 时自动附加 ruri -z，保证 TTY 信号正确传递。
  4. 前台输出经 tee 同时写 run.log，脚本等 tee 刷完再返回。
  5. 运行状态用 /proc/<pid>/stat 的 starttime 校验并排除僵尸进程。
EOF
}

_help_detail() {
    case "$1" in
    pull)
        cat <<'EOF'
用法
  docker pull [--platform OS/ARCH] <镜像>[:tag]

选项
  --platform OS/ARCH   按指定架构解包（linux/arm64 或 arm64 都可以）

示例
  docker pull alpine:latest
  docker pull --platform linux/arm64 alpine:3.20

注意
  镜像源默认 ghcr.io，可用 DOCKER_REGISTRY_MIRROR 覆盖。
  同名镜像会先删旧目录再整体替换，拉取失败不会留下半成品。
  不支持 digest 引用，请用 tag。
EOF
        ;;
    images)
        cat <<'EOF'
用法
  docker images [-q]

选项
  -q, --quiet   只输出镜像 ID

说明
  依次列出 REPOSITORY / TAG / IMAGE ID / CREATED / SIZE。
  -a、--no-trunc 被接受但没有效果。
EOF
        ;;
    rmi)
        cat <<'EOF'
用法
  docker rmi [-f] <镜像>[:tag]

选项
  -f, --force   镜像被容器引用时也强制删除

示例
  docker rmi alpine:3.20
  docker rmi -f alpine:3.20

注意
  不加 -f 时，只要还有容器引用该镜像就会拒绝删除。
EOF
        ;;
    tag)
        cat <<'EOF'
用法
  docker tag <源镜像>[:tag] <目标镜像>[:tag]

说明
  优先用硬链接复制镜像目录，几乎不占额外空间；目标已存在则失败。

示例
  docker tag alpine:latest alpine:backup
EOF
        ;;
    save)
        cat <<'EOF'
用法
  docker save [-o FILE] <镜像>[:tag] [FILE]

选项
  -o, --output FILE   输出文件（与位置参数 FILE 二选一）

示例
  docker save -o alpine.tar alpine:latest
  docker save alpine:latest alpine.tar

注意
  产物是本脚本自有目录结构的 tar（bundle/rootfs + config.json），
  不是 docker save 格式，只能用 docker load 读回。
EOF
        ;;
    load)
        cat <<'EOF'
用法
  docker load [-i FILE] [FILE.tar]

选项
  -i, --input FILE   输入文件（与位置参数二选一）

说明
  也兼容只含 rootfs/ 的包（自动整理成 bundle/rootfs）。
  包内没有 .ref 时会提示输入镜像名。
EOF
        ;;
    create)
        cat <<'EOF'
用法
  docker create [--name NAME] [-i] [-t] [--rm] [镜像选项...] <镜像>[:tag] [命令...]

命令选项（只属于 create）
  --name NAME   容器名（默认 ctr_<时间戳>_<随机数>）
  -i, --interactive   保持 stdin 打开
  -t, --tty           分配伪终端
  -it, -ti            等价于 -i -t
  --rm                容器退出后自动删除
  -p, --publish       接受但忽略（共享主机网络）
  -d, --detach        create 不支持，告警后忽略

镜像选项
  -e/--env --env-file -v/--volume --mount -w/--workdir -u/--user
  -h/--hostname --privileged --cap-add --cap-drop --read-only
  -m/--memory --cpus --pids-limit --device --security-opt
  --net/--network --platform --init --entrypoint --stop-signal
  --stop-timeout --add-host --dns --dns-search --dns-option
  --label --label-file --cidfile --restart --expose --oom-score-adj
  逐项映射与忽略清单见: docker help options

示例
  docker create --name web -p 8080:80 -e TZ=Asia/Shanghai nginx:alpine
  docker start web

注意
  选项必须写在 IMAGE 之前；IMAGE 之后一律作为容器命令。
  create 不会启动容器，镜像配置在每次 start 时重新同步。

运行配置（与 docker 对齐）
  容器创建时把镜像 config.json 快照到 containers/<名>/.image_config.json，
  每次 start 重新同步；用户显式选项保存在 .user_args，不会被镜像覆盖：
    命令     = [--entrypoint 或镜像 Entrypoint] + [容器命令 或 镜像 Cmd]
    环境     = 镜像 Env（被 -e/--env-file 同名覆盖）+ 用户 env + HOSTNAME
    工作目录 = -w > 镜像 WorkingDir
    用户     = -u > 镜像 User
    停止信号 = --stop-signal > 镜像 StopSignal > SIGTERM
    匿名卷   = 镜像 Volumes 自动挂载到 containers/<名>/volumes/<路径>
  每次 start 刷新 .etc/{hosts,hostname,resolv.conf}；--dns/--dns-search/
  --dns-option/--add-host 的修改在下次 start 生效。
EOF
        ;;
    run)
        cat <<'EOF'
用法
  docker run [-d] [--name NAME] [-i] [-t] [--rm] [镜像选项...] <镜像>[:tag] [命令...]

命令选项（只属于 run）
  -d, --detach        后台运行，打印容器名后立即返回
  -i, --interactive   保持 stdin 打开
  -t, --tty           分配伪终端
  -it, -ti            等价于 -i -t
  --name NAME         容器名（默认 ctr_<时间戳>_<随机数>）
  --rm                容器退出后自动删除
  -p, --publish       接受但忽略（共享主机网络）

镜像选项
  与 create 相同：-e/--env --env-file -v/--volume --mount -w/--workdir
  -u/--user -h/--hostname --privileged --cap-add --cap-drop --read-only
  -m/--memory --cpus --pids-limit --device --security-opt --net/--network
  --platform --init --entrypoint --stop-signal --stop-timeout --add-host
  --dns --dns-search --dns-option --label --label-file --cidfile
  --restart --expose --oom-score-adj
  逐项映射与忽略清单见: docker help options

示例
  docker run --rm alpine:latest echo hello
  docker run -d --name web -p 8080:80 -e TZ=Asia/Shanghai nginx:alpine
  docker run -it --rm -v "$PWD:/work" -w /work alpine:latest sh
  docker run alpine -- sh -c 'ls -l'

注意
  选项必须写在 IMAGE 之前；IMAGE 之后的参数一律作为容器命令。
  前台运行时 Ctrl-C 会转发给容器，必要时脚本会升级为 stop。
EOF
        ;;
    start)
        cat <<'EOF'
用法
  docker start [-a] [-i] <容器名>

选项（start 只有这两个，镜像选项在这里无效）
  -a, --attach         前台运行，输出接到当前终端
  -i, --interactive    保持 stdin 打开，隐含 -a

说明
  对已运行或已暂停的容器是幂等的，直接返回 0。
  每次 start 都按镜像 config.json 重新同步 Env/WorkingDir/User/命令，
  并刷新 /etc/{hosts,hostname,resolv.conf}。
  容器已暂停时请先 unpause。

示例
  docker start web
  docker start -a web
  docker start -i web

注意
  前台 attach 时 Ctrl-C 会转发给容器；容器不退出时脚本会走完整 stop。
EOF
        ;;
    stop)
        cat <<'EOF'
用法
  docker stop [-t 秒] <容器名>

选项
  -t, --time, --timeout 秒   停止超时（默认取 --stop-timeout，否则 10 秒）

说明
  先发停止信号（--stop-signal > 镜像 StopSignal > SIGTERM），超时后升级。
  对已停止的容器是幂等的。

示例
  docker stop web
  docker stop -t 3 web

注意
  容器处于 paused 状态时需先 docker unpause。
EOF
        ;;
    restart)
        cat <<'EOF'
用法
  docker restart [-t 秒] <容器名>

选项
  -t, --time, --timeout 秒   传给 stop 的超时

示例
  docker restart web
EOF
        ;;
    kill)
        cat <<'EOF'
用法
  docker kill [-s SIGNAL] <容器名>

选项
  -s, --signal SIGNAL   发给容器 init 的信号，默认 KILL
                        可写 TERM、SIGTERM、9 等

示例
  docker kill web
  docker kill -s TERM web

注意
  容器必须处于 running；paused 时先 unpause。
EOF
        ;;
    pause)
        cat <<'EOF'
用法
  docker pause <容器名>

说明
  映射到 ruri --freeze，需要宿主 cgroup v2，且容器未使用 ruri 不支持的配置。

注意
  暂停期间容器不响应 stop/kill，需要先 unpause；rm -f 会先自动解冻。
EOF
        ;;
    unpause)
        cat <<'EOF'
用法
  docker unpause <容器名>

说明
  映射到 ruri --thaw。容器未暂停时直接返回 0。
EOF
        ;;
    rm)
        cat <<'EOF'
用法
  docker rm [-f] [-v] <容器名>

选项
  -f, --force    运行中/已暂停的容器也强制停止后删除
  -v, --volumes  被接受；本脚本无独立卷管理，匿名卷随容器目录一起删除

注意
  运行中的容器默认拒绝删除；删除前会清理挂载点。
EOF
        ;;
    rename)
        cat <<'EOF'
用法
  docker rename <旧名> <新名>

说明
  直接重命名数据目录下的容器目录；新名字已存在时失败。
EOF
        ;;
    commit)
        cat <<'EOF'
用法
  docker commit [-f|--force] <容器名> <新镜像>[:tag]

选项
  -f, --force   目标镜像已存在时覆盖

说明
  把容器 rootfs 快照为镜像，跳过 /proc /sys /dev /dev/pts /run /tmp 与
  ruri 运行时状态。有 rsync 时用它复制，否则用 cp -a。

注意
  容器必须已停止（running 会直接报错，paused 也会被拒）。
  产物是扁平化全量快照，不是 OCI 分层镜像。
EOF
        ;;
    exec)
        cat <<'EOF'
用法
  docker exec [-it] [-u USER] [-w DIR] [-e K=V] [--env-file FILE] <容器名> <命令...>

选项（exec 用自己的 -u/-w/-e，与 create/run 的镜像选项无关）
  -i, --interactive   保持 stdin 打开
  -t, --tty           分配伪终端（容器内用 script 实现）
  -it, -ti            等价于 -i -t
  -u, --user USER     指定用户；未指定时继承容器配置
  -w, --workdir DIR   指定工作目录；未指定时继承容器配置
  -e, --env K=V       追加环境变量，可重复
  --env-file FILE     从文件读环境变量

示例
  docker exec web sh -c 'cat /etc/os-release'
  docker exec -it web sh
  docker exec -u nobody -w /tmp web id

注意
  仅支持运行中的容器。
  未指定 -u/-w 时继承容器的用户与工作目录；环境变量继承容器 Env（不是宿主环境），
  -e 覆盖同名变量。
  优先用 ruri -N -J <init_pid> 加入已有命名空间；init pid 失效时退化为针对同一
  rootfs 启动新进程。
  -t 时由宿主 util-linux 的 script 分配 PTY；宿主 /dev/pts 未挂载 devpts 时脚本会
  尝试自动挂载（需要 root），失败则退化为无 PTY 并给出修复命令。
EOF
        ;;
    cp)
        cat <<'EOF'
用法
  docker cp <容器名>:<容器内路径> <宿主路径>
  docker cp <宿主路径> <容器名>:<容器内路径>

说明
  容器内路径必须是绝对路径，越界路径会被拒绝。

示例
  docker cp web:/etc/nginx/nginx.conf ./nginx.conf
  docker cp ./index.html web:/usr/share/nginx/html/
EOF
        ;;
    export)
        cat <<'EOF'
用法
  docker export [-o FILE] <容器名>

选项
  -o, --output FILE   写入文件；不给则输出到 stdout

说明
  把容器 rootfs 打成 tar。指定 -o 时目标文件已存在会失败。

注意
  容器运行中导出会告警：内容可能不一致。
EOF
        ;;
    ps)
        cat <<'EOF'
用法
  docker ps [-a] [-q]

选项
  -a, --all     包含已停止的容器
  -q, --quiet   只输出容器 ID

说明
  默认只显示 running/paused。
  -f/--filter 与 --no-trunc 被接受但忽略（支持列表见 docker help limits）。
EOF
        ;;
    logs)
        cat <<'EOF'
用法
  docker logs [-f] [-n N] <容器名>

选项
  -f, --follow      持续输出（tail -f）
  -n, --tail N      只显示最后 N 行；N 也可以是 all

说明
  日志来自 containers/<名>/run.log，前台运行时输出同时写终端和该文件。
  -t/--timestamps、--since、--until 被接受但忽略（脚本日志无时间戳）。
EOF
        ;;
    top)
        cat <<'EOF'
用法
  docker top <容器名>

说明
  列出 root 指向容器 rootfs 的进程（PID + CMD），容器必须处于 running。
EOF
        ;;
    wait)
        cat <<'EOF'
用法
  docker wait <容器名>

说明
  阻塞到容器不再处于 running/paused，然后输出退出码。
  被信号终止时输出 128+信号值。
EOF
        ;;
    port)
        cat <<'EOF'
用法
  docker port <容器名> [端口[/协议]]

说明
  ruri 共享主机网络，没有端口映射，因此没有输出，只校验容器存在。
  容器监听 0.0.0.0:PORT 就等于宿主监听该端口。
EOF
        ;;
    inspect)
        cat <<'EOF'
用法
  docker inspect [-f FORMAT] <镜像名|容器名>...

选项
  -f, --format FORMAT   格式化输出

说明
  -f '{{.字段}}' 这种单字段模板会被转成 jq 取字段；其它内容按 jq 表达式处理。
  同名时优先按容器解析，找不到再按镜像解析。
  --type 被接受但忽略。

示例
  docker inspect web
  docker inspect -f '{{.State.Pid}}' web
  docker inspect -f '.Config.Env' web
EOF
        ;;
    info)
        cat <<'EOF'
用法
  docker info

说明
  打印数据目录、运行时路径、是否自动 -S、ruri 是否支持 --auto-umount、
  QEMU 路径、镜像数与容器数、网络模型。
EOF
        ;;
    help)
        cat <<'EOF'
用法
  docker help [<命令>|options|env|limits|all]

主题
  <命令>     该命令的用法、选项、示例与注意
  options    create/run 可用的 docker 选项：映射与忽略
  env        环境变量
  limits     已知差异与限制
  all        打印以上全部

示例
  docker help
  docker help run
  docker help options
EOF
        ;;
    version)
        cat <<'EOF'
用法
  docker version

说明
  打印 docker2ruri 版本，以及 ruri 的版本行。
EOF
        ;;
    esac
}

_help_cmd() {
    local cmd="$1" row grp desc opts
    local found=false
    for row in "${_HELP_ROWS[@]}"; do
        if [[ "${row%%$'\t'*}" == "$cmd" ]]; then
            IFS=$'\t' read -r _ grp desc opts <<< "$row"
            found=true
            break
        fi
    done
    if ! $found; then
        return 1
    fi
    printf 'docker %s — %s\n\n' "$cmd" "$desc"
    _help_detail "$cmd"
    printf '\n相关\n  选项映射: docker help options   限制: docker help limits\n'
}

_help_all() {
    _help_overview
    printf '\n'
    local row cmd
    for row in "${_HELP_ROWS[@]}"; do
        cmd="${row%%$'\t'*}"
        printf '================================================================\n'
        _help_cmd "$cmd"
        printf '\n'
    done
    printf '================================================================\n'
    _help_options
    printf '\n'
    _help_env
    printf '\n'
    _help_limits
}

show_help() {
    local topic="${1:-}"
    case "$topic" in
    ""|overview|--help|-h) _help_overview ;;
    options|opt) _help_options ;;
    env|environment) _help_env ;;
    limits|limit) _help_limits ;;
    all) _help_all ;;
    *)
        if ! _help_cmd "$topic"; then
            echo "未知帮助主题: $topic" >&2
            echo "可用: <命令> | options | env | limits | all（不带参数看总览）" >&2
            return 1
        fi
        ;;
    esac
}

preflight_check() {
    [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux"
    [[ "$EUID" -eq 0 ]] || die "需要 root 权限（chroot 必需）"
    [[ -d /proc/self ]] || die "/proc 未挂载"
    local bv
    bv=${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        die "需要 bash >= 4.4，当前 $bv"
    fi
}

# ====================== 入口 ======================
main() {
    local subcmd="${1:-help}"

    case "$subcmd" in
    help|--help|-h) show_help "${2:-}"; exit 0 ;;
    version|--version) cmd_version; exit 0 ;;
    esac

    # docker <命令> --help：--help 不是任何子命令自己的选项，可以在这里统一拦截。
    # （-h 不能拦：run/create 的 -h 是 --hostname）
    if [[ "${2:-}" == "--help" ]]; then
        show_help "$subcmd"
        exit $?
    fi

    preflight_check
    ensure_data_dir
    check_deps
    shift || true
    case "$subcmd" in
    pull)     cmd_pull "$@" ;;
    images)   cmd_images "$@" ;;
    rmi)      cmd_rmi "$@" ;;
    create)   cmd_create "$@" ;;
    run)      cmd_run "$@" ;;
    start)    cmd_start "$@" ;;
    stop)     cmd_stop "$@" ;;
    restart)  cmd_restart "$@" ;;
    kill)     cmd_kill "$@" ;;
    pause)    cmd_pause "$@" ;;
    unpause)  cmd_unpause "$@" ;;
    ps)       cmd_ps "$@" ;;
    logs)     cmd_logs "$@" ;;
    exec)     cmd_exec "$@" ;;
    rm)       cmd_rm "$@" ;;
    tag)      cmd_tag "$@" ;;
    rename)   cmd_rename "$@" ;;
    wait)     cmd_wait "$@" ;;
    top)      cmd_top "$@" ;;
    cp)       cmd_cp "$@" ;;
    export)   cmd_export "$@" ;;
    port)     cmd_port "$@" ;;
    commit)   cmd_commit "$@" ;;
    save)     cmd_save "$@" ;;
    load)     cmd_load "$@" ;;
    inspect)  cmd_inspect "$@" ;;
    info)     cmd_info ;;
    *)        die "不支持的子命令: $subcmd（build/push/login/network/volume/system 等未实现）" ;;
    esac
}

main "$@"