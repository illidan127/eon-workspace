;;; eon-workspace.el --- Frame-based workspaces with project root -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, workspace, frames, project

;;; Commentary:
;;
;; 一个结合 perspective 与 projectile 部分理念的 Emacs 工作区插件。
;;
;; 特性：
;;   - 每个 workspace 运行在独立 frame 中
;;   - 每个 workspace 绑定一个工作目录，创建后不可变更
;;   - eon-workspace-create 从已知项目列表选择（按 recent 文件 MRU 排序）：已打开则切换，未打开则创建
;;   - 可以在 workspace 中打开非工作目录的文件
;;   - 每个 workspace 维护私有 buffer 列表（基于 window-buffer-change-functions
;;     自动追踪 frame 中显示过的 buffer），eon-workspace-switch-to-buffer
;;     仅在该列表中切换
;;   - eon-workspace-buffer-isolation-mode（global minor mode）启用后，
;;     通过 frame 的 buffer-predicate 与 read-buffer-function 两层机制，
;;     做到 workspace 间 buffer 列表互相隔离。同一文件被多个 workspace
;;     打开时仍是同一 buffer，可同时归属多个 workspace 的私有列表
;;   - eon-workspace-find-file 通过 fd 列出 ROOT 下文件，ivy 补全选择
;;     （支持 ivy-occur 等 ivy-read 能力），
;;     遵守 .gitignore，并叠加 ROOT/.eon.yaml 中
;;     ignore-patterns: 配置的额外过滤模式
;;   - 提供清理命令，清理当前 workspace 中非工作目录文件对应的 buffer，
;;     临时 buffer（无文件关联、名字以空格或 * 开头）不处理
;;
;; .eon.yaml 示例（放在 workspace 根目录）：
;;
;;   ignore-patterns:
;;     - "*.log"
;;     - "dist"
;;     - "node_modules"
;;
;; 主要命令：
;;   M-x eon-workspace-create          创建或切换到 workspace（已知项目列表）
;;   M-x eon-workspace-find-file       在当前 workspace 打开文件
;;   M-x eon-workspace-open             从任意 workspace 选择文件打开（不切换工作区）
;;   M-x eon-workspace-rg              在当前 workspace ROOT 中用 rg 搜索
;;   M-x eon-workspace-switch-to-buffer 在 workspace 私有 buffer 列表中切换（Marginalia + C-k kill）
;;   M-x eon-workspace-cleanup         清理非工作目录的文件 buffer
;;   M-x eon-workspace-kill            删除 workspace 并关闭其 frame
;;   M-x eon-workspace-list            列出所有 workspace
;;   M-x eon-workspace-add-project     手工把目录加入已知项目列表
;;   M-x eon-workspace-remove-project  从已知项目列表中移除
;;   M-x eon-workspace-init-config     在当前 workspace 根目录创建 .eon.yaml
;;   M-x eon-workspace-config           用 customize 风格界面编辑 .eon.yaml
;;   M-x eon-workspace-compile          执行 .eon.yaml 中配置的 compile 命令

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup eon-workspace nil
  "Frame-based workspaces with bound working directories."
  :group 'convenience
  :prefix "eon-workspace-")

