# DEEIX Chat 单机生产部署

目标为 `deeix.motion-cover.com`，宿主目录 `/opt/deeix-chat`，使用现有 Woodpecker 3.17 Docker 后端。应用由根 `Dockerfile` 同时构建 Go API 与 Next.js 静态页面，发布为宿主本地镜像 `local/deeix-chat:<完整 SHA>`。应用使用 SQLite、内存缓存和本地文件存储，只监听宿主 `127.0.0.1:3180`，由宿主 Nginx 提供 HTTPS。

## 文件与持久化

| 文件或目录 | 用途 |
| --- | --- |
| `.woodpecker/deploy.yml` | 仅 `dev` 分支的 `push` / `manual` 事件，构建测试成功后部署 |
| `build.sh` | 使用独立 BuildKit builder 测试后端并构建同源运行镜像 |
| `deploy.sh` | 校验镜像、保存一致性快照、切换、健康和 commit 验证、失败恢复 |
| `/opt/deeix-chat/config.yaml` | 服务器私有配置，权限 `0600`，不进入 Git 或构建上下文 |
| `/opt/deeix-chat/data/` | SQLite 数据库及 WAL 文件 |
| `/opt/deeix-chat/storage/` | 附件等本地存储 |
| `/opt/deeix-chat/image.env` | 当前 Compose 镜像标记，原子更新 |
| `/opt/deeix-chat/maintenance.flag` | Nginx 发布维护闸门；存在时业务请求返回带专用响应头的 HTTP 503 |
| `/opt/deeix-chat/current-release.json` | 已通过探针的 SHA、版本、镜像 ID、时间和备份目录名 |
| `/opt/deeix-chat/{health,readiness,version}.json` | 最近成功探针的原始 JSON；回滚成功后更新为恢复实例的结果 |
| `/opt/deeix-chat/backups/` | 发布前的配置、元数据、`state.tar` 及失败状态；不自动清理 |
| `/opt/deeix-chat/docker-client/` | 共用的 Docker / buildx 客户端元数据，不放注册表凭据 |

`state.tar` 在旧应用完全停止后保存 `data/` 和 `storage/`，使 SQLite、WAL 和附件保持一致。部署根目录必须为 `0755`，让 Nginx worker 能检查维护标记；私有配置保持 `0600`，`data/`、`storage/`、`backups/`、`docker-client/` 保持 `0700`。备份包含私有配置与用户数据，不要作为 CI 工件上传。发布会短暂停机，需要预留一份完整持久化目录大小的可用空间。

发布在停止旧应用和备份前先启用 Nginx 维护闸门，直接通过宿主 HTTPS 验证 HTTP 503 及 `X-DEEIX-Maintenance: deployment`。旧进程退出后才生成快照；候选版本验证期间公网业务请求仍被拒绝，避免候选版本确认的新写入随后被失败回滚撤销。只有健康、版本和发布记录全部成功，或旧版本完整恢复成功后，才移除本次部署创建的标记。预先存在的初始化/人工维护标记始终保留。

## 服务器一次性准备

以下命令由管理员在宿主的已核实仓库检出目录执行。CI 不负责 DNS、TLS、宿主 Nginx 或初始凭据分发。

1. 确认 Docker Engine、Compose、buildx、Nginx 可用；创建受限目录：

   ```sh
   install -d -m 0755 /opt/deeix-chat
   install -d -m 0700 /opt/deeix-chat/data /opt/deeix-chat/storage
   install -d -m 0700 /opt/deeix-chat/backups /opt/deeix-chat/docker-client
   install -d -m 0755 /opt/deeix-chat/acme
   # 首次初始化期间保持维护，管理员完成初始化后再人工放通。
   install -m 0600 /dev/null /opt/deeix-chat/maintenance.flag
   ```

2. 以 `config.example.yaml` 为基础生成 `/opt/deeix-chat/config.yaml`。将两个 `change-me` 占位值分别替换为独立的随机值，至少 32 字节熵；保持 `app.env: prod`。不要把密钥打印到终端、CI 日志或聊天。文件权限设为 `0600`。已有数据的 `data_encryption_key` 不可随意替换；换钥需保留 `data_encryption_keys_previous` 并按应用的轮换流程完成。

3. 创建专用 builder，使用与流水线相同的客户端元数据目录：

   ```sh
   export DOCKER_CONFIG=/opt/deeix-chat/docker-client
   docker buildx create \
     --name deeix-chat-production \
     --driver docker-container \
     --driver-opt memory=3g \
     --driver-opt memory-swap=4g \
     --driver-opt cpu-period=100000 \
     --driver-opt cpu-quota=200000 \
     --driver-opt env.GOMAXPROCS=2 \
     --buildkitd-config deploy/production/buildkitd.toml
   docker buildx inspect --bootstrap deeix-chat-production
   docker pull curlimages/curl:8.16.0
   ```

   BuildKit 缓存保留约 2 GB、上限 10 GB，并尽量为宿主保留 12 GB 可用空间；这些阈值仅管理本项目 builder 的缓存，不清理其他项目。

   已存在时先检查原 builder，避免创建第二个。`buildkitd.toml` 将构建图并行度设为 1；builder 总配额为 2 CPU、3 GiB 内存及 4 GiB 内存加交换空间。临时 Dockerfile 给 Go builder 增加 `GOMAXPROCS=2` / `GOFLAGS=-p=2`，前端增加 `NODE_OPTIONS=--max-old-space-size=2048` 和禁用遥测，并追加 `api-tests` 目标执行 `go test -p 2 ./...`。运行镜像仍使用根 Dockerfile 的 `runtime` 目标；其中 `pnpm build` 执行 Next.js 构建及 TypeScript 检查。镜像只构建 `linux/amd64`，不推送注册表。

