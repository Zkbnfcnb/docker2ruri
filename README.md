# docker2ruri

用 [ruri](https://github.com/Moe-hacker/ruri) 直接运行 OCI 镜像的 **docker CLI 兼容层**。
不需要 dockerd、不需要 systemd —— 一条 `docker run` 就能把镜像的 rootfs 跑成容器。

- 单文件 bash 脚本（`docker.sh`），依赖少、可直接审计
- 命令与选项按 docker 习惯实现，选项**按命令划分**（`run` 的选项 `start` 不认）
- 镜像、容器、日志都落在普通目录里，没有后台守护进程
- 明确区分「已映射」「仅记录」「接受但忽略」三类 docker 选项，不静默吞参数

---

## 1. 它解决什么问题

很多环境（轻量 VM、CI runner、嵌入式设备、容器里再跑容器）装不了或不想装 dockerd，
但已经能用 ruri 跑 rootfs。本项目把常用的 docker 命令翻译成 ruri 调用，让你继续用
`pull / run / ps / logs / exec / commit` 这套熟悉的操作。

**它不是什么**：不是 dockerd 的重实现。没有镜像分层、没有网络插件、没有卷驱动、
没有 `build/push/login`。

---

## 2. 安装

### 依赖

| 类型 | 依赖 | 说明 |
| --- | --- | --- |
| 必需 | Linux + root、bash ≥ 4.4 | chroot 需要 root |
| 必需 | `ruri` | 容器运行时，默认路径 `/root/ruri/ruri` |
| 必需 | `skopeo`、`umoci`、`jq`、`tar` | 拉取/解包/解析镜像 |
| 可选 | `timeout` | 拉取镜像的超时保护 |
| 可选 | `rsync` | `commit` 更快、保留权限与硬链接 |
| 可选 | `flock` | 数据目录与容器的并发锁 |
| 可选 | util-linux 的 `script` | `exec -t` 分配 PTY |

```bash
# Debian/Ubuntu
apt install util-linux skopeo umoci jq tar rsync
# Alpine
apk add util-linux skopeo umoci jq tar rsync
```

### 部署

```bash
install -m 755 docker.sh /usr/local/bin/docker2ruri
# 想直接当 docker 用（注意不要覆盖系统已有的 docker）
ln -s /usr/local/bin/docker2ruri /usr/local/bin/docker

# ruri 不在默认路径时
export RURI_BIN=/opt/ruri/ruri
```

`docker.sh` 会在需要时自动创建数据目录（默认 `~/.local/share/docker-sh`）。

---

## 3. 快速开始

下面用 `docker` 代指本脚本（即 `docker2ruri`）。

```bash
# 拉取镜像（默认镜像源 ghcr.io）
docker pull alpine:latest
docker images

# 前台运行，退出即结束
docker run --rm alpine:latest echo hello

# 后台运行；容器监听什么端口，宿主就是什么端口（共享主机网络，见第 6 节）
docker run -d --name web nginx:alpine
docker ps
docker logs -f web
docker exec -it web sh
docker stop web && docker rm web

# 把容器当前状态提交成新镜像
docker run -it --name work alpine:latest sh
docker stop work
docker commit work myimg:snapshot
docker run --rm myimg:snapshot cat /etc/os-release
```

`docker run` 的镜像选项必须写在镜像名之前，镜像名之后一律是容器命令：

```bash
docker run -it --rm -v "$PWD:/work" -w /work -e TZ=Asia/Shanghai alpine:latest sh
docker run alpine -- sh -c 'ls -l'     # 容器命令以 - 开头时，用 -- 交给 ruri
```

---

## 4. 命令一览

命令按用途分组，**每行「选项」列只列该命令自己接受的选项**。完整用法用
`docker help <命令>` 查看。

### 镜像

| 命令 | 说明 | 选项 |
| --- | --- | --- |
| `pull IMAGE[:TAG]` | 拉取镜像到本地数据目录 | `--platform OS/ARCH` |
| `images` | 列出本地镜像 | `-q/--quiet` |
| `rmi IMAGE[:TAG]` | 删除镜像 | `-f/--force` |
| `tag SRC DST` | 给镜像增加标签 | 无 |
| `save IMAGE [FILE]` | 导出镜像为 tar | `-o/--output FILE` |
| `load [FILE.tar]` | 从 tar 导入镜像 | `-i/--input FILE` |

### 容器

| 命令 | 说明 | 选项 |
| --- | --- | --- |
| `create IMAGE [CMD...]` | 创建容器，不启动 | `--name`、`-i`、`-t`、`-it`、`--rm`、`-p`（仅告警）、镜像选项 |
| `run IMAGE [CMD...]` | 创建并启动容器 | `-d/--detach`、`--name`、`-i`、`-t`、`-it`、`--rm`、`-p`（仅告警）、镜像选项 |
| `start NAME` | 启动已有容器 | `-a/--attach`、`-i/--interactive` |
| `stop NAME` | 停止容器 | `-t/--timeout 秒` |
| `restart NAME` | 重启容器 | `-t/--timeout 秒` |
| `kill NAME` | 向容器 init 发信号 | `-s/--signal`（默认 KILL） |
| `pause NAME` / `unpause NAME` | 冻结 / 解冻容器 | 无 |
| `rm NAME` | 删除容器 | `-f/--force`、`-v` |
| `rename OLD NEW` | 重命名容器 | 无 |
| `commit NAME NEWIMAGE` | 提交容器为新镜像 | `-f/--force` |

### 容器内操作

| 命令 | 说明 | 选项 |
| --- | --- | --- |
| `exec NAME CMD...` | 在运行中的容器里执行命令 | `-i`、`-t`、`-it`、`-u/--user`、`-w/--workdir`、`-e/--env`、`--env-file` |
| `cp SRC DST` | 宿主与容器之间复制文件 | 无 |
| `export NAME` | 导出容器 rootfs 为 tar | `-o/--output FILE` |

### 观测与信息

| 命令 | 说明 | 选项 |
| --- | --- | --- |
| `ps` | 列出容器 | `-a/--all`、`-q/--quiet` |
| `logs NAME` | 查看容器日志 | `-f/--follow`、`-n/--tail N` |
| `top NAME` | 列出容器内进程 | 无 |
| `wait NAME` | 等待容器退出并输出退出码 | 无 |
| `port NAME` | 端口映射（共享主机网络，无输出） | 无 |
| `inspect NAME...` | 输出镜像/容器的 docker 风格 JSON | `-f/--format` |
| `info` | 打印数据目录与运行时信息 | 无 |

### 其他

| 命令 | 说明 | 选项 |
| --- | --- | --- |
| `help [主题]` | 显示帮助 | `<命令>`、`options`、`env`、`limits`、`all` |
| `version` | 打印版本 | 无 |

---

## 5. 选项归属：`run` 和 `start` 不是一套选项

这是本脚本与「一个大 help 页」最大的区别：**选项按命令归属，跨命令使用会直接报错**。

```bash
# 正确：run 有自己的 -d/--name/--rm，以及镜像选项
docker run -d --name web -e TZ=Asia/Shanghai nginx:alpine

# 正确：start 只有 -a / -i
docker start -a web

# 错误：start 不认 -e、--rm、-d（会报「未知参数」）
docker start -e TZ=Asia/Shanghai web
```

| 命令 | 自己的选项 | 不接受 |
| --- | --- | --- |
| `create`、`run` | `--name`、`-i`、`-t`、`--rm`、镜像选项（`-e/-v/-w/-u/...`） | — |
| `start` | `-a`、`-i` | 镜像选项、`--name`、`--rm` |
| `stop`、`restart` | `-t 秒` | 其它 |
| `kill` | `-s 信号` | 其它 |
| `exec` | `-i`、`-t`、`-u`、`-w`、`-e`、`--env-file` | 镜像选项中的 `-v/--mount` 等 |
| `ps`、`logs`、`inspect` | 见第 4 节各自一行 | 其它 |

两条位置规则：

1. **镜像选项必须写在镜像之前**。镜像名之后的参数一律作为容器命令保存。
2. 容器命令本身以 `-` 开头时，用 `--` 交给 ruri：

```bash
docker run alpine -- sh -c 'ls -l'
```

---

## 6. docker 选项支持矩阵（`create` / `run`）

### 已映射到 ruri

| docker 选项 | 行为 |
| --- | --- |
| `-e/--env K=V` | → ruri `-e K V`；`-e K` 取当前 shell 的变量，未定义则告警忽略 |
| `--env-file FILE` | 逐行 `K=V` 转为 `-e` |
| `-v/--volume SRC:DST` | 读写 bind → `-m SRC DST`；`:ro` → `-M SRC DST` |
| `--mount type=bind,...` | → `-m/-M`（不支持 volume/tmpfs） |
| `-w/--workdir` | → `-W`（ruri 的 `-w` 是 no-warnings） |
| `-u/--user` | → `-E` |
| `-h/--hostname` | → `-t`；默认共享 UTS 命名空间，只做 `/etc/hostname` 文件级注入 |
| `-m/--memory` | → `-l memory=512M`（单位自动大写） |
| `--cpus N` | → `-l cpupercent=N*100` |
| `--pids-limit N` | → `-l pids=N`（`-1` 表示不限，忽略） |
| `--privileged` | → `-p` |
| `--cap-add` / `--cap-drop` | → `-k` / `-d` |
| `--device SRC[:DST[:PERM]]` | → `-I DST名 MAJOR MINOR`（DST 必须在 `/dev` 下） |
| `--security-opt seccomp=default` | → `-s`（ruri 支持时） |
| `--security-opt no-new-privileges` | → `-n` |
| `--read-only` | → `-R`（ruri 未实现 `-R` 时告警忽略） |
| `--init` | → `--fork-as-init`（不支持时告警忽略） |
| `--net/--network none` | → `-x`（断网）；`host` 为默认行为 |
| `--platform OS/ARCH` | → `-a ARCH -q $RURI_QEMU_PATH`（未配置 QEMU 时告警忽略） |
| `--oom-score-adj N` | → `-O N` |

### 仅记录（`start` 时使用，`inspect` 可查）

`--entrypoint`（含 `""` 清空）、`--stop-signal`、`--stop-timeout`、`--add-host`、
`--dns`、`--dns-search`、`--dns-option`、`--label`、`--label-file`、`--cidfile`、
`--restart`、`--expose`、`--rm`。

其中 `--restart` 只记录策略：**没有守护进程，不会自动重启**。

### 接受但忽略（消费参数并告警）

`--ulimit`、`--log-driver`、`--log-opt`、`--cgroupns`、`--ipc`、`--pid`、`--userns`、
`--uts`、`--sysctl`、`--group-add`、`--link`、`--mac-address`、`--ip`、`--tmpfs`、
`--health-*`、`--shm-size`、`--memory-swap`、`--memory-reservation`、`--cpu-shares`、
`--cpu-quota`、`--cpu-period`、`--cpuset-cpus`、`--cpuset-mems`、`--blkio-weight`、
`--volumes-from`、`--network-alias`、`--no-healthcheck`、`--oom-kill-disable`、
`--disable-content-trust`。

清单之外的 `-` 开头参数会直接报错，并提示用 `--` 分隔容器命令。

---

## 7. 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DOCKER_DATA_DIR` | `$HOME/.local/share/docker-sh` | 镜像、容器、日志的存放目录 |
| `RURI_BIN` | `/root/ruri/ruri` | ruri 可执行文件 |
| `DOCKER_REGISTRY_MIRROR` | `ghcr.io` | `pull` 使用的镜像源前缀 |
| `RURI_QEMU_PATH` | 空 | 跨架构 `--platform` 使用的 QEMU，未设置则忽略 `--platform` |
| `RURI_HOST_RUNTIME` | `0` | `1` = 给 ruri 加 `-S`，bind 宿主 `/dev /sys /proc`（隔离性差） |
| `DOCKER_LOCK_WAIT` | `10` | 容器级锁等待秒数 |
| `WAIT_TIMEOUT_TICKS` | `30` | 等待容器进入 running 的轮询次数 |
| `WAIT_INTERVAL` | `0.2` | 轮询间隔秒数 |

---

## 8. 数据目录布局

```
$DOCKER_DATA_DIR/
├── images/
│   └── <repo_tag>/          # 例: library_alpine_latest
│       ├── bundle/rootfs/   # 解包后的 rootfs
│       ├── bundle/config.json
│       ├── oci/             # skopeo 拉下的 OCI layout
│       ├── .ref             # repo:tag
│       └── .pulled_at
└── containers/
    └── <name>/
        ├── rootfs/          # 容器自己的 rootfs
        ├── run.log          # 容器输出（logs 读这里）
        ├── .state           # created/running/paused/exited
        ├── .pid / .pid_start
        ├── .ruri_args       # 传给 ruri 的参数
        ├── .cmd_args        # 容器启动命令
        ├── .image_config.json
        ├── .user_args / .user_cmd
        ├── .etc/            # hosts / hostname / resolv.conf 注入
        └── volumes/         # 镜像匿名卷
```

删数据目录前先 `docker ps -a` 确认没有运行中的容器，并清理遗留挂载：
`mount | grep "$DOCKER_DATA_DIR"`。

---

## 9. 已知差异与限制

1. **没有 dockerd**：无镜像分层、无守护进程、无 `build/push/login/network/volume/system`
   子命令。容器 = 一个 ruri 进程 + 一个 rootfs 目录。
2. **共享主机网络**：`--net none` 可用，其它网络模式与 `-p` 端口映射不支持。
   容器监听 `0.0.0.0:PORT` 等于宿主监听该端口，所以 `-p 8080:80` 不会报错但也不生效。
3. **没有卷管理**：`--mount type=volume|tmpfs` 不支持，`-v` 只做 bind 挂载。
4. **没有健康检查**；`--ulimit`、`--sysctl`、`--ipc` 等选项接受但忽略。
5. `save` / `load` 是本脚本自有的目录 tar，**不是 docker save 格式**。
6. 不支持 digest 引用（`IMG@sha256:...`），请用 tag。
7. `commit` 生成扁平化全量快照，不是 OCI 分层镜像；容器必须已停止。
8. `pause` / `unpause` 依赖 ruri `--freeze/--thaw` 与 cgroup v2；暂停期间不响应
   `stop/kill`，需先 `unpause`（`rm -f` 会先自动解冻）。
9. `exec` 只能进入运行中的容器；优先加入已有命名空间，失败时退化为针对同一 rootfs
   启动新进程。
10. 容器内 `/dev /proc /sys` 默认由 ruri 自建（与 docker 默认一致）。需要宿主设备时用
    `--device`，或设置 `RURI_HOST_RUNTIME=1`。
11. 前台 attach（`start -a`、`run` 不加 `-d`）时 Ctrl-C 会转发给容器；容器未退出时脚本
    会走完整 stop，容器因此被终止。
12. 容器 ID 是随机 hex，不是 docker 的 sha256；`rename` 后不变。

---

## 10. 帮助

```bash
docker help              # 总览：命令分组，每个命令只列自己的选项
docker help run          # 单命令：用法 / 选项 / 示例 / 注意
docker help start
docker help options      # create/run 的 docker 选项：映射与忽略
docker help env          # 环境变量与依赖
docker help limits       # 已知差异与限制
docker help all          # 全部打印
docker run --help        # 等价于 docker help run
```

---

## 11. 测试

```bash
bash tests/lint.sh     # shellcheck -S warning + bash -n
bash tests/smoke.sh    # 假 ruri 桩 + 假镜像，不触碰真实镜像与容器
```

`smoke.sh` 覆盖：容器名路径穿越、未知选项与参数错位、镜像后命令与 `--` 分隔、
`-v`/`--mount` 挂载、entrypoint/env-file/add-host/dns、前台退出码与日志、
`--rm` 与后台启动、`inspect` 路径穿越、并发同名创建、镜像 config 同步、
`start` 刷新 `.etc`、`STOPSIGNAL`、`commit`、ps/images/tag/rename/cp/export/kill、
save/load、pause、`--oom-score-adj`、Ctrl-C 信号转发。

测试失败时按小节输出定位；`smoke.sh` 会在退出时清理临时目录与容器进程。

---

## 12. 故障排查

| 现象 | 排查方向 |
| --- | --- |
| `缺少依赖工具：xxx` | 按第 2 节安装；ruri 路径用 `RURI_BIN` 指定 |
| `需要 root 权限` | 用 root 运行（chroot 必需） |
| 容器起不来 | `docker logs <名>`；再确认 `docker info` 里的 ruri 路径 |
| `等待容器锁超时` | 调大 `DOCKER_LOCK_WAIT`；旧版本启动的容器可能继承了锁 fd，`stop/rm` 会自动降级 |
| 挂载泄漏 | `mount \| grep "$DOCKER_DATA_DIR"`，再 `umount` 残留路径 |
| `pause` 报不支持 | 需要 cgroup v2 且 ruri 支持 `--freeze` |
| `exec -t` 没有 PTY | 宿主 `/dev/pts` 未挂载 devpts，脚本会尝试自动挂载并给出修复命令 |
| `--platform` 无效 | 设置 `RURI_QEMU_PATH`（如 `/usr/bin/qemu-aarch64`） |

---

## 13. 项目结构

```
.
├── docker.sh          # 全部实现（CLI 解析、镜像、容器、help）
├── tests/
│   ├── lint.sh        # shellcheck + bash -n
│   └── smoke.sh       # 端到端冒烟测试（假 ruri）
└── memory/            # 项目连续性记录（PROJECT/DECISIONS/SESSIONS）
```
