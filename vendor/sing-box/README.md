# 内置 sing-box

官方安装渠道（软件包、GitHub release）都不可用时，`install.sh` 会使用这里的 musl 静态包。文件名和包内路径与官方 release 相同：`sing-box-<版本>-linux-<arch>-musl.tar.gz`。

- 当前版本见 `VERSION`，需与 `src/01-core.sh` 中的 `VENDORED_SINGBOX_VERSION` 一致（回归测试会检查）。
- 覆盖架构：`amd64`、`arm64`、`armv7`、`386`。
- 更新方式：手动运行 GitHub Actions 中的 “Update vendored sing-box”，或执行 `bash scripts/update-vendored-singbox.sh [版本号]`，二者都会下载官方 release 包并替换这里的文件。

当前的 v1.14.3 包是在无法访问 GitHub release 的环境中，用 Go 模块代理获取的官方源码（tag v1.14.3）按官方 `release/DEFAULT_BUILD_TAGS_OTHERS`、`release/LDFLAGS` 构建的，`CGO_ENABLED=0`，不含需要 cgo 的 `with_naive_outbound`。下次运行更新流程后会被官方 release 包替换。
