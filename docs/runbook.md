# TeleDrive 本地运行与验证手册

适用工作区：`D:\code\TeleDrive`。命令默认在 Windows PowerShell 中执行。

## 组件与端口

| 组件 | 位置 | 默认地址 | 说明 |
| --- | --- | --- | --- |
| Teldrive | `run\teldrive` | `http://127.0.0.1:8787` | 上游 `tgdrive/teldrive` 容器，使用本地 Postgres |
| Postgres | `run\teldrive` compose service | compose 内部 `postgres:5432` | 保存 `teldrive.*` 与 `teldrive_importer.*` 数据 |
| Importer | `cmd\teledrive-importer`，由 `run\teldrive\docker-compose.yml` 构建 | `http://127.0.0.1:8891` | 扫描 Teldrive 选中频道，登记 document/video，按需把普通 photo 转成 document |
| Bridge | `cmd\teledrive-bridge`，由 `run\teldrive\docker-compose.yml` 构建 | `http://127.0.0.1:8892` | 对外提供 catalog、media proxy、import trigger，是 ULTIMATE_WEB 后续集成面 |
| Demo | `run\demo` | `http://127.0.0.1:8890` | 早期 Node demo，读取 catalog 并代理 `/media/<file_id>/<filename>`，保留 Range 请求 |

验证脚本位于 `scripts\verify-*.ps1`。默认不调用 importer 扫描频道；只有显式传入 `-DryRunImport` 或 `-RunImport` 的脚本会触发 `/api/import`。`-RunImport` 会真实导入/转存。

## 快速启动

```powershell
cd D:\code\TeleDrive\run\teldrive
.\start.ps1
```

打开 `http://127.0.0.1:8787`，完成 Telegram 登录，并确认 Teldrive 已选中或创建用于存储的 Telegram 频道。

Demo 单独启动：

```powershell
cd D:\code\TeleDrive\run\demo
.\start.ps1
```

停止服务：

```powershell
cd D:\code\TeleDrive\run\teldrive
.\stop.ps1

cd D:\code\TeleDrive\run\demo
.\stop.ps1
```

## 推荐验证顺序

从工作区根目录运行：

```powershell
cd D:\code\TeleDrive
powershell -ExecutionPolicy Bypass -File .\scripts\verify-stack.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-importer.ps1 -Limit 20
powershell -ExecutionPolicy Bypass -File .\scripts\verify-demo-catalog.ps1
```

验证 importer 手动 dry-run 触发：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-importer.ps1 -Limit 20 -DryRunImport
```

有视频和已转换 photo 后，再运行严格媒体验证：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-video-range.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-photo-document.ps1 -RequireConverted
```

也可以使用聚合脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-all.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-all.ps1 -StrictMedia
```

## Teldrive 容器验证

脚本：

```powershell
cd D:\code\TeleDrive
powershell -ExecutionPolicy Bypass -File .\scripts\verify-stack.ps1
```

它会检查：

- `postgres`、`teldrive`、`importer`、`bridge` compose service 是否 running。
- Postgres `pg_isready`。
- Teldrive HTTP 可达性。
- Importer `/health`。
- Bridge `/health` 和 `/v1/catalog/items`。
- `teldrive.files`、`teldrive.sessions`、`teldrive.channels` 表是否存在。
- 是否已有 Teldrive session 和 selected channel。没有时脚本给 warning，后续 importer/media 验证通常需要先登录 Teldrive。

常用人工检查：

```powershell
cd D:\code\TeleDrive\run\teldrive
docker compose ps
docker compose logs --tail=100 teldrive
docker compose logs --tail=100 importer
docker compose logs --tail=100 bridge
docker compose logs --tail=100 postgres
```

## Bridge 验证

Bridge 是正式对外接口，默认端口 `8892`：

```powershell
Invoke-RestMethod http://127.0.0.1:8892/health
Invoke-RestMethod http://127.0.0.1:8892/v1/catalog/items
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8892/v1/imports -ContentType "application/json" -Body '{"limit":100,"convert_photos":true}'
```

媒体内容通过 Bridge 访问：

```text
GET /v1/files/{file_id}/content?name={filename}
Range: bytes=0-1023
```

预期视频 Range 请求返回 `206 Partial Content`，并保留 `Content-Range`。

## Importer 手动触发

Importer 默认手动模式，compose 中 `POLL_INTERVAL_SECONDS=0`。

只预览，不写数据库、不上传 photo：

```powershell
Invoke-RestMethod `
  -Method Post `
  -Uri http://127.0.0.1:8891/api/import `
  -ContentType "application/json" `
  -Body '{"limit":100,"convert_photos":true,"dry_run":true}'
```

真实导入 document/video，并把普通 photo 下载后重新作为 document 发回同一频道再登记：