(defcustom eon-workspace-default-name-function #'eon-workspace--default-name
  "由 ROOT 目录生成默认 workspace 名称的函数。"
  :type 'function
  :group 'eon-workspace)

(defcustom eon-workspace-confirm-kill t
  "删除 workspace 前是否确认。"
  :type 'boolean
  :group 'eon-workspace)

(defcustom eon-workspace-open-dired-on-create t
  "创建 workspace 后是否在其 frame 中打开 ROOT 的 dired。"
  :type 'boolean
  :group 'eon-workspace)

(defcustom eon-workspace-projects-file nil
  "保存已知 workspace 项目列表的文件路径（固定集合，仅增删不改序）。
为 nil 时自动选择：
- 若已加载 `no-littering'，使用 `no-littering-var-directory' 下
  的 eon-workspace-projects.el
- 否则使用 `user-emacs-directory' 下的 eon-workspace-projects.el"
  :type '(choice (const :tag "自动" nil) file)
  :group 'eon-workspace)

(defcustom eon-workspace-recent-file nil
  "保存最近使用工作区顺序的文件路径。
为 nil 时使用与 `eon-workspace-projects-file' 同目录下的
eon-workspace-recent.el。"
  :type '(choice (const :tag "自动" nil) file)
  :group 'eon-workspace)

(defcustom eon-workspace-config-file ".eon.yaml"
  "Workspace 根目录下的配置文件名。"
  :type 'string
  :group 'eon-workspace)

(defcustom eon-workspace-ignore-patterns-key "ignore-patterns"
  ".eon.yaml 中表示忽略模式列表的顶层 key 名。"
  :type 'string
  :group 'eon-workspace)

(defcustom eon-workspace-compile-key "compile"
  ".eon.yaml 中表示 compile 命令的顶层 key 名。
对应的值应为多行 shell 命令，支持 YAML 块字符串格式（| 或 >）。"
  :type 'string
  :group 'eon-workspace)

(defcustom eon-workspace-fd-executable "fd"
  "列出 workspace 文件时使用的 fd 可执行文件。
需要支持 -H、-0、-tf、-E、--strip-cwd-prefix 等选项。"
  :type 'string
  :group 'eon-workspace)

(defcustom eon-workspace-fd-args
  '("-H" "-0" "-tf" "--strip-cwd-prefix" "-c" "never")
  "传给 fd 的基础参数（不含 -E 忽略项与最后的搜索路径）。
参考 `projectile-git-fd-args'。
fd 默认会遵守 .gitignore / .ignore / .fdignore，因此 ROOT 下
受 git 忽略的文件已被自动排除。.eon.yaml 中的 ignore-patterns
作为额外的 -E 模式叠加传入。"
  :type '(repeat string)
  :group 'eon-workspace)

(defcustom eon-workspace-rg-initial-input nil
  "`eon-workspace-rg' 传给 `counsel-rg' 的初始搜索输入。"
  :type 'sexp
  :group 'eon-workspace)

(defcustom eon-workspace-shared-buffer-predicate
  #'eon-workspace--default-shared-buffer-p
  "判定一个 buffer 是否被所有 workspace 共享可见的谓词函数。
共享 buffer 不受 buffer 隔离限制。默认共享：
minibuffer、名字以空格开头的 internal buffer、*scratch*、*Messages*。"
  :type 'function
  :group 'eon-workspace)


;;;; 数据结构

(cl-defstruct (eon-workspace
               (:constructor eon-workspace--make)
               (:copier nil))
  name      ;; 唯一名称
  root      ;; 工作目录绝对路径（末尾带 /），一旦创建不可变更
  frame     ;; 关联 frame
  buffers)  ;; 该 workspace 私有的 buffer 列表（按访问顺序，最近的在前）

(defvar eon-workspace--list nil
  "所有已创建的 workspace 列表。")

(defvar eon-workspace-switch-hook nil
  "切换 workspace 后调用的 hook，无参数。")

(defvar eon-workspace-create-hook nil
  "创建 workspace 后调用的 hook，无参数。")

(defvar eon-workspace-kill-hook nil
  "删除 workspace 后调用的 hook，无参数。")

(defvar eon-workspace--projects nil
  "已知 workspace 项目目录列表（运行时缓存，固定顺序）。")

(defvar eon-workspace--projects-loaded nil
  "是否已经从文件加载过项目列表。")

(defvar eon-workspace--recent nil
  "最近使用的工作区目录列表（运行时缓存，MRU 顺序）。")

(defvar eon-workspace--recent-loaded nil
  "是否已经从文件加载过最近使用列表。")


;;;; 工具函数

(defun eon-workspace--default-name (root)
  "由 ROOT 目录生成默认 workspace 名称。"
  (file-name-nondirectory (directory-file-name root)))

(defun eon-workspace--normalize-dir (dir)
  "把 DIR 转为规范绝对路径（末尾 /）；目录存在时用 `file-truename` 去重 symlink。"
  (let ((expanded (expand-file-name dir)))
    (file-name-as-directory
     (if (file-directory-p expanded)
         (file-truename expanded)
       expanded))))

(defun eon-workspace--alive-p (ws)
  "判断 WS 是否仍持有有效 frame。"
  (and ws (frame-live-p (eon-workspace-frame ws))))

(defun eon-workspace--cleanup-dead ()
  "移除 frame 已销毁的 workspace。"
  (setq eon-workspace--list
        (seq-filter #'eon-workspace--alive-p eon-workspace--list)))

(defun eon-workspace--find-by-name (name)
  "按 NAME 查找 workspace。"
  (seq-find (lambda (ws) (string= (eon-workspace-name ws) name))
            eon-workspace--list))

(defun eon-workspace--find-by-frame (frame)
  "按 FRAME 查找 workspace。"
  (seq-find (lambda (ws) (eq (eon-workspace-frame ws) frame))
            eon-workspace--list))

(defun eon-workspace-current ()
  "返回当前 frame 对应的 workspace，未关联返回 nil。"
  (eon-workspace--find-by-frame (selected-frame)))

(defun eon-workspace--read-workspace (prompt &optional mark-open)
  "用 PROMPT 让用户选择一个 workspace，返回其 ROOT 绝对路径。
显示格式与 `eon-workspace--read-project' 一致（~ 前缀、重名时 〔basename〕）。
MARK-OPEN 非 nil 时，对已打开项标注 〔已打开〕。"
  (eon-workspace--cleanup-dead)
  (unless eon-workspace--list (user-error "尚无任何 workspace"))
  (let* ((roots (mapcar #'eon-workspace-root eon-workspace--list))
         (pairs (eon-workspace--project-display-pairs roots mark-open))
         (choices (mapcar #'car pairs))
         (selected (completing-read prompt choices nil t)))
    (cdr (assoc-string selected pairs))))

(defun eon-workspace--file-in-root-p (file root)
  "判断 FILE 是否在 ROOT 目录之下。"
  (and file root
       (string-prefix-p (eon-workspace--normalize-dir root)
                        (expand-file-name file))))

(defun eon-workspace--data-directory ()
  "返回存放 eon-workspace 数据文件的目录。"
  (or (bound-and-true-p no-littering-var-directory)
      user-emacs-directory))

(defun eon-workspace--projects-file-path ()
  "返回实际使用的项目列表文件路径。"
  (or eon-workspace-projects-file
      (expand-file-name "eon-workspace-projects.el"
                        (eon-workspace--data-directory))))

(defun eon-workspace--recent-file-path ()
  "返回实际使用的最近使用列表文件路径。"
  (or eon-workspace-recent-file
      (expand-file-name "eon-workspace-recent.el"
                        (eon-workspace--data-directory))))

(defun eon-workspace--read-list-file (file)
  "从 FILE 读取一个目录列表 sexp，失败返回 nil。"
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (condition-case _
          (let ((v (read (current-buffer))))
            (if (listp v) v nil))
        (error nil)))))

(defun eon-workspace--dedupe-dirs (dirs)
  "对 DIRS 去重（`eon-workspace--normalize-dir'），保留首次出现顺序。"
  (let (seen result)
    (dolist (d dirs)
      (when (and d (stringp d) (not (string-empty-p d)))
        (let ((nd (eon-workspace--normalize-dir d)))
          (unless (member nd seen)
            (push nd seen)
            (push nd result)))))
    (nreverse result)))

(defun eon-workspace--dirs-duplicated-p (dirs)
  "DIRS 按规范路径去重后是否变短（即存在重复项）。"
  (let ((dirs (or dirs nil)))
    (> (length dirs) (length (eon-workspace--dedupe-dirs dirs)))))

(defun eon-workspace--write-list-file (file header dirs)
  "把 DIRS 写入 FILE，文件头注释为 HEADER。"
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (let ((print-length nil)
          (print-level nil))
      (insert ";;; -*- lexical-binding: t; no-byte-compile: t -*-\n")
      (insert header "\n")
      (prin1 dirs (current-buffer))
      (insert "\n"))))

(defun eon-workspace--load-projects ()
  "从 `eon-workspace--projects-file-path' 读取项目列表（去重）。"
  (let* ((file (eon-workspace--projects-file-path))
         (raw (eon-workspace--read-list-file file))
         (deduped (eon-workspace--dedupe-dirs raw)))
    (setq eon-workspace--projects deduped
          eon-workspace--projects-loaded t)
    (when (eon-workspace--dirs-duplicated-p raw)
      (eon-workspace--save-projects))
    deduped))

(defun eon-workspace--ensure-projects-loaded ()
  "加载项目列表，并保证内存中为去重后的规范路径。"
  (unless eon-workspace--projects-loaded
    (eon-workspace--load-projects))
  (let ((deduped (eon-workspace--dedupe-dirs eon-workspace--projects)))
    (unless (equal deduped eon-workspace--projects)
      (setq eon-workspace--projects deduped)
      (eon-workspace--save-projects))))

(defun eon-workspace--save-projects ()
  "把项目列表写回 `eon-workspace--projects-file-path'。"
  (eon-workspace--write-list-file
   (eon-workspace--projects-file-path)
   ";; eon-workspace 已知项目列表，自动生成，请勿手工编辑。"
   (eon-workspace--dedupe-dirs eon-workspace--projects)))

(defun eon-workspace--load-recent ()
  "从 `eon-workspace--recent-file-path' 读取最近使用列表。"
  (let* ((file (eon-workspace--recent-file-path))
         (raw (eon-workspace--read-list-file file))
         (deduped (eon-workspace--dedupe-dirs raw)))
    (setq eon-workspace--recent deduped
          eon-workspace--recent-loaded t)
    ;; 首次无 recent 文件时，用当前 projects 顺序作为初始 MRU
    (when (and (not (file-readable-p file)) eon-workspace--projects)
      (setq eon-workspace--recent (copy-sequence eon-workspace--projects))
      (eon-workspace--save-recent))
    (when (eon-workspace--dirs-duplicated-p raw)
      (eon-workspace--save-recent))
    eon-workspace--recent))

(defun eon-workspace--ensure-recent-loaded ()
  "加载最近使用列表，并保证内存中为去重后的规范路径。"
  (eon-workspace--ensure-projects-loaded)
  (unless eon-workspace--recent-loaded
    (eon-workspace--load-recent))
  (let ((deduped (eon-workspace--dedupe-dirs eon-workspace--recent)))
    (unless (equal deduped eon-workspace--recent)
      (setq eon-workspace--recent deduped)
      (eon-workspace--save-recent))))

(defun eon-workspace--save-recent ()
  "把最近使用列表写回 `eon-workspace--recent-file-path'。"
  (eon-workspace--write-list-file
   (eon-workspace--recent-file-path)
   ";; eon-workspace 最近使用工作区（MRU），自动生成，请勿手工编辑。"
   (eon-workspace--dedupe-dirs eon-workspace--recent)))

(defun eon-workspace--touch-project (dir)
  "把 DIR 记入最近使用列表最前（仅更新 recent 文件）。"
  (eon-workspace--ensure-recent-loaded)
  (let ((d (eon-workspace--normalize-dir dir)))
    (setq eon-workspace--recent
          (cons d (delq d eon-workspace--recent)))
    (eon-workspace--save-recent)))

(defun eon-workspace--remember-project (dir)
  "把 DIR 加入已知项目列表末尾（若尚未存在），并记入最近使用。"
  (eon-workspace--ensure-projects-loaded)
  (let ((d (eon-workspace--normalize-dir dir)))
    (unless (member d eon-workspace--projects)
      (setq eon-workspace--projects
            (append eon-workspace--projects (list d)))
      (eon-workspace--save-projects))
    (eon-workspace--touch-project d)))

(defun eon-workspace--project-open-p (dir)
  "DIR 是否已绑定存活 workspace（有对应 frame）。
调用前需已执行 `eon-workspace--cleanup-dead'。"
  (let ((ws (eon-workspace--find-by-root dir)))
    (and ws (eon-workspace--alive-p ws))))

(defun eon-workspace--project-display-pairs (dirs &optional mark-open)
  "为 DIRS 生成 (显示名 . 绝对路径) 列表；显示名冲突时附带目录 basename 区分。
MARK-OPEN 非 nil 时，对已绑定且 frame 存活的工作区在显示名后标注 〔已打开〕。"
  (when mark-open (eon-workspace--cleanup-dead))
  (let ((paths (eon-workspace--dedupe-dirs dirs))
        (abbr-count (make-hash-table :test 'equal)))
    (mapcar
     (lambda (p)
       (let* ((abbr (eon-workspace--abbreviate-dir p))
              (n (gethash abbr abbr-count 0))
              (label (if (> n 0)
                         (format "%s 〔%s〕" abbr
                                 (file-name-nondirectory
                                  (directory-file-name p)))
                       abbr)))
         (puthash abbr (1+ n) abbr-count)
         (cons (if (and mark-open (eon-workspace--project-open-p p))
                   (format "%s  〔已打开〕" label)
                 label)
               p)))
     paths)))

(defun eon-workspace--known-projects ()
  "返回用于 F8 选择的项目列表：已知项目按最近使用排序。
不在 projects 中但出现在 recent 的项会被忽略。"
  (eon-workspace--ensure-recent-loaded)
  (eon-workspace--dedupe-dirs
   (append (seq-filter (lambda (d) (member d eon-workspace--projects))
                       eon-workspace--recent)
           (seq-remove (lambda (d) (member d eon-workspace--recent))
                       eon-workspace--projects))))

(defun eon-workspace--find-by-root (root)
  "按 ROOT 工作目录查找 workspace。"
  (let ((dir (eon-workspace--normalize-dir root)))
    (seq-find (lambda (ws)
                (string= (eon-workspace--normalize-dir (eon-workspace-root ws))
                         dir))
              eon-workspace--list)))

(defun eon-workspace--abbreviate-dir (dir)
  "把 DIR 的 HOME 前缀替换为 ~，用于补全列表显示。"
  (abbreviate-file-name (directory-file-name dir)))

(defun eon-workspace--read-project ()
  "选择一个项目目录用于创建 workspace。
优先从已知项目列表中选择（按最近使用排序），为空则回退到 `read-directory-name'。
列表中以 ~ 代替 HOME 前缀显示，选中后返回绝对路径。"
  (let ((candidates (eon-workspace--known-projects)))
    (if candidates
        (let* ((pairs (eon-workspace--project-display-pairs candidates t))
               (choices (mapcar #'car pairs))
               (selected (completing-read "选择工作区: "
                                          choices nil t)))
          (cdr (assoc-string selected pairs)))
      (read-directory-name "Workspace 工作目录: " nil nil t))))

(defun eon-workspace--parse-yaml-list (file key)
  "从 FILE 中提取 yaml 顶层 KEY 下的简单字符串列表。
仅识别如下形式（首列无缩进的 key，下方缩进的 - item）：

  key:
    - val1
    - \"val 2\"
    - \\='val 3\\='

不支持嵌套结构。"
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((header (format "^%s[ \t]*:[ \t]*$" (regexp-quote key)))
            (item-re "^[ \t]+-[ \t]+\\(.*?\\)[ \t]*$")
            results)
        (when (re-search-forward header nil t)
          (forward-line 1)
          (while (and (not (eobp))
                      (looking-at item-re))
            (let ((v (string-trim (match-string 1))))
              (when (string-match "\\`\\(['\"]\\)\\(.*\\)\\1\\'" v)
                (setq v (match-string 2 v)))
              (push v results))
            (forward-line 1)))
        (nreverse results)))))

(defun eon-workspace--parse-yaml-block-string (file key)
  "从 FILE 中提取 yaml 顶层 KEY 对应的多行块字符串值。
识别如下 YAML 块字符串格式（| 或 >）：

    key: |
      第一行
      第二行

返回去缩进后的多行文本，失败返回 nil。"
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((header (format "^%s[ \t]*:[ \t]*[|>]?[ \t]*$"
                            (regexp-quote key)))
            lines base-indent)
        (when (re-search-forward header nil t)
          (forward-line 1)
          (while (and (not (eobp))
                      (looking-at "^\\([ \t]+\\)\\(.*\\)$"))
            (let ((indent (length (match-string 1)))
                  (content (match-string 2)))
              (unless base-indent
                (setq base-indent indent))
              (push (substring (concat (match-string 1) content)
                               base-indent)
                    lines))
            (forward-line 1)))
        (if lines
            (string-trim-right (string-join (nreverse lines) "\n"))
          nil)))))

(defun eon-workspace--ignore-patterns (root)
  "读取 ROOT 下 `eon-workspace-config-file' 的忽略模式列表。"
  (let ((file (expand-file-name eon-workspace-config-file root)))
    (eon-workspace--parse-yaml-list file eon-workspace-ignore-patterns-key)))

(defun eon-workspace--compile-command (root)
  "读取 ROOT 下 `eon-workspace-config-file' 配置的 compile 命令。"
  (let ((file (expand-file-name eon-workspace-config-file root)))
    (eon-workspace--parse-yaml-block-string file eon-workspace-compile-key)))

(defun eon-workspace--rg-ignored-globs (root)
  "从 ROOT 的 .eon.yaml ignore-patterns 生成 rg 的 --glob ! 参数串。"
  (mapconcat (lambda (p)
               (concat "--glob !" (shell-quote-argument p)))
             (eon-workspace--ignore-patterns root)
             " "))

(defun eon-workspace--list-project-files (root)
  "用 fd 列出 ROOT 下文件，按 .eon.yaml ignore-patterns 过滤。
返回相对 ROOT 的路径字符串列表。"
  (unless (executable-find eon-workspace-fd-executable)
    (user-error "找不到可执行文件: %s" eon-workspace-fd-executable))
  (let* ((patterns (eon-workspace--ignore-patterns root))
         (ignore-args (cl-mapcan (lambda (p) (list "-E" p)) patterns))
         (default-directory root)
         (args (append eon-workspace-fd-args ignore-args (list "."))))
    (with-temp-buffer
      (let ((exit (apply #'call-process
                         eon-workspace-fd-executable nil t nil args)))
        (unless (zerop exit)
          (user-error "fd 执行失败 (exit %s): %s"
                      exit (string-trim (buffer-string))))
        (split-string (buffer-string) "\0" t)))))

(defun eon-workspace--record-buffer (ws buf)
  "把 BUF 登记到 WS 的私有 buffer 列表（最近访问者在前）。"
  (when (and ws buf (buffer-live-p buf))
    (setf (eon-workspace-buffers ws)
          (cons buf (delq buf (eon-workspace-buffers ws))))))

(defun eon-workspace--track-frame-buffers (frame)
  "FRAME 中显示的 buffer 改变时，登记到对应 workspace。
作为 `window-buffer-change-functions' 钩子使用。"
  (let ((ws (eon-workspace--find-by-frame frame)))
    (when ws
      (dolist (win (window-list frame 'no-mini))
        (eon-workspace--record-buffer ws (window-buffer win))))))

(defun eon-workspace--untrack-killed-buffer ()
  "BUF 被 kill 时，从所有 workspace 的 buffer 列表中移除。
作为 `kill-buffer-hook' 使用。"
  (let ((buf (current-buffer)))
    (dolist (ws eon-workspace--list)
      (setf (eon-workspace-buffers ws)
            (delq buf (eon-workspace-buffers ws))))))

(defun eon-workspace-buffer-list (&optional ws)
  "返回 WS（默认为当前 frame 所属 workspace）的私有 buffer 列表，
仅返回仍然存活的 buffer。"
  (when-let ((ws (or ws (eon-workspace-current))))
    (let ((live (seq-filter #'buffer-live-p (eon-workspace-buffers ws))))
      (setf (eon-workspace-buffers ws) live)
      live)))

(defun eon-workspace--kill-private-buffers (ws &optional cancellable)
  "Kill WS 中的非 shared 私有 buffer。
先用 `save-some-buffers' 让用户对未保存的 buffer 选择是否保存，
再逐个调用 `kill-buffer'；对仍未保存的 buffer，`kill-buffer'
自身会再次询问 \"kill anyway?\"。

CANCELLABLE 非 nil 时（用户主动调用 `eon-workspace-kill'），
若某次 `kill-buffer' 被用户拒绝，立即返回 nil 终止整个流程；
为 nil 时（关闭 frame 时被动调用）尽力 kill 全部，结尾返回 t。"
  (let ((privates (seq-remove #'eon-workspace--shared-buffer-p
                              (eon-workspace-buffer-list ws))))
    (save-some-buffers nil (lambda () (memq (current-buffer) privates)))
    (catch 'cancel
      (dolist (buf privates)
        (when (buffer-live-p buf)
          (unless (kill-buffer buf)
            (when cancellable
              (throw 'cancel nil)))))
      t)))

(defun eon-workspace--default-shared-buffer-p (buf)
  "默认 shared buffer 判定。"
  (let ((name (buffer-name buf)))
    (or (minibufferp buf)
        (string-prefix-p " " name)
        (member name '("*scratch*" "*Messages*")))))

(defun eon-workspace--shared-buffer-p (buf)
  "BUF 是否被所有 workspace 共享。"
  (and (buffer-live-p buf)
       (funcall eon-workspace-shared-buffer-predicate buf)))

(defun eon-workspace--buffer-visible-p (ws buf)
  "BUF 对 WS 是否可见（属于 WS 的 buffer 列表，或全局共享）。"
  (and (buffer-live-p buf)
       (or (eon-workspace--shared-buffer-p buf)
           (memq buf (eon-workspace-buffers ws)))))

(defun eon-workspace--make-buffer-predicate (ws)
  "返回闭包，用作 WS 对应 frame 的 `buffer-predicate'。"
  (lambda (buf) (eon-workspace--buffer-visible-p ws buf)))

(defvar eon-workspace--prev-read-buffer-function nil
  "启用隔离前的 `read-buffer-function'，关闭时复原。")

(defun eon-workspace--visible-buffer-names ()
  "返回当前 workspace 视角下可见 buffer 名列表；无 workspace 时返回全部。"
  (let ((ws (eon-workspace-current)))
    (if ws
        (let (names)
          (dolist (buf (buffer-list))
            (when (eon-workspace--buffer-visible-p ws buf)
              (push (buffer-name buf) names)))
          (nreverse names))
      (mapcar #'buffer-name (buffer-list)))))

(defun eon-workspace--read-buffer (prompt &optional def require-match predicate)
  "Workspace-aware 的 `read-buffer-function' 实现。
仅在候选列表层做过滤，对应 buffer 选完后行为不变。"
  (let* ((names (eon-workspace--visible-buffer-names))
         (def (cond
               ((null def) nil)
               ((bufferp def) (buffer-name def))
               (t def)))
         (table (lambda (str pred action)
                  (complete-with-action action names str pred))))
    (completing-read prompt table predicate require-match nil
                     'buffer-name-history def)))

;;;###autoload
(define-minor-mode eon-workspace-buffer-isolation-mode
  "全局开关：在 workspace 之间隔离 buffer 列表。
启用时：
- 给每个 workspace 的 frame 设置 `buffer-predicate'，
  阻止系统自动切到其它 workspace 的 buffer
- 把 `read-buffer-function' 替换为 workspace-aware 版本，
  `switch-to-buffer' 等命令的候选只包含当前 workspace 的 buffer
  以及 `eon-workspace-shared-buffer-predicate' 判定的共享 buffer"
  :global t
  :group 'eon-workspace
  (cond
   (eon-workspace-buffer-isolation-mode
    (unless (eq read-buffer-function #'eon-workspace--read-buffer)
      (setq eon-workspace--prev-read-buffer-function read-buffer-function))
    (setq read-buffer-function #'eon-workspace--read-buffer)
    (dolist (ws eon-workspace--list)
      (when (eon-workspace--alive-p ws)
        (set-frame-parameter (eon-workspace-frame ws)
                             'buffer-predicate
                             (eon-workspace--make-buffer-predicate ws)))))
   (t
    (when (eq read-buffer-function #'eon-workspace--read-buffer)
      (setq read-buffer-function eon-workspace--prev-read-buffer-function))
    (dolist (ws eon-workspace--list)
      (when (eon-workspace--alive-p ws)
        (set-frame-parameter (eon-workspace-frame ws)
                             'buffer-predicate nil))))))

(defun eon-workspace--buffer-temp-p (buf)
  "判断 BUF 是否视为临时 buffer。
无文件关联，或名字以空格、* 开头者视为临时。"
  (let ((name (buffer-name buf))
        (file (buffer-file-name buf)))
    (or (null file)
        (string-prefix-p " " name)
        (string-prefix-p "*" name))))


;;;; 命令

;;;###autoload
(defun eon-workspace-create (root &optional name)
  "创建或切换到 workspace。
ROOT 是工作目录；NAME 是 workspace 名称，缺省由 ROOT 生成。
若 ROOT 已绑定 workspace 则直接切换；否则创建新 workspace（独立 frame）。"
  (interactive (list (eon-workspace--read-project) nil))
  (eon-workspace--cleanup-dead)
  (let* ((dir (eon-workspace--normalize-dir root))
         (ws-name (or name (funcall eon-workspace-default-name-function dir)))
         (existing (eon-workspace--find-by-root dir)))
    (unless (file-directory-p dir)
      (user-error "目录不存在: %s" dir))
    (if existing
        ;; 该目录已绑定 workspace，直接切过去
        (progn
          (select-frame-set-input-focus (eon-workspace-frame existing))
          (eon-workspace--touch-project dir)
          (run-hooks 'eon-workspace-switch-hook)
          (message "已切换到已有 workspace: %s (%s)"
                   (eon-workspace-name existing) dir)
          existing)
      (when (eon-workspace--find-by-name ws-name)
        (user-error "Workspace 已存在: %s" ws-name))
      (let* ((frame-title (format "Workspace: %s" ws-name))
             ;; 当前只有一个 frame，且该 frame 还未关联 workspace 时，复用之
             (reuse-current (and (= (length (frame-list)) 1)
                                 (null (eon-workspace-current))))
             (frame (if reuse-current
                        (selected-frame)
                      (make-frame `((name . ,frame-title)))))
             (ws (eon-workspace--make :name ws-name :root dir :frame frame)))
        (when reuse-current
          (set-frame-name frame-title))
        (push ws eon-workspace--list)
        (when eon-workspace-open-dired-on-create
          (with-selected-frame frame
            (let ((default-directory dir))
              (dired dir)
              (eon-workspace--record-buffer ws (current-buffer)))))
        (when eon-workspace-buffer-isolation-mode
          (set-frame-parameter frame 'buffer-predicate
                               (eon-workspace--make-buffer-predicate ws)))
        (select-frame-set-input-focus frame)
        (eon-workspace--touch-project dir)
        (run-hooks 'eon-workspace-create-hook)
        (message "已创建 workspace: %s (%s)" ws-name dir)
        ws))))

;;;###autoload
(defun eon-workspace-init-config ()
  "在当前 workspace 根目录创建 `eon-workspace-config-file' 文件。
若文件已存在则不做处理。默认内容包含忽略 .git 目录。"
  (interactive)
  (let ((ws (eon-workspace-current)))
    (unless ws (user-error "当前 frame 未关联 workspace"))
    (let ((file (expand-file-name eon-workspace-config-file
                                  (eon-workspace-root ws))))
      (if (file-exists-p file)
          (message "%s 已存在，跳过" file)
        (with-temp-file file
          (insert "# eon-workspace 配置文件\n")
          (insert "# ignore-patterns: 列表中的每项作为 -E 参数传给 fd，用于\n")
          (insert "# 过滤 eon-workspace-find-file 的候选文件。\n\n")
          (insert (format "%s:\n" eon-workspace-ignore-patterns-key))
          (insert "  - \".git\"\n")
          (insert "\n")
          (insert (format "# %s: 编译命令（多行 shell 脚本），\n"
                          eon-workspace-compile-key))
          (insert "# 执行时以 workspace 根目录作为工作目录。\n")
          (insert "# 支持 YAML 块字符串格式（| 或 >）。\n")
          (insert (format "#%s: |\n" eon-workspace-compile-key))
          (insert "#   echo \"TODO: 配置编译命令\"\n"))
        (message "已创建 %s" file)))))

;;;###autoload
(defun eon-workspace-compile ()
  "执行当前 workspace 的 .eon.yaml 中配置的 compile 命令。
compile 的值应为多行 shell 命令，支持 YAML 块字符串格式（| 或 >）。
编译输出显示在 *compilation-<workspace>* buffer 中。"
  (interactive)
  (let ((ws (eon-workspace-current)))
    (unless ws (user-error "当前 frame 未关联 workspace"))
    (let* ((root (eon-workspace-root ws))
           (cmd (eon-workspace--compile-command root)))
      (unless cmd
        (user-error "%s 中未配置 compile 命令"
                    (expand-file-name eon-workspace-config-file root)))
      (require 'compile)
      (let ((default-directory root))
        (compilation-start
         cmd nil
         (lambda (_)
           (format "*compilation-%s*" (eon-workspace-name ws))))))))


;;;; 配置界面 (customize-like)

(defvar-local eon-workspace-config--editable-list nil
  "Buffer-local reference to the editable-list widget.")

(defvar-local eon-workspace-config--compile-widget nil
  "Buffer-local reference to the compile text widget.")

(defvar-local eon-workspace-config--config-file nil
  "Buffer-local path to the .eon.yaml being edited.")

(defun eon-workspace-config--write-yaml (file patterns compile-cmd)
  "Write PATTERNS and COMPILE-CMD to FILE in .eon.yaml format."
  (let ((filtered (seq-remove #'string-empty-p patterns)))
    (with-temp-file file
      (insert (format "# eon-workspace 配置文件\n"))
      (insert (format "# %s: 列表中的每项作为 -E 参数传给 fd，用于过滤文件。\n\n"
                      eon-workspace-ignore-patterns-key))
      (insert (format "%s:\n" eon-workspace-ignore-patterns-key))
      (if filtered
          (dolist (p filtered)
            (insert (format "  - \"%s\"\n" p)))
        (insert "  []\n"))
      (when (and compile-cmd (not (string-empty-p compile-cmd)))
        (insert "\n")
        (insert (format "%s: |\n" eon-workspace-compile-key))
        (dolist (line (split-string compile-cmd "\n"))
          (insert (format "  %s\n" line)))))))

(defun eon-workspace-config--save ()
  "Read widget values and write them to .eon.yaml."
  (interactive)
  (if (and eon-workspace-config--editable-list
           eon-workspace-config--compile-widget)
      (let ((patterns (widget-value eon-workspace-config--editable-list))
            (compile-cmd (widget-value eon-workspace-config--compile-widget)))
        (eon-workspace-config--write-yaml eon-workspace-config--config-file
                                          patterns compile-cmd)
        (message "已保存到 %s" eon-workspace-config--config-file))
    (user-error "找不到配置 widget")))

(defun eon-workspace-config--revert ()
  "Reload config from .eon.yaml and refresh the widget buffer."
  (interactive)
  (when eon-workspace-config--config-file
    (let* ((root (file-name-directory eon-workspace-config--config-file))
           (patterns (eon-workspace--ignore-patterns root))
           (compile-cmd (eon-workspace--compile-command root)))
      (with-current-buffer (get-buffer-create "*Eon Config*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (remove-overlays)
          (setq eon-workspace-config--editable-list nil)
          (setq eon-workspace-config--compile-widget nil)
          (widget-insert (propertize
                          (format "配置文件: %s\n\n"
                                  eon-workspace-config--config-file)
                          'face 'bold))
          (widget-insert (propertize
                          (format "%s:\n" eon-workspace-ignore-patterns-key)
                          'face 'widget-documentation-face))
          (widget-insert
           "  作为 fd -E / rg --glob ! 参数叠加，用于排除文件。\n\n")
          (setq eon-workspace-config--editable-list
                (widget-create
                 'editable-list
                 :entry-format "%i %d %v"
                 :insert-button-args '(:tag "新增")
                 :delete-button-args '(:tag "删除")
                 :append-button-args '(:tag "新增")
                 :value (or patterns '())
                 :indent 2
                 '(editable-field :format "%v")))
          (widget-insert "\n")
          (widget-insert (propertize
                          (format "%s:\n" eon-workspace-compile-key)
                          'face 'widget-documentation-face))
          (widget-insert
           "  编译命令，多行 shell 脚本（将 workspace 根目录作为工作目录执行）。\n\n")
          (setq eon-workspace-config--compile-widget
                (widget-create 'text
                               :value (or compile-cmd "")
                               :indent 2
                               :size 4))
          (widget-insert "\n")
          (widget-create 'push-button
                         :notify (lambda (&rest _) (eon-workspace-config--save))
                         "保存")
          (widget-insert "  ")
          (widget-create 'push-button
                         :notify (lambda (&rest _) (eon-workspace-config--revert))
                         "还原")
          (widget-insert "  ")
          (widget-create 'push-button
                         :notify (lambda (&rest _) (quit-window))
                         "退出")
          (widget-setup)
          (widget-forward 1)))
      (message "配置已还原"))))

;;;###autoload
(defun eon-workspace-config ()
  "用 customize 风格界面编辑当前 workspace 的 .eon.yaml 配置。
在 *Eon Config* buffer 中以 widget 形式展示忽略模式列表和 compile 命令，
每个忽略模式可独立编辑、新增或删除。提供保存 (C-c C-s)、
还原 (C-c C-k)、退出 (q) 按钮与快捷键。"
  (interactive)
  (require 'wid-edit)
  (let ((ws (eon-workspace-current)))
    (unless ws (user-error "当前 frame 未关联 workspace"))
    (let* ((root (eon-workspace-root ws))
           (config-file (expand-file-name eon-workspace-config-file root))
           (patterns (eon-workspace--ignore-patterns root))
           (compile-cmd (eon-workspace--compile-command root))
           (buf (get-buffer-create "*Eon Config*")))
      (pop-to-buffer buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer))
        (remove-overlays)
        (setq eon-workspace-config--editable-list nil)
        (setq eon-workspace-config--compile-widget nil)
        (setq eon-workspace-config--config-file config-file)
        (widget-insert (propertize
                        (format "配置文件: %s\n\n" config-file)
                        'face 'bold))
        (widget-insert (propertize
                        (format "%s:\n" eon-workspace-ignore-patterns-key)
                        'face 'widget-documentation-face))
        (widget-insert
         "  作为 fd -E / rg --glob ! 参数叠加，用于排除文件。\n\n")
        (setq eon-workspace-config--editable-list
              (widget-create
               'editable-list
               :entry-format "%i %d %v"
               :insert-button-args '(:tag "新增")
               :delete-button-args '(:tag "删除")
               :append-button-args '(:tag "新增")
               :value (or patterns '())
               :indent 2
               '(editable-field :format "%v")))
        (widget-insert "\n")
        (widget-insert (propertize
                        (format "%s:\n" eon-workspace-compile-key)
                        'face 'widget-documentation-face))
        (widget-insert
         "  编译命令，多行 shell 脚本（将 workspace 根目录作为工作目录执行）。\n\n")
        (setq eon-workspace-config--compile-widget
              (widget-create 'text
                             :value (or compile-cmd "")
                             :indent 2
                             :size 4))
        (widget-insert "\n")
        (widget-create 'push-button
                       :notify (lambda (&rest _) (eon-workspace-config--save))
                       "保存")
        (widget-insert "  ")
        (widget-create 'push-button
                       :notify (lambda (&rest _) (eon-workspace-config--revert))
                       "还原")
        (widget-insert "  ")
        (widget-create 'push-button
                       :notify (lambda (&rest _) (quit-window))
                       "退出")
        (use-local-map (copy-keymap widget-keymap))
        (local-set-key (kbd "C-c C-s") #'eon-workspace-config--save)
        (local-set-key (kbd "C-c C-k") #'eon-workspace-config--revert)
        (local-set-key (kbd "q") #'quit-window)
        (widget-setup)
        (goto-char (point-min))
        (widget-forward 1)))))


;;;###autoload
(defun eon-workspace-add-project (dir)
  "把 DIR 加入已知项目列表。"
  (interactive (list (read-directory-name "添加项目: " nil nil t)))
  (eon-workspace--remember-project dir)
  (message "已添加项目: %s" (eon-workspace--normalize-dir dir)))

;;;###autoload
(defun eon-workspace-remove-project (dir)
  "从已知项目列表中移除 DIR。"
  (interactive
   (list (progn
           (eon-workspace--ensure-projects-loaded)
           (unless eon-workspace--projects
             (user-error "已知项目列表为空"))
           (completing-read "移除项目: " eon-workspace--projects nil t))))
  (eon-workspace--ensure-projects-loaded)
  (let ((d (eon-workspace--normalize-dir dir)))
    (setq eon-workspace--projects (delq d eon-workspace--projects)
          eon-workspace--recent (delq d eon-workspace--recent))
    (eon-workspace--save-projects)
    (eon-workspace--save-recent)
    (message "已移除项目: %s" d)))

;;;###autoload
(defun eon-workspace-find-file ()
  "在当前 workspace 中打开文件。
若当前 frame 已关联 workspace，则用 fd 列出 ROOT 下的所有文件
（自动遵守 .gitignore，并叠加 `.eon.yaml' 中 ignore-patterns 配置
的过滤），通过 `ivy-read' 选择（支持 `ivy-occur' 等）。
否则回退到普通的 `find-file'。"
  (interactive)
  (let ((ws (eon-workspace-current)))
    (if (null ws)
        (call-interactively #'find-file)
      (let* ((root (eon-workspace-root ws))
             (files (eon-workspace--list-project-files root)))
        (unless files
          (user-error "%s 下没有匹配的文件" root))
        (require 'ivy)
        (ivy-read (format "打开文件 (%s): "
                          (eon-workspace-name ws))
                  files
                  :action (lambda (rel)
                            (find-file (expand-file-name rel root)))
                  :caller 'eon-workspace-find-file)))))

;;;###autoload
(defun eon-workspace-open ()
  "从已有 workspace 列表中选择工作区，列出其文件并打开。
不同于 `eon-workspace-find-file'（仅限当前工作区），
可打开其他 workspace 的文件而不切换工作区。"
  (interactive)
  (let* ((root (eon-workspace--read-workspace "选择工作区: " t))
         (files (eon-workspace--list-project-files root)))
    (unless files
      (user-error "%s 下没有匹配的文件" root))
    (require 'ivy)
    (ivy-read (format "打开文件 (%s): "
                      (directory-file-name root))
              files
              :action (lambda (rel)
                        (find-file (expand-file-name rel root)))
              :caller 'eon-workspace-open)))

;;;###autoload
(defun eon-workspace-rg (&optional options)
  "在当前 workspace ROOT 中用 rg 搜索，行为类似 `counsel-projectile-rg'。
忽略规则来自 ROOT/.eon.yaml 的 ignore-patterns（转为 rg --glob !）。
\\[universal-argument] 前缀参数时额外读取 rg 选项。"
  (interactive)
  (let ((ws (eon-workspace-current)))
    (unless ws (user-error "当前 frame 未关联 workspace"))
    (require 'counsel)
    (let* ((root (eon-workspace-root ws))
           (ignored (eon-workspace--rg-ignored-globs root))
           (counsel-rg-base-command
            (let ((counsel-ag-command counsel-rg-base-command))
              (counsel--format-ag-command ignored "%s")))
           (prompt-prefix (format "%s rg: " (eon-workspace-name ws))))
      ;; counsel-rg 用 C-u C-u 提示额外选项；此处把单次 C-u 映射过去
      (when (= (prefix-numeric-value current-prefix-arg) 4)
        (setq current-prefix-arg '(16)))
      (counsel-rg (eval eon-workspace-rg-initial-input)
                  root
                  options
                  prompt-prefix))))

;;;###autoload
(defun eon-workspace-cleanup ()
  "清理当前 workspace 中非工作目录的文件 buffer。
仅遍历 workspace 自己的 buffer 列表，仅处理有 file 关联的 buffer，
临时 buffer 保留。"
  (interactive)
  (let ((ws (eon-workspace-current)))
    (unless ws (user-error "当前 frame 未关联 workspace"))
    (let ((root (eon-workspace-root ws))
          (killed 0))
      (dolist (buf (eon-workspace-buffer-list ws))
        (unless (eon-workspace--buffer-temp-p buf)
          (let ((file (buffer-file-name buf)))
            (when (and file
                       (not (eon-workspace--file-in-root-p file root)))
              (when (kill-buffer buf)
                (cl-incf killed))))))
      (message "已清理 %d 个非工作目录 buffer" killed))))

(defun eon-workspace--buffer-name-list (&optional ws)
  "返回 WS（默认当前 workspace）私有 buffer 的名称列表。"
  (let ((ws (or ws (eon-workspace-current))))
    (when ws
      (mapcar #'buffer-name (eon-workspace-buffer-list ws)))))

(defun eon-workspace--buffer-list-collection (str &optional predicate _action)
  "Ivy/`all-completions' 用的 collection，只返回当前 workspace 存活 buffer 的名称。"
  (when-let ((names (eon-workspace--buffer-name-list)))
    (all-completions str (lambda (_s &rest _) names) predicate)))

(defun eon-workspace--ivy-kill-buffer-action (name)
  "Kill 名为 NAME 的 buffer，并刷新 workspace 候选列表。"
  (when (and name (not (string-empty-p name)))
    (when-let ((buf (get-buffer name)))
      (kill-buffer buf)))
  (unless (buffer-live-p (ivy-state-buffer ivy-last))
    (setf (ivy-state-buffer ivy-last)
          (with-ivy-window (current-buffer))))
  ;; 与 ivy--kill-current-candidate 相同：先删掉当前项，再按最新列表重建
  (setf (ivy-state-preselect ivy-last) ivy--index)
  (setq ivy--old-re nil)
  (setq ivy--all-candidates
        (cl-delete name ivy--all-candidates
                   :key (lambda (c) (if (consp c) (car c) c))
                   :test #'string=))
  (setq ivy--all-candidates
        (eon-workspace--buffer-list-collection "" nil nil))
  (let ((ivy--recompute-index-inhibit t))
    (ivy--exhibit)))

(defvar eon-workspace-ivy-switch-buffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-k") #'eon-workspace-ivy-switch-buffer-kill)
    map)
  "eon-workspace-switch-to-buffer 的 ivy keymap。")

(defun eon-workspace-ivy-switch-buffer-kill ()
  "行末 kill 当前候选 buffer；否则 `ivy-kill-line'。"
  (interactive)
  (if (not (eolp))
      (ivy-kill-line)
    (let ((cand (ivy-state-current ivy-last)))
      (eon-workspace--ivy-kill-buffer-action
       (if (consp cand) (car cand) cand)))))

;;;###autoload
(defun eon-workspace-switch-to-buffer ()
  "在当前 workspace 的私有 buffer 列表中切换 buffer。
通过 ivy 展示候选；Marginalia 显示 major-mode 与文件路径（见 `eon-marginalia-annotate-buffer'）。
`C-k' 在行末可 kill 当前候选 buffer。"
  (interactive)
  (let ((ws (eon-workspace-current)))
    (unless ws (user-error "当前 frame 未关联 workspace"))
    (unless (eon-workspace-buffer-list ws)
      (user-error "当前 workspace 无可切换 buffer"))
    (require 'ivy)
    (ivy-read (format "切换 buffer (%s): " (eon-workspace-name ws))
              #'eon-workspace--buffer-list-collection
                :keymap eon-workspace-ivy-switch-buffer-map
                :preselect (buffer-name (other-buffer (current-buffer)))
              :action #'ivy--switch-buffer-action
              :caller 'ivy-switch-buffer)))

;;;###autoload
(defun eon-workspace-kill (&optional root)
  "删除 ROOT 对应 workspace，并关闭其 frame。
ROOT 为工作目录绝对路径；交互选择与 `eon-workspace-create' 相同的路径展示形式。
删除前会逐一处理私有 buffer 的未保存内容（提示保存或 kill anyway）。
若用户在某一步取消，整个流程中止，frame 与 workspace 都不会被删。"
  (interactive (list (eon-workspace--read-workspace "删除 workspace: ")))
  (let ((ws (eon-workspace--find-by-root root))
        (label (eon-workspace--abbreviate-dir root)))
    (unless ws (user-error "未找到 workspace: %s" root))
    (when (or (not eon-workspace-confirm-kill)
              (yes-or-no-p (format "确认删除 workspace %s (%s)? "
                                   (eon-workspace-name ws) label)))
      (if (not (eon-workspace--kill-private-buffers ws t))
          (message "已取消删除 workspace: %s (%s)"
                   (eon-workspace-name ws) label)
        (let ((frame (eon-workspace-frame ws)))
          ;; 先从列表移除，避免 delete-frame 钩子再次进入 buffer 清理流程
          (setq eon-workspace--list (delq ws eon-workspace--list))
          (when (frame-live-p frame)
            (delete-frame frame t)))
        (run-hooks 'eon-workspace-kill-hook)
        (message "已删除 workspace: %s (%s)"
                 (eon-workspace-name ws) label)))))

;;;###autoload
(defun eon-workspace-list ()
  "在 *Eon-Workspaces* buffer 中列出所有 workspace。"
  (interactive)
  (eon-workspace--cleanup-dead)
  (let ((buf (get-buffer-create "*Eon-Workspaces*"))
        (current (eon-workspace-current)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%-2s %-24s %s\n" "" "NAME" "ROOT"))
        (insert (make-string 70 ?-) "\n")
        (dolist (ws eon-workspace--list)
          (insert (format "%-2s %-24s %s\n"
                          (if (eq ws current) "*" "")
                          (eon-workspace-name ws)
                          (eon-workspace-root ws)))))
      (special-mode))
    (display-buffer buf)))


;;;; frame 销毁时回收

(defun eon-workspace--on-delete-frame (frame)
  "FRAME 被删除时同步移除对应 workspace，并尽力 kill 其私有 buffer。
此路径不可取消 delete-frame；在 emacs 退出过程中跳过 buffer 处理，
避免与 `save-buffers-kill-emacs' 的统一提示重复。"
  (when-let ((ws (eon-workspace--find-by-frame frame)))
    (unless (or noninteractive
                (memq this-command
                      '(save-buffers-kill-emacs
                        save-buffers-kill-terminal
                        kill-emacs)))
      (eon-workspace--kill-private-buffers ws nil))
    (setq eon-workspace--list (delq ws eon-workspace--list))))

(add-hook 'delete-frame-functions #'eon-workspace--on-delete-frame)
(add-hook 'window-buffer-change-functions #'eon-workspace--track-frame-buffers)
(add-hook 'kill-buffer-hook #'eon-workspace--untrack-killed-buffer)


(provide 'eon-workspace)
;;; eon-workspace.el ends here
