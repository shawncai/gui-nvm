# gui-nvm for macOS

SwiftUI 原生应用，支持 Apple Silicon 和 macOS 14+。项目扫描、配置预览与保存、Node 版本库、隔离安装、任务日志和设置均在本机完成。应用自带 nvm 安装脚本与已审查的 semver 7.7.3；运行时不依赖源码仓库、Node、pnpm、Python 或 Web 服务。

## 本地安装

构建产物位于 `output/macos/`：

- `gui-nvm.app`：可直接运行或复制到应用程序目录。
- `gui-nvm-0.1.0-arm64.dmg`：打开后将应用拖入 Applications。
- `SHA256SUMS.txt`：DMG 的 SHA-256 校验值。

首版使用 ad-hoc 本地签名，没有 Developer ID 签名和 Apple 公证。当前构建机器可直接验证使用；经网络转发到其他 Mac 后，系统可能要求在「系统设置 → 隐私与安全性」中明确允许打开。不要关闭 Gatekeeper。面向广泛分发时应采用 Developer ID 签名与公证。

关闭最后一个窗口或按 ⌘Q 会等待当前文件写入，取消扫描、同步和安装，回收安装子进程并清理本次临时安装目录。应用不常驻后台。

## 首次使用与数据

首次启动会只读导入旧 Web 的项目清单和版本缓存。原生状态位于 `~/Library/Application Support/gui-nvm/native/`，旧 Web 的 `state.json` 和 `releases.json` 保持独立。导入记录保存在 `migration.json`，不会每次启动重复导入。没有历史扫描目录时，点击「添加扫描目录」选择项目所在位置。

nvm 目录优先使用原生设置中已保存的目录，其次为启动环境的 `NVM_DIR`，最后为 `~/.nvm`。Finder 启动通常没有终端环境变量；自定义目录请在设置中选择。Node 安装或全局包操作运行时不能切换 nvm 目录。应用不会执行用户 shell profile 或自动请求管理员权限。

项目声明仍按最近目录优先、同级 `.nvmrc` > `.node-version` > `package.json engines.node` 解析。保存前检查预览修订，外部编辑后需重新预览。父目录继承的声明只写入当前项目。原生版与 Web、终端共用真实项目文件和 Node 安装目录。

安装仅接受本机架构的官方 Node 二进制，使用 nvm 下载校验流程，不回退源码编译、不安装默认全局包、不隐式修改默认版本。安装在独立临时目录完成，验证版本后才发布到真实 nvm 目录。终端自动切换继续由既有 auto-switch 配置负责；应用不会修改 `.zshrc`，也不会改变已运行进程的 Node 版本。

版本索引从 Node 官方同步；支持周期使用仓库现有的 `2026-10-21` 快照。断网保留缓存，任务历史仅保留本次运行最近 30 条。网络遵循代理环境变量，其次读取 macOS 系统 HTTP/HTTPS 代理，不修改系统代理设置。

## 全局包

「全局包」页汇总所有已安装 Node 的顶层全局包，支持包名搜索、按 Node 筛选和刷新；Node 版本列表也提供直接入口。选中包可查看位置，删除或调整到精确版本（包含预发布版本）。不包含安装新包、跨 Node 复制和 pnpm 共享全局目录。

应用通过目标 Node 的绝对路径执行其 npm，并固定全局安装目录；不会切换默认 Node。此功能调用 npm 是运行时管理既有包的例外，开发依赖仍只使用 pnpm。版本调整从用户配置的 registry 安装，沿用用户认证配置和代理；不接受 `latest`、范围、URL 或 Git 输入。

版本调整的安装脚本默认关闭，可在确认窗口单次勾选允许；关闭脚本可能影响需要构建或下载二进制的工具。删除须点击「执行删除」，卸载始终禁止脚本。npm、corepack、链接包和损坏包只读；pnpm/yarn 的普通安装包可操作，但不会强制覆盖其他工具的命令链接。

操作前复查包及目录是否变化，操作后更新真实列表。失败或取消可能已经产生部分变更，不保证自动回滚。包任务与 Node 安装共用单任务互斥、日志、取消和退出回收；历史仍仅保留本次运行最近 30 条。

## 构建和验证

开发要求 Xcode 26.0.1 / Swift 6.2（当前验证环境），无需额外 Swift 包。工程提交在仓库中；生成器仅使用 Python 标准库，构建时更新源文件列表。

```sh
bash macos/scripts/test.sh
bash macos/scripts/build.sh
bash macos/scripts/package.sh --skip-build
```

可以直接打开 `macos/GUINVM.xcodeproj`，选择 GUINVM scheme。核心模块为静态库，应用只链接系统框架。最低部署版本为 macOS 14；当前实际运行验证在 macOS 15.7.5，尚未在 macOS 14 真机运行验证。

构建缓存默认放在 `~/Library/Caches/gui-nvm/DerivedData/`，避免外部磁盘的附加元数据影响代码签名。可使用 `GUI_NVM_DERIVED_DATA` 指定其他本机 APFS 目录。详细验收结果见 [verification.json](verification.json)，任务清单见 [checklist.json](checklist.json)。本次应用已安装到 `~/Applications/gui-nvm.app`。

快捷键：⌘1 项目、⌘2 Node 版本、⌘3 全局包、⌘4 任务、⌘5 设置；⌘K 搜索当前项目/版本/全局包页面，⌘O 添加项目，⌘⇧O 添加扫描目录，⌘R 刷新（全局包页会重新扫描包），⌘⇧R 开始或取消项目扫描，⌘Q 退出。

现有 Web 和 auto-switch 回归仍使用固定 Node 与 pnpm：

```sh
. "$HOME/.nvm/nvm.sh" --no-use
nvm use 22.22.3
pnpm gui:build
pnpm gui:test
pnpm run test:auto
dot_clean ./
```

测试在独立临时目录中创建项目与 nvm 安装，不修改用户默认版本。UI 验证可通过 `GUI_NVM_DATA_DIR`、`GUI_NVM_LEGACY_DIR`、`GUI_NVM_NVM_DIR` 指向隔离目录，并设置 `GUI_NVM_NO_SYNC=1` 关闭启动同步。这些开关只用于进程启动配置，不包含凭据。

未包含 Intel、Mac App Store、自动更新、Node 卸载、删除项目及 shell 集成安装器。没有新增第三方依赖，没有升级现有依赖。
