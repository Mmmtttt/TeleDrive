# TeleDrive Bridge API 合约

本文定义 TeleDrive Bridge 面向 `ULTIMATE_WEB` 和其他服务端 consumer 的 HTTP API。Bridge API 是稳定集成面；Teldrive 原生 API、Teldrive session hash、Telegram message id 和数据库结构都属于 Bridge 内部实现。

## 版本与约定

- Base URL: `http://127.0.0.1:<bridge-port>/v1`
- 认证：`Authorization: Bearer <bridge_api_token>`
- 请求体：`application/json; charset=utf-8`
- 响应体：JSON，媒体内容接口除外。
- 时间：UTC ISO-8601，例如 `2026-05-22T10:15:30Z`。
- ID：对外 ID 都是 opaque string。调用方可以保存和回传，但不应解析。
- 分页：列表接口使用 `limit` + `cursor`，返回 `next_cursor`。
- 请求追踪：调用方可传 `X-Request-Id`；未传时 Bridge 生成。

MVP 可以先运行在本机，例如 `http://127.0.0.1:8892/v1`。端口不是合约的一部分。

## 兼容当前 demo/importer 的映射

| 当前能力 | 当前接口 | Bridge 合约 |
| --- | --- | --- |
| 健康检查 | importer `GET /health` | `GET /health` 和 `GET /v1/status` |
| 手动导入 | importer `POST /api/import` | `POST /v1/imports` |
| 导入状态 | importer `GET /api/status` | `GET /v1/imports/latest` |
| 媒体列表 | demo `GET /api/catalog` | `GET /v1/catalog/items` |
| 媒体代理 | demo `GET /media/{file_id}/{filename}` | `GET /v1/files/{file_id}/content` |
| Teldrive 流 | Teldrive `GET /api/files/{id}/{name}?hash=...` | Bridge 内部调用，不对外暴露 |

## 通用响应

### 成功列表包装

```json
{
  "items": [],
  "next_cursor": null,
  "count": 0
}
```

`count` 表示当前页条数，不保证是全量总数。生产阶段如需全量统计，可增加 `total_count`，但调用方不应依赖它存在。

### 错误响应

```json
{
  "error": {
    "code": "file_not_found",
    "message": "File was not found.",
    "request_id": "req_01HX...",
    "details": {
      "file_id": "tdf_..."
    }
  }
}
```

常见 HTTP 状态：

| HTTP | code | 含义 |
| --- | --- | --- |
| 400 | `bad_request` | 参数格式错误或枚举值不合法。 |
| 401 | `unauthorized` | 缺少或无效 token。 |
| 403 | `forbidden` | token 无权访问 source/asset。 |
| 404 | `not_found` | source、catalog item、file 不存在。 |
| 409 | `job_conflict` | 导入任务已在运行或幂等键冲突。 |
| 416 | `range_not_satisfiable` | 媒体 Range 不可满足。 |
| 429 | `rate_limited` | 触发 Bridge 或 Telegram 侧限流。 |
| 502 | `upstream_error` | Teldrive/importer 返回不可恢复错误。 |
| 503 | `upstream_unavailable` | Teldrive/importer 不可用，或没有可用 session。 |

## 数据类型

### Source

```json
{
  "id": "src_default",
  "provider": "teldrive",
  "name": "Local Teldrive",
  "status": "ready",
  "default": true,
  "capabilities": ["import", "image", "video", "range_stream"],
  "roots": {
    "imports": "/Telegram Imports",
    "comics": "/Library/Comics",
    "videos": "/Library/Videos"
  }
}
```

字段说明：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | Bridge 内 source id。 |
| `provider` | string | 当前固定为 `teldrive`，以后可扩展。 |
| `status` | string | `ready`、`degraded`、`unavailable`。 |
| `capabilities` | string[] | 当前 source 支持能力。 |
| `roots` | object | Bridge 对 Teldrive 目录的业务解释。 |

### FileAsset

```json
{
  "id": "tdf_01HX...",
  "source_id": "src_default",
  "name": "001.jpg",
  "kind": "image",
  "mime_type": "image/jpeg",
  "size": 123456,
  "content_url": "/v1/files/tdf_01HX.../content",
  "thumbnail_url": "/v1/files/tdf_01HX.../content",
  "updated_at": "2026-05-22T10:15:30Z",
  "provider": {
    "name": "teldrive",
    "file_id": "internal-file-id"
  }
}
```

