# 新增一个镜像

## 1. 选一个明确的版本

本仓库只接受固定版本。可用的 tag 必须满足：

- 不是 `latest`，也不是任何会随上游发布而移动的别名 tag（`stable`、`main`、`v3`）。
- 是某个正式发布版本，例如 `1.31.8`、`v3.15.1`。
- 上游确实发布了该版本对应的多架构 manifest（若只发布单架构，需要在
  `platforms` 里只声明上游实际提供的架构）。

查看上游现有 tag（以 quay.io 为例）：

```bash
skopeo list-tags docker://quay.io/prometheus/prometheus | jq -r '.Tags[]' | sort -V | tail
```

## 2. 取 digest（推荐）

钉死 digest 后，如果上游把同一个 tag 重新指向别的字节，同步会失败而不是悄悄
覆盖。取 digest 的方式与脚本一致——对原始 manifest 字节做哈希：

```bash
skopeo inspect --raw docker://quay.io/prometheus/prometheus:v3.15.1 \
  | sha256sum | cut -d' ' -f1
# macOS 上没有 sha256sum 时：| shasum -a 256 | cut -d' ' -f1
```

注意不要用 `skopeo inspect --format '{{.Digest}}'`：它会按当前主机平台去挑选
manifest，在 macOS（darwin/arm64）上对 Linux 镜像会直接报错；对 manifest list
也可能返回子 manifest 的 digest。脚本用的是"对原始 manifest 字节做哈希"，与
Registry 返回的 `Docker-Content-Digest` 一致。

输出是 64 位十六进制，前面补 `sha256:`。

## 3. 选择文件

按领域放进 `images/` 下已有的文件，不要新建"杂项"文件：

| 文件 | 内容 |
| --- | --- |
| `kubernetes.yaml` | Kubernetes 运行时组件、基础镜像 |
| `observability.yaml` | 指标、日志、面板 |
| `databases.yaml` | 数据库与缓存 |
| `networking.yaml` | 网关、代理、Web 服务器 |
| `ai-inference.yaml` | 模型推理运行时 |

确有必要新增领域时，新建 `images/<domain>.yaml`，`metadata.name` 必须与文件名
一致。新增文件不需要改任何 workflow：矩阵是按目录内容动态展开的。

## 4. 写条目

```yaml
    - name: my-image
      source: ghcr.io/org/my-image
      target: harbor.isuanova.com/mirrors/ghcr.io/org/my-image
      versions:
        - tag: v1.2.3
          digest: sha256:0123…      # 可选但推荐
```

要点：

- `source` / `target` **不带** tag 或 digest，版本写在 `versions[]`。
- `target` 的第三段必须是源 Registry 主机名。
- 同一镜像需要保留多个版本时，直接列多个 `versions[]` 条目。
- 上游只有单架构时，用 `platforms` 覆盖默认值，否则平台断言会失败：

  ```yaml
      platforms:
        - linux/amd64
  ```

## 5. 本地验证

```bash
make validate                       # 静态校验，无需凭据
make check-sources ARGS="--image my-image"   # 只读探测：tag 是否存在、架构是否齐全
make dry-run ARGS="--image my-image"         # 确认目标地址
```

`check-sources` 只读，不写 Harbor，可以放心在本地跑。

## 6. PR 检查清单

- [ ] `make validate` 通过
- [ ] `make check-sources` 通过（tag 存在、架构齐全）
- [ ] 目标路径包含源 Registry 主机名
- [ ] 没有引入 `latest`
- [ ] 生产镜像已钉 digest
- [ ] 合并到 `main` 后确认 Actions 的 Sync 报告为 `Mirrored` 或
      `Already up to date`，并记录了 digest

## 升级已有镜像

升级就是一次 PR：把旧 `tag`（及其 `digest`）替换成新版本。如果要保留旧版本供
尚未升级的集群继续拉取，就同时保留两条 `versions[]` 记录，等确认不再使用后再
用另一个 PR 删除。删除条目**不会**从 Harbor 删除镜像，清理是 Harbor 侧的独立
操作。
