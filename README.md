# eon-workspace

基于 **frame** 的 Emacs 工作区插件，借鉴 [perspective](https://github.com/nex3/perspective-el) 与 [projectile](https://github.com/bbatsov/projectile) 的部分能力，但实现路径不同：每个 workspace 独占一个 frame，并绑定一个不可变更的工作目录。

## 特性

- **Frame 隔离**：不同 workspace 运行在不同 frame 中
- **固定根目录**：创建时绑定 `root`，之后不可修改
- **创建即切换**：`eon-workspace-create` 从已知项目列表选择（已打开的工作区优先排在前面，均按最近使用排序）；已打开则切换 frame，未打开则新建
- **Buffer 隔离**：`eon-workspace-buffer-isolation-mode` 通过 `buffer-predicate` 与 `read-buffer-function` 限制各 workspace 可见 buffer
- **项目内找文件**：`eon-workspace-find-file` 用 `fd` 列出文件，Ivy 选择（支持 `ivy-occur`），遵守 `.gitignore`，并叠加 `.eon.yaml` 忽略规则
- **项目内搜索**：`eon-workspace-rg` 在当前 workspace 根目录执行 `counsel-rg`
- **Action 系统**：在 `.eon.yaml` 中定义可复用的 shell 操作（编译、部署、同步等），支持本地执行与 SSH 远程执行
- **清理**：`eon-workspace-cleanup` 关闭当前 workspace 中位于根目录之外的文件 buffer

## 依赖

| 组件 | 用途 |
|------|------|
| Emacs ≥ 27.1 | `window-buffer-change-functions` 等 API |
| [fd](https://github.com/sharkdp/fd) | `eon-workspace-find-file` 列文件 |
| [ivy](https://github.com/abo-abo/swiper) | `eon-workspace-find-file`、`eon-workspace-switch-to-buffer`（调用时 `require`） |
| [counsel](https://github.com/abo-abo/swiper) | `eon-workspace-rg`（可选，调用时 `require`） |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | `eon-workspace-rg` 后端 |

## 安装

将本仓库放到任意目录，在 Emacs 配置中加入：

```elisp
(use-package eon-workspace
  :load-path "/path/to/workspace"
  :demand t
  :bind (("<f8>" . eon-workspace-create)
         ([remap switch-to-buffer] . eon-workspace-switch-to-buffer))
  :config
  (eon-workspace-buffer-isolation-mode 1))
```

若使用 Ivy 且 `ivy-mode-map` 中已有 `[remap switch-to-buffer]`，需在其加载后覆盖：

```elisp
(with-eval-after-load 'ivy
  (define-key ivy-mode-map [remap switch-to-buffer]
              #'eon-workspace-switch-to-buffer))
```

## 命令

| 命令 | 说明 |
|------|------|
| `eon-workspace-create` | 从已知项目列表创建或切换到 workspace |
| `eon-workspace-find-file` | 在当前 workspace 内找文件并打开 |
| `eon-workspace-rg` | 在当前 workspace 根目录 ripgrep（`C-u` 可输入额外 rg 参数） |
| `eon-workspace-switch-to-buffer` | 仅在当前 workspace 的 buffer 列表中切换 |
| `eon-workspace-cleanup` | 清理根目录外的文件 buffer |
| `eon-workspace-kill` | 删除 workspace（先处理未保存 buffer，再关 frame） |
| `eon-workspace-list` | 列出所有 workspace |
| `eon-workspace-add-project` | 将目录加入已知项目列表 |
| `eon-workspace-remove-project` | 从已知项目列表移除目录 |
| `eon-workspace-init-config` | 在 workspace 根目录创建 `.eon.yaml` 模板 |
| `eon-workspace-config` | 编辑 `.eon.yaml`（ignore-patterns 与 action.default） |
| `eon-workspace-action` | 从已配置的 action 中选择并执行 |
| `eon-workspace-action-default` | 执行 `action.default` 指定的默认 action |
| `eon-workspace-compile` | 执行 compile 命令（向后兼容，推荐迁移到 action.compile） |

每个 workspace 的 action 还会自动注册为 `M-x eon-workspace-action-<name>` 形式的独立命令，可直接调用或绑定快捷键。

## 已知项目与最近使用

两个独立文件（目录默认同 `user-emacs-directory` 或 `no-littering-var-directory`）：

| 文件 | 作用 |
|------|------|
| `eon-workspace-projects.el` | 已知项目固定集合，仅 `add-project` / `remove-project` 增删，顺序稳定 |
| `eon-workspace-recent.el` | F8 列表的 MRU 顺序，每次切换/创建 workspace 时更新；已打开项优先排前 |

加载 `projects` 时会自动去重并写回。首次无 `recent` 文件时，用当前 `projects` 顺序初始化。

创建 workspace **不会**自动加入 `projects`，需 `eon-workspace-add-project`；切换/创建会更新 `recent`。

路径：`eon-workspace-projects-file`、`eon-workspace-recent-file`（均为 nil 时自动选择上述默认路径）。

## `.eon.yaml`

放在 workspace 根目录，配置忽略规则与 action。

### 文件忽略

```yaml
ignore-patterns:
  - ".git"
  - "*.log"
  - "dist"
  - "node_modules"
```

模式会作为 `fd -E` 和 `rg --glob !` 参数叠加到 `.gitignore` 之上。

### Action 系统

`action` 子树下定义可执行的 shell 操作，每个子 key 对应一个命令。支持两种格式：

**1. 块字符串格式（简单命令）：**

```yaml
action:
  default: compile
  compile: |
    echo "building..."
    make all -j32
  test: |
    pytest -v
```

- `default` 指定 `M-x eon-workspace-action-default` 执行的默认 action
- `M-x eon-workspace-action` 从列表中交互选择
- `M-x eon-workspace-action-<name>` 直接执行指定 action

**2. 结构化格式（exec / ssh-exec，支持多步编排与远程执行）：**

```yaml
action:
  deploy:
    - exec: rsync -avz ./ devcloud:/path/to/project/
    - ssh-exec:
        remote: devcloud
        exec: |
          set -ex
          cd /path/to/project
          make all -j32
    - exec: echo "部署完成"
```

结构化格式的 key：

| Key | 说明 |
|-----|------|
| `exec` | 本地 shell 命令（块字符串或行内值） |
| `ssh-exec` | 通过 SSH 在远程执行 |

`ssh-exec` 支持的字段：

| 字段 | 必填 | 说明 |
|------|------|------|
| `remote` | 是 | SSH 目标主机（`~/.ssh/config` 中配置的 Host） |
| `exec` | 是 | 远程执行的命令（块字符串格式） |
| `arg` | 否 | 传给 `ssh` 的额外参数，如 `-p 2222 -o StrictHostKeyChecking=no` |

生成的 SSH 命令格式为 `ssh <arg> <remote> bash -l -s <<-EOF`。`-l` 确保远端加载 `.bash_profile` 中的 PATH；顶层 heredoc 使用无引号定界符，可在 `ssh-exec` 中引用前面 `exec` 步骤里设置的本地 shell 变量：

```yaml
action:
  proto:
    - exec: |
        temp_dir=$(ssh devcloud "mktemp -d")
        scp -r ./proto/* devcloud:"$temp_dir/"
    - ssh-exec:
        remote: devcloud
        exec: |
          cd $temp_dir    # 本地变量，在发送到 SSH 前被展开
          make proto
```

如有需要原样传给远端的 `$`，用 `\$` 转义。

### Config 界面

`M-x eon-workspace-config` 打开 widget 界面，可编辑：
- `ignore-patterns`：新增/删除忽略模式
- `action.default`：指定默认 action

其他 action 以只读方式展示。新增、修改、删除 action 请直接编辑 `.eon.yaml`，保存后在界面中点「还原」刷新。

快捷键：`C-c C-s` 保存、`C-c C-k` 还原、`q` 退出。

## 配置项（节选）

| 变量 | 说明 |
|------|------|
| `eon-workspace-projects-file` | 已知项目列表文件路径 |
| `eon-workspace-recent-file` | 最近使用顺序文件路径 |
| `eon-workspace-config-file` | 配置文件名（默认 `.eon.yaml`） |
| `eon-workspace-action-key` | action 子树的 YAML key 名（默认 `action`） |
| `eon-workspace-action-default-key` | 默认 action 的 key 名（默认 `default`） |
| `eon-workspace-fd-executable` | `fd` 可执行文件（默认 `fd`） |
| `eon-workspace-open-dired-on-create` | 创建后是否打开 dired |
| `eon-workspace-confirm-kill` | 删除 workspace 前是否确认 |

完整选项：`M-x customize-group RET eon-workspace RET`

## 与 perspective / projectile 的差异

| | perspective | eon-workspace |
|---|-------------|---------------|
| 隔离单位 | 同一 frame 内 perspective | 每个 workspace 一个 frame |
| 项目列表 | 随 perspective 状态 | `projects.el` + `recent.el` |
| 根目录 | 可随项目变化 | 创建后固定 |
| 找文件 / rg | projectile 体系 | `fd` + `.eon.yaml`，`counsel-rg` |

## License

见仓库许可证文件（若未单独声明，以作者约定为准）。