`provider.file_id` 只用于调试和服务端日志排查。生产可以默认不返回，或只在 admin token 下返回。

### Comic

```json
{
  "id": "comic_01HX...",
  "source_id": "src_default",
  "title": "Example Comic",
  "slug": "example-comic",
  "chapter_count": 12,
  "thumbnail_url": "/v1/files/tdf_cover/content",
  "updated_at": "2026-05-22T10:15:30Z"
}
```

### Chapter

```json
{
  "id": "chapter_01HX...",
  "comic_id": "comic_01HX...",
  "title": "第 001 话",
  "number": 1,
  "page_count": 24,
  "updated_at": "2026-05-22T10:15:30Z"
}
```

### Page

```json
{
  "id": "page_01HX...",
  "chapter_id": "chapter_01HX...",
  "index": 1,
  "width": null,
  "height": null,
  "image_url": "/v1/files/tdf_01HX.../content",
  "thumbnail_url": "/v1/files/tdf_01HX.../content",
  "file": {
    "id": "tdf_01HX...",
    "name": "001.jpg",
    "mime_type": "image/jpeg",
    "size": 123456
  }
}
```

`width` 和 `height` MVP 可为 `null`。生产阶段可由缩略图/图片探测任务补齐。

### VideoAsset

```json
{
  "id": "video_01HX...",
  "source_id": "src_default",
  "title": "example.mp4",
  "mime_type": "video/mp4",
  "size": 734003200,
  "duration_seconds": null,
  "thumbnail_url": null,
  "stream_url": "/v1/files/tdf_01HX.../content",
  "file": {
    "id": "tdf_01HX...",
    "name": "example.mp4"
  },
  "updated_at": "2026-05-22T10:15:30Z"
}
```

视频 `thumbnail_url` MVP 可为 `null`。调用方应显示默认封面。

### ImportJob

```json
{
  "id": "imp_01HX...",
  "status": "succeeded",
  "source_id": "src_default",
  "started_at": "2026-05-22T10:15:30Z",
  "finished_at": "2026-05-22T10:15:42Z",
  "request": {
    "limit": 100,
    "convert_photos": true,
    "dry_run": false
  },
  "result": {
    "user_id": 123456,
    "channel_id": 987654,
    "scanned": 100,
    "imported": 8,
    "converted_photos": 3,
    "skipped": 92,
    "errors": []
  }
}
```

`status` 取值：`queued`、`running`、`succeeded`、`failed`、`cancelled`。

## System API

### GET /health

不要求认证，用于进程级健康检查。

响应：

```json
{
  "ok": true,
  "service": "teledrive-bridge",
  "version": "0.1.0"
}
```

### GET /v1/status

要求认证，返回 Bridge 和上游状态。

响应：

```json
{
  "ok": true,
  "bridge": {
    "status": "ready"
  },
  "upstreams": {
    "teldrive": {
      "status": "ready",
      "origin": "http://127.0.0.1:8787"
    },
    "importer": {
      "status": "ready",
      "origin": "http://127.0.0.1:8891"
    }
  }
}
```

### GET /v1/capabilities

响应：

```json
{
  "capabilities": [
    "catalog",
    "import",
    "image",
    "video",
    "range_stream",
    "comics_projection"
  ],
  "limits": {
    "max_page_size": 200,
    "max_import_limit": 1000
  }
}
```

## Sources API

### GET /v1/sources

查询可用 source。

响应：

```json
{
  "items": [
    {
      "id": "src_default",
      "provider": "teldrive",
      "name": "Local Teldrive",
      "status": "ready",
      "default": true,
      "capabilities": ["import", "image", "video", "range_stream"],
      "roots": {
        "imports": "/Telegram Imports",
        "comics": "/Library/Comics",
        "videos": "/Library/Videos"
      }
    }
  ],
  "next_cursor": null,
  "count": 1
}
```

## Import API

### POST /v1/imports

触发一次导入。MVP 可同步调用 importer 并立即返回最终结果；生产阶段应返回 `202 Accepted` 和 `queued/running` job。

请求：

```json
{
  "source_id": "src_default",
  "limit": 100,
  "convert_photos": true,
  "dry_run": false,
  "user_id": null,
  "channel_id": null
}
```

字段说明：

