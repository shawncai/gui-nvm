# nvm 自动切换 Fork

本 Fork 基于上游 **nvm v0.40.3**，增加交互式 zsh 的项目 Node 版本自动切换。仓库为 [shawncai/nvm](https://github.com/shawncai/nvm)，维护分支为 `auto-switch`，首版发布标签为 `v0.40.3-auto.1`。上游使用说明见 [README.md](README.md)。

## 自动识别规则

新终端启用功能后、`cd` / `pushd` / `popd` 切换目录后，以及显示提示符前，检查当前目录的版本要求。声明在当前目录或祖先目录内生效；最近的声明所在目录优先，同一目录依次检查：

| 优先级 | 来源 | 规则 |
| --- | --- | --- |
| 1 | `.nvmrc` | 沿用 nvm 原生文件解析和本地版本/别名解析，支持完整版本、部分版本及 `lts/*` 等别名 |
| 2 | `.node-version` | 单个版本或 nvm 别名；不支持 `^`、`>=` 等范围表达式 |
| 3 | `package.json` 的 `engines.node` | 使用固定的 `node-semver 7.7.3` 解析范围，选择满足范围的最高已安装稳定版 |

例如子目录有 `engines.node`，父目录有 `.nvmrc`，子目录的声明生效。没有 `engines.node` 的 `package.json` 不阻断向父目录继续查找。

- 版本缺失、声明无效或文件不可读时，保持当前 Node，提示来源、原因和处理方式；不会改用低优先级声明。
- 不自动安装 Node，不因切换目录联网。需要其他版本时，由你显式运行 `nvm install <版本>`。
- 离开有版本声明的目录后，恢复现有的 `nvm default`；默认版本不可用时保留当前环境并提示。安装器不会修改 default 别名。
- 手动 `nvm use` 可临时覆盖自动选择，直到目录或声明发生变化，或执行 `nvm auto refresh`。
- 未变化的配置走缓存路径；重复错误按状态去重。安装新版本或修改别名后重新解析。
- 只有交互式 zsh 注册钩子。Bash、脚本、CI 及非交互 shell 的使用方式保持原状。

项目声明仅作为数据读取。`package.json` 使用 `JSON.parse`，不会执行项目脚本，也不会加载项目依赖。解析器仅使用 `NVM_DIR` 中已安装的 Node，并移除解析子进程的 `NODE_OPTIONS`、`NODE_PATH`。

解析 `engines.node` 需要至少一个已安装的 Node 10 或更高版本。`package.json` 必须是可读取的普通文件且不超过 1 MiB；版本范围必须是非空字符串且不超过 4,096 个字符。`.nvmrc` 和 `.node-version` 的大小上限为 8 KiB。无效 JSON、无效范围及超限文件会提示错误并保留当前 Node。`engines.node` 使用 semver 范围，不接受 `lts/*` 等 nvm 别名，也不选择预发布版本。

## 日常命令

```sh
nvm auto on       # 启用本 shell 的钩子并检查当前项目
nvm auto status   # 显示来源、要求版本、解析结果及当前版本
nvm auto refresh  # 忽略缓存，立即重新检查
nvm auto off      # 移除本 shell 的自动切换钩子
```

重复执行 `on` 不会重复注册钩子。`nvm unload` 会清理自动切换函数、状态及钩子。`source nvm.sh --no-use` 本身不注册钩子；下面的安装器在 `.zshrc` 的自有区块中显式调用 `nvm auto on`。

`off` 和 `unload` 只影响当前 shell；只要 `.zshrc` 仍保留启用区块，新终端仍会自动启用。需要持久恢复原安装时，使用卸载脚本。

## 安装与本机迁移

要求已有 nvm 目录和已安装的 Node；安装脚本使用 Bash 3.2+ 及常见系统命令，不需要 npm、yarn 或 Python。macOS 使用系统 Bash 即可。源码目录必须独立于 `NVM_DIR`，profile 文件及其链接目标必须位于这两个目录外。安装后不要移动或删除源码目录。

```sh
mkdir -p "$HOME/.local/share"
git clone --branch auto-switch https://github.com/shawncai/nvm.git "$HOME/.local/share/nvm-fork"
cd "$HOME/.local/share/nvm-fork"
git checkout v0.40.3-auto.1
bash install-fork.sh --nvm-dir "$HOME/.nvm" --profile "${ZDOTDIR:-$HOME}/.zshrc"
```

已经克隆仓库时，跳过 `git clone`。在自己的开发分支迭代时可保持 `auto-switch` 分支，不必切到发布标签。

安装器先备份以下内容至 `NVM_DIR/.nvm-fork-install`，然后切换入口：

- 原来的 `nvm.sh`、`nvm-exec`、`bash_completion`、`auto-switch` 文件或符号链接；原本不存在也会记录。
- `.zshrc` 原始内容及其链接信息。链接形式的 `.zshrc` 保持为链接。

四个入口会指向独立 checkout，`.zshrc` 末尾追加 `# >>> nvm auto-switch fork >>>` 和 `# <<< nvm auto-switch fork <<<` 包围的区块。区块设置既有 `NVM_DIR`，加载 Fork 并启用自动切换。已有配置行不会被覆盖。安装器不会修改 Homebrew 软件包，也不会移动或清空 Node 版本、全局包、别名、缓存。

重复安装会校验现有状态，不重复追加配置。安装失败会恢复事务开始前的入口和配置。备份目录权限为 `700`；其中可能包含你原有的 shell 配置，请勿提交到 GitHub。

安装只修改后续加载入口，已经运行的终端不会自动换用新函数。打开新终端，或运行：

```sh
source "${ZDOTDIR:-$HOME}/.zshrc"
nvm auto status
```

然后进入有声明的项目，使用 `node --version` 检查实际版本。现有其他 zsh 目录/提示符钩子会保留。

## 卸载与回滚

```sh
cd "$HOME/.local/share/nvm-fork"
bash uninstall-fork.sh --nvm-dir "$HOME/.nvm" --profile "${ZDOTDIR:-$HOME}/.zshrc"
```

卸载脚本恢复安装前的入口，只移除自有 `.zshrc` 区块，保留安装后用户添加或修改的其他配置。若配置没有其他变化，恢复完整原始内容，包括原来没有文件或没有末尾换行的情况。原始备份保留在 `NVM_DIR/.nvm-fork-uninstalled-时间-进程号` 目录。

如果入口被其他程序替换、`.zshrc` 链接目标变化，或自有区块被手动改动，脚本会在修改前停止并报告冲突。核对冲突后再运行，避免覆盖你的改动。不要直接删除备份来强制安装。安装锁残留时，先确认没有安装/卸载进程正在运行，再处理报告中的锁目录。

卸载后打开新终端以使用恢复后的 nvm；已经运行的 shell 仍可能保留 Fork 函数。Node 版本、全局包、别名和缓存始终保留。

## 测试与后续迭代

完整验证入口（无需安装项目开发依赖）：

```sh
nvm use
pnpm run test:auto
```

测试使用隔离的 `NVM_DIR`。上游兼容检查运行精选 fast、sourcing 和命令用例，使用离线 fixture 与模拟 Node，不代表完整上游安装矩阵。Fork 的 CI 覆盖 macOS 和 Linux；原上游工作流仅在 `nvm-sh/nvm` 仓库运行，避免 Fork 自动执行 npm/yarn 聚合脚本。

安装器测试在临时目录构造 mock checkout、Homebrew 入口和 profile，不修改真实 `HOME`、项目声明或 Node 安装：

```sh
bash test-auto/installer.sh
```

覆盖幂等安装、符号链接和普通文件恢复、缺失 profile、中文/空格/引号路径、用户后续配置保留、入口冲突拒绝，以及安装/卸载失败的事务回滚。其他自动切换与解析器测试由仓库 CI 运行。

开发时保留 `origin` 指向个人 Fork、`upstream` 指向 `nvm-sh/nvm`，在 `auto-switch` 分支提交。上游版本和 `node-semver` 依赖只在明确审查、验证后升级；不要用上游安装脚本覆盖 Fork 入口。发布新版本前运行自动切换、解析器、安装器及相关上游兼容测试，完成检查清单，再创建版本标签和 GitHub Release。