4. 创建 Compose 使用的独立外部网络，读取实际网关：

   ```sh
   docker network create deeix-chat-production
   docker network inspect deeix-chat-production \
     --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
   ```

   在开启公网流量前，将该 IPv4 网关的 `/32` 加入私有配置的 `server.trusted_proxies`，保留 loopback。网络由管理员维护，Compose 使用 `external: true`；已存在时只检查，不重复创建。不要把示例中的全部私网 CIDR 加入信任列表。SSRF 默认启用；私网模型网关必须用明确的 hostname 或 CIDR 白名单配置。

5. DNS 指向目标宿主，确认 TLS 证书后按 `nginx.conf.example` 接入宿主 Nginx。证书保存在 `/opt/deeix-chat/letsencrypt/live/deeix.motion-cover.com/`，ACME webroot 为 `/opt/deeix-chat/acme`。HTTP 和 HTTPS 都保留 challenge 路径，兼容 Cloudflare 的 Always Use HTTPS 跳转；维护闸门不影响这些路径。配置支持 SSE 与 WebSocket，并由 Nginx 覆盖转发来源头。先执行宿主 `nginx -t`，再按宿主服务管理方式重载；首次部署也必须已有可验证的 TLS 和维护闸门，否则脚本拒绝触碰应用。容器不开放其他宿主端口。

## Woodpecker 设置

- 启用仓库 `zengwenliang416/DEEIX-Chat`，配置文件为 `.woodpecker/deploy.yml`；关闭 PR 运行，仅允许受控 `dev` 发布。
- 专用 agent 标签必须同时包含 `location=production-80` 和 `repo=zengwenliang416/DEEIX-Chat`；该 agent 并发为 1。
- 仓库只开启工作流所需的 `volumes` 信任能力，不开启其他 trusted 能力。仅该受信仓库使用生产 agent。
- 两个步骤挂载 `/var/run/docker.sock` 和 `/opt/deeix-chat:/opt/deeix-chat`，使用 `docker:29-cli`；`DOCKER_CONFIG` 必须与宿主创建 builder 时一致。
- 构建和部署串行，任意后端测试、前端构建、镜像元数据或部署校验失败都会使工作流失败。应用容器限制为 1 CPU / 1 GiB，无额外交换配额，日志轮转为 `10m × 3`。

## 发布与验证

通常向 `dev` 推送已审核提交即可触发，也可在 Woodpecker 手动运行该分支。手动 API 按 `branch=dev` 解析当前 HEAD，不能假定传入的 SHA 会被平台固定；需要绑定审核提交时，把完整 SHA 作为 `EXPECTED_COMMIT` 传入构建步骤，脚本发现它与实际 `CI_COMMIT_SHA` 不同就立即失败。管理员在宿主可使用同一入口：

```sh
export DOCKER_CONFIG=/opt/deeix-chat/docker-client
sha=$(git rev-parse HEAD)
sh deploy/production/build.sh "$sha"
sh deploy/production/deploy.sh "$sha"
```

部署脚本先验证镜像的完整 revision 标签、版本标签、`linux/amd64` 平台及 Compose 配置，再创建或保留 `maintenance.flag`。固定域名 `deeix.motion-cover.com` 的 TLS 证书必须通过验证，宿主 Nginx 必须返回 HTTP 503 和专用维护响应头；未确认这两项时不会停止、重建或恢复应用数据。闸门生效后才停止旧应用并备份。仅通过三项容器网络探针后才更新 `current-release.json`：

- `/healthz`：HTTP 成功且 `status=ok`。
- `/readyz`：HTTP 成功且 `status=ok`，包括实际 SQLite 与内存缓存检查。
- `/api/v1/version`：响应的 `commit` 与本次完整 SHA 完全一致。

探针使用已缓存的 `curlimages/curl:8.16.0`，不依赖应用镜像安装 curl。可用 `DEEIX_PROBE_IMAGE` 指定经过核实的替代镜像。应用探针每次最多尝试 30 轮，每轮间隔 2 秒，单个 HTTP 请求超时 6 秒。维护探针以独立的 `--network host` sidecar 访问宿主回环 Nginx，使用 `--resolve deeix.motion-cover.com:443:127.0.0.1` 保留固定 Host/SNI 及正常 TLS 验证，不经过 CDN，不使用 `-k`，不修改宿主防火墙；总超时 10 秒。该网络参数用于 Docker socket 启动的探针容器，Woodpecker 步骤本身仍使用默认网络，无需开启额外的 `trusted.network`。

