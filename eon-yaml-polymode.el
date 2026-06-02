;;; eon-yaml-polymode.el --- polymode for .eon.yaml — shell in yaml  -*- lexical-binding: t; -*-
;;
;; 在 .eon.yaml 的 exec: | 块内启用 sh-mode 语法高亮和缩进。
;;
;; 安装:
;;   1. M-x package-install RET polymode RET
;;   2. 在 init.el 中添加: (require 'eon-yaml-polymode)
;;
;; 效果:
;;   - exec: | 块内的 shell 脚本自动使用 sh-mode 高亮/缩进
;;   - 块外保持 yaml-mode 行为

(require 'polymode)

;;; 辅助

(defun eon-poly--blank-or-comment-p ()
  "当前行是否为空白或仅注释。"
  (save-excursion
    (beginning-of-line)
    (looking-at "^[ \t]*\\($\\|#\\)")))

(defun eon-poly--exec-head-p (&optional _span)
  "point 是否在 exec: | 块头行。"
  (looking-at "^[ \t]+\\(- \\)?exec:[ \t]*[|>][ \t]*$"))

(defun eon-yaml-sh--indent-offset (&optional _span)
  "exec 块内容首行缩进，供 polymode 校正 sh-mode（含 heredoc 体）。"
  (save-excursion
    (beginning-of-line)
    (when (re-search-backward "^[ \t]+\\(- \\)?exec:[ \t]*[|>][ \t]*$"
                             nil t)
      (forward-line 1)
      (while (and (not (eobp)) (looking-at "^[ \t]*$"))
        (forward-line 1))
      (when (looking-at "^\\([ \t]+\\)")
        (length (match-string 1))))))

(defun eon-poly--exec-tail (span)
  "从 SPAN（polymode span plist）出发，找到 exec 块结束位置。
块内容行缩进 > exec key 行缩进；等缩进或更浅缩进表示块结束。"
  (let ((head-pos (plist-get span :head)))
    (save-excursion
      (goto-char head-pos)
      (beginning-of-line)
      (let ((min-indent (current-indentation)))
        (forward-line 1)
        (while (and (not (eobp))
                    (or (eon-poly--blank-or-comment-p)
                        (> (current-indentation) min-indent)))
          (forward-line 1))
        (line-beginning-position)))))

;;; polymode 定义

(define-hostmode eon-yaml-hostmode
  :mode 'yaml-ts-mode)

(define-innermode eon-yaml-sh-innermode
  :mode 'sh-mode
  :head-matcher #'eon-poly--exec-head-p
  :tail-matcher #'eon-poly--exec-tail
  :head-mode 'host
  :tail-mode 'host
  :indent-offset #'eon-yaml-sh--indent-offset)

(define-polymode eon-yaml-mode
  :hostmode 'eon-yaml-hostmode
  :innermodes '(eon-yaml-sh-innermode))

;;; 自动识别 .eon.yaml
;;;###autoload
(add-to-list 'auto-mode-alist '("/\\.eon\\.yaml\\'" . eon-yaml-mode))

(provide 'eon-yaml-polymode)
;;; eon-yaml-polymode.el ends here