| 字段 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | default source | Bridge source。 |
| `limit` | number | `100` | 扫描最近 N 条频道消息。 |
| `convert_photos` | boolean | `true` | 是否把普通 Telegram photo 转存为 document。 |
| `dry_run` | boolean | `false` | 只扫描不写库、不上传转换文件。 |
| `user_id` | number/null | `null` | 管理接口可覆盖 Teldrive user id；普通 ULTIMATE_WEB 调用不应传。 |
| `channel_id` | number/null | `null` | 管理接口可覆盖频道；普通 ULTIMATE_WEB 调用不应传。 |

推荐请求头：

```text
Idempotency-Key: import-20260522-001
```

成功响应：

```json
{
  "job": {
    "id": "imp_01HX...",
    "status": "succeeded",
    "source_id": "src_default",
    "started_at": "2026-05-22T10:15:30Z",
    "finished_at": "2026-05-22T10:15:42Z",
    "request": {
      "limit": 100,
      "convert_photos": true,
      "dry_run": false
    },
    "result": {
      "user_id": 123456,
      "channel_id": 987654,
      "scanned": 100,
      "imported": 8,
      "converted_photos": 3,
      "skipped": 92,
      "errors": [],
      "files": [
        {
          "file_id": "tdf_01HX...",
          "name": "photo-1001.jpg",
          "mime_type": "image/jpeg",
          "size": 345678,
          "category": "image",
          "converted": true
        }
      ]
    }
  }
}
```

### GET /v1/imports/latest

返回最近一次导入状态。

响应：

```json
{
  "job": {
    "id": "imp_latest",
    "status": "succeeded",
    "source_id": "src_default",
    "started_at": "2026-05-22T10:15:30Z",
    "finished_at": "2026-05-22T10:15:42Z",
    "request": {
      "limit": 100,
      "convert_photos": true,
      "dry_run": false
    },
    "result": {
      "scanned": 100,
      "imported": 8,
      "converted_photos": 3,
      "skipped": 92,
      "errors": []
    }
  }
}
```

### GET /v1/imports/{job_id}

生产阶段接口。MVP 若没有 job store，可以只支持 `latest` 或把 `imp_latest` 映射到最近结果。

## Catalog API

### GET /v1/catalog/items

低层统一媒体列表，适合 ULTIMATE_WEB 适配器做兜底浏览。

查询参数：

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | default source | 来源。 |
| `kind` | string | `all` | `all`、`image`、`video`、`audio`、`document`。 |
| `path` | string | empty | 限定 Teldrive 目录或 Bridge 虚拟目录。 |
| `query` | string | empty | 文件名搜索。 |
| `limit` | number | `80` | 当前页大小。 |
| `cursor` | string | empty | 下一页游标。 |

响应：

```json
{
  "items": [
    {
      "id": "tdf_01HX...",
      "source_id": "src_default",
      "name": "001.jpg",
      "kind": "image",
      "mime_type": "image/jpeg",
      "size": 123456,
      "content_url": "/v1/files/tdf_01HX.../content",
      "thumbnail_url": "/v1/files/tdf_01HX.../content",
      "updated_at": "2026-05-22T10:15:30Z"
    }
  ],
  "next_cursor": null,
  "count": 1
}
```

### GET /v1/catalog/search

跨漫画和视频的统一搜索。MVP 可先映射为文件名搜索。

查询参数：

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `q` | string | 搜索关键词。 |
| `types` | string | 逗号分隔：`comic,chapter,page,video,file`。 |
| `source_id` | string | 可选。 |
| `limit` | number | 可选。 |
| `cursor` | string | 可选。 |

响应：

```json
{
  "items": [
    {
      "type": "video",
      "item": {
        "id": "video_01HX...",
        "title": "example.mp4",
        "stream_url": "/v1/files/tdf_01HX.../content"
      }
    }
  ],
  "next_cursor": null,
  "count": 1
}
```

## Comics API

### GET /v1/comics

返回漫画作品列表。

查询参数：

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | default source | 来源。 |
| `query` | string | empty | 标题搜索。 |
| `limit` | number | `50` | 页大小。 |
| `cursor` | string | empty | 下一页。 |

响应：

```json
{
  "items": [
    {
      "id": "comic_01HX...",
      "source_id": "src_default",
      "title": "Example Comic",
      "slug": "example-comic",
      "chapter_count": 12,
      "thumbnail_url": "/v1/files/tdf_cover/content",
      "updated_at": "2026-05-22T10:15:30Z"
    }
  ],
  "next_cursor": null,
  "count": 1
}
```

### GET /v1/comics/{comic_id}

响应：