公网放通后，还须从外部验证 HTTPS、首页、三个探针及真实登录/聊天流程。容器探针证明进程、依赖与版本正常，不能代替浏览器或模型调用验收。初始管理员信息可能出现在应用启动日志中，应由管理员在受限环境提取并立即修改密码；流水线不输出应用日志，也不自动分发管理员凭据。

## 失败处理与回滚

部署目录的 `.deploy.lock` 防止两个脚本同时切换。若 job 被强制结束而残留锁，先确认没有运行中的部署及正在恢复的数据，再人工移除；不要在下一次 job 自动绕过。中断、文件写入失败或候选验证失败时，只有完整回滚成功才允许撤销自建维护标记；闸门验证失败或恢复失败会保留维护。成功提交发布记录后，即使清除标记失败，也只报告需人工恢复公网访问，不再倒退数据。

旧容器存在时，脚本保留其精确镜像 ID。若新版本启动或任意探针失败，先再次确认维护闸门仍然生效，再停止新容器、把失败时的数据移入备份目录的 `failed-data/` 和 `failed-storage/`，恢复一致性快照与旧配置、Compose、镜像标记，再启动并验证旧 SHA 和恢复旧发布记录。只有这些步骤全部成功才撤销本次创建的维护标记。即使同一 SHA 被重建而镜像 tag 改变，也会重新绑定旧镜像 ID。工作流仍以失败结束，以便保留本次发布失败记录。

首次发布失败时会停止新容器并保留现场数据、容器日志和维护标记，供受限排查；不把首次失败状态标为已发布。脚本仅输出容器状态、退出码、OOM 状态与时间，不打印应用日志。自动回滚若失败，会明确报告备份路径并保留维护标记；先修复恢复步骤，不要移除标记或让其他入口绕过 Nginx。

人工恢复某个备份时，先确认它包含 `compose.yaml`、`image.env`、`config.yaml`、`state.tar`、`previous-image-id`，并确认该备份对应要恢复的已知版本。以下命令中的备份路径必须由管理员替换；恢复期间禁止并行发布：

```sh
set -eu
umask 077
export DOCKER_CONFIG=/opt/deeix-chat/docker-client
root=/opt/deeix-chat
backup=/opt/deeix-chat/backups/REPLACE_WITH_VERIFIED_BACKUP
maintenance_preexisted=0
if [ -f "$root/maintenance.flag" ]; then
  maintenance_preexisted=1
else
  (set -C; printf 'manual recovery\n' > "$root/maintenance.flag")
fi
docker run --rm --pull never --network host \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --user 65534:65534 curlimages/curl:8.16.0 \
  --silent --show-error --head --noproxy '*' --connect-timeout 3 --max-time 10 \
  --resolve deeix.motion-cover.com:443:127.0.0.1 \
  --write-out '\n%{http_code}\n' https://deeix.motion-cover.com/readyz \
  > "$root/manual-maintenance-probe.txt"
test "$(tail -n 1 "$root/manual-maintenance-probe.txt")" = 503
tr -d '\r' < "$root/manual-maintenance-probe.txt" | \
  grep -Eiq '^X-DEEIX-Maintenance:[[:space:]]*deployment[[:space:]]*$'
docker stop --time 30 deeix-chat-production-app

# 保留当前失败现场，不覆盖已有 recovery 目录。
recovery="$root/manual-recovery-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$recovery"
tar -xpf "$backup/state.tar" -C "$recovery"
mv "$root/data" "$recovery/failed-data"
mv "$root/storage" "$recovery/failed-storage"
mv "$recovery/data" "$root/data"
mv "$recovery/storage" "$root/storage"
cp -p "$backup/config.yaml" "$root/config.yaml"
cp -p "$backup/compose.yaml" "$root/compose.yaml"
cp -p "$backup/image.env" "$root/image.env"
old_image=$(sed -n 's/^DEEIX_CHAT_IMAGE=//p' "$backup/image.env")
docker tag "$(cat "$backup/previous-image-id")" "$old_image"
docker compose --project-name deeix-chat-production --project-directory "$root" \
  --env-file "$root/image.env" --file "$root/compose.yaml" \
  up --detach --no-deps --pull never --force-recreate app
```

人工恢复后用容器内网络重新验证 `/healthz`、`/readyz`、`/api/v1/version` 的 SHA，并将实际恢复结果写入发布记录；不要继续展示新版本的成功记录。全部通过且 `maintenance_preexisted=0` 时，才可人工移除本次创建的 `maintenance.flag`；预先存在的标记继续保留。不要在未核对回滚需求前清理旧镜像、BuildKit 缓存或备份。维护窗口之外恢复历史数据库快照仍会撤销快照之后的业务写入，必须另行处理这些数据，不能把它当作本次发布的自动回滚。
