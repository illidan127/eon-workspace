;;; eon-workspace-format.el --- Format .eon.yaml exec blocks with shfmt -*- lexical-binding: t; -*-
;;
;; 对 .eon.yaml 中 exec: | 块内的 shell 脚本调用 shfmt 格式化，
;; 并处理 << / <<- heredoc 缩进。
;;
;; 依赖 eon-workspace.el（eon-workspace-current 等）及外部命令 shfmt。
;;
;; 安装: (require 'eon-workspace-format)  或由 eon-workspace.el 自动加载

(require 'cl-lib)

(defconst eon-workspace--shfmt-indent 2
  "shfmt -i 参数；heredoc 体相对 opener 行额外缩进同此值。")

(defun eon-workspace--line-leading-ws-prefix (line)
  "返回 LINE 行首空白前缀（可为空字符串）。"
  (if (string-match "\\`\\([ \t]*\\)" line)
      (match-string 1 line)
    ""))

(defun eon-workspace--line-leading-indent (line)
  "非空行返回行首空白长度，空行返回 nil。"
  (when (and line (not (string-empty-p (string-trim line))))
    (if (string-match "^\\([ \t]+\\)" line)
        (length (match-string 1 line))
      0)))

(defun eon-workspace--lines-min-indent (lines)
  "LINES 中非空行的最小行首缩进。"
  (let ((min nil))
    (dolist (l lines)
      (when-let ((ind (eon-workspace--line-leading-indent l)))
        (setq min (if min (min min ind) ind))))
    min))

(defun eon-workspace--heredoc-prepare (content)
  "预处理 CONTENT 中的 << / <<- heredoc，供 shfmt 使用。
提取 heredoc 体 → 递归格式化体内容 → 去缩进并用唯一标记替换起止定界符。
返回 (FIXED-CONTENT . HINFO)。HINFO 为回归列表，供 heredoc-restore 使用。"
  (let* ((lines (split-string content "\n"))
         (out nil)
         (hinfo nil)
         (counter 0))
    (catch 'done
      (let ((i 0) (hlen (length lines)))
        (while (< i hlen)
          (if (string-match
               "<<-?\\(['\"]?\\)\\([A-Za-z_][A-Za-z_0-9]*\\)\\1"
               (nth i lines))
              (let* ((orig-line (nth i lines))
                     (m-start (match-beginning 0))
                     (m-end (match-end 0))
                     (dash-p (string-match-p "<<-" orig-line))
                     (quote (match-string 1 orig-line))
                     (delim (match-string 2 orig-line))
                     (marker (format "__EON_H%d__" counter))
                     (body-lines nil)
                     (body-content-indent nil)
                     (close-prefix nil)
                     (j (1+ i))
                     (found nil))
                (while (and (< j hlen) (not found))
                  (let ((bl (nth j lines)))
                    (if (string-match
                         (format "^\\([ \t]*\\)%s[ \t]*$"
                                 (regexp-quote delim)) bl)
                        (progn
                          (setq close-prefix (match-string 1 bl))
                          (setq found t))
                      (progn
                        (push bl body-lines)
                        (when-let ((ind (eon-workspace--line-leading-indent bl)))
                          (setq body-content-indent
                                (if body-content-indent
                                    (min body-content-indent ind)
                                  ind))))))
                  (setq j (1+ j)))
                (if (and found body-lines)
                    (let* ((body-indent (or body-content-indent 0))
                           (deindented
                            (mapcar (lambda (l)
                                      (if (and body-indent (> body-indent 0)
                                               (>= (length l) body-indent))
                                          (substring l body-indent)
                                        l))
                                    (nreverse body-lines)))
                           (body-text (string-join deindented "\n"))
                           (fmt-body (condition-case nil
                                         (eon-workspace--shfmt-recursive
                                          body-text)
                                       (error nil))))
                      (when fmt-body
                        (setq deindented (split-string fmt-body "\n")))
                      (push (concat (substring orig-line 0 m-start)
                                    (format "<<%s%s%s" quote marker quote)
                                    (substring orig-line m-end))
                            out)
                      (dolist (dl deindented)
                        (push dl out))
                      (push marker out)
                      (push (list :marker marker :delim delim
                                  :quote quote :dash-p dash-p
                                  :close-prefix close-prefix)
                            hinfo)
                      (setq i j)
                      (setq counter (1+ counter)))
                  (push (nth i lines) out)
                  (setq i (1+ i))))
            (push (nth i lines) out)
            (setq i (1+ i))))))
    (cons (string-join (nreverse out) "\n")
          (nreverse hinfo))))

(defun eon-workspace--heredoc-restore (content hinfo)
  "用 HINFO（来自 heredoc-prepare）还原 CONTENT 中的 << / <<- heredoc。
body 行缩进为 opener 行前缀再加 `eon-workspace--shfmt-indent' 空格；
<< 的 closing 行保持行首（不跟 opener 缩进）；<<- 另保留 closing 行前缀。"
  (dolist (info hinfo)
    (let* ((marker (plist-get info :marker))
           (delim (plist-get info :delim))
           (quote (plist-get info :quote))
           (dash-p (plist-get info :dash-p))
           (close-prefix (plist-get info :close-prefix))
           (lines (split-string content "\n"))
           (out nil)
           (hlen (length lines))
           (found nil))
      (catch 'done
        (let ((i 0))
          (while (< i hlen)
            (if (and (not found)
                     (string-match
                      (format "<<%s%s%s"
                              (regexp-quote quote)
                              (regexp-quote marker)
                              (regexp-quote quote))
                      (nth i lines)))
                (let* ((orig-restore-line (nth i lines))
                       (rs-start (match-beginning 0))
                       (rs-end (match-end 0))
                       (opener-prefix
                        (eon-workspace--line-leading-ws-prefix
                         orig-restore-line))
                       (body-prefix
                        (concat opener-prefix
                                (make-string eon-workspace--shfmt-indent ?\s)))
                       (body-lines nil)
                       (j (1+ i))
                       (shfmt-dedent nil))
                  (while (and (< j hlen)
                              (not (string-match
                                    (format "^[ \t]*%s[ \t]*$"
                                            (regexp-quote marker))
                                    (nth j lines))))
                    (push (nth j lines) body-lines)
                    (setq j (1+ j)))
                  (setq shfmt-dedent (eon-workspace--lines-min-indent body-lines))
                  (push (concat (substring orig-restore-line 0 rs-start)
                                (format "%s%s%s%s"
                                        (if dash-p "<<-" "<<")
                                        quote delim quote)
                                (substring orig-restore-line rs-end))
                        out)
                  (dolist (bl (nreverse body-lines))
                    (let ((line (if shfmt-dedent
                                    (substring bl (min shfmt-dedent (length bl)))
                                  bl)))
                      (push (concat body-prefix line) out)))
                  (push (concat (if dash-p (or close-prefix "") "") delim) out)
                  (setq found t)
                  (setq i (1+ j)))
              (push (nth i lines) out)
              (setq i (1+ i))))))
      (setq content (string-join (nreverse out) "\n"))))
  content)

(defun eon-workspace--normalize-continuations (content)
  "统一 CONTENT 中反斜杠续行的缩进。
shfmt 不处理引号字符串内部，因此这部分续行保持原始缩进。
此函数确保所有 \\ 续行使用统一的 `eon-workspace--shfmt-indent' 缩进。"
  (let* ((lines (split-string content "\n"))
         (out nil)
         (cont-prefix (make-string eon-workspace--shfmt-indent ?\s))
         (prev-cont nil))
    (dolist (line lines)
      (if prev-cont
          (let ((trimmed (string-trim-right line)))
            (push (concat cont-prefix (string-trim-left line)) out)
            (setq prev-cont (and (> (length trimmed) 0)
                                 (eq (aref trimmed (1- (length trimmed))) ?\\))))
        (let ((trimmed (string-trim-right line)))
          (push line out)
          (setq prev-cont (and (> (length trimmed) 0)
                               (eq (aref trimmed (1- (length trimmed))) ?\\))))))
    (string-join (nreverse out) "\n")))

(defun eon-workspace--shfmt-recursive (content)
  "递归格式化 CONTENT，自动处理其中的 << / <<- heredoc 体。
先通过 heredoc-prepare 把内层 heredoc 体也格式化完，再整体跑 shfmt。"
  (let* ((prep (eon-workspace--heredoc-prepare content))
         (shfmt-in (car prep))
         (hinfo (cdr prep))
         (formatted
          (with-temp-buffer
            (insert shfmt-in)
            (if (zerop (call-process-region (point-min) (point-max)
                                            "shfmt" t t nil
                                            "-i" (number-to-string
                                                  eon-workspace--shfmt-indent)
                                            "-ci" "-bn"))
                (string-trim-right (buffer-string))
              nil))))
    (when formatted
      (if hinfo
          (or (eon-workspace--heredoc-restore formatted hinfo) formatted)
        formatted))))

(defun eon-workspace--format-exec-block (key-indent)
  "格式化 point 处的 exec 块字符串内容（调用 shfmt）。
KEY-INDENT 是 exec key 所在行的缩进列数。
成功返回 t，失败返回 nil。"
  (let* ((block-start (line-beginning-position))
         (content-base nil)
         (lines nil)
         (min-indent (1+ key-indent)))
    ;; 收集内容行（缩进 > key-indent，含块内空白行）
    (while (and (not (eobp))
                (or (looking-at (format "^\\([ \t]\\{%d,\\}\\)\\(.*\\)$"
                                        min-indent))
                    (and content-base
                         (looking-at-p "^[ \t]*$"))))
      (if (looking-at-p "^[ \t]*$")
          (push "" lines)
        (let* ((line-indent (length (match-string 1)))
               (content (match-string 2)))
          (unless content-base
            (setq content-base line-indent))
          (push (if (string-empty-p content)
                    ""
                  (substring (concat (match-string 1) content)
                             content-base))
                lines)))
      (forward-line 1))
    (when (and lines content-base)
      (let* ((block-end (point))
             (raw (string-join (nreverse lines) "\n"))
             (normalized (eon-workspace--normalize-continuations raw))
             (formatted (eon-workspace--shfmt-recursive normalized)))
        (when (and formatted (not (string-empty-p formatted)))
          (delete-region block-start block-end)
          (goto-char block-start)
          (dolist (line (split-string formatted "\n"))
            (insert (make-string content-base ?\s) line "\n"))
          t)))))

(defun eon-workspace--format-file (file)
  "格式化 FILE 中的所有 exec 块内容。"
  (let ((buf (find-file-noselect file))
        (count 0))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward
                "^\\([ \t]+\\)\\(- \\)?exec:[ \t]*[|>][ \t]*$" nil t)
          (let ((key-indent (length (match-string 1))))
            (forward-line 1)
            (when (eon-workspace--format-exec-block key-indent)
              (setq count (1+ count))))))
      (if (> count 0)
          (progn (save-buffer)
                 (message "已格式化 %s (%d 个 exec 块)" file count))
        (message "%s 中没有需要格式化的 exec 块" file)))))

;;;###autoload
(defun eon-workspace-format ()
  "格式化当前 workspace 的 .eon.yaml 文件。
对每个 exec 块字符串内容调用 shfmt 进行 shell 格式化。
需要安装 shfmt: brew install shfmt"
  (interactive)
  (let ((ws (eon-workspace-current)))
    (unless ws (user-error "当前 frame 未关联 workspace"))
    (let* ((root (eon-workspace-root ws))
           (file (expand-file-name eon-workspace-config-file root)))
      (unless (file-exists-p file)
        (user-error "%s 不存在" file))
      (unless (executable-find "shfmt")
        (user-error "未找到 shfmt，请安装: brew install shfmt"))
      (eon-workspace--format-file file))))

(provide 'eon-workspace-format)
;;; eon-workspace-format.el ends here