```json
{
  "comic": {
    "id": "comic_01HX...",
    "source_id": "src_default",
    "title": "Example Comic",
    "slug": "example-comic",
    "chapter_count": 12,
    "thumbnail_url": "/v1/files/tdf_cover/content",
    "updated_at": "2026-05-22T10:15:30Z"
  }
}
```

### GET /v1/comics/{comic_id}/chapters

响应：

```json
{
  "items": [
    {
      "id": "chapter_01HX...",
      "comic_id": "comic_01HX...",
      "title": "第 001 话",
      "number": 1,
      "page_count": 24,
      "updated_at": "2026-05-22T10:15:30Z"
    }
  ],
  "next_cursor": null,
  "count": 1
}
```

### GET /v1/chapters/{chapter_id}/pages

返回章节页。页面顺序必须稳定，优先使用自然数字排序。

响应：

```json
{
  "chapter": {
    "id": "chapter_01HX...",
    "comic_id": "comic_01HX...",
    "title": "第 001 话",
    "number": 1,
    "page_count": 2
  },
  "items": [
    {
      "id": "page_01",
      "chapter_id": "chapter_01HX...",
      "index": 1,
      "width": null,
      "height": null,
      "image_url": "/v1/files/tdf_page_001/content",
      "thumbnail_url": "/v1/files/tdf_page_001/content",
      "file": {
        "id": "tdf_page_001",
        "name": "001.jpg",
        "mime_type": "image/jpeg",
        "size": 123456
      }
    },
    {
      "id": "page_02",
      "chapter_id": "chapter_01HX...",
      "index": 2,
      "width": null,
      "height": null,
      "image_url": "/v1/files/tdf_page_002/content",
      "thumbnail_url": "/v1/files/tdf_page_002/content",
      "file": {
        "id": "tdf_page_002",
        "name": "002.jpg",
        "mime_type": "image/jpeg",
        "size": 123457
      }
    }
  ],
  "next_cursor": null,
  "count": 2
}
```

## Videos API

### GET /v1/videos

查询视频列表。

查询参数：

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | default source | 来源。 |
| `query` | string | empty | 标题或文件名搜索。 |
| `limit` | number | `50` | 页大小。 |
| `cursor` | string | empty | 下一页。 |

响应：

```json
{
  "items": [
    {
      "id": "video_01HX...",
      "source_id": "src_default",
      "title": "example.mp4",
      "mime_type": "video/mp4",
      "size": 734003200,
      "duration_seconds": null,
      "thumbnail_url": null,
      "stream_url": "/v1/files/tdf_01HX.../content",
      "file": {
        "id": "tdf_01HX...",
        "name": "example.mp4"
      },
      "updated_at": "2026-05-22T10:15:30Z"
    }
  ],
  "next_cursor": null,
  "count": 1
}
```

### GET /v1/videos/{video_id}

响应：

```json
{
  "video": {
    "id": "video_01HX...",
    "source_id": "src_default",
    "title": "example.mp4",
    "mime_type": "video/mp4",
    "size": 734003200,
    "duration_seconds": null,
    "thumbnail_url": null,
    "stream_url": "/v1/files/tdf_01HX.../content",
    "file": {
      "id": "tdf_01HX...",
      "name": "example.mp4"
    },
    "updated_at": "2026-05-22T10:15:30Z"
  }
}
```

## Files API

### GET /v1/files/{file_id}

返回文件元数据。

响应：

```json
{
  "file": {
    "id": "tdf_01HX...",
    "source_id": "src_default",
    "name": "example.mp4",
    "kind": "video",
    "mime_type": "video/mp4",
    "size": 734003200,
    "content_url": "/v1/files/tdf_01HX.../content",
    "thumbnail_url": null,
    "updated_at": "2026-05-22T10:15:30Z"
  }
}
```

### GET /v1/files/{file_id}/content

返回文件内容。该接口必须支持图片加载和视频 Range 播放。

查询参数：

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `download` | `0`/`1` | `0` | `1` 时以附件下载。 |
| `filename` | string | file name | 可选下载文件名，Bridge 应做清洗。 |

请求示例：

```http
GET /v1/files/tdf_01HX/content HTTP/1.1
Authorization: Bearer bridge-token
Range: bytes=1048576-2097151
```

响应示例：

```http
HTTP/1.1 206 Partial Content
Accept-Ranges: bytes
Content-Type: video/mp4
Content-Length: 1048576
Content-Range: bytes 1048576-2097151/734003200
ETag: "..."
Last-Modified: Fri, 22 May 2026 10:15:30 GMT
Cache-Control: private, max-age=30
```

