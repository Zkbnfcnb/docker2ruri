#!/usr/bin/env bash
# docker.sh smoke test：用假 ruri 桩 + 假镜像验证参数解析、路径安全与生命周期。
# 用法: bash tests/smoke.sh [docker.sh 路径]
set -uo pipefail

SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)/docker.sh}"
TMP=$(mktemp -d)
export DOCKER_DATA_DIR="$TMP/data"
export RURI_BIN="$TMP/ruri-stub"
LOG_DIR="$TMP/logs"

cleanup() {
    if [[ -d "$DOCKER_DATA_DIR/containers" ]]; then
        for pidf in "$DOCKER_DATA_DIR"/containers/*/.pid; do
            [[ -f "$pidf" ]] || continue
            pid=$(cat "$pidf" 2>/dev/null || true)
            [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
        done
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

mkdir -p "$LOG_DIR"
d() { bash "$SRC" "$@"; }

# ---- 假 ruri ----
cat > "$RURI_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "${RURI_STUB_LOG:-/tmp/ruri-argv.log}"
case "${1:-}" in
--help)
    cat <<'H'
  -m, --mount   -M, --ro-mount   -e, --env   -S, --host-runtime
  -b, --background   -L, --logfile   --pid-file   --auto-umount
  --freeze --thaw -O --oom-score-adj --health-check
  --fork-as-init   --enable-seccomp   -N, --no-rurienv   -J, --join-ns
  -U, --umount   -P, --ps   -E, --user   -W, --work-dir   -l, --limit
  -z, --enable-tty-signals   -I, --char-dev   -n, --no-new-privs
H
    exit 0 ;;
--version) echo "ruri 3.9.5 (stub)"; exit 0 ;;
--freeze|--thaw) exit 0 ;;
-U|--umount) exit 0 ;;
esac
pidfile=""; logfile=""; prev=""
for a in "$@"; do
    [[ "$prev" == "--pid-file" ]] && pidfile="$a"
    [[ "$prev" == "-L" || "$prev" == "--logfile" ]] && logfile="$a"
    prev="$a"
done
if [[ -n "$pidfile" ]]; then
    if [[ -n "$logfile" ]]; then
        echo "stub-bg-1" >> "$logfile"
        echo "stub-run-end" >> "$logfile"
    fi
    (
        # 模拟 ruri 退出时把 RURI_SIGNALED_<sig> 写回 pidfile
        trap 'echo "RURI_SIGNALED_15" > "$pidfile"; echo TERM >> "${RURI_SIG_LOG:-/dev/null}"; exit 0' TERM
        trap 'echo "RURI_SIGNALED_3" > "$pidfile"; echo QUIT >> "${RURI_SIG_LOG:-/dev/null}"; exit 0' QUIT
        while :; do sleep 0.2; done
    ) &
    echo "$!" > "$pidfile"
    exit 0
fi
if [[ "${RURI_WAIT_SIG:-}" == "1" ]]; then
    trap 'echo INT >> "${RURI_SIG_LOG:-/dev/null}"; exit 0' INT
    trap 'echo TERM >> "${RURI_SIG_LOG:-/dev/null}"; exit 0' TERM
    while :; do sleep 0.2; done
fi
echo "stub-run-1"
echo "stub-run-end"
exit 7
STUB
chmod +x "$RURI_BIN"

# ---- 假镜像 ----
IMG="$DOCKER_DATA_DIR/images/library_alpine_latest"
mkdir -p "$IMG/bundle/rootfs/etc"
echo '{"process":{"args":["/bin/sh"]}}' > "$IMG/bundle/config.json"
echo "alpine:latest" > "$IMG/.ref"

rargs() { tr '\0' '\n' < "$DOCKER_DATA_DIR/containers/$1/.ruri_args"; }
cargs() { tr '\0' '\n' < "$DOCKER_DATA_DIR/containers/$1/.cmd_args"; }

echo "== 1. 容器名路径穿越 =="
mkdir -p "$TMP/evil"; echo x > "$TMP/evil/f"
if d rm ../../evil >/dev/null 2>&1; then fail "rm ../../evil 未被拒绝"; fi
[[ -f "$TMP/evil/f" ]] || fail "路径穿越导致外部文件被删除"
if d stop '..' >/dev/null 2>&1; then fail "stop .. 未被拒绝"; fi
if d logs 'a/b' >/dev/null 2>&1; then fail "logs a/b 未被拒绝"; fi
ok "非法容器名被拒绝且未触碰外部路径"

echo "== 2. 未知选项 / 参数错位 =="
if d run --foo bar alpine >/dev/null 2>&1; then fail "未知选项 --foo 未报错"; fi
if d create --foo bar alpine >/dev/null 2>&1; then fail "create 未知选项未报错"; fi
d create --name t2 --ulimit 100 alpine >/dev/null 2>&1 || fail "--ulimit 不应阻塞创建"
[[ "$(cargs t2)" == "/bin/sh" ]] || fail "--ulimit 的值被当成命令: $(cargs t2)"
ok "未知选项明确报错，带值选项不会错位"

echo "== 3. 镜像后命令 / -- 分隔 =="
d create --name t3 alpine -x -y || fail "镜像后命令失败"
[[ "$(cargs t3 | tr '\n' ' ')" == "-x -y " ]] || fail "镜像后命令保存错误: $(cargs t3 | tr '\n' ' ')"
ok "镜像之后的参数完整作为容器命令"

echo "== 4. 文件挂载 BIND: 与目标创建 =="
echo hostdata > "$TMP/hostfile"
mkdir -p "$TMP/hostdir"; echo y > "$TMP/hostdir/f"
d create --name t4 -v "$TMP/hostfile:/etc/myfile:ro" alpine >/dev/null || fail "-v 文件挂载失败"
rargs t4 | grep -qx -- "-M" || fail "-v :ro 未映射为 -M"
rargs t4 | grep -q "BIND:$TMP/hostfile" || fail "文件源未加 BIND: 前缀"
[[ -f "$DOCKER_DATA_DIR/containers/t4/rootfs/etc/myfile" ]] || fail "容器内文件目标未创建"
d create --name t5 -v "$TMP/hostdir:/data" alpine >/dev/null || fail "-v 目录挂载失败"
[[ -d "$DOCKER_DATA_DIR/containers/t5/rootfs/data" ]] || fail "容器内目录目标未创建"
ok "文件挂载使用 BIND:，目标自动创建"

echo "== 5. --mount =="
d create --name t6 --mount "type=bind,source=$TMP/hostdir,target=/mnt/data,readonly" alpine >/dev/null \
    || fail "--mount bind 失败"
rargs t6 | grep -qx -- "-M" || fail "--mount readonly 未映射为 -M"
rargs t6 | grep -qx -- "/mnt/data" || fail "--mount target 未传入"
[[ -d "$DOCKER_DATA_DIR/containers/t6/rootfs/mnt/data" ]] || fail "--mount 目标未创建"
if d create --name t7 --mount "type=volume,source=v,target=/x" alpine >/dev/null 2>&1; then
    fail "type=volume 应报错"
fi

# 逗号路径：反斜杠转义 / 引号 / target 含逗号 / readonly=false
mkdir -p "$TMP/dir,comma"; echo comma > "$TMP/dir,comma/f"
d create --name t6b --mount "type=bind,source=$TMP/dir\\,comma,target=/mnt/comma,readonly" alpine >/dev/null \
    || fail "反斜杠转义 --mount 失败"
rargs t6b | grep -qx -- "$TMP/dir,comma" || fail "反斜杠转义路径错误: $(rargs t6b | tr '\n' ' ')"
rargs t6b | grep -qx -- "/mnt/comma" || fail "逗号路径 target 错误"
d create --name t6c --mount "type=bind,source=\"$TMP/dir,comma\",target=/mnt/comma2" alpine >/dev/null \
    || fail "引号转义 --mount 失败"
rargs t6c | grep -qx -- "$TMP/dir,comma" || fail "引号路径错误"
d create --name t6d --mount "type=bind,source=$TMP/hostdir,target=/mnt/a,b" alpine >/dev/null \
    || fail "target 含逗号失败"
rargs t6d | grep -qx -- "/mnt/a,b" || fail "target 含逗号解析错误"
d create --name t6e --mount "type=bind,source=$TMP/hostdir,target=/mnt/ro,readonly=false" alpine >/dev/null \
    || fail "readonly=false 失败"
if rargs t6e | grep -qx -- "-M"; then fail "readonly=false 不应出现 -M"; fi
if d create --name t6f --mount "type=bind,source=$TMP/hostdir,target=/x,foo=bar" alpine >/dev/null 2>&1; then
    fail "未知字段应报错"
fi
if d create --name t6h --mount "source=$TMP/hostdir,target=/x" alpine >/dev/null 2>&1; then
    fail "省略 type 应按 docker 默认 volume 报错"
fi
d create --name t6g --mount "type=tmpfs,target=/tmpfs" alpine >/dev/null 2>&1 || fail "tmpfs 应忽略而不是失败"
ok "--mount 支持逗号转义/引号/别名/readonly=false，未知字段与 volume 报错"

echo "== 6. entrypoint / env-file / add-host / dns =="
d create --name t8 --entrypoint /bin/echo alpine hello >/dev/null || fail "entrypoint 失败"
[[ "$(cargs t8 | tr '\n' ' ')" == "/bin/echo hello " ]] || fail "entrypoint 合并错误: $(cargs t8 | tr '\n' ' ')"
printf 'A=1\n# comment\nB=two words\n' > "$TMP/env"
d create --name t9 --env-file "$TMP/env" alpine >/dev/null || fail "env-file 失败"
rargs t9 | grep -qx -- "A" || fail "env-file A 未注入"
rargs t9 | grep -qx -- "two words" || fail "env-file B 未注入"
d create --name t10 --add-host myhost:10.0.0.1 --dns 1.1.1.1 alpine >/dev/null || fail "add-host/dns 失败"
grep -q "10.0.0.1 myhost" "$DOCKER_DATA_DIR/containers/t10/.etc/hosts" || fail "add-host 未写入 hosts"
grep -q "nameserver 1.1.1.1" "$DOCKER_DATA_DIR/containers/t10/.etc/resolv.conf" || fail "dns 未写入 resolv.conf"
ok "entrypoint/env-file/add-host/dns 生效"

echo "== 7. 前台 run：退出码 / 日志 / 状态 =="
set +e
d run --name t11 alpine >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 7 ]] || fail "前台 run 退出码应为 7，实际 $rc"
grep -q "stub-run-end" "$DOCKER_DATA_DIR/containers/t11/run.log" || fail "日志尾部丢失（tee 未刷完）"
[[ "$(cat "$DOCKER_DATA_DIR/containers/t11/.state")" == "exited" ]] || fail "状态未更新为 exited"
ok "前台运行退出码透传，日志完整，状态正确"

echo "== 8. --rm / 后台 run / stop / logs 参数顺序 =="
d run --rm --name t12 alpine >/dev/null 2>&1 || true  # 桩固定 exit 7
[[ -d "$DOCKER_DATA_DIR/containers/t12" ]] && fail "--rm 后容器仍存在"
d run -d --name t13 alpine >/dev/null || fail "后台 run 失败"
sleep 0.3
d ps > "$TMP/ps.out"
grep -q t13 "$TMP/ps.out" || fail "ps 未显示运行中的容器"
d logs t13 -n 1 | grep -q "stub-run-end" || fail "logs NAME -n N 不可用"
d stop t13 >/dev/null || fail "stop 失败"
[[ "$(cat "$DOCKER_DATA_DIR/containers/t13/.state")" == "exited" ]] || fail "stop 后状态错误"
ok "--rm / 后台启动 / stop / logs 顺序参数正常"

echo "== 9. inspect 路径穿越 =="
if d inspect ../../etc >/dev/null 2>&1; then fail "inspect ../../etc 未被拒绝"; fi
ok "inspect 非法路径被拒绝"

echo "== 10. 并发同名 create =="
d create --name t14 alpine >/dev/null || fail "首次 create 失败"
if d create --name t14 alpine >/dev/null 2>&1; then fail "重复 create 未被拒绝"; fi
ok "同名容器创建被拒绝"

echo "== 11. 镜像 config 同步（Env/WorkingDir/User/Entrypoint/Cmd） =="
# 假镜像带完整 OCI layout，才能读到拆分后的 Entrypoint/Cmd
MIMG="$DOCKER_DATA_DIR/images/library_meta_latest"
mkdir -p "$MIMG/bundle/rootfs" "$MIMG/oci/blobs/sha256"
printf '%s' '{"process":{"args":["/entry","--img-cmd"]}}' > "$MIMG/bundle/config.json"
printf '%s' '{"architecture":"amd64","os":"linux","config":{"Env":["PATH=/bin","IMG=1"],"Cmd":["--img-cmd"],"Entrypoint":["/entry"],"WorkingDir":"/work","User":"1001","StopSignal":"SIGQUIT","Volumes":{"/data":{}},"Labels":{"org.example.label":"v1"},"ExposedPorts":{"8080/tcp":{}}}}' > "$MIMG/oci/blobs/sha256/cfg"
csum=$(sha256sum "$MIMG/oci/blobs/sha256/cfg" | cut -d' ' -f1)
mv "$MIMG/oci/blobs/sha256/cfg" "$MIMG/oci/blobs/sha256/$csum"
printf '%s' "{\"schemaVersion\":2,\"config\":{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"sha256:$csum\"},\"layers\":[]}" > "$MIMG/oci/blobs/sha256/mf"
msum=$(sha256sum "$MIMG/oci/blobs/sha256/mf" | cut -d' ' -f1)
mv "$MIMG/oci/blobs/sha256/mf" "$MIMG/oci/blobs/sha256/$msum"
printf '%s' "{\"schemaVersion\":2,\"manifests\":[{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:$msum\"}]}" > "$MIMG/oci/index.json"
echo "meta:latest" > "$MIMG/.ref"

d create --name m1 -e IMG=user -e X=1 meta >/dev/null || fail "meta 镜像 create 失败"
mr1=$(rargs m1 | tr '\n' ' ')
[[ "$mr1" == *"-e PATH /bin"* ]] || fail "镜像 Env 未注入: $mr1"
[[ "$mr1" == *"-e IMG user"* ]] || fail "用户 -e 未覆盖镜像 Env: $mr1"
[[ "$mr1" == *"-e HOSTNAME m1"* ]] || fail "HOSTNAME 未注入: $mr1"
[[ "$mr1" == *"-W /work"* ]] || fail "镜像 WorkingDir 未注入: $mr1"
[[ "$mr1" == *"-E 1001"* ]] || fail "镜像 User 未注入: $mr1"
[[ "$(cargs m1 | tr '\n' ' ')" == "/entry --img-cmd " ]] || fail "Entrypoint+Cmd 合并错误: $(cargs m1 | tr '\n' ' ')"
# 镜像 VOLUME：自动创建匿名卷并挂载
rargs m1 | grep -q "containers/m1/volumes/_data" || fail "镜像 Volumes 未挂载: $(rargs m1 | tr '\n' ' ')"
[[ -d "$DOCKER_DATA_DIR/containers/m1/volumes/_data" ]] || fail "匿名卷目录未创建"
# inspect 输出 docker 风格 JSON
d inspect m1 | jq -e '.[0].Config.Env | index("IMG=user") != null' >/dev/null || fail "inspect Config.Env 错误"
d inspect m1 | jq -e '.[0].Config.Labels["org.example.label"] == "v1"' >/dev/null || fail "inspect Labels 错误"
d inspect m1 | jq -e '.[0].Config.ExposedPorts["8080/tcp"] != null' >/dev/null || fail "inspect ExposedPorts 错误"

d create --name m2 meta hello >/dev/null || fail "用户命令 create 失败"
[[ "$(cargs m2 | tr '\n' ' ')" == "/entry hello " ]] || fail "用户命令未替换 CMD: $(cargs m2 | tr '\n' ' ')"

d create --name m3 --entrypoint /bin/sh meta -c 'echo hi' >/dev/null || fail "--entrypoint create 失败"
[[ "$(cargs m3 | tr '\n' ' ')" == "/bin/sh -c echo hi " ]] || fail "--entrypoint 覆盖错误: $(cargs m3 | tr '\n' ' ')"

d create --name m4 --entrypoint '' meta >/dev/null || fail "--entrypoint '' create 失败"
[[ "$(cargs m4 | tr '\n' ' ')" == "--img-cmd " ]] || fail "--entrypoint '' 未清空: $(cargs m4 | tr '\n' ' ')"
ok "镜像 Env/WorkingDir/User 注入，Entrypoint/Cmd 按 docker 语义合并"

echo "== 12. start 刷新 .etc 与镜像配置 =="
d create --name s1 --dns 8.8.8.8 meta >/dev/null || fail "s1 create 失败"
echo "1.1.1.1" > "$DOCKER_DATA_DIR/containers/s1/.dns"
d start s1 >/dev/null 2>&1 || true
sleep 0.3
grep -q "nameserver 1.1.1.1" "$DOCKER_DATA_DIR/containers/s1/.etc/resolv.conf" || fail "start 未刷新 resolv.conf"
rargs s1 | grep -qx "/work" || fail "start 后镜像 WorkingDir 丢失"
d stop s1 >/dev/null 2>&1 || true
ok "start 刷新 .etc 并重新同步镜像配置"

echo "== 13. stop 使用镜像 StopSignal =="
export RURI_SIG_LOG="$TMP/ruri-sig.log"
: > "$RURI_SIG_LOG"
d run -d --name s2 meta >/dev/null || fail "s2 run 失败"
d stop s2 >/dev/null || fail "s2 stop 失败"
grep -qx QUIT "$RURI_SIG_LOG" || fail "stop 未使用镜像 StopSignal: $(tr '\n' ' ' < "$RURI_SIG_LOG")"
unset RURI_SIG_LOG
ok "stop 使用镜像 STOPSIGNAL"

echo "== 14. commit 写回运行配置并排除 ruri 运行时文件 =="
m1dir="$DOCKER_DATA_DIR/containers/m1"
touch "$m1dir/rootfs/.rurienv" "$m1dir/rootfs/.ruri_umounted"
d commit m1 smoke/committed:1 >/dev/null || fail "commit 失败"
NIMG="$DOCKER_DATA_DIR/images/smoke_committed_1"
jq -e '.process.args == ["/entry","--img-cmd"]' "$NIMG/bundle/config.json" >/dev/null \
    || fail "commit 未写回 process.args"
jq -e '.process.env | index("IMG=user") != null' "$NIMG/bundle/config.json" >/dev/null \
    || fail "commit 未写回用户 Env"
jq -e '.process.env | index("HOSTNAME=m1") == null' "$NIMG/bundle/config.json" >/dev/null \
    || fail "commit 写入了运行时 HOSTNAME"
if [[ -e "$NIMG/bundle/rootfs/.rurienv" ]]; then fail "commit 带入了 .rurienv"; fi
if [[ -e "$NIMG/bundle/rootfs/.ruri_umounted" ]]; then fail "commit 带入了 .ruri_umounted"; fi
ok "commit 写回 args/env，排除 ruri 运行时文件"

echo "== 15. docker 命令兼容（ps/images/inspect/tag/rename/cp/export/kill/rm -f） =="
imgq=$(d images -q)
[[ -n "$imgq" ]] || fail "images -q 无输出"
d tag meta meta2 >/dev/null || fail "tag 失败"
d images > "$TMP/images.out"
grep -q "library/meta2" "$TMP/images.out" || fail "tag 后 images 未显示新标签"
d rename m1 m1x >/dev/null || fail "rename 失败"
[[ -d "$DOCKER_DATA_DIR/containers/m1x" ]] || fail "rename 后目录不存在"
d inspect m1x | jq -e '.[0].HostConfig.NetworkMode == "host"' >/dev/null || fail "inspect HostConfig 错误"
d cp m1x:/etc/hosts "$TMP/hosts-copy" >/dev/null || fail "cp 容器→宿主失败"
[[ -f "$TMP/hosts-copy" ]] || fail "cp 后文件不存在"
d export m1x -o "$TMP/export.tar" >/dev/null || fail "export 失败"
[[ -s "$TMP/export.tar" ]] || fail "export 输出为空"
d run -d --name s4 meta >/dev/null || fail "run s4 失败"
s4id=$(cat "$DOCKER_DATA_DIR/containers/s4/.id")
d ps -q > "$TMP/psq.out"
grep -qx "${s4id:0:12}" "$TMP/psq.out" || fail "ps -q 未输出容器 ID"
if d rm s4 >/dev/null 2>&1; then fail "rm 运行中容器未拒绝"; fi
d kill -s TERM s4 >/dev/null || fail "kill 失败"
d rm -f s4 >/dev/null || fail "rm -f 失败"
if [[ -d "$DOCKER_DATA_DIR/containers/s4" ]]; then fail "rm -f 后容器仍存在"; fi
ok "ps/images -q、inspect JSON、tag、rename、cp、export、kill、rm -f 正常"

echo "== 16. save/load、rmi -f、label/cidfile、exec 环境、后台 --rm =="
d save -o "$TMP/meta.tar" meta >/dev/null || fail "save -o 失败"
[[ -s "$TMP/meta.tar" ]] || fail "save -o 输出为空"
d rmi -f meta >/dev/null || fail "rmi -f 失败"
if [[ -d "$DOCKER_DATA_DIR/images/library_meta_latest" ]]; then fail "rmi -f 后镜像仍存在"; fi
d load -i "$TMP/meta.tar" >/dev/null || fail "load -i 失败"
[[ -d "$DOCKER_DATA_DIR/images/library_meta_latest" ]] || fail "load 后镜像不存在"
d create --name lb1 --label app=test --cidfile "$TMP/lb1.cid" --stop-timeout 1 meta >/dev/null     || fail "label/cidfile/stop-timeout create 失败"
grep -qx "app=test" "$DOCKER_DATA_DIR/containers/lb1/.labels" || fail "--label 未记录"
[[ -f "$TMP/lb1.cid" ]] || fail "--cidfile 未写入"
[[ "$(cat "$DOCKER_DATA_DIR/containers/lb1/.stop_timeout")" == "1" ]] || fail "--stop-timeout 未记录"
d inspect lb1 | jq -e '.[0].Config.Labels.app == "test"' >/dev/null || fail "inspect 未显示用户 --label"

d run -d --name ex1 meta >/dev/null || fail "ex1 run 失败"
export RURI_STUB_LOG="$TMP/exec-argv.log"
: > "$RURI_STUB_LOG"
d exec ex1 /bin/true >/dev/null 2>&1 || true
tr '\0' '\n' < "$RURI_STUB_LOG" | grep -qx IMG || fail "exec 未继承容器 Env"
if tr '\0' '\n' < "$RURI_STUB_LOG" | grep -q "DSH_SESSION_ID"; then fail "exec 注入了宿主环境"; fi
unset RURI_STUB_LOG
d kill -s TERM ex1 >/dev/null 2>&1 || true

d run -d --rm --name rm1 meta >/dev/null || fail "run -d --rm 失败"
d kill -s TERM rm1 >/dev/null 2>&1 || true
sleep 3
if [[ -d "$DOCKER_DATA_DIR/containers/rm1" ]]; then fail "后台 --rm 未删除容器"; fi
ok "save -o/load -i、rmi -f、label/cidfile/stop-timeout、exec 容器环境、后台 --rm 正常"

echo "== 17. 退出码 / pause / oom-score-adj =="
d run -d --name w1 --stop-signal TERM meta >/dev/null || fail "w1 run 失败"
d stop w1 >/dev/null || fail "w1 stop 失败"
rc=$(d wait w1)
[[ "$rc" == "143" ]] || fail "wait 未返回 128+SIGTERM: $rc"
d ps -a > "$TMP/ps2.out"
grep -q "Exited (143)" "$TMP/ps2.out" || fail "ps 未显示退出码: $(grep w1 "$TMP/ps2.out")"
d inspect w1 | jq -e '.[0].State.ExitCode == 143' >/dev/null || fail "inspect ExitCode 错误"
d run -d --name w2 meta >/dev/null || fail "w2 run 失败"
d stop w2 >/dev/null || fail "w2 stop 失败"
[[ "$(d wait w2)" == "131" ]] || fail "镜像 StopSignal 未生效（应为 128+SIGQUIT=131）"

d run -d --name p1 meta >/dev/null || fail "p1 run 失败"
d pause p1 >/dev/null || fail "pause 失败"
[[ "$(cat "$DOCKER_DATA_DIR/containers/p1/.state")" == "paused" ]] || fail "pause 后状态错误"
d ps > "$TMP/ps3.out"
grep -q "(Paused)" "$TMP/ps3.out" || fail "ps 未显示 Paused"
if d stop p1 >/dev/null 2>&1; then fail "暂停容器 stop 未拒绝"; fi
d unpause p1 >/dev/null || fail "unpause 失败"
[[ "$(cat "$DOCKER_DATA_DIR/containers/p1/.state")" == "running" ]] || fail "unpause 后状态错误"
d stop p1 >/dev/null 2>&1 || true

d create --name o1 --oom-score-adj 100 meta >/dev/null || fail "oom create 失败"
rargs o1 | grep -qx "\-O" || fail "oom-score-adj 未生成 -O"
rargs o1 | grep -qx "100" || fail "oom-score-adj 未传入值"
if d create --name o2 --oom-score-adj 2000 meta >/dev/null 2>&1; then fail "oom-score-adj 越界未拒绝"; fi
ok "wait 退出码、pause/unpause、oom-score-adj 正常"

echo "== 18. 前台 Ctrl+C 信号转发 =="
d create --name sig1 meta >/dev/null || fail "sig1 create 失败"
if command -v python3 >/dev/null 2>&1; then
    export RURI_SIG_LOG="$TMP/foreground-sig.log"
    : > "$RURI_SIG_LOG"
    # 用 Python 发 SIGINT：`bash ... &` 启动的脚本会继承“忽略 SIGINT”，
    # 无法模拟真实 Ctrl+C（前台进程组）
    if ! RURI_WAIT_SIG=1 python3 - "$SRC" <<'PYEOF'
import os, signal, subprocess, sys, time
src = sys.argv[1]
p = subprocess.Popen(["bash", src, "start", "-a", "sig1"],
                     env=os.environ.copy(),
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1.2)
p.send_signal(signal.SIGINT)
try:
    p.wait(timeout=6)
except subprocess.TimeoutExpired:
    p.kill()
    sys.exit(1)
PYEOF
    then
        fail "Ctrl+C 后脚本未退出"
    fi
    grep -qx INT "$RURI_SIG_LOG" || fail "SIGINT 未转发给 ruri: $(cat "$RURI_SIG_LOG" 2>/dev/null)"
    st=$(cat "$DOCKER_DATA_DIR/containers/sig1/.state" 2>/dev/null)
    [[ "$st" == "exited" ]] || fail "Ctrl+C 后容器状态错误: $st"
    unset RURI_SIG_LOG
    ok "前台 Ctrl+C 转发给 ruri 并停止容器"
else
    ok "(skip) 无 python3，跳过 Ctrl+C 信号测试"
fi

echo "== 19. help 按命令分类 =="
# help 不能依赖 preflight_check（root / 依赖），因此在子 shell 里去掉运行时依赖跑
help_out() { bash "$SRC" help "$@" 2>&1; }
overview=$(help_out)
for c in pull images rmi tag save load create run start stop restart kill pause \
         unpause rm rename commit exec cp export ps logs top wait port inspect info; do
    printf '%s\n' "$overview" | grep -qE "^  $c +[^ ]" || fail "help 总览缺少命令: $c"
done
# 每个命令的选项必须挂在它自己名下：run 有 -d，start 只有 -a/-i
printf '%s\n' "$overview" | grep -q -- "-d/--detach" || fail "help 总览缺少 run 的 -d"
run_h=$(help_out run)
[[ "$run_h" == *"--name"* ]] || fail "docker help run 缺少 --name"
[[ "$run_h" == *"-d, --detach"* ]] || fail "docker help run 缺少 --detach"
start_h=$(help_out start)
[[ "$start_h" == *"-a, --attach"* ]] || fail "docker help start 缺少 -a"
if [[ "$start_h" == *"--name"* ]]; then fail "docker help start 不应出现 run 的 --name"; fi
# 主题与错误路径
help_out options | grep -q -- "映射为 ruri" || fail "docker help options 内容异常"
help_out env | grep -q "DOCKER_DATA_DIR" || fail "docker help env 缺少环境变量"
help_out limits | grep -q "已知差异" || fail "docker help limits 内容异常"
if bash "$SRC" help nosuch >/dev/null 2>&1; then fail "未知帮助主题应返回非 0"; fi
bash "$SRC" run --help >/dev/null 2>&1 || fail "docker run --help 失败"
ok "help 总览按命令分组，单命令只列自己的选项"

echo "ALL PASS"
