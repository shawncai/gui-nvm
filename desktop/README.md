# gui-nvm 本机界面

这是 gui-nvm 的 Web 入口。React 界面由只监听 `127.0.0.1` 的 Node 服务提供；复用仓库中的 nvm 和已审查的 node-semver。原生 SwiftUI 应用的安装和构建方式见 [macOS 应用说明](../macos/README.md)，完整使用指南见 [仓库 README](../README.md)。

## 启动

macOS 双击仓库根目录的 `启动 gui-nvm.command`。关闭该终端或按 `Ctrl+C` 会停止服务，并取消当前安装任务。

也可在仓库根目录运行：

```sh
. "$HOME/.nvm/nvm.sh" --no-use
nvm use 22.22.3
pnpm --dir desktop install --frozen-lockfile --ignore-scripts
pnpm gui:build
pnpm gui:start
```

默认地址 `http://127.0.0.1:4783`。端口冲突时设置 `GUI_NVM_PORT`。开发使用 `pnpm gui:dev`，设计样例使用 `pnpm --dir desktop demo`；演示模式不会操作本机项目。

## 功能与数据

- 首次扫描仓库的上级目录。通过「扫描目录 +」添加其他目录、用户主目录或外接卷；项目清单的范围取决于已添加的扫描目录。
- 递归查找 `package.json`、`.nvmrc`、`.node-version`，包含 monorepo 子项目。跳过依赖、构建输出、隐藏目录及符号链接目录。单次最多扫描 50,000 个目录，权限错误和达到上限会显示在界面中。额外项目可直接添加。
- 沿父目录向上查找版本声明；最近一级目录优先，同级 `.nvmrc` > `.node-version` > `package.json` 的 `engines.node`。
- 从 `NVM_DIR`（默认 `~/.nvm`）列出 nvm 管理的全部已安装版本。不会导入其他 Node 管理器的安装。
- 目标版本支持已安装版本、nvm 别名，以及 `engines.node` 的 semver 范围。预览后显式保存；继承配置会写到当前项目，不覆盖父目录。目标版本未安装、文件被外部修改、声明优先级冲突或符号链接文件会阻止保存。
- Node 官方索引提供可安装版本、发布日期和架构适配；官方 release schedule 快照提供 Current、LTS、维护期和 EOL 描述。版本库可手动同步；断网显示缓存及同步错误。同步与安装优先使用代理环境变量，其次读取 macOS 已启用的 HTTP/HTTPS 系统代理；不修改系统网络设置。
- 安装在独立临时 NVM_DIR 中运行仓库 nvm，使用官方二进制与 nvm 校验流程，禁止回退源码编译、跳过默认全局包。成功后移入真实版本目录；失败和取消不会发布半成品，不修改真实默认版本。可查看日志和取消任务。
- 「设为默认」显式更新 `NVM_DIR/alias/default`。配置保存和默认版本变更不会重启正在运行的 Node 进程；终端自动切换沿用此仓库原有的 auto-switch 配置。

本地应用状态和版本索引缓存位于 `~/Library/Application Support/gui-nvm/`。当前任务记录保存在服务内存中，重启服务后清空。支持周期快照日期为 2026-10-21，见 `server/release-schedule.json`；维护此快照时使用 Node 官方 Release 仓库。

## 验证

```sh
nvm use 22.22.3
pnpm gui:build
pnpm gui:test
pnpm run test:auto
```

后端测试使用独立临时目录，不修改现有项目。依赖版本、安全审查和安装约束见 `dependency-review.json`。默认测试同时验证 Web 打包结构，因此全新 checkout 应先构建再测试。

## 来源

- [Node 发布索引](https://nodejs.org/dist/index.json)
- [Node 官方支持周期](https://github.com/nodejs/Release/blob/main/schedule.json)
- [Tabler 图标](https://github.com/tabler/tabler-icons)
