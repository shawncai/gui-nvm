# 自动切换验证

`sh test-auto/upstream.sh` 运行经过挑选的上游测试和兼容性检查，**不是完整的
上游 fast / slow 测试套件**。每个用例都在临时的完整源码副本中执行，使用独立
`NVM_DIR`、用户目录和临时目录；结束或失败后回收这些副本，不修改已安装的 Node。

覆盖范围：

- `sh`、`bash`、`zsh` 三种 shell 的十个 fast 单元测试，包括路径切换、向上查找、
  本地版本路径与比较、已安装版本检查及按需切换。
- 上游的 sourcing 用例，包括 `--no-use`、`--install`、默认版本、保持当前版本、
  全局 alias、调用方参数及卸载。
- 上游 `nvm run` 的指定版本、`.nvmrc`、参数和缺少版本行为。
- 补充的 `nvm use/run/exec/install/unload` 兼容性检查，包含 `exec` 的空格参数、
  退出码传递、父 shell 版本保持，以及重复安装已有版本。

测试中的 Node 可执行文件只报告模拟版本，不是下载的 Node。`curl` 被替换为只
返回上游仓库已有 `index.tab` 的本地替身，其他 URL 会使测试失败。即使安装已有
版本，上游 `nvm install` 也先解析远端版本，所以这条路径使用本地索引替身。
测试 PATH 是系统工具白名单，不包含 npm/yarn，也不调用包管理器。没有运行安装
新 Node、编译 Node 或全局包迁移测试；这些行为不属于这份离线兼容证据。

## 发现的上游既存差异

在本机 macOS 上，上游 `test/fast/Unit tests/nvm_strip_path` 的最后一个断言失败：
输入 `:/a/b/bin::/c/d/bin:` 时，预期保留末尾冒号，实际输出是
`:/a/b/bin::/c/d/bin`。使用未修改的 `v0.40.3` 标签源码也得到同样结果。
该用例未列入此处的可移植精选集合，也未借本次功能修改上游路径算法；本次
路径切换风险由上游 `nvm_change_path` 和交互式 zsh 的环境恢复测试覆盖。

在 macOS 的仓库目录可这样复核原版行为：

```sh
task_baseline=$(mktemp -d)
git show v0.40.3:nvm.sh > "$task_baseline/nvm.sh"
NVM_DIR="$task_baseline" sh -c '
  . "$NVM_DIR/nvm.sh" --no-use
  nvm_strip_path ":/a/b/bin::/c/d/bin:" /bin
'
rm -rf "$task_baseline"
```

`auto-switch/test-resolve.cjs` 独立验证 semver 范围、无匹配、非法输入、中文路径、
预发布排除、输出协议及不执行项目代码；`auto-switch/verify-vendor.py` 离线验证
固定版本依赖的完整文件清单。