```powershell
Invoke-RestMethod `
  -Method Post `
  -Uri http://127.0.0.1:8891/api/import `
  -ContentType "application/json" `
  -Body '{"limit":100,"convert_photos":true}'
```

脚本验证：

```powershell
cd D:\code\TeleDrive
powershell -ExecutionPolicy Bypass -File .\scripts\verify-importer.ps1 -Limit 20
powershell -ExecutionPolicy Bypass -File .\scripts\verify-importer.ps1 -Limit 20 -DryRunImport
powershell -ExecutionPolicy Bypass -File .\scripts\verify-importer.ps1 -Limit 100 -RunImport
```

`verify-importer.ps1` 默认只查 health/status/marker table，不触发扫描。传 `-DryRunImport` 会调用 `dry_run=true`，不会创建候选文件记录或上传 photo；传 `-RunImport` 才做真实导入。返回里的关键字段：

- `scanned`：扫描到的频道消息数。
- `imported`：本轮登记的文件数。
- `converted_photos`：本轮由普通 photo 转 document 的数量。
- `skipped`：非媒体、已导入、已存在 parts 等跳过数量。
- `errors`：单条消息处理失败的错误列表。

重复运行应该是幂等的：importer 会同时看 `teldrive.files.parts` 与 `teldrive_importer.imported_messages`。第二次导入同一批消息时，`imported` 通常应为 `0` 或明显减少，`skipped` 增加。

## Importer 自动触发

如需轮询，把 `run\teldrive\docker-compose.yml` 中 importer service 的 `POLL_INTERVAL_SECONDS` 改为正整数，例如 `60`，然后重建/重启：

```powershell
cd D:\code\TeleDrive\run\teldrive
docker compose up -d --build importer
```

验证自动模式已开启：

```powershell
cd D:\code\TeleDrive
powershell -ExecutionPolicy Bypass -File .\scripts\verify-importer.ps1 -ExpectPolling
```

等待自动触发更新 `last_result`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-importer.ps1 -ExpectPolling -WaitForAutoSeconds 90
```

自动模式仍然会使用 importer 的幂等逻辑。大频道建议先用手动 dry-run 估算，再开启轮询。

## Demo Catalog 验证

启动 demo：

```powershell
cd D:\code\TeleDrive\run\demo
.\start.ps1
```

接口：

```powershell
Invoke-RestMethod http://127.0.0.1:8890/api/catalog
```

脚本：

```powershell
cd D:\code\TeleDrive
powershell -ExecutionPolicy Bypass -File .\scripts\verify-demo-catalog.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-demo-catalog.ps1 -RequireMedia
powershell -ExecutionPolicy Bypass -File .\scripts\verify-demo-catalog.ps1 -RequireImage
powershell -ExecutionPolicy Bypass -File .\scripts\verify-demo-catalog.ps1 -RequireVideo
```

demo catalog 只展示 `teldrive.files` 中 active 的 image/video 文件，最多 80 条。浏览器不会拿到 Teldrive session hash，媒体通过 demo 的 `/media/<file_id>/<filename>` 代理访问。

## 视频 Range 测试

确保 catalog 中已有 video 文件后运行：

```powershell
cd D:\code\TeleDrive
powershell -ExecutionPolicy Bypass -File .\scripts\verify-video-range.ps1
```

脚本会从 `/api/catalog` 找第一条 video，向 demo 的 `/media/...` 发送：

```text
Range: bytes=0-1023
```

预期：

- HTTP `206 Partial Content`。
- 响应头包含 `Content-Range`。
- 可选包含 `Accept-Ranges`。

也可以指定文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-video-range.ps1 `
  -FileId "<teldrive_file_id>" `
  -FileName "<filename>"
```

如果返回 `200`，说明 Range 没有被上游或代理正确处理；优先看 demo 日志和 Teldrive 媒体接口。

## Photo 转 Document 测试

测试步骤：

1. 在 Telegram 中向 Teldrive 当前选中的频道转发或发送一张普通 photo，不要作为文件发送。
2. 先 dry-run：

   ```powershell
   cd D:\code\TeleDrive
   powershell -ExecutionPolicy Bypass -File .\scripts\verify-photo-document.ps1 -RunImport -DryRun -Limit 50
   ```

