# v0.40.3-auto.1

基于 nvm v0.40.3 的个人 Fork，首版为交互式 zsh 添加项目 Node 版本自动切换。

- 就近识别 `.nvmrc`、`.node-version`、`package.json.engines.node`，同目录按上述顺序选择。
- 打开终端、切换目录、修改声明后自动切换；范围选择最高已安装稳定版，离开项目恢复 default。
- `nvm auto on|off|status|refresh`，支持手动临时覆盖、缓存、错误提示去重及失败环境恢复。
- 固定内置 semver 7.7.3，保留 ISC 许可及供应链核验记录；解析器不执行项目代码。
- 独立源码目录与可回滚迁移脚本，保留原有 Node、全局包、别名、缓存及 Homebrew 安装。

安装（已有 nvm 和 Node，macOS/Linux，交互式 zsh）：

```sh
git clone --branch v0.40.3-auto.1 https://github.com/shawncai/gui-nvm.git "$HOME/.local/share/nvm-fork"
bash "$HOME/.local/share/nvm-fork/install-fork.sh"
exec zsh
nvm auto status
```

若该源码目录已存在，请先阅读[更新与回滚说明](README.auto-switch.zh-CN.md)，不要覆盖已有工作。本版不自动安装 Node，不自动升级上游。安装后仍保持 `NVM_DIR=~/.nvm`。

回滚：

```sh
bash "$HOME/.local/share/nvm-fork/uninstall-fork.sh"
exec zsh
```

验证入口为 `pnpm run test:auto`，包含解析器、zsh 集成、安装回滚以及精选上游 shell 兼容测试；运行时使用隔离目录和已有/模拟 Node，不下载 Node。GitHub CI 覆盖 Linux 和 macOS。
