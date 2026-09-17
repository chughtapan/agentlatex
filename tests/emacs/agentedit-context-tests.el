;;; agentedit-context-tests.el --- Contextual review tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agentedit-review)

(defmacro agentedit-context-test--with-review (text &rest body)
  "Open real Ediff on TEXT and evaluate BODY with source and session bound."
  (declare (indent 1) (debug t))
  `(let ((source (generate-new-buffer " *AgentEdit context test*"))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (ediff-split-window-function #'split-window-horizontally)
         (ediff-keep-variants t)
         (agentedit-review-auto-save nil)
         session)
     (unwind-protect
         (progn
           (with-current-buffer source
             (insert ,text)
             (if (and (boundp 'agentedit-review-test--use-auctex)
                      agentedit-review-test--use-auctex)
                 (LaTeX-mode) (latex-mode))
             (buffer-enable-undo)
             (goto-char (point-min))
             (agentedit-review t)
             (setq session (gethash source agentedit-review--sessions)))
           ,@body)
       (agentedit-context-test--dispose session)
       (when (buffer-live-p source) (kill-buffer source)))))

(defun agentedit-context-test--dispose (session)
  "Dispose SESSION and its report/recovery after a test."
  (when session
    (unless (agentedit-review--terminal-state-p (agentedit-review-session-state session))
      (setf (agentedit-review-session-state session) 'failed))
    (agentedit-review--force-terminal-cleanup session)
    (dolist (buffer (list (agentedit-review-session-report session)
                         (agentedit-review-session-recovery session)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defmacro agentedit-context-test--with-file (text &rest body)
  "Review TEXT in a disposable real file; bind source, session, and filename."
  (declare (indent 1) (debug t))
  `(let* ((directory (make-temp-file "agentedit-save-" t))
          (filename (expand-file-name "paper.tex" directory))
          (ediff-window-setup-function #'ediff-setup-windows-plain)
          (ediff-split-window-function #'split-window-horizontally)
          (ediff-keep-variants t)
          (agentedit-review-auto-save t)
          source session)
     (unwind-protect
         (progn
           (with-temp-file filename (insert ,text))
           (setq source (find-file-noselect filename))
           (with-current-buffer source
             (if (and (boundp 'agentedit-review-test--use-auctex)
                      agentedit-review-test--use-auctex)
                 (LaTeX-mode) (latex-mode))
             (goto-char (point-min))
             (agentedit-review t)
             (setq session (gethash source agentedit-review--sessions)))
           ,@body)
       (agentedit-context-test--dispose session)
       (when (buffer-live-p source)
         (with-current-buffer source (set-buffer-modified-p nil))
         (kill-buffer source))
       (delete-directory directory t))))

(defun agentedit-context-test--disk (filename)
  "Read plain text in FILENAME."
  (with-temp-buffer (insert-file-contents filename) (buffer-string)))

(defun agentedit-context-test--command (session key &optional pane)
  "Run KEY through SESSION's real keymap, optionally in PANE."
  (with-current-buffer (or pane (agentedit-review-session-control session))
    (call-interactively (key-binding (kbd key)))))

(defun agentedit-context-test--text (buffer)
  "Return BUFFER's plain display text."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest agentedit-context-shows-paragraph-and-neighbor-original ()
  (agentedit-context-test--with-review
      "Earlier paragraph.\n\nA \\agentedit{one}{Improve.}{nice}{clear} example and \\agentedit{two}{Improve.}{old}{new} ending.\n\nLater paragraph.\n"
    (let ((original (agentedit-context-test--text
                     (agentedit-review-session-projection-a session)))
          (result (agentedit-context-test--text
                   (agentedit-review-session-projection-b session))))
      (should (string-match-p "A nice example and old ending" original))
      (should (string-match-p "A clear example and old ending" result))
      (should-not (string-match-p "agentedit\\|Earlier\\|Later" result))
      (agentedit-context-test--command session "C-c w")
      (should (string-match-p "Earlier paragraph"
                             (agentedit-context-test--text
                              (agentedit-review-session-projection-b session))))
      (should (= 0 (agentedit-review-session-index session)))
      (should (eq session (gethash source agentedit-review--sessions))))))

(ert-deftest agentedit-context-stages-custom-draft-from-control-before-accept ()
  (agentedit-context-test--with-review
      "A \\agentedit{one}{Improve.}{nice}{clear} example.\n"
    (let ((before (agentedit-context-test--text source)))
      (agentedit-context-test--command session "C-c e")
      (with-current-buffer (agentedit-review-session-projection-b session)
        (goto-char agentedit-review--fragment-end)
        (insert "er"))
      (should-error (agentedit-context-test--command session "A") :type 'user-error)
      (should-error (agentedit-context-test--command session "C-c w") :type 'user-error)
      (should (equal before (agentedit-context-test--text source)))
      (agentedit-context-test--command session "C-c C-c")
      (should (equal "clearer" (agentedit-review-session-draft session)))
      (should (eq 'reviewing (agentedit-review-session-state session)))
      (should (equal before (agentedit-context-test--text source)))
      (agentedit-context-test--command session "C-c w")
      (agentedit-context-test--command session "A")
      (sleep-for 0.02)
      (should (equal "A clearer example.\n" (agentedit-context-test--text source)))
      (with-current-buffer source (undo-only 1))
      (should (equal before (agentedit-context-test--text source))))))

(ert-deftest agentedit-context-empty-fragment-boundaries-and-seed-cancel ()
  (agentedit-context-test--with-review
      "Before \\agentedit{one}{Insert.}{}{} after.\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (goto-char agentedit-review--fragment-start)
      (insert "α")
      (goto-char agentedit-review--fragment-end)
      (insert "\nβ")
      (should-error (delete-region (point-min) (1+ (point-min))) :type 'user-error))
    (agentedit-context-test--command session "C-c C-c")
    (should (equal "α\nβ" (agentedit-review-session-draft session)))
    (agentedit-context-test--command session "C-c o")
    (should (equal "" (agentedit-review--live-draft session)))
    (agentedit-context-test--command session "C-c p")
    (agentedit-context-test--command session "C-c C-k"
                                       (agentedit-review-session-projection-a session))
    (should (equal "α\nβ" (agentedit-review-session-draft session)))
    (should (equal "α\nβ" (agentedit-review--live-draft session)))))

(ert-deftest agentedit-context-protects-roles-and-native-help ()
  (agentedit-context-test--with-review
      "Before \\agentedit{one}{Improve.}{old}{new} after.\n"
    (dolist (key '("a" "b" "w" "~"))
      (should-error (agentedit-context-test--command session key) :type 'user-error))
    (with-current-buffer (agentedit-review-session-control session)
      (should (eq #'ediff-documentation (key-binding (kbd "E"))))
      (should (eq #'ediff-toggle-help (key-binding (kbd "?"))))
      (should (eq #'ediff-toggle-split (key-binding (kbd "|")))))
    (with-current-buffer (agentedit-review-session-projection-a session)
      (let ((buffer-read-only nil))
        (should-error (insert "corruption") :type 'user-error)))
    (should (= 0 (agentedit-review-session-index session)))))

(ert-deftest agentedit-context-source-drift-preserves-live-draft ()
  (agentedit-context-test--with-review
      "Before \\agentedit{one}{Improve.}{old}{new} after.\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (goto-char agentedit-review--fragment-end)
      (insert " custom"))
    (with-current-buffer source (goto-char (point-max)) (insert "Elsewhere.\n"))
    (agentedit-context-test--command session "C-c C-c")
    (should (eq 'stale (agentedit-review-session-state session)))
    (should (equal "new custom"
                   (agentedit-context-test--text
                    (agentedit-review-session-recovery session))))
    (should-not (gethash source agentedit-review--sessions))
    (should (string-match-p "agentedit" (agentedit-context-test--text source)))))


(ert-deftest agentedit-context-auto-saves-only-decisions-and-undo-remains-unsaved ()
  (agentedit-context-test--with-file
      "A \\agentedit{one}{Why?}{old}{new} example.\n\\agentedit{two}{Why?}{before}{after}\n"
    (let ((before (agentedit-context-test--disk filename)) (saves 0))
      (with-current-buffer source
        (add-hook 'after-save-hook (lambda () (cl-incf saves)) nil t))
      (agentedit-context-test--command session "C-c e")
      (with-current-buffer (agentedit-review-session-projection-b session)
        (goto-char agentedit-review--fragment-end) (insert "er"))
      (agentedit-context-test--command session "C-c C-c")
      (should (= saves 0))
      (should (equal before (agentedit-context-test--disk filename)))
      (agentedit-context-test--command session "A")
      (sleep-for 0.02)
      (should (= saves 1))
      (should-not (buffer-modified-p source))
      (should (string-prefix-p "A newer example." (agentedit-context-test--disk filename)))
      (agentedit-context-test--command session "S")
      (should (= saves 1))
      (should (eq 'finished (agentedit-review-session-state session)))
      (with-current-buffer source (undo-only 1))
      (should (equal before (agentedit-context-test--text source)))
      (should (= saves 1))
      (should-not (equal before (agentedit-context-test--disk filename)))
      (let ((report (agentedit-context-test--text (agentedit-review--render-report session))))
        (should (string-match-p "1 accepted (1 custom), 0 rejected, 1 skipped, 0 unvisited; 1 unresolved" report))
        (should (string-match-p "modified since verified save" report))))))

(ert-deftest agentedit-context-save-failures-keep-one-applied-decision ()
  (dolist (failure '(error quit rewrite noop rename))
    (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
      (let ((before (agentedit-context-test--disk filename)))
        (with-current-buffer source
          (pcase failure
            ('error (add-hook 'write-contents-functions (lambda () (error "save failed")) nil t))
            ('quit (add-hook 'before-save-hook (lambda () (signal 'quit nil)) nil t))
            ('rewrite (add-hook 'after-save-hook (lambda () (goto-char (point-max)) (insert "hook")) nil t))
            ('noop (add-hook 'write-contents-functions
                             (lambda () (set-buffer-modified-p nil) t) nil t))
            ('rename (add-hook 'before-save-hook
                              (lambda () (setq buffer-file-name (concat filename ".moved"))) nil t))))
        (agentedit-context-test--command session "A")
        (should (eq 'partial-failure (agentedit-review-session-state session)))
        (should (= 1 (agentedit-review-session-index session)))
        (should (= 1 (agentedit-review-session-accepted session)))
        (should-not (gethash source agentedit-review--sessions))
        (should (string-prefix-p "new" (agentedit-context-test--text source)))
        (should (string-match-p "Applied; save not confirmed"
                                (agentedit-context-test--text (agentedit-review-session-report session))))
        (when (memq failure '(error quit noop))
          (should (equal before (agentedit-context-test--disk filename))))))))

(ert-deftest agentedit-context-no-filename-or-disk-conflict-refuses-before-mutation ()
  (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
    (setf (agentedit-review-session-auto-save session) t)
    (let ((before (agentedit-context-test--text source)))
      (agentedit-context-test--command session "A")
      (should (equal before (agentedit-context-test--text source)))
      (should (= 0 (agentedit-review-session-accepted session)))))
  (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
    (let ((before (agentedit-context-test--text source)))
      (with-temp-file filename (insert "external disk contents\n"))
      (set-file-times filename (time-add (current-time) 10))
      (agentedit-context-test--command session "R")
      (should (equal before (agentedit-context-test--text source)))
      (should (= 0 (agentedit-review-session-rejected session)))
      (should (equal "external disk contents\n" (agentedit-context-test--disk filename))))))

(ert-deftest agentedit-context-late-native-cleanup-failure-never-advances ()
  (dolist (tail '("" "\\agentedit{two}{Why?}{earlier}{later}\n"))
    (agentedit-context-test--with-file (concat "\\agentedit{one}{Why?}{old}{new}\n" tail)
      (with-current-buffer (agentedit-review-session-control session)
        (add-hook 'ediff-cleanup-hook (lambda () (error "late teardown")) t t))
      (agentedit-context-test--command session "A")
      (sleep-for 0.02)
      (should (eq 'partial-failure (agentedit-review-session-state session)))
      (should (agentedit-review-session-save-confirmed session))
      (should (= 1 (agentedit-review-session-index session)))
      (should-not (agentedit-review-session-timer session))
      (should-not (buffer-live-p (agentedit-review-session-control session)))
      (should (string-match-p "Saved; review stopped" (agentedit-review--terminal-message session)))
      (should (equal (concat "new\n" tail) (agentedit-context-test--disk filename))))))

(ert-deftest agentedit-context-killed-panes-recover-empty-and-whitespace-drafts ()
  (dolist (role '(original edited control))
    (dolist (draft '("" " \n" "custom"))
      (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
        (agentedit-context-test--command session "C-c e")
        (with-current-buffer (agentedit-review-session-projection-b session)
          (delete-region agentedit-review--fragment-start agentedit-review--fragment-end)
          (goto-char agentedit-review--fragment-start) (insert draft))
        (kill-buffer (pcase role
                       ('original (agentedit-review-session-projection-a session))
                       ('edited (agentedit-review-session-projection-b session))
                       (_ (agentedit-review-session-control session))))
        (sleep-for 0.02)
        (should (equal draft (agentedit-context-test--text (agentedit-review-session-recovery session))))
        (should-not (gethash source agentedit-review--sessions))
        (should (buffer-live-p (agentedit-review-session-report session)))))))

(ert-deftest agentedit-context-refresh-failure-recovers-pre-cancel-draft ()
  (dolist (failure '(error quit))
    (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
      (agentedit-context-test--command session "C-c e")
      (with-current-buffer (agentedit-review-session-projection-b session)
        (goto-char agentedit-review--fragment-end) (insert " live"))
      (cl-letf (((symbol-function 'ediff-update-diffs)
                 (lambda () (signal failure '("refresh failed")))))
        (agentedit-context-test--command session "C-c C-k"))
      (should (equal "new live" (agentedit-context-test--text (agentedit-review-session-recovery session))))
      (should (eq 'failed (agentedit-review-session-state session))))))

(ert-deftest agentedit-context-scanner-refuses-custom-comment-hiding-next-legacy-marker ()
  (agentedit-context-test--with-review
      "\\agentedit{one}{Why?}{old}{new} \\agentedit{two}{Why?}{before}{after}\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (goto-char agentedit-review--fragment-end) (insert "%"))
    (agentedit-context-test--command session "C-c C-c")
    (agentedit-context-test--command session "A")
    (sleep-for 0.02)
    (should (agentedit-review--terminal-state-p (agentedit-review-session-state session)))
    (should (= 1 (agentedit-review-session-accepted session)))
    (should (string-match-p "agentedit{two}" (agentedit-context-test--text source)))))

(ert-deftest agentedit-context-project-policy-dirty-source-and-partial-save-report ()
  (dolist (automatic '(t nil))
    (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
      (agentedit-context-test--dispose session)
      (let* ((second-path (expand-file-name "second.tex" directory))
             (third-path (expand-file-name "untouched.tex" directory))
             second third)
        (unwind-protect
            (progn
              (with-temp-file second-path (insert "\\agentedit{two}{Why?}{before}{after}\n"))
              (with-temp-file third-path (insert "untouched\n"))
              (setq second (find-file-noselect second-path)
                    third (find-file-noselect third-path))
              (with-current-buffer second
                (latex-mode)
                (setq-local agentedit-review-auto-save (not automatic))
                (when automatic
                  (add-hook 'write-contents-functions (lambda () (error "second cannot save")) nil t)))
              (with-current-buffer third (goto-char (point-max)) (insert "pre-existing unsaved third\n"))
              (with-current-buffer source
                (goto-char (point-min)) (insert "pre-existing unsaved first\n")
                (setq-local agentedit-review-auto-save automatic)
                (agentedit-review--begin
                 source (list source second third)
                 (append (agentedit-review--scan-records (point-min))
                         (with-current-buffer second (agentedit-review--scan-records (point-min))))
                 "empty")
                (setq session (gethash source agentedit-review--sessions))
                ;; Later changes in any buffer must not switch session policy.
                (setq-local agentedit-review-auto-save (not automatic)))
              (agentedit-context-test--command session "A")
              (sleep-for 0.02)
              (agentedit-context-test--command session "R")
              (should (eq (agentedit-review-session-state session)
                          (if automatic 'partial-failure 'finished)))
              (should (= 1 (agentedit-review-session-accepted session)))
              (should (= 1 (agentedit-review-session-rejected session)))
              (should (equal "before\n" (agentedit-context-test--text second)))
              (should (equal "untouched\n" (agentedit-context-test--disk third-path)))
              (should (equal "\\agentedit{two}{Why?}{before}{after}\n"
                             (agentedit-context-test--disk second-path)))
              (if automatic
                  (should (equal "pre-existing unsaved first\nnew\n" (agentedit-context-test--disk filename)))
                (should (equal "\\agentedit{one}{Why?}{old}{new}\n" (agentedit-context-test--disk filename))))
              (let ((report (agentedit-context-test--text (agentedit-review-session-report session))))
                (should (string-match-p (if automatic "Saved at last decision" "MANUAL") report))
                (should (string-match-p "untouched.tex" report))))
          (dolist (buffer (list second third))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (set-buffer-modified-p nil))
              (kill-buffer buffer))))))))

(ert-deftest agentedit-context-scope-preserves-earlier-malformed-and-duplicate-legacy ()
  (dolist (prefix '("\\agentedit{one}{Earlier.}{before}{after}\n\n"
                    "\\agentedit{broken}\n\n"))
    (agentedit-context-test--with-review "\\agentedit{first}{Why?}{old}{new}\n"
      (agentedit-context-test--dispose session)
      (with-current-buffer source
        (erase-buffer)
        (insert "\\agentedit{first}{Why?}{old}{new}\n" prefix
                "\\agentedit{one}{Scoped reason in full.}{old}{new}\n")
        (goto-char (point-max)) (forward-line -1)
        (agentedit-review t)
        (setq session (gethash source agentedit-review--sessions)))
      (should (= 1 (length (agentedit-review-session-records session))))
      (agentedit-context-test--command session "C-c w")
      (agentedit-context-test--command session "A")
      (should (string-match-p (regexp-quote prefix) (agentedit-context-test--text source)))
      (let ((report (agentedit-context-test--text (agentedit-review-session-report session))))
        (should (string-match-p "0 unvisited; 0 unresolved in this review" report))
        (should (string-match-p "pending outside review scope" report))))))

(ert-deftest agentedit-context-no-records-still-reports-outside-scope-without-saving ()
  (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
    (agentedit-context-test--dispose session)
    (with-current-buffer source
      (goto-char (point-max)) (insert "dirty tail\n")
      (agentedit-review t)
      (setq session agentedit-review--last-session))
    (should (eq 'finished (agentedit-review-session-state session)))
    (should (equal "\\agentedit{one}{Why?}{old}{new}\n" (agentedit-context-test--disk filename)))
    (let ((report (agentedit-context-test--text (agentedit-review-session-report session))))
      (should (string-match-p "1 pending outside review scope" report))
      (should (string-match-p "Pending outside scope: \"one\"" report)))))

(ert-deftest agentedit-context-forced-context-or-role-tamper-fails-without-writing ()
  (dolist (tamper '(original result roles))
    (agentedit-context-test--with-review "Before \\agentedit{one}{Why?}{old}{new} after.\n"
      (let ((before (agentedit-context-test--text source)))
        (pcase tamper
          ('roles (with-current-buffer (agentedit-review-session-control session)
                    (cl-rotatef ediff-buffer-A ediff-buffer-B)))
          (_ (with-current-buffer
                 (if (eq tamper 'original) (agentedit-review-session-projection-a session)
                   (agentedit-review-session-projection-b session))
               (let ((inhibit-read-only t) (inhibit-modification-hooks t))
                 (goto-char (point-min)) (insert "tampered ")))))
        (agentedit-context-test--command session "A")
        (should (equal before (agentedit-context-test--text source)))
        (should (= 0 (agentedit-review-session-accepted session)))
        (should-not (gethash source agentedit-review--sessions))))))

(ert-deftest agentedit-context-skip-and-quit-confirm-custom-discard ()
  (dolist (key '("S" "q"))
    (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
      (agentedit-context-test--command session "C-c e")
      (with-current-buffer (agentedit-review-session-projection-b session)
        (goto-char agentedit-review--fragment-end) (insert " custom"))
      (when (equal key "S") (agentedit-context-test--command session "C-c C-c"))
      (let (prompt)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (question) (setq prompt question) nil)))
          (agentedit-context-test--command session key))
        (should (string-match-p "Discard custom draft" prompt))
        (should (buffer-live-p (agentedit-review-session-control session)))
        (should (equal "new custom" (agentedit-review--live-draft session)))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_question) t)))
          (agentedit-context-test--command session key))
        (should-not (agentedit-review-session-recovery session))
        (should (string-match-p "agentedit" (agentedit-context-test--text source)))))))

(ert-deftest agentedit-context-auto-mode-refuses-unnamed-source-at-start ()
  (let ((source (generate-new-buffer " *AgentEdit unnamed*")))
    (unwind-protect
        (with-current-buffer source
          (insert "\\agentedit{one}{Why?}{old}{new}\n")
          (latex-mode)
          (buffer-enable-undo)
          (goto-char (point-min))
          (should-error (agentedit-review t) :type 'user-error)
          (should-not (gethash source agentedit-review--sessions))
          (should (string-match-p "agentedit" (buffer-string))))
      (kill-buffer source))))

(ert-deftest agentedit-context-multiline-span-and-whole-file-toggle ()
  (agentedit-context-test--with-review
      (concat "First paragraph.\n\nThe \\agentedit{one}{Why?}{first\nsecond}{replacement\nline} here.\n\n"
              "Third paragraph.\n")
    (let ((paragraph (agentedit-context-test--text (agentedit-review-session-projection-b session))))
      (should (string-match-p "The replacement\nline here" paragraph))
      (should-not (string-match-p "First paragraph\|Third paragraph" paragraph))
      (agentedit-context-test--command session "C-c w")
      (let ((whole (agentedit-context-test--text (agentedit-review-session-projection-b session))))
        (should (string-match-p "First paragraph" whole))
        (should (string-match-p "Third paragraph" whole))
        (should (string-match-p "replacement\nline" whole)))
      (agentedit-context-test--command session "C-c w")
      (should (equal paragraph (agentedit-context-test--text (agentedit-review-session-projection-b session)))))))

(ert-deftest agentedit-context-zero-diff-still-resolves-exact-wrapper ()
  (agentedit-context-test--with-review "A \\agentedit{one}{Why?}{same}{same} word.\n"
    (should (= 0 (with-current-buffer (agentedit-review-session-control session)
                   ediff-number-of-differences)))
    (agentedit-context-test--command session "A")
    (should (equal "A same word.\n" (agentedit-context-test--text source)))
    (should (eq 'finished (agentedit-review-session-state session)))))

(ert-deftest agentedit-context-source-change-then-undo-is-still-stale ()
  (agentedit-context-test--with-review "A \\agentedit{one}{Why?}{old}{new} word.\n"
    (let ((before (agentedit-context-test--text source)))
      (with-current-buffer source
        (goto-char (point-max)) (insert "temporary") (delete-region (- (point-max) 9) (point-max)))
      (should (equal before (agentedit-context-test--text source)))
      (agentedit-context-test--command session "A")
      (should (= 0 (agentedit-review-session-accepted session)))
      (should (eq 'stale (agentedit-review-session-state session))))))

(ert-deftest agentedit-context-result-header-updates-empty-and-whitespace ()
  (agentedit-context-test--with-review "A \\agentedit{one}{Why?}{old}{new} word.\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (delete-region agentedit-review--fragment-start agentedit-review--fragment-end)
      (should (string-match-p "empty fragment" (mapconcat #'substring-no-properties header-line-format "")))
      (goto-char agentedit-review--fragment-start) (insert " \n")
      (should (string-match-p "whitespace only" (mapconcat #'substring-no-properties header-line-format ""))))))

(ert-deftest agentedit-context-report-links-and-source-status-refresh ()
  (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
    (agentedit-context-test--command session "A")
    (let* ((report (agentedit-review-session-report session))
           (text (agentedit-context-test--text report)))
      (should (string-match-p "paper.tex:1" text))
      (should (string-match-p "Review scope: queue from source line 1" text))
      (with-current-buffer report
        (goto-char (point-min))
        (search-forward "Visit source")
        (push-button (point))
        (should (eq (current-buffer) report)))
      (with-current-buffer source (goto-char (point-max)) (insert "later"))
      (with-current-buffer report (call-interactively (key-binding (kbd "g"))))
      (should (string-match-p "modified since verified save" (agentedit-context-test--text report))))))

(ert-deftest agentedit-context-auto-save-preserves-utf8-dos-line-endings ()
  (let* ((directory (make-temp-file "agentedit-dos-" t))
         (filename (expand-file-name "paper.tex" directory))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (ediff-keep-variants t)
         (agentedit-review-auto-save t)
         source session)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-dos))
            (with-temp-file filename
              (insert "Préface.\n\\agentedit{one}{Why?}{α}{β}\nLast line.\n")))
          (setq source (find-file-noselect filename))
          (with-current-buffer source (latex-mode) (goto-char (point-min)) (agentedit-review t))
          (setq session (gethash source agentedit-review--sessions))
          (agentedit-context-test--command session "A")
          (should (eq 'finished (agentedit-review-session-state session)))
          (with-temp-buffer
            (insert-file-contents-literally filename)
            (should (equal (string-as-unibyte (buffer-string))
                           (encode-coding-string "Préface.\r\nβ\r\nLast line.\r\n" 'utf-8)))))
      (agentedit-context-test--dispose session)
      (when (buffer-live-p source) (kill-buffer source))
      (delete-directory directory t))))

(ert-deftest agentedit-context-source-replacement-hook-failure-rolls-back ()
  (dolist (failure '(error quit))
    (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
      (let ((before (agentedit-context-test--text source)))
        (agentedit-context-test--command session "C-c e")
        (with-current-buffer (agentedit-review-session-projection-b session)
          (goto-char agentedit-review--fragment-end) (insert " custom"))
        (agentedit-context-test--command session "C-c C-c")
        (with-current-buffer source
          (add-hook 'before-change-functions
                    (lambda (_start _end) (signal failure '("source hook"))) nil t))
        (agentedit-context-test--command session "A")
        (should (equal before (agentedit-context-test--text source)))
        (should (equal before (agentedit-context-test--disk filename)))
        (should (= 0 (agentedit-review-session-accepted session)))
        (should (equal "new custom"
                       (agentedit-context-test--text
                        (agentedit-review-session-recovery session))))))))

(ert-deftest agentedit-context-seed-failure-recovers-live-custom-text ()
  (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (goto-char agentedit-review--fragment-end) (insert " live"))
    (let ((result (agentedit-review-session-projection-b session)))
      (with-current-buffer result
        (add-hook 'before-change-functions
                  (lambda (_start _end) (error "seed failure")) nil t)))
    (agentedit-context-test--command session "C-c o")
    (should (eq 'failed (agentedit-review-session-state session)))
    (should (equal "new live"
                   (agentedit-context-test--text
                    (agentedit-review-session-recovery session))))))

(ert-deftest agentedit-context-stage-or-toggle-refresh-failure-recovers-draft ()
  (dolist (key '("C-c C-c" "C-c w"))
    (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
      (agentedit-context-test--command session "C-c e")
      (with-current-buffer (agentedit-review-session-projection-b session)
        (delete-region agentedit-review--fragment-start agentedit-review--fragment-end))
      (when (equal key "C-c w")
        (agentedit-context-test--command session "C-c C-c"))
      (cl-letf (((symbol-function 'ediff-update-diffs)
                 (lambda () (error "refresh failure"))))
        (agentedit-context-test--command session key))
      (should (equal "" (agentedit-context-test--text
                          (agentedit-review-session-recovery session))))
      (should (eq 'failed (agentedit-review-session-state session))))))

(ert-deftest agentedit-context-filename-change-before-decision-does-not-write ()
  (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
    (let ((before (agentedit-context-test--text source))
          (newname (concat filename ".elsewhere")))
      (with-current-buffer source (setq buffer-file-name newname))
      (agentedit-context-test--command session "A")
      (should (eq 'failed (agentedit-review-session-state session)))
      (should (= 0 (agentedit-review-session-accepted session)))
      (should (equal before (agentedit-context-test--text source)))
      (should (equal before (agentedit-context-test--disk filename)))
      (should-not (file-exists-p newname)))))

(ert-deftest agentedit-context-before-save-formatter-stops-with-accurate-disk ()
  (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
    (with-current-buffer source
      (add-hook 'before-save-hook
                (lambda () (goto-char (point-max)) (insert "formatter\n")) nil t))
    (agentedit-context-test--command session "A")
    (should (eq 'partial-failure (agentedit-review-session-state session)))
    (should (= 1 (agentedit-review-session-accepted session)))
    (should (equal "new\nformatter\n" (agentedit-context-test--disk filename)))
    (should (equal "new\nformatter\n" (agentedit-context-test--text source)))
    (should (string-match-p "Applied; save not confirmed"
                            (agentedit-context-test--text
                             (agentedit-review-session-report session))))))

(ert-deftest agentedit-context-post-apply-disk-conflict-does-not-overwrite ()
  (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
    (let ((original (symbol-function 'agentedit-review--replace-current))
          (before (agentedit-context-test--text source)))
      (cl-letf (((symbol-function 'agentedit-review--replace-current)
                 (lambda (current replacement)
                   (funcall original current replacement)
                   (with-temp-file filename (insert "external disk update\n"))
                   (set-file-times filename
                                   (time-add (current-time) (seconds-to-time 5))))))
        (agentedit-context-test--command session "A"))
      (should (eq 'partial-failure (agentedit-review-session-state session)))
      (should (= 1 (agentedit-review-session-accepted session)))
      (should (equal "new\n" (agentedit-context-test--text source)))
      (should (equal "external disk update\n" (agentedit-context-test--disk filename)))
      (with-current-buffer source (undo-only 1))
      (should (equal before (agentedit-context-test--text source))))))

(ert-deftest agentedit-context-report-reason-newline-is-quoted ()
  (agentedit-context-test--with-review
      "\\agentedit{one}{Why?\nSaved at last decision}{old}{new}\n"
    (agentedit-context-test--command session "A")
    (let ((report (agentedit-context-test--text (agentedit-review-session-report session))))
      (should (string-match-p (regexp-quote "Reason: \"Why?\\nSaved at last decision\"") report))
      (should-not (string-match-p "Reason: Why?\nSaved at last decision" report)))))

(ert-deftest agentedit-context-report-buttons-visit-source-record-and-recovery ()
  (agentedit-context-test--with-file "\\agentedit{one}{Why?}{old}{new}\n"
    (agentedit-context-test--command session "A")
    (let ((report (agentedit-review-session-report session)))
      (with-current-buffer report
        (goto-char (point-min)) (search-forward "Visit source") (backward-char 1)
        (push-button (point)))
      (should (eq source (window-buffer (selected-window))))
      (with-current-buffer report
        (goto-char (point-min)) (search-forward "Visit record") (backward-char 1)
        (push-button (point)))
      (should (eq source (window-buffer (selected-window))))
      (should (= (with-current-buffer source (point)) (marker-position
                           (agentedit-review-record-start
                            (car (agentedit-review-session-records session))))))))
  (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (goto-char agentedit-review--fragment-end) (insert " custom"))
    (with-current-buffer source (goto-char (point-max)) (insert "source drift"))
    (agentedit-context-test--command session "C-c C-c")
    (let ((recovery (agentedit-review-session-recovery session))
          (report (agentedit-review-session-report session)))
      (with-current-buffer report
        (goto-char (point-min)) (search-forward "Open recovered draft") (backward-char 1)
        (push-button (point)))
      (should (eq recovery (window-buffer (selected-window)))))))

(ert-deftest agentedit-context-invalid-paragraph-rules-fall-back-to-full-file ()
  (agentedit-context-test--with-review "First.\n\n\\agentedit{one}{Why?}{old}{new}\n\nLast.\n"
    (agentedit-context-test--dispose session)
    (with-current-buffer source
      (setq-local paragraph-start "[" paragraph-separate "[")
      (goto-char (point-min)) (agentedit-review t)
      (setq session (gethash source agentedit-review--sessions)))
    (should (agentedit-review-view-fallback (agentedit-review-session-view session)))
    (should (string-match-p "First."
                            (agentedit-context-test--text
                             (agentedit-review-session-projection-b session))))
    (agentedit-context-test--command session "A")
    (should (equal "First.\n\nnew\n\nLast.\n" (agentedit-context-test--text source)))))

(ert-deftest agentedit-context-empty-paragraph-at-boundaries ()
  (let ((source (generate-new-buffer " *AgentEdit paragraph boundaries*"))
        (plain "Alpha paragraph.\n\nBeta paragraph.\n"))
    (unwind-protect
        (with-current-buffer source
          (fundamental-mode)
          (dolist (case `((1 . "Alpha paragraph.")
                          (17 . "Alpha paragraph.\n\nBeta paragraph.")
                          (18 . "Alpha paragraph.\n\nBeta paragraph.")
                          (,(1+ (length plain)) . "Beta paragraph.")))
            (let* ((point (car case))
                   (view (agentedit-review--make-view-data
                          :text plain :start point :end point))
                   (bounds (agentedit-review--paragraph-bounds view source))
                   (shown (and bounds
                               (substring plain (1- (car bounds)) (1- (cdr bounds))))))
              (should bounds)
              (should (string-match-p (regexp-quote (cdr case)) shown)))))
      (kill-buffer source))))

(ert-deftest agentedit-context-multiple-diff-hunks-retain-active-fragment ()
  (let* ((middle (mapconcat (lambda (number) (format "same line %02d" number))
                            (number-sequence 1 30) "\n"))
         (old (format "old first\n%s\nold last" middle))
         (new (format "new first\n%s\nnew last" middle)))
    (agentedit-context-test--with-review
        (format "Before.\n\n\\agentedit{two-hunks}{Why?}{%s}{%s}\n\nAfter.\n" old new)
      (with-current-buffer (agentedit-review-session-control session)
        (should (>= ediff-number-of-differences 2)))
      (agentedit-context-test--command session "C-c w")
      (with-current-buffer (agentedit-review-session-projection-b session)
        (should (string-match-p "new first" (buffer-string)))
        (should (string-match-p "new last" (buffer-string))))
      (agentedit-context-test--command session "A")
      (should (string-match-p "new first" (agentedit-context-test--text source)))
      (should (string-match-p "new last" (agentedit-context-test--text source))))))

(ert-deftest agentedit-context-pending-label-follows-longer-custom-fragment ()
  (agentedit-context-test--with-review
      "A \\agentedit{one}{Why?}{old}{new} then \\agentedit{two}{Why?}{before}{after}.\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (delete-region agentedit-review--fragment-start agentedit-review--fragment-end)
      (goto-char agentedit-review--fragment-start) (insert "muchlonger"))
    (agentedit-context-test--command session "C-c C-c")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (let* ((plain (buffer-substring-no-properties (point-min) (point-max)))
             (badge (cl-find-if
                     (lambda (overlay) (overlay-get overlay 'agentedit-pending))
                     (append (car (overlay-lists)) (cdr (overlay-lists))))))
        (should badge)
        (should (= (overlay-start badge) (1+ (string-match "before" plain))))
        (should (string-match-p "pending two" (overlay-get badge 'before-string)))))))

(ert-deftest agentedit-context-hundred-records-repeat-toggle-and-stage ()
  (let ((fixture (concat
                  (mapconcat
                   (lambda (number)
                     (format "\\agentedit{item-%03d}{Why?}{old}{new}" number))
                   (number-sequence 1 110) " ")
                  "\n")))
    (agentedit-context-test--with-review fixture
      (let ((started (float-time)))
        (dotimes (_ 8) (agentedit-context-test--command session "C-c w"))
        (dotimes (_ 4)
          (agentedit-context-test--command session "C-c e")
          (with-current-buffer (agentedit-review-session-projection-b session)
            (goto-char agentedit-review--fragment-end) (insert "x"))
          (agentedit-context-test--command session "C-c C-c"))
        (should (equal "newxxxx" (agentedit-review-session-draft session)))
        (should (equal fixture (agentedit-context-test--text source)))
        (should (= 0 (agentedit-review-session-index session)))
        (should (eq session (gethash source agentedit-review--sessions)))
        (with-current-buffer (agentedit-review--render-report session)
          (should (< (buffer-size) 100000)))
        (message "AgentEdit 110-record repeated toggle/stage: %.3fs"
                 (- (float-time) started))))))

(ert-deftest agentedit-context-native-ediff-quit-releases-lock-and-live-draft ()
  (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
    (agentedit-context-test--command session "C-c e")
    (with-current-buffer (agentedit-review-session-projection-b session)
      (goto-char agentedit-review--fragment-end) (insert " live"))
    (with-current-buffer (agentedit-review-session-control session)
      (ediff-really-quit nil))
    (sleep-for 0.02)
    (should (eq 'failed (agentedit-review-session-state session)))
    (should-not (gethash source agentedit-review--sessions))
    (should (equal "new live"
                   (agentedit-context-test--text
                    (agentedit-review-session-recovery session))))
    (should (string-match-p "Ediff was closed outside"
                            (agentedit-context-test--text
                             (agentedit-review-session-report session))))))

(ert-deftest agentedit-context-native-ediff-quit-without-draft-releases-lock ()
  (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
    (with-current-buffer (agentedit-review-session-control session)
      (ediff-really-quit nil))
    (sleep-for 0.02)
    (should (eq 'failed (agentedit-review-session-state session)))
    (should-not (gethash source agentedit-review--sessions))
    (should-not (agentedit-review-session-recovery session))
    (should (string-match-p "Ediff was closed outside"
                            (agentedit-context-test--text
                             (agentedit-review-session-report session))))))

(ert-deftest agentedit-context-closed-report-link-explains-recovery ()
  (agentedit-context-test--with-review "\\agentedit{one}{Why?}{old}{new}\n"
    (agentedit-context-test--command session "S")
    (let ((report (agentedit-review-session-report session)))
      (with-current-buffer source (set-buffer-modified-p nil))
      (kill-buffer source)
      (with-current-buffer report
        (goto-char (point-min)) (search-forward "Visit source") (backward-char 1)
        (should-error (push-button (point)) :type 'user-error)))))

(ert-deftest agentedit-context-report-keeps-outside-record-after-source-closes ()
  (agentedit-context-test--with-review
      "\\agentedit{earlier}{Why?}{old}{new}\n\\agentedit{current}{Why?}{old}{new}\n"
    (agentedit-context-test--dispose session)
    (with-current-buffer source
      (goto-char (point-max)) (forward-line -1)
      (agentedit-review t)
      (setq session (gethash source agentedit-review--sessions)))
    (agentedit-context-test--command session "A")
    (should (= 1 (agentedit-review-file-outside
                   (car (agentedit-review-session-files session)))))
    (with-current-buffer source (set-buffer-modified-p nil))
    (kill-buffer source)
    (let ((report (agentedit-context-test--text (agentedit-review--render-report session))))
      (should (string-match-p "source buffer closed" report))
      (should (string-match-p "Pending outside scope: \\\"earlier\\\"" report))
      (should (string-match-p "Original: \\\"old\\\"" report)))))

(ert-deftest agentedit-context-two-files-accept-reject-skip-and-undo ()
  (let* ((directory (make-temp-file "agentedit-twofile-" t))
         (first-path (expand-file-name "first.tex" directory))
         (second-path (expand-file-name "second.tex" directory))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (ediff-keep-variants t)
         (agentedit-review-auto-save t)
         first second session)
    (unwind-protect
        (progn
          (with-temp-file first-path (insert "A \\agentedit{one}{Why?}{old}{new}.\n"))
          (with-temp-file second-path
            (insert "B \\agentedit{two}{Why?}{before}{after} and \\agentedit{three}{Why?}{slow}{fast}.\n"))
          (setq first (find-file-noselect first-path)
                second (find-file-noselect second-path))
          (dolist (buffer (list first second))
            (with-current-buffer buffer (latex-mode) (goto-char (point-min))))
          (with-current-buffer first
            (agentedit-review--begin
             first (list first second)
             (append (agentedit-review--scan-records (point-min))
                     (with-current-buffer second (agentedit-review--scan-records (point-min))))
             "none"))
          (setq session (gethash first agentedit-review--sessions))
          (agentedit-context-test--command session "C-c e")
          (with-current-buffer (agentedit-review-session-projection-b session)
            (goto-char agentedit-review--fragment-end) (insert "er"))
          (agentedit-context-test--command session "C-c C-c")
          (should (equal "A \\agentedit{one}{Why?}{old}{new}.\n"
                         (agentedit-context-test--disk first-path)))
          (dolist (key '("A" "R" "S"))
            (agentedit-context-test--command session key)
            (sleep-for 0.02))
          (should (eq 'finished (agentedit-review-session-state session)))
          (should (equal "A newer.\n" (agentedit-context-test--disk first-path)))
          (should (= 1 (agentedit-review-session-custom session)))
          (should (equal "B before and \\agentedit{three}{Why?}{slow}{fast}.\n"
                         (agentedit-context-test--disk second-path)))
          (should (= 1 (agentedit-review-file-skipped (cadr (agentedit-review-session-files session)))))
          (with-current-buffer second (undo-only 1))
          (should (string-match-p "agentedit{two}" (agentedit-context-test--text second)))
          (should-not (string-match-p "agentedit{two}" (agentedit-context-test--disk second-path)))
          (let ((report (agentedit-context-test--text (agentedit-review-session-report session))))
            (should (string-match-p "1 unresolved in this review" report))))
      (agentedit-context-test--dispose session)
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest agentedit-context-queued-file-drift-stops-after-prior-save ()
  (let* ((directory (make-temp-file "agentedit-drift-" t))
         (first-path (expand-file-name "first.tex" directory))
         (second-path (expand-file-name "second.tex" directory))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (ediff-keep-variants t)
         (agentedit-review-auto-save t)
         first second session)
    (unwind-protect
        (progn
          (with-temp-file first-path (insert "\\agentedit{one}{Why?}{old}{new}\n"))
          (with-temp-file second-path (insert "\\agentedit{two}{Why?}{before}{after}\n"))
          (setq first (find-file-noselect first-path)
                second (find-file-noselect second-path))
          (dolist (buffer (list first second))
            (with-current-buffer buffer (latex-mode) (goto-char (point-min))))
          (with-current-buffer first
            (agentedit-review--begin
             first (list first second)
             (append (agentedit-review--scan-records (point-min))
                     (with-current-buffer second (agentedit-review--scan-records (point-min))))
             "none"))
          (setq session (gethash first agentedit-review--sessions))
          (with-current-buffer second (goto-char (point-max)) (insert "external edit\n"))
          (agentedit-context-test--command session "A")
          (sleep-for 0.02)
          (should (eq 'failed (agentedit-review-session-state session)))
          (should (string-match-p "stale" (agentedit-review-session-last-error session)))
          (should (= 1 (agentedit-review-session-accepted session)))
          (should (equal "new\n" (agentedit-context-test--disk first-path)))
          (should (equal "\\agentedit{two}{Why?}{before}{after}\n"
                         (agentedit-context-test--disk second-path)))
          (should (string-match-p "external edit"
                                  (agentedit-context-test--text second)))
          (should-not (agentedit-review-file-error
                       (car (agentedit-review-session-files session))))
          (should (string-match-p
                   "stale"
                   (agentedit-review-file-error
                    (cadr (agentedit-review-session-files session)))))
          (should-not (gethash first agentedit-review--sessions))
          (should-not (gethash second agentedit-review--sessions)))
      (agentedit-context-test--dispose session)
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(provide 'agentedit-context-tests)
;;; agentedit-context-tests.el ends here