3. 真实导入与转存：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\verify-photo-document.ps1 -RunImport -Limit 50 -RequireConverted
   ```

脚本会检查：

- `teldrive_importer.imported_messages.converted = true`。
- 对应 `teldrive.files` 记录为 `status='active'`。
- `mime_type` 为 `image/*`，`category='image'`。
- `teldrive.files.parts` 包含转存后的 `imported_msg_id`，也就是新 document 消息 id。

指定原始 photo 消息 id：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-photo-document.ps1 -OriginalMessageId 1234 -RequireConverted
```

注意：`-DryRun` 不会上传转换后的 document，也不会写入 converted 记录；它只用于确认扫描流程和候选消息。

## 常见故障排查

### 端口占用

默认端口：

- Teldrive：`8787`
- Demo：`8890`
- Importer：`8891`

查看占用：

```powershell
Get-NetTCPConnection -LocalPort 8787,8890,8891 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, State, OwningProcess
```

定位进程：

```powershell
Get-Process -Id <OwningProcess>
```

处理方式：

- 关闭占用进程。
- 或修改 compose/demo 环境变量端口后重启；同步给验证脚本传 `-TeldriveUrl`、`-ImporterUrl`、`-DemoUrl`。

### Docker 或 compose 异常

先检查 Docker Desktop 是否运行：

```powershell
docker version
docker compose version
```

重启当前栈：

```powershell
cd D:\code\TeleDrive\run\teldrive
docker compose up -d --build
docker compose ps
```

看日志：

```powershell
docker compose logs --tail=200 postgres
docker compose logs --tail=200 teldrive
docker compose logs --tail=200 importer
```

Postgres 未 healthy 时，Teldrive 和 importer 会等待；如果卡住，优先看 `postgres` 日志和 `run\teldrive\postgres_data` 是否被其他进程锁住。

### Telegram `LIMIT_INVALID`

常见触发点：

- Telegram API 请求的 `limit` 超出接口允许范围。
- 下载 photo 时分片大小、offset 或请求频率触发 Telegram 侧限制。
- 大频道一次扫描太多，或自动轮询间隔太短。

处理建议：

- importer 触发时把 `limit` 降低，例如 `20` 或 `50`。
- 先用 `dry_run=true` 观察 `scanned/skipped/errors`。
- 保持 `POLL_INTERVAL_SECONDS=0` 手动验证，稳定后再开启自动轮询。
- 如果频繁出现 flood/rate 相关错误，停一段时间后再试。

### 重复导入

重复导入通常应被跳过。确认：

```powershell
cd D:\code\TeleDrive\run\teldrive
docker compose exec -T postgres psql -U teldrive -d postgres -c "select count(*) from teldrive_importer.imported_messages;"
docker compose exec -T postgres psql -U teldrive -d postgres -c "select original_msg_id, imported_msg_id, file_id, name, converted, created_at from teldrive_importer.imported_messages order by created_at desc limit 20;"
```

如果同名文件存在，importer 会用 `name-1.ext`、`name-2.ext` 形式分配唯一名称。若同一 Telegram 消息被多次登记，检查：

- 是否清空过 `teldrive_importer.imported_messages`。
- `teldrive.files.parts` 是否被手动改动。
- 是否切换了 channel 或 user，导致幂等键变化。

### `check` 命令误删 orphan 风险

上游 Teldrive 的 `check` 命令会比较数据库文件 parts 与 Telegram 频道消息。源码说明它会识别 missing file parts 和 orphan messages；非 dry-run 时会清理 missing files，并删除 orphan messages。

在当前 importer 方案中，photo 转 document 会在同一频道新增 document 消息，然后在数据库中登记。任何“数据库还没登记但 Telegram 已有消息”的窗口，都可能被 `check` 视作 orphan。不要在 importer 正在运行、刚做 photo 转存、或不清楚 orphan 列表来源时运行非 dry-run 的 `teldrive check`。

只允许先 dry-run 并导出结果人工检查：

```powershell
teldrive check --dry-run
```

禁止在本地验证流程里直接运行会清理的形式，例如：

```powershell
teldrive check
teldrive check --clean-pending
teldrive check --clean-uploads
```

如果必须清理，先备份 Postgres 数据，并确认 orphan message id 不包含 importer 刚转存的 document 消息。

## 验证脚本清单

| 脚本 | 默认是否写数据 | 用途 |
| --- | --- | --- |
| `scripts\verify-stack.ps1` | 否 | 检查 compose services、HTTP、DB 基础结构 |
| `scripts\verify-importer.ps1` | 否；传 `-DryRunImport` 会调用 dry-run；传 `-RunImport` 会写 | 检查 importer health/status/marker table；可显式验证手动触发 |
| `scripts\verify-demo-catalog.ps1` | 否 | 检查 demo root 和 `/api/catalog` |
| `scripts\verify-video-range.ps1` | 否 | 对 demo media URL 发 HEAD + Range，验证 HTTP 206 |
| `scripts\verify-photo-document.ps1` | 否；传 `-RunImport` 可写 | 验证 photo 转 document 后的 DB 记录；传 `-DryRun` 时不写 |
| `scripts\verify-all.ps1` | 否；传 `-DryRunImport` 会调用 dry-run；传 `-RunImport` 可写 | 串行运行主要验证；传 `-StrictMedia` 要求视频和 converted photo 都存在 |