行为要求：

- `Range` 为空时返回 `200 OK` 和完整内容。
- 单段 `Range` 可满足时返回 `206 Partial Content`。
- 多段 `Range` MVP 可返回 `416` 或 `400`，与 Teldrive 当前行为保持一致即可。
- 不可满足 Range 返回 `416`，带 `Content-Range: bytes */{size}`。
- 支持 `HEAD`，返回与 `GET` 相同的 metadata headers，不返回 body。
- Bridge 不得把 Teldrive session hash、cookie、Telegram session string 放入 URL、响应头或响应体。

### HEAD /v1/files/{file_id}/content

用于播放器探测。

响应示例：

```http
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Type: video/mp4
Content-Length: 734003200
ETag: "..."
Last-Modified: Fri, 22 May 2026 10:15:30 GMT
```

## Thumbnail API

### GET /v1/thumbnails/{asset_id}

MVP 可不实现独立缩略图接口，直接在 `thumbnail_url` 中返回 `/v1/files/{file_id}/content` 或 `null`。生产阶段再启用该接口。

查询参数：

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `width` | number | `320` | 目标宽度。 |
| `height` | number | auto | 目标高度。 |
| `fit` | string | `cover` | `cover`、`contain`。 |

未生成时：

```json
{
  "error": {
    "code": "thumbnail_not_ready",
    "message": "Thumbnail is not ready.",
    "request_id": "req_01HX..."
  }
}
```

建议 HTTP 状态为 `404` 或 `202`，由最终实现选择并在 OpenAPI 中固定。

## 安全要求

- Bridge token 只发给 ULTIMATE_WEB 后端，不发给浏览器长期保存。
- 浏览器访问媒体时可以使用短期签名 URL，或由 ULTIMATE_WEB 后端代理加上 Bridge token。MVP 本地可先使用同源后端代理。
- Teldrive session hash 只存在 Bridge 内部请求中。
- 日志中必须脱敏：
  - `Authorization`
  - `Cookie`
  - Teldrive `hash`
  - Telegram session string
  - Telegram API hash
- CORS 生产环境只允许 ULTIMATE_WEB 域名。

## 缓存要求

| 内容 | MVP | 生产建议 |
| --- | --- | --- |
| Catalog JSON | `Cache-Control: no-store` | 可按 source 和 cursor 缓存 5-30 秒。 |
| 图片内容 | `private, max-age=30` | 可加 ETag 和短缓存。 |
| 视频内容 | `private, max-age=30` | Range 响应可短缓存，视权限模型决定。 |
| Import status | `no-store` | `no-store`。 |

## ULTIMATE_WEB 调用建议

漫画：

1. `GET /v1/comics?query=...`
2. `GET /v1/comics/{comic_id}/chapters`
3. `GET /v1/chapters/{chapter_id}/pages`
4. 前端阅读器加载 `page.image_url`。

视频：

1. `GET /v1/videos?query=...`
2. `GET /v1/videos/{video_id}`
3. 播放器使用 `video.stream_url`，需要支持 Range。

导入：

1. 管理页或后台任务调用 `POST /v1/imports`。
2. 调用 `GET /v1/imports/latest` 或 `GET /v1/imports/{job_id}` 轮询。
3. 导入成功后刷新 catalog。

## MVP 必须实现的最小集合

为了接入 ULTIMATE_WEB，首版 Bridge 至少实现：

- `GET /health`
- `GET /v1/status`
- `POST /v1/imports`
- `GET /v1/imports/latest`
- `GET /v1/catalog/items`
- `GET /v1/files/{file_id}`
- `GET /v1/files/{file_id}/content`
- `HEAD /v1/files/{file_id}/content`

如果 ULTIMATE_WEB 首次接入直接走业务对象，还应实现：

- `GET /v1/comics`
- `GET /v1/comics/{comic_id}/chapters`
- `GET /v1/chapters/{chapter_id}/pages`
- `GET /v1/videos`
- `GET /v1/videos/{video_id}`

## 后向兼容策略

- `/v1` 内字段只追加不删除。
- 新字段必须可选，旧 consumer 忽略后仍能工作。
- 枚举新增值时，consumer 应按 unknown 兜底处理。
- 错误 `code` 一旦发布不得复用为其他含义。
- 若需要破坏性变更，新增 `/v2`，`/v1` 保持一个迁移窗口。

