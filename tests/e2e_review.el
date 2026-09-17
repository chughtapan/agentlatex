;;; e2e_review.el --- Review native model output with real Ediff -*- lexical-binding: t; -*-

(require 'agentedit-review)

(defun agentedit-e2e-read (path)
  "Read PATH without changing any visiting buffer."
  (with-temp-buffer (insert-file-contents path) (buffer-string)))

(defun agentedit-e2e-key (session key)
  "Invoke KEY through SESSION's actual Ediff control keymap."
  (with-current-buffer (agentedit-review-session-control session)
    (let ((action (key-binding (kbd key))))
      (unless (commandp action) (error "Missing review binding %s" key))
      (call-interactively action))))

(defun agentedit-e2e-open (source)
  "Begin a public review from the start of SOURCE and return its session."
  (with-current-buffer source
    (goto-char (point-min))
    (call-interactively #'agentedit-review)
    (or (gethash source agentedit-review--sessions)
        (error "No review session opened"))))

(defun agentedit-e2e-decisions (session)
  "Accept the first and reject the second record in SESSION."
  (dolist (key '("A" "R"))
    (agentedit-e2e-key session key)
    (sleep-for 0.05))
  (unless (eq (agentedit-review-session-state session) 'finished)
    (error "Review queue did not finish")))

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
    (buffer-enable-undo))
  (setq session (agentedit-e2e-open source))
  (unless (= 2 (length (agentedit-review-session-records session)))
    (error "Expected two independently reviewable word edits"))
  (agentedit-e2e-decisions session)
  (unless (equal expected (agentedit-e2e-read path))
    (error "Default A/R did not save the exact expected source"))
  (with-current-buffer source
    (undo-only 2)
    (unless (equal original (buffer-string))
      (error "Two undo steps did not restore the complete source"))
    (unless (equal expected (agentedit-e2e-read path))
      (error "Undo unexpectedly saved the source"))
    (save-buffer)
    (setq-local agentedit-review-auto-save nil))
  (setq session (agentedit-e2e-open source))
  (agentedit-e2e-decisions session)
  (unless (equal original (agentedit-e2e-read path))
    (error "Manual A/R unexpectedly saved the source"))
  (with-current-buffer source
    (unless (equal expected (buffer-string))
      (error "Manual accept/reject changed source extent or whitespace"))
    (save-buffer))
  (unless (equal expected (agentedit-e2e-read path))
    (error "Explicit manual save did not persist expected source"))
  ;; A separate disposable file proves a custom fragment stages without
  ;; writing and then persists through the same A/R path.
  (let* ((custom-path (expand-file-name "custom.tex" directory))
         (custom-source nil)
         (custom-expected (replace-regexp-in-string
                           "often" "sometimes" expected t t)))
    (with-temp-file custom-path (insert original))
    (setq custom-source (find-file-noselect custom-path))
    (with-current-buffer custom-source (latex-mode) (buffer-enable-undo))
    (setq session (agentedit-e2e-open custom-source))
    (agentedit-e2e-key session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (delete-region agentedit-review--fragment-start agentedit-review--fragment-end)
      (goto-char agentedit-review--fragment-start)
      (insert "sometimes"))
    (agentedit-e2e-key session "C-c C-c")
    (unless (equal original (agentedit-e2e-read custom-path))
      (error "Staging custom text wrote source prematurely"))
    (agentedit-e2e-key session "A")
    (sleep-for 0.05)
    (agentedit-e2e-key session "R")
    (unless (equal custom-expected (agentedit-e2e-read custom-path))
      (error "Custom result did not save exactly")))
  (princ "E2E Ediff: default auto-save, exact undo, manual mode, custom stage/apply PASS\n"))

;;; e2e_review.el ends here
