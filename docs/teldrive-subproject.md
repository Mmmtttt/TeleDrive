# Teldrive 子库化和上游管理方案

## 结论

建议选择 Git submodule 作为 Teldrive 的长期管理方式。

当前工作区已经有 `third_party/teldrive`，它是从 `https://github.com/tgdrive/teldrive.git` clone 下来的源码；父项目已初始化为 git repo，并把该路径注册为 submodule。因此方案分两层：

- 当前：`third_party/teldrive` 作为 Git submodule，由父仓库记录一个精确的 Teldrive commit。
- 临时/救援：如果父仓库尚未 clone submodule，可用脚本重新初始化并校验来源、提交号和工作区状态。

这给 CI、部署和多人协作留下可重复的锁定方式。

## 为什么选 submodule

| 方案 | 适配度 | 优点 | 代价 |
| --- | --- | --- | --- |
| submodule | 推荐 | 父仓库只记录一个 gitlink，Teldrive 上游历史保持独立；更新 diff 清楚；适合 `third_party/teldrive` 这种已有独立 clone 的目录 | 需要团队记得初始化 submodule；父目录必须是 git repo 才能正式登记 |
| subtree | 不推荐 | 单次 clone 父仓库即可拿到源码；不需要 submodule 命令 | 父仓库会吸收 Teldrive 历史或大批源码提交；上游同步提交噪音大 |
| vendor/plain clone | 只适合临时 | 不要求父目录是 git repo；当前状态能直接工作 | 父仓库不能自然锁定 commit；多人复现依赖额外文档或 lock 文件 |

## 目录约定

```text
D:\code\TeleDrive
  docs\
    teldrive-subproject.md
  scripts\
    teldrive-init.ps1
    teldrive-update.ps1
    teldrive-patch.ps1
    teldrive-build-image.ps1
  third_party\
    README.md
    teldrive\
```

`third_party/teldrive` 只放上游源码。项目自己的 importer、Bridge、demo、runtime compose 分别位于 `cmd/*` 与 `run/*`，避免把本项目逻辑混进上游目录。

## 初始化

当前父目录不是 git repo 时：

```powershell
.\scripts\teldrive-init.ps1
```

脚本会做这些事：

- 如果 `third_party/teldrive` 不存在，则 clone 上游。
- 如果目录已存在，则确认它是 git repo 并提示 remote 是否匹配。
- 输出当前 Teldrive HEAD。
- 不会把父目录强制初始化为 git repo。

父目录变成 git repo 后，注册 submodule：

```powershell
git init
.\scripts\teldrive-init.ps1 -RegisterSubmodule
git add .gitmodules third_party/teldrive third_party/README.md docs/teldrive-subproject.md scripts
```

如果 `third_party/teldrive` 已经是干净的 clone，`git submodule add --force` 可以复用现有目录。提交父仓库后，其他机器使用：

```powershell
git submodule update --init --recursive
```

## 更新上游

更新到上游主线：

```powershell
.\scripts\teldrive-update.ps1 -Ref origin/main
```

更新到 tag 或精确 commit：

```powershell
.\scripts\teldrive-update.ps1 -Ref v1.8.3
.\scripts\teldrive-update.ps1 -Ref d400a2df41db17ba220cd06973fc8df5c6f2854c
```

脚本默认行为：

- 要求 `third_party/teldrive` 工作区干净，除非显式传 `-AllowDirty`。
- 执行 `git fetch origin --tags --prune`。
- 解析 `-Ref` 到 commit。
- 用 detached HEAD checkout 到目标 commit，便于父仓库精确 pin。
- 如果父目录是 git repo，提醒提交 submodule pointer。

建议更新流程：

1. 运行更新脚本。
2. 构建本地镜像。
3. 启动 `run/teldrive` 和 importer 做 smoke test。
4. 如果父目录是 git repo，提交 submodule pointer 和相关说明。

## 本地补丁策略

优先把对 Teldrive 的改动做成上游 PR。必须本地保留时，采用“submodule 分支 + patch 文件”的方式：

```powershell
git -C .\third_party\teldrive switch -c teledrive/importer-compat
# edit and commit inside third_party/teldrive
git -C .\third_party\teldrive commit -am "Adapt Teldrive for TeleDrive importer"
.\scripts\teldrive-patch.ps1 -Mode ExportFormatPatch -BaseRef origin/main -OutputFile .\teldrive-local.patch
```

应用 patch：

```powershell
.\scripts\teldrive-patch.ps1 -Mode ApplyMailbox -PatchFile .\teldrive-local.patch
```

如果只是未提交 diff：

```powershell
.\scripts\teldrive-patch.ps1 -Mode ExportDiff -BaseRef origin/main -OutputFile .\teldrive-local.diff
.\scripts\teldrive-patch.ps1 -Mode ApplyDiff -PatchFile .\teldrive-local.diff
```

补丁文件最终存放位置可以在父仓库正式化后再定，例如 `third_party/patches/teldrive/`。当前任务没有创建补丁目录，避免扩大写入范围。

## 构建自定义镜像

构建本地镜像：

```powershell
.\scripts\teldrive-build-image.ps1 -ImageTag local/teldrive:dev -Platform linux/amd64
```

推送多架构镜像：

```powershell
.\scripts\teldrive-build-image.ps1 -ImageTag ghcr.io/your-org/teldrive:teledrive-dev -Platform linux/amd64,linux/arm64 -Push
```

构建脚本使用 Docker BuildKit/buildx，并通过 stdin 传入临时 Dockerfile，所以不会在 `third_party/teldrive` 下生成构建文件。构建阶段会：

- 使用 Teldrive 当前源码作为 Docker build context。
- 下载 Teldrive UI release asset 到镜像构建层。
- 执行 `go generate ./...` 生成 API 代码。
- 用 `VERSION` 文件和当前 git commit 注入版本信息。
- 产出 scratch runtime 镜像，入口保持 `/teldrive run`。

当前 `run/teldrive/docker-compose.yml` 使用 `ghcr.io/tgdrive/teldrive:latest`。验证自定义镜像时，建议新增临时 compose override 或手动改运行环境中的 image 标签；这不属于 third-party 管理脚本的职责。

## 安全边界

这些脚本不会主动执行以下操作：

- `git reset --hard`
- `git clean`
- 删除或移动 `third_party/teldrive`
- 重写父仓库历史
- 修改 `run/teldrive`、`run/demo`、`cmd/teledrive-importer`、`cmd/teledrive-bridge`

遇到冲突或脏工作区时，默认停止并让操作者明确处理。

## CI 草案

父仓库正式 git 化后，CI 可以按以下顺序：

```powershell
git submodule update --init --recursive
.\scripts\teldrive-update.ps1 -NoFetch -Ref HEAD
.\scripts\teldrive-build-image.ps1 -ImageTag local/teldrive:${env:GITHUB_SHA} -Platform linux/amd64
```

真正的发布流水线应使用 tag 或 commit SHA，而不是浮动的 `origin/main`。
