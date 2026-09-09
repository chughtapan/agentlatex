;;; e2e_review.el --- Review native model output with real Ediff -*- lexical-binding: t; -*-

(require 'agentedit-review)

(defun agentedit-e2e-read (path)
  "Read PATH without changing any visiting buffer."
  (with-temp-buffer (insert-file-contents path) (buffer-string)))

(let* ((directory (getenv "AGENTEDIT_E2E_DIR"))
       (path (expand-file-name "pair.tex" directory))
       (source (find-file-noselect path))
       (original (agentedit-e2e-read path))
       (expected (agentedit-e2e-read (expand-file-name "pair.expected" directory)))
       (ediff-window-setup-function #'ediff-setup-windows-plain)
       (ediff-keep-variants t)
       session)
  (with-current-buffer source
    (latex-mode)
    (buffer-enable-undo)
    (goto-char (point-min))
    ;; Enter using the public command; decisions use the actual control keymap.
    (call-interactively #'agentedit-review)
    (setq session (gethash source agentedit-review--sessions)))
  (unless (= 2 (length (agentedit-review-session-records session)))
    (error "Expected two independently reviewable word edits"))
  (dolist (key '("A" "R"))
    (with-current-buffer (agentedit-review-session-control session)
      (let ((action (key-binding (kbd key))))
        (unless (commandp action) (error "Missing review binding %s" key))
        (call-interactively action)))
    (sleep-for 0.05))
  (unless (eq (agentedit-review-session-state session) 'finished)
    (error "Review queue did not finish"))
  (unless (equal original (agentedit-e2e-read path))
    (error "Review unexpectedly saved the source"))
  (with-current-buffer source
    (unless (equal expected (buffer-string))
      (error "Accept/reject changed source extent or whitespace"))
    (undo-only 2)
    (unless (equal original (buffer-string))
      (error "Two undo steps did not restore the complete source"))
    ;; Repeat the public review after undo, then explicitly save for handoff.
    (goto-char (point-min))
    (call-interactively #'agentedit-review)
    (setq session (gethash source agentedit-review--sessions)))
  (dolist (key '("A" "R"))
    (with-current-buffer (agentedit-review-session-control session)
      (call-interactively (key-binding (kbd key))))
    (sleep-for 0.05))
  (with-current-buffer source
    (unless (equal expected (buffer-string)) (error "Repeat review differs"))
    (save-buffer))
  (princ "E2E Ediff: accept, reject, unsaved disk, exact undo, repeat, explicit save PASS\n"))

;;; e2e_review.el ends here
