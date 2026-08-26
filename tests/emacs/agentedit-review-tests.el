;;; agentedit-review-tests.el --- Tests for AgentEdit review -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agentedit-review)

(defconst agentedit-review-test--use-auctex
  (equal (getenv "AGENTEDIT_TEST_AUCTEX") "1"))

(when agentedit-review-test--use-auctex
  (require 'latex)
  (require 'font-latex))

(defmacro agentedit-review-test--with-source (text &rest body)
  "Create a built-in LaTeX buffer containing TEXT, then evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (if agentedit-review-test--use-auctex
         (LaTeX-mode)
       (latex-mode))
     (buffer-enable-undo)
     (goto-char (point-min))
     ,@body))

(defun agentedit-review-test--records (text &optional origin)
  "Parse and return records from TEXT beginning at ORIGIN."
  (agentedit-review-test--with-source text
    (agentedit-review--scan-records (or origin (point-min)))))

(defun agentedit-review-test--ids (records)
  "Return the stable IDs from RECORDS."
  (mapcar #'agentedit-review-record-id records))

(ert-deftest agentedit-review-parser-supports-payload-shapes ()
  (let* ((text (concat
                "\\agentedit{add}{Add text.}{}{new}\n"
                "\\agentedit{delete}{Delete text.}{old}{}\n"
                "\\agentedit{nested-braces}{Clarify.}"
                "{before {inside} after}{line one\nline two}\n"))
         (records (agentedit-review-test--records text)))
    (should (equal (agentedit-review-test--ids records)
                   '("add" "delete" "nested-braces")))
    (should (string-empty-p
             (agentedit-review-record-original (car records))))
    (should (string-empty-p
             (agentedit-review-record-edited (cadr records))))
    (should (equal (agentedit-review-record-original (caddr records))
                   "before {inside} after"))))

(ert-deftest agentedit-review-parser-honors-exact-control-tokens ()
  (let ((records
         (agentedit-review-test--records
          (concat
           "\\agentediting{long}{Ignored.}{old}{new}\n"
           "\\\\agentedit{symbol}{Ignored.}{old}{new}\n"
           "\\\\ \\agentedit{valid}{Detected.}{old}{new}\n"))))
    (should (equal (agentedit-review-test--ids records) '("valid")))))

(ert-deftest agentedit-review-parser-handles-comments-and-escaped-percent ()
  (let ((records
         (agentedit-review-test--records
          (concat
           "% \\agentedit{comment}{Ignored.}{old}{new}\n"
           "\\% \\agentedit{visible}{Detected.}{old}{new}\n"
           "\\\\% \\agentedit{comment-two}{Ignored.}{old}{new}\n"
           "\\agentedit{next-line}{Detected.}{old}{new}\n"))))
    (should (equal (agentedit-review-test--ids records)
                   '("visible" "next-line")))))

(ert-deftest agentedit-review-parser-ignores-verb-tokens ()
  (let ((records
         (agentedit-review-test--records
          (concat
           "\\verb|\\agentedit{verb}{Ignored.}{old}{new}|\n"
           "\\verb*+\\agentedit{star}{Ignored.}{old}{new}+\n"
           "\\agentedit{visible}{Detected.}{old}{new}\n"))))
    (should (equal (agentedit-review-test--ids records) '("visible")))))

(ert-deftest agentedit-review-parser-ignores-default-verbatim-environments ()
  (dolist (environment agentedit-review-verbatim-environments)
    (let* ((text (format
                  (concat "\\begin{%s}\n"
                          "\\agentedit{hidden}{Ignored.}{old}{new}\n"
                          "  \\end{%s} %% trailing comment\n"
                          "\\agentedit{visible}{Detected.}{old}{new}\n")
                  environment environment))
           (records (agentedit-review-test--records text)))
      (should (equal (agentedit-review-test--ids records) '("visible"))))))

(ert-deftest agentedit-review-parser-supports-custom-verbatim-environment ()
  (let ((agentedit-review-verbatim-environments '("codeblock")))
    (should
     (equal
      (agentedit-review-test--ids
       (agentedit-review-test--records
        (concat "\\begin{codeblock}\n"
                "\\agentedit{hidden}{Ignored.}{old}{new}\n"
                "\\end{codeblock}\n"
                "\\agentedit{visible}{Detected.}{old}{new}")))
      '("visible")))))

(ert-deftest agentedit-review-parser-rejects-unterminated-opaque-contexts ()
  (should-error
   (agentedit-review-test--records "\\verb|unterminated")
   :type 'user-error)
  (should-error
   (agentedit-review-test--records
    "\\begin{verbatim}\nunterminated")
   :type 'user-error))

(ert-deftest agentedit-review-parser-rejects-invalid-records ()
  (dolist (text (list "\\agentedit{}{Reason.}{old}{new}"
                      "\\agentedit{id}{ \n\t }{old}{new}"
                      "\\agentedit{id}{Reason.}{old}"
                      "\\agentedit{id}{Reason.}{old}{new"
                      (concat "\\agentedit{outer}{Reason.}{old}"
                              "{\\agentedit{inner}{Reason.}{old}{new}}")))
    (should-error (agentedit-review-test--records text) :type 'user-error)))

(ert-deftest agentedit-review-nested-detection-honors-opaque-payload-text ()
  (let* ((text
          (concat
           "\\agentedit{id}{Reason.}"
           "{before\n% \\agentedit ignored in a comment\nafter}"
           "{\\verb|\\agentedit| stays literal}"))
         (record (car (agentedit-review-test--records text))))
    (should (equal (agentedit-review-record-id record) "id"))
    (should (string-match-p "ignored in a comment"
                            (agentedit-review-record-original record)))
    (should (equal (agentedit-review-record-edited record)
                   "\\verb|\\agentedit| stays literal"))))

(ert-deftest agentedit-review-parser-rejects-duplicate-ids ()
  (should-error
   (agentedit-review-test--records
    (concat "\\agentedit{same}{First.}{old}{new}\n"
            "\\agentedit{same}{Second.}{old}{new}"))
   :type 'user-error))

(ert-deftest agentedit-review-parser-origin-is-control-word-based ()
  (let* ((first "\\agentedit{first}{Reason.}{old}{new}")
         (between (concat first "\n"))
         (text (concat between
                       "\\agentedit{second}{Reason.}{old}{new}")))
    (should (equal (agentedit-review-test--ids
                    (agentedit-review-test--records text (length between)))
                   '("second")))
    (should (equal (agentedit-review-test--ids
                    (agentedit-review-test--records text (1+ (length between))))
                   '("second")))
    (should (equal (agentedit-review-test--ids
                    (agentedit-review-test--records text 2))
                   '("second")))))

(ert-deftest agentedit-review-parser-ignores-invalid-record-before-origin ()
  (let* ((prefix "\\agentedit{broken}\n")
         (text (concat prefix "\\agentedit{good}{Reason.}{old}{new}")))
    (should (equal (agentedit-review-test--ids
                    (agentedit-review-test--records text (length prefix)))
                   '("good")))))

(ert-deftest agentedit-review-validates-verbatim-customization ()
  (dolist (value '("verbatim" ("verbatim" 3) ("")))
    (let ((agentedit-review-verbatim-environments value))
      (should-error (agentedit-review--validate-environments)
                    :type 'user-error)))
  (let ((agentedit-review-verbatim-environments '("custom")))
    (should-not (agentedit-review--validate-environments))))

(ert-deftest agentedit-review-normalizes-display-without-changing-record ()
  (let* ((raw-id "  id%b\twith\nspace  ")
         (raw-reason "line one\n\tline two \u2603")
         (record (agentedit-review--make-record
                  :id raw-id :reason raw-reason)))
    (should (equal (agentedit-review--normalize-one-line raw-id)
                   "id%b with space"))
    (should (equal (agentedit-review--normalize-one-line raw-reason)
                   "line one line two \u2603"))
    (should (equal (agentedit-review-record-id record) raw-id))
    (should (equal (agentedit-review-record-reason record) raw-reason))))

(ert-deftest agentedit-review-display-keeps-percent-metadata-literal ()
  (with-temp-buffer
    (switch-to-buffer (current-buffer))
    (setq-local agentedit-review--display-pass "AgentEdit 1 / 1")
    (setq-local agentedit-review--display-id "id%b")
    (setq-local agentedit-review--display-reason "why%p")
    (setq-local agentedit-review--display-source "file%l")
    (setq-local agentedit-review--display-location "7")
    (should (equal (agentedit-review--header-format)
                   '(agentedit-review--header-required
                     agentedit-review--header-reason
                     agentedit-review--header-location)))
    (should (string-match-p "id%b" agentedit-review--header-required))
    (should (string-match-p "why%p" agentedit-review--header-reason))
    (when (not (string-empty-p agentedit-review--header-location))
      (should (string-match-p "file%l" agentedit-review--header-location)))))

(ert-deftest agentedit-review-header-respects-column-width ()
  (with-temp-buffer
    (switch-to-buffer (current-buffer))
    (setq-local agentedit-review--display-pass "AgentEdit 1 / 1")
    (setq-local agentedit-review--display-id
                "a-very-long-identifier-that-needs-elision")
    (setq-local agentedit-review--display-reason
                "a long reason that also needs elision")
    (setq-local agentedit-review--display-source "long-source-name.tex")
    (setq-local agentedit-review--display-location "7")
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 40)))
      (agentedit-review--header-format))
    (should
     (<= (+ (string-width agentedit-review--header-required)
            (string-width agentedit-review--header-reason)
            (string-width agentedit-review--header-location))
         40))))

(ert-deftest agentedit-review-sanitizes-temporary-buffer-names ()
  (let ((name (agentedit-review--temporary-name
               "original" "id/with\ncontrols-and-a-very-long-suffix-0123456789")))
    (should-not (string-match-p "[/\n]" name))
    (should (< (string-width name) 80))))

(ert-deftest agentedit-review-projection-visuals-are-local-and-textual ()
  (let ((global-remapping (default-value 'face-remapping-alist))
        (original-text "before text"))
    (with-temp-buffer
      (insert original-text)
      (agentedit-review--install-projection-visuals "original")
      (should (equal (buffer-string) original-text))
      (should (equal (cadr (assq 'ediff-current-diff-A
                                 face-remapping-alist))
                     'agentedit-review-original-hunk))
      (should (equal (cadr (assq 'ediff-fine-diff-A
                                 face-remapping-alist))
                     'agentedit-review-original-fine))
      (should (string-match-p
               "− ORIGINAL.*reject keeps this"
               (mapconcat #'substring-no-properties header-line-format ""))))
    (with-temp-buffer
      (agentedit-review--install-projection-visuals "edited")
      (should (equal (cadr (assq 'ediff-current-diff-B
                                 face-remapping-alist))
                     'agentedit-review-proposed-hunk))
      (should (equal (cadr (assq 'ediff-fine-diff-B
                                 face-remapping-alist))
                     'agentedit-review-proposed-fine))
      (should (string-match-p
               "\\+ PROPOSED.*accept keeps this"
               (mapconcat #'substring-no-properties header-line-format ""))))
    (should (equal (default-value 'face-remapping-alist) global-remapping))))

(ert-deftest agentedit-review-control-visuals-mark-overlays-and-refine ()
  (with-temp-buffer
    (let ((overlay-a (make-overlay (point-min) (point-min)))
          (overlay-b (make-overlay (point-min) (point-min)))
          refined)
      (setq-local ediff-auto-refine 'off)
      (setq-local ediff-number-of-differences 1)
      (setq-local ediff-current-difference 0)
      (setq-local ediff-current-diff-overlay-A overlay-a)
      (setq-local ediff-current-diff-overlay-B overlay-b)
      (cl-letf (((symbol-function 'ediff-install-fine-diff-if-necessary)
                 (lambda (difference) (setq refined difference))))
        (agentedit-review--install-control-visuals))
      (should (eq ediff-auto-refine 'on))
      (should (= refined 0))
      (should (equal (substring-no-properties
                      (overlay-get overlay-a 'before-string))
                     "− "))
      (should (eq (get-text-property
                   0 'face (overlay-get overlay-a 'before-string))
                  'agentedit-review-original-label))
      (should (equal (substring-no-properties
                      (overlay-get overlay-b 'before-string))
                     "+ "))
      (should (eq (get-text-property
                   0 'face (overlay-get overlay-b 'before-string))
                  'agentedit-review-proposed-label)))))

(ert-deftest agentedit-review-announcement-is-emitted-exactly-once ()
  (let ((session (agentedit-review--make-session
                  :pending-announcement "Next record"))
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (agentedit-review--emit-announcement session)
      (agentedit-review--emit-announcement session))
    (should (equal messages '("Next record")))
    (should-not (agentedit-review-session-pending-announcement session))))

(ert-deftest agentedit-review-announcement-crosses-cleanup-once ()
  (let ((source (generate-new-buffer " *AgentEdit announcement source*"))
        (control (generate-new-buffer " *AgentEdit announcement control*"))
        (session (agentedit-review--make-session
                  :state 'deciding :pending-action 'continue
                  :pending-announcement "Accepted · Next record"))
        scheduled messages)
    (unwind-protect
        (progn
          (setf (agentedit-review-session-source session) source
                (agentedit-review-session-sources session) (list source))
          (agentedit-review--lock-session session (list source))
          (with-current-buffer control
            (setq-local agentedit-review--session session)
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_delay _repeat function &rest args)
                         (setq scheduled (cons function args)))))
              (agentedit-review--cleanup)
              (agentedit-review--cleanup)))
          (should (eq (car scheduled) #'agentedit-review--open-current))
          (cl-letf (((symbol-function 'agentedit-review--open-current)
                     (lambda (handoff-session)
                       (agentedit-review--emit-announcement handoff-session)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (apply (car scheduled) (cdr scheduled))
            (apply (car scheduled) (cdr scheduled)))
          (should (equal messages '("Accepted · Next record")))
          (setf (agentedit-review-session-state session) 'failed)
          (agentedit-review--release session))
      (remhash source agentedit-review--sessions)
      (dolist (buffer (list control source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-presentation-metadata-is-computed-once-per-record ()
  (let ((source (generate-new-buffer " *AgentEdit presentation source*"))
        (control (generate-new-buffer " *AgentEdit presentation control*"))
        (normalize-calls 0)
        (line-calls 0))
    (unwind-protect
        (with-current-buffer source
          (insert "source")
          (let* ((record (agentedit-review--make-record
                          :id "id" :reason "Reason."
                          :start (copy-marker (point-min)) :source source))
                 (session (agentedit-review--make-session
                           :source source :sources (list source)
                           :records (list record)))
                 (normalize (symbol-function
                             'agentedit-review--normalize-one-line))
                 (record-line (symbol-function 'agentedit-review--record-line)))
            (cl-letf (((symbol-function 'agentedit-review--normalize-one-line)
                       (lambda (text)
                         (setq normalize-calls (1+ normalize-calls))
                         (funcall normalize text)))
                      ((symbol-function 'agentedit-review--record-line)
                       (lambda (value)
                         (setq line-calls (1+ line-calls))
                         (funcall record-line value))))
              (with-current-buffer control
                (use-local-map (make-sparse-keymap))
                (agentedit-review--install-control session record)
                (dotimes (_ 3)
                  (agentedit-review--header-format)
                  (agentedit-review--mode-line-format))))
            (should (= normalize-calls 3))
            (should (= line-calls 1))))
      (dolist (buffer (list control source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-control-preserves-native-layout-and-help ()
  (let ((source (generate-new-buffer " *AgentEdit control source*"))
        (control (generate-new-buffer " *AgentEdit control buffer*")))
    (unwind-protect
        (with-current-buffer source
          (insert "source")
          (let* ((start (copy-marker (point-min)))
                 (record (agentedit-review--make-record
                          :id "id" :reason "Reason." :start start
                          :source source))
                 (session (agentedit-review--make-session
                           :source source :sources (list source)
                           :records (list record))))
            (with-current-buffer control
              (let ((map (make-sparse-keymap)))
                (define-key map (kbd "|") #'ignore)
                (use-local-map map))
              (agentedit-review--install-control session record)
              (should (eq (lookup-key (current-local-map) (kbd "|")) #'ignore))
              (dolist (key '("A" "R" "S" "q"))
                (should (commandp (lookup-key (current-local-map) (kbd key))))))
            (dolist (command '(agentedit-review--accept
                               agentedit-review--reject
                               agentedit-review--skip
                               agentedit-review--quit))
              (should (stringp (documentation command))))))
      (dolist (buffer (list control source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-mode-line-elides-by-priority ()
  (let ((source (generate-new-buffer " *AgentEdit mode source*")))
    (unwind-protect
        (with-temp-buffer
          (let ((session (agentedit-review--make-session
                          :source source :sources (list source)
                          :accepted 2 :rejected 1 :skipped 3)))
            (setq-local agentedit-review--session session)
            (cl-letf (((symbol-function 'window-body-width)
                       (lambda (&rest _) 30)))
              (agentedit-review--mode-line-format))
            (should-not (string-empty-p agentedit-review--mode-controls))
            (should (string-empty-p agentedit-review--mode-counts))
            (should (string-empty-p agentedit-review--mode-status))))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest agentedit-review-state-machine-accepts-only-declared-edges ()
  (dolist (edge '((starting reviewing)
                  (starting finished)
                  (starting failed)
                  (reviewing deciding)
                  (reviewing aborting)
                  (reviewing failed)
                  (deciding reviewing)
                  (deciding finished)
                  (deciding stale)
                  (deciding partial-failure)
                  (deciding failed)))
    (let ((session (agentedit-review--make-session :state (car edge))))
      (agentedit-review--transition session (cadr edge))
      (should (eq (agentedit-review-session-state session) (cadr edge)))))
  (dolist (edge '((starting deciding)
                  (reviewing finished)
                  (finished reviewing)
                  (failed starting)))
    (let ((session (agentedit-review--make-session :state (car edge))))
      (should-error (agentedit-review--transition session (cadr edge))))))

(ert-deftest agentedit-review-replaces-exact-snapshot-and-undoes-once ()
  (agentedit-review-test--with-source
      "prefix \\agentedit{id}{Reason.}{old}{new} suffix"
    (let* ((record (car (agentedit-review--scan-records (point-min))))
           (session (agentedit-review--make-session
                     :source (current-buffer) :records (list record))))
      (agentedit-review--replace-current session "new")
      (should (equal (buffer-string) "prefix new suffix"))
      (undo-only 1)
      (should (equal (buffer-string)
                     "prefix \\agentedit{id}{Reason.}{old}{new} suffix")))))

(ert-deftest agentedit-review-two-decisions-undo-independently ()
  (agentedit-review-test--with-source
      (concat "\\agentedit{one}{First.}{old-1}{new-1}\n"
              "\\agentedit{two}{Second.}{old-2}{new-2}")
    (let* ((original (buffer-string))
           (records (agentedit-review--scan-records (point-min)))
           (session (agentedit-review--make-session
                     :source (current-buffer) :records records)))
      (agentedit-review--replace-current session "new-1")
      (setf (agentedit-review-session-index session) 1)
      (agentedit-review--replace-current session "new-2")
      (should (equal (buffer-string) "new-1\nnew-2"))
      (undo-only 1)
      (should (equal (buffer-string)
                     "new-1\n\\agentedit{two}{Second.}{old-2}{new-2}"))
      (undo-more 1)
      (should (equal (buffer-string) original)))))

(ert-deftest agentedit-review-replaces-record-in-its-own-source-buffer ()
  (let ((first (generate-new-buffer " *AgentEdit project first*"))
        (second (generate-new-buffer " *AgentEdit project second*")))
    (unwind-protect
        (progn
          (dolist (buffer (list first second))
            (with-current-buffer buffer
              (insert (if (eq buffer first)
                          "\\agentedit{first}{First.}{old-1}{new-1}"
                        "\\agentedit{second}{Second.}{old-2}{new-2}"))
              (if agentedit-review-test--use-auctex
                  (LaTeX-mode)
                (latex-mode))
              (buffer-enable-undo)))
          (let* ((first-record
                  (with-current-buffer first
                    (car (agentedit-review--scan-records (point-min)))))
                 (second-record
                  (with-current-buffer second
                    (car (agentedit-review--scan-records (point-min)))))
                 (session (agentedit-review--make-session
                           :source first :sources (list first second)
                           :records (list first-record second-record))))
            (agentedit-review--replace-current session "new-1")
            (setf (agentedit-review-session-index session) 1)
            (agentedit-review--replace-current session "new-2")
            (should (equal (with-current-buffer first (buffer-string)) "new-1"))
            (should (equal (with-current-buffer second (buffer-string)) "new-2"))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-project-locks-and-releases-every-source ()
  (let* ((first (generate-new-buffer " *AgentEdit project lock first*"))
         (second (generate-new-buffer " *AgentEdit project lock second*"))
         (session (agentedit-review--make-session
                   :source first :sources (list first second))))
    (unwind-protect
        (progn
          (agentedit-review--lock-session session (list first second))
          (should (eq (gethash first agentedit-review--sessions) session))
          (should (eq (gethash second agentedit-review--sessions) session))
          (setf (agentedit-review-session-state session) 'finished)
          (agentedit-review--release session)
          (should-not (gethash first agentedit-review--sessions))
          (should-not (gethash second agentedit-review--sessions)))
      (dolist (buffer (list first second))
        (remhash buffer agentedit-review--sessions)
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-rejects-overlapping-session-without-stealing-lock ()
  (let* ((source (generate-new-buffer " *AgentEdit overlapping source*"))
         (owner (agentedit-review--make-session
                 :source source :sources (list source)))
         (challenger (agentedit-review--make-session
                      :source source :sources (list source))))
    (unwind-protect
        (progn
          (agentedit-review--lock-session owner (list source))
          (should-error
           (agentedit-review--lock-session challenger (list source))
           :type 'user-error)
          (should (eq (gethash source agentedit-review--sessions) owner)))
      (setf (agentedit-review-session-state owner) 'failed)
      (agentedit-review--release owner)
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest agentedit-review-project-rejects-cross-file-duplicate-ids ()
  (let ((first (generate-new-buffer " *AgentEdit duplicate first*"))
        (second (generate-new-buffer " *AgentEdit duplicate second*")))
    (unwind-protect
        (let (records)
          (dolist (entry `((,first "\\agentedit{same}{First.}{old}{new}")
                           (,second "\\agentedit{same}{Second.}{old}{new}")))
            (with-current-buffer (car entry)
              (insert (cadr entry))
              (if agentedit-review-test--use-auctex
                  (LaTeX-mode)
                (latex-mode))
              (setq records
                    (nconc records
                           (agentedit-review--scan-records (point-min))))))
          (should-error
           (agentedit-review--validate-project-ids records)
           :type 'user-error))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-preserves-boundary-insertions ()
  (agentedit-review-test--with-source
      "\\agentedit{id}{Reason.}{old}{new}"
    (let* ((record (car (agentedit-review--scan-records (point-min))))
           (start (agentedit-review-record-start record))
           (end (agentedit-review-record-end record))
           (session (agentedit-review--make-session
                     :source (current-buffer) :records (list record))))
      (goto-char start)
      (insert "before ")
      (goto-char end)
      (insert " after")
      (agentedit-review--replace-current session "new")
      (should (equal (buffer-string) "before new after")))))

(ert-deftest agentedit-review-refuses-stale-snapshot ()
  (agentedit-review-test--with-source
      "\\agentedit{id}{Reason.}{old}{new}"
    (let* ((record (car (agentedit-review--scan-records (point-min))))
           (session (agentedit-review--make-session
                     :source (current-buffer) :records (list record))))
      (goto-char (+ 2 (marker-position (agentedit-review-record-start record))))
      (delete-char 1)
      (insert "X")
      (should-error (agentedit-review--replace-current session "new")
                    :type 'agentedit-review-stale))))

(ert-deftest agentedit-review-refuses-unsafe-source-at-mutation-time ()
  (agentedit-review-test--with-source
      "\\agentedit{id}{Reason.}{old}{new}"
    (let* ((record (car (agentedit-review--scan-records (point-min))))
           (session (agentedit-review--make-session
                     :source (current-buffer) :records (list record))))
      (narrow-to-region (point-min) (1- (point-max)))
      (should-error (agentedit-review--replace-current session "new"))
      (widen)
      (setq buffer-undo-list t)
      (should-error (agentedit-review--replace-current session "new")))))

(ert-deftest agentedit-review-atomic-error-preserves-wrapper ()
  (agentedit-review-test--with-source
      "\\agentedit{id}{Reason.}{old}{new}"
    (let* ((original (buffer-string))
           (record (car (agentedit-review--scan-records (point-min))))
           (session (agentedit-review--make-session
                     :source (current-buffer) :records (list record))))
      (add-text-properties (point-min) (1+ (point-min)) '(read-only t))
      (should-error (agentedit-review--replace-current session "new"))
      (should (equal (buffer-string) original)))))

(ert-deftest agentedit-review-injected-replacement-error-rolls-back ()
  (agentedit-review-test--with-source
      "\\agentedit{id}{Reason.}{old}{new}"
    (let* ((original (buffer-string))
           (record (car (agentedit-review--scan-records (point-min))))
           (session (agentedit-review--make-session
                     :source (current-buffer) :records (list record))))
      (add-hook 'before-change-functions
                (lambda (begin end)
                  (when (= begin end)
                    (error "injected insertion failure")))
                nil t)
      (should-error (agentedit-review--replace-current session "new"))
      (should (equal (buffer-string) original)))))

(ert-deftest agentedit-review-preflight-rejects-disabled-undo ()
  (agentedit-review-test--with-source "plain text"
    (setq buffer-undo-list t)
    (should-error (agentedit-review--preflight) :type 'user-error)
    (should (eq buffer-undo-list t))))

(ert-deftest agentedit-review-preflight-enforces-minimum-emacs-version ()
  (agentedit-review-test--with-source "plain text"
    (let ((emacs-major-version 29)
          (emacs-minor-version 3))
      (should-error (agentedit-review--preflight) :type 'user-error))
    (dolist (version '((29 4) (30 1) (30 2) (31 0)))
      (let ((emacs-major-version (car version))
            (emacs-minor-version (cadr version)))
        (should (agentedit-review--supported-emacs-version-p))
        (agentedit-review--preflight)))))

(ert-deftest agentedit-review-preflight-rejects-buffer-shape-and-permissions ()
  (agentedit-review-test--with-source "plain text"
    (let ((buffer-read-only t))
      (should-error (agentedit-review--preflight) :type 'user-error))
    (narrow-to-region (point-min) (max (point-min) (1- (point-max))))
    (should-error (agentedit-review--preflight) :type 'user-error)
    (widen)
    (let ((indirect (make-indirect-buffer
                     (current-buffer) " *AgentEdit indirect*" t)))
      (unwind-protect
          (with-current-buffer indirect
            (should-error (agentedit-review--preflight) :type 'user-error))
        (kill-buffer indirect)))))

(ert-deftest agentedit-review-recognizes-built-in-tex-mode-family ()
  (dolist (mode '(tex-mode plain-tex-mode latex-mode))
    (let ((major-mode mode))
      (should (agentedit-review--supported-mode-p))))
  (let ((major-mode 'fundamental-mode))
    (should-not (agentedit-review--supported-mode-p))))

(ert-deftest agentedit-review-auctex-plain-mode-is-project-capable ()
  (skip-unless agentedit-review-test--use-auctex)
  (with-temp-buffer
    (plain-TeX-mode)
    (should (agentedit-review--supported-mode-p))
    (should (agentedit-review--auctex-project-capable-p))))

(ert-deftest agentedit-review-routes-built-in-mode-to-current-buffer ()
  (let (scope)
    (cl-letf (((symbol-function 'agentedit-review--auctex-mode-p)
               (lambda () nil))
              ((symbol-function 'agentedit-review--review-buffer)
               (lambda () (setq scope 'buffer)))
              ((symbol-function 'agentedit-review--review-project)
               (lambda () (setq scope 'project))))
      (agentedit-review))
    (should (eq scope 'buffer))))

(ert-deftest agentedit-review-routes-auctex-mode-to-project ()
  (let (scope)
    (cl-letf (((symbol-function 'agentedit-review--auctex-mode-p)
               (lambda () t))
              ((symbol-function 'agentedit-review--review-buffer)
               (lambda () (setq scope 'buffer)))
              ((symbol-function 'agentedit-review--review-project)
               (lambda () (setq scope 'project))))
      (agentedit-review))
    (should (eq scope 'project))))

(ert-deftest agentedit-review-prefix-forces-current-buffer-in-auctex ()
  (let (scope)
    (cl-letf (((symbol-function 'agentedit-review--auctex-mode-p)
               (lambda () t))
              ((symbol-function 'agentedit-review--review-buffer)
               (lambda () (setq scope 'buffer)))
              ((symbol-function 'agentedit-review--review-project)
               (lambda () (setq scope 'project))))
      (agentedit-review '(4)))
    (should (eq scope 'buffer))))

(ert-deftest agentedit-review-auctex-without-project-apis-does-not-fallback ()
  (cl-letf (((symbol-function 'agentedit-review--auctex-mode-p)
             (lambda () t))
            ((symbol-function 'agentedit-review--preflight) #'ignore)
            ((symbol-function 'agentedit-review--auctex-project-capable-p)
             (lambda () nil))
            ((symbol-function 'agentedit-review--review-buffer)
             (lambda () (ert-fail "must not fall back to buffer review"))))
    (should-error (agentedit-review) :type 'user-error)))

(ert-deftest agentedit-review-auctex-master-uses-native-persistence ()
  (skip-unless agentedit-review-test--use-auctex)
  (let* ((directory (make-temp-file "agentedit-auctex-master-" t))
         (master (expand-file-name "main.tex" directory))
         (child (expand-file-name "child.tex" directory))
         buffer)
    (unwind-protect
        (progn
          (write-region "\\documentclass{article}\n" nil master nil 'silent)
          (write-region "Child.\n" nil child nil 'silent)
          (setq buffer (find-file-noselect child))
          (with-current-buffer buffer
            (LaTeX-mode)
            (setq-local TeX-master nil)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) master)))
              (should (equal (file-truename
                              (agentedit-review--auctex-master-file))
                             (file-truename master))))
            (should (equal TeX-master "main"))
            (should (string-match-p "TeX-master: \\\"main\\\""
                                    (buffer-string)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest agentedit-review-auctex-master-preserves-native-cancel-semantics ()
  (skip-unless agentedit-review-test--use-auctex)
  (let* ((directory (make-temp-file "agentedit-auctex-cancel-" t))
         (child (expand-file-name "child.tex" directory))
         buffer)
    (unwind-protect
        (progn
          (write-region "Child.\n" nil child nil 'silent)
          (setq buffer (find-file-noselect child))
          (with-current-buffer buffer
            (LaTeX-mode)
            (setq-local TeX-master nil)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) (signal 'quit nil))))
              (should (equal (file-truename
                              (agentedit-review--auctex-master-file))
                             (file-truename child))))
            (should (eq TeX-master t))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest agentedit-review-auctex-master-rejects-missing-results ()
  (cl-letf (((symbol-function 'agentedit-review--auctex-project-capable-p)
             (lambda () t))
            ((symbol-function 'TeX-master-file) (lambda (&rest _) nil)))
    (should-error (agentedit-review--auctex-master-file) :type 'user-error))
  (cl-letf (((symbol-function 'agentedit-review--auctex-project-capable-p)
             (lambda () t))
            ((symbol-function 'TeX-master-file)
             (lambda (&rest _) "definitely-missing.tex")))
    (should-error (agentedit-review--auctex-master-file) :type 'user-error)))

(ert-deftest agentedit-review-auctex-project-follows-live-input-order ()
  (skip-unless agentedit-review-test--use-auctex)
  (let* ((directory (make-temp-file "agentedit-auctex-project-" t))
         (nested (expand-file-name "nested" directory))
         (master (expand-file-name "main.tex" directory))
         (first (expand-file-name "first.tex" directory))
         (second (expand-file-name "nested/second.tex" directory))
         buffers)
    (unwind-protect
        (progn
          (make-directory nested)
          (write-region
           (concat "\\documentclass{article}\n"
                   "\\input{first}\n"
                   "\\input{nested/second}\n")
           nil master nil 'silent)
          (write-region
           "\\agentedit{first}{First.}{old-1}{new-1}\n"
           nil first nil 'silent)
          (write-region
           "\\agentedit{second}{Second.}{old-2}{new-2}\n"
           nil second nil 'silent)
          (setq buffers (agentedit-review--auctex-project-buffers master))
          (should
           (equal (mapcar (lambda (buffer)
                            (file-truename (buffer-file-name buffer)))
                          buffers)
                  (mapcar #'file-truename (list master first second))))
          (let (records)
            (dolist (buffer buffers)
              (with-current-buffer buffer
                (setq records
                      (nconc records
                             (agentedit-review--scan-records (point-min))))))
            (should (equal (agentedit-review-test--ids records)
                           '("first" "second")))
            (should (eq (agentedit-review-record-source (car records))
                        (cadr buffers)))
            (should (eq (agentedit-review-record-source (cadr records))
                        (caddr buffers)))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest agentedit-review-public-command-integrates-auctex-project-scope ()
  (skip-unless agentedit-review-test--use-auctex)
  (let* ((directory (make-temp-file "agentedit-auctex-public-" t))
         (master (expand-file-name "main.tex" directory))
         (child (expand-file-name "child.tex" directory))
         master-buffer captured-sources captured-records)
    (unwind-protect
        (progn
          (write-region "\\input{child}\n" nil master nil 'silent)
          (write-region "\\agentedit{id}{Reason.}{old}{new}\n"
                        nil child nil 'silent)
          (setq master-buffer (find-file-noselect master))
          (with-current-buffer master-buffer
            (LaTeX-mode)
            (setq-local TeX-master t)
            (buffer-enable-undo)
            (cl-letf (((symbol-function 'agentedit-review--begin)
                       (lambda (_source sources records _empty-message)
                         (setq captured-sources sources
                               captured-records records))))
              (agentedit-review)))
          (should (= (length captured-sources) 2))
          (should (equal (agentedit-review-test--ids captured-records) '("id"))))
      (dolist (buffer captured-sources)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (when (buffer-live-p master-buffer)
        (kill-buffer master-buffer))
      (delete-directory directory t))))

(ert-deftest agentedit-review-rechecks-compatibility-before-mutation ()
  (agentedit-review-test--with-source
      "\\agentedit{id}{Reason.}{old}{new}"
    (let* ((original (buffer-string))
           (record (car (agentedit-review--scan-records (point-min))))
           (session (agentedit-review--make-session
                     :source (current-buffer)
                     :records (list record)
                     :state 'reviewing)))
      (with-temp-buffer
        (setq-local agentedit-review--session session)
        (cl-letf (((symbol-function
                    'agentedit-review--check-ediff-compatibility)
                   (lambda () (error "compatibility removed")))
                  ((symbol-function 'agentedit-review--ediff-really-quit)
                   #'ignore))
          (agentedit-review--accept)))
      (should (equal (buffer-string) original))
      (should (= (agentedit-review-session-accepted session) 0))
      (should (eq (agentedit-review-session-state session) 'failed)))))

(ert-deftest agentedit-review-no-match-keeps-source-selected ()
  (agentedit-review-test--with-source "No markers here."
    (let ((source (current-buffer)))
      (agentedit-review t)
      (should (eq (current-buffer) source))
      (should-not (gethash source agentedit-review--sessions)))))

(ert-deftest agentedit-review-batch-ediff-accept-reject-skip ()
  (let ((source (generate-new-buffer " *AgentEdit integration source*"))
        (ediff-window-setup-function #'ediff-setup-windows-plain)
        (ediff-split-window-function #'split-window-horizontally)
        (ediff-keep-variants t)
        (ediff-auto-refine 'off))
    (unwind-protect
        (with-current-buffer source
          (insert (concat
                   "\\agentedit{one}{Use new.}{old-one}{new-one}\n"
                   "\\agentedit{two}{Keep old.}{old-two}{new-two}\n"
                   "\\agentedit{three}{Defer.}{old-three}{new-three}"))
          (if agentedit-review-test--use-auctex
              (LaTeX-mode)
            (latex-mode))
          (buffer-enable-undo)
          (goto-char (point-min))
          (agentedit-review t)
          (let ((session (gethash source agentedit-review--sessions)))
            (should session)
            (let ((buffer-a (agentedit-review-session-projection-a session))
                  (buffer-b (agentedit-review-session-projection-b session)))
              (with-current-buffer buffer-a
                (should (string-match-p
                         "− ORIGINAL.*reject keeps this"
                         (mapconcat #'substring-no-properties
                                    header-line-format "")))
                (should (assq 'ediff-current-diff-A face-remapping-alist))
                (should (assq 'ediff-fine-diff-A face-remapping-alist)))
              (with-current-buffer buffer-b
                (should (string-match-p
                         "\\+ PROPOSED.*accept keeps this"
                         (mapconcat #'substring-no-properties
                                    header-line-format "")))
                (should (assq 'ediff-current-diff-B face-remapping-alist))
                (should (assq 'ediff-fine-diff-B face-remapping-alist))))
            (with-current-buffer (agentedit-review-session-control session)
              (should (eq (lookup-key (current-local-map) (kbd "A"))
                          #'agentedit-review--accept))
              (should (eq ediff-auto-refine 'on))
              (should (= ediff-current-difference 0))
              (agentedit-review--accept))
            (sleep-for 0.05)
            (with-current-buffer (agentedit-review-session-control session)
              (agentedit-review--reject))
            (sleep-for 0.05)
            (with-current-buffer (agentedit-review-session-control session)
              (agentedit-review--skip))
            (sleep-for 0.05)
            (should (eq (agentedit-review-session-state session) 'finished))
            (should (= (agentedit-review-session-accepted session) 1))
            (should (= (agentedit-review-session-rejected session) 1))
            (should (= (agentedit-review-session-skipped session) 1))
            (should-not (gethash source agentedit-review--sessions))
            (should
             (equal
              (buffer-string)
              (concat "new-one\nold-two\n"
                      "\\agentedit{three}{Defer.}{old-three}{new-three}")))
            (should (buffer-modified-p))))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest agentedit-review-preserves-horizontal-and-vertical-ediff-layouts ()
  (dolist (split '(split-window-horizontally split-window-vertically))
    (let ((source (generate-new-buffer " *AgentEdit layout source*"))
          (ediff-window-setup-function #'ediff-setup-windows-plain)
          (ediff-split-window-function split)
          (ediff-keep-variants t))
      (unwind-protect
          (with-current-buffer source
            (insert "\\agentedit{id}{Reason.}{old}{new}")
            (if agentedit-review-test--use-auctex
                (LaTeX-mode)
              (latex-mode))
            (buffer-enable-undo)
            (goto-char (point-min))
            (agentedit-review t)
            (let ((session (gethash source agentedit-review--sessions)))
              (should session)
              (with-current-buffer (agentedit-review-session-control session)
                (should (eq ediff-split-window-function split))
                (should (commandp
                         (lookup-key (current-local-map) (kbd "|"))))
                (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                  (agentedit-review--quit)))
              (sleep-for 0.05)
              (should (eq (agentedit-review-session-state session) 'aborting))
              (should-not (gethash source agentedit-review--sessions))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest agentedit-review-quit-decline-preserves-current-session ()
  (let ((session (agentedit-review--make-session
                  :state 'reviewing
                  :records (list (agentedit-review--make-record :id "id")))))
    (with-temp-buffer
      (setq-local agentedit-review--session session)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                ((symbol-function 'agentedit-review--ediff-really-quit)
                 (lambda () (ert-fail "quit should not run"))))
        (agentedit-review--quit))
      (should (eq (agentedit-review-session-state session) 'reviewing)))))

(ert-deftest agentedit-review-quit-confirm-aborts-without-mutation ()
  (let ((source (generate-new-buffer " *AgentEdit quit source*"))
        (ediff-window-setup-function #'ediff-setup-windows-plain)
        (ediff-keep-variants t))
    (unwind-protect
        (with-current-buffer source
          (insert "\\agentedit{id}{Reason.}{old}{new}")
          (if agentedit-review-test--use-auctex
              (LaTeX-mode)
            (latex-mode))
          (buffer-enable-undo)
          (goto-char (point-min))
          (agentedit-review t)
          (let ((session (gethash source agentedit-review--sessions)))
            (with-current-buffer (agentedit-review-session-control session)
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (agentedit-review--quit)))
            (sleep-for 0.05)
            (should (eq (agentedit-review-session-state session) 'aborting))
            (should-not (gethash source agentedit-review--sessions))
            (should (equal (buffer-string)
                           "\\agentedit{id}{Reason.}{old}{new}"))))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest agentedit-review-killed-projection-fails-cleanly ()
  (dolist (side '(a b))
    (let ((source (generate-new-buffer " *AgentEdit killed source*"))
          (ediff-window-setup-function #'ediff-setup-windows-plain)
          (ediff-keep-variants t))
      (unwind-protect
          (with-current-buffer source
            (insert "\\agentedit{id}{Reason.}{old}{new}")
            (if agentedit-review-test--use-auctex
                (LaTeX-mode)
              (latex-mode))
            (buffer-enable-undo)
            (goto-char (point-min))
            (agentedit-review t)
            (let* ((session (gethash source agentedit-review--sessions))
                   (target (if (eq side 'a)
                               (agentedit-review-session-projection-a session)
                             (agentedit-review-session-projection-b session))))
              (kill-buffer target)
              (sleep-for 0.05)
              (should (eq (agentedit-review-session-state session) 'failed))
              (should-not (gethash source agentedit-review--sessions))
              (should-not
               (buffer-live-p
                (agentedit-review-session-projection-a session)))
              (should-not
               (buffer-live-p
                (agentedit-review-session-projection-b session)))
              (should (equal (buffer-string)
                             "\\agentedit{id}{Reason.}{old}{new}"))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest agentedit-review-startup-failure-releases-lock-and-projections ()
  (agentedit-review-test--with-source
      "\\agentedit{id}{Reason.}{old}{new}"
    (let* ((source (current-buffer))
           (record (car (agentedit-review--scan-records (point-min))))
           (session (agentedit-review--make-session
                     :source source :sources (list source)
                     :records (list record)
                     :pending-announcement "must be replaced"))
           projection-a projection-b)
      (agentedit-review--lock-session session (list source))
      (cl-letf (((symbol-function 'ediff-buffers)
                 (lambda (buffer-a buffer-b)
                   (setq projection-a buffer-a projection-b buffer-b)
                   (error "injected startup failure")))
                ((symbol-function 'run-at-time) #'ignore))
        (should-error (agentedit-review--open-current session)
                      :type 'user-error))
      (should (eq (agentedit-review-session-state session) 'failed))
      (should-not (agentedit-review-session-pending-announcement session))
      (should (string-match-p "could not start Ediff"
                              (agentedit-review-session-last-error session)))
      (should-not (gethash source agentedit-review--sessions))
      (should-not (buffer-live-p projection-a))
      (should-not (buffer-live-p projection-b)))))

(ert-deftest agentedit-review-control-buffer-kill-releases-owned-resources ()
  (let ((source (generate-new-buffer " *AgentEdit killed control source*"))
        (control (generate-new-buffer " *AgentEdit killed control*"))
        (projection-a (generate-new-buffer " *AgentEdit killed control A*"))
        (projection-b (generate-new-buffer " *AgentEdit killed control B*")))
    (unwind-protect
        (let ((session (agentedit-review--make-session
                        :source source :sources (list source)
                        :state 'reviewing :control control
                        :projection-a projection-a :projection-b projection-b)))
          (agentedit-review--lock-session session (list source))
          (with-current-buffer control
            (setq-local agentedit-review--session session)
            (add-hook 'kill-buffer-hook #'agentedit-review--control-killed nil t))
          (kill-buffer control)
          (should (eq (agentedit-review-session-state session) 'failed))
          (should-not (gethash source agentedit-review--sessions))
          (should-not (buffer-live-p projection-a))
          (should-not (buffer-live-p projection-b)))
      (dolist (buffer (list projection-a projection-b control source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-continuation-cleanup-keeps-pass-lock ()
  (let ((source (generate-new-buffer " *AgentEdit continuation source*"))
        (control (generate-new-buffer " *AgentEdit continuation control*"))
        scheduled)
    (unwind-protect
        (let ((session (agentedit-review--make-session
                        :source source :sources (list source)
                        :state 'deciding :pending-action 'continue)))
          (agentedit-review--lock-session session (list source))
          (with-current-buffer control
            (setq-local agentedit-review--session session)
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (&rest args) (push args scheduled))))
              (agentedit-review--cleanup)
              (agentedit-review--cleanup)))
          (should (= (length scheduled) 1))
          (should (eq (gethash source agentedit-review--sessions) session))
          (setf (agentedit-review-session-state session) 'failed)
          (agentedit-review--release session))
      (remhash source agentedit-review--sessions)
      (dolist (buffer (list control source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest agentedit-review-source-ready-rejects-killed-and-read-only-source ()
  (let* ((source (generate-new-buffer " *AgentEdit unavailable source*"))
         (record (agentedit-review--make-record :source source)))
    (with-current-buffer source
      (setq buffer-read-only t))
    (should-error (agentedit-review--source-ready record))
    (kill-buffer source)
    (should-error (agentedit-review--source-ready record))))

(ert-deftest agentedit-review-stale-finish-does-not-consume-input ()
  (let* ((source (generate-new-buffer " *AgentEdit stale dead source*"))
         (marker (with-current-buffer source (copy-marker (point-min))))
         (record (agentedit-review--make-record :start marker :source source))
         (session (agentedit-review--make-session
                   :source source :records (list record) :state 'stale))
         (unread-command-events '(?x ?y)))
    (kill-buffer source)
    (should (equal (agentedit-review--finish-terminal session "stale") "stale"))
    (should (equal unread-command-events '(?x ?y)))))

(ert-deftest agentedit-review-last-decision-teardown-failure-is-partial ()
  (let ((source (generate-new-buffer " *AgentEdit partial source*"))
        (control (generate-new-buffer " *AgentEdit partial control*")))
    (unwind-protect
        (with-current-buffer source
          (insert "\\agentedit{id}{Reason.}{old}{new}")
          (if agentedit-review-test--use-auctex
              (LaTeX-mode)
            (latex-mode))
          (buffer-enable-undo)
          (goto-char (point-min))
          (let* ((record (car (agentedit-review--scan-records (point-min))))
                 (session (agentedit-review--make-session
                           :source source
                           :records (list record)
                           :state 'reviewing
                           :control control
                           :lock-key source)))
            (puthash source session agentedit-review--sessions)
            (with-current-buffer control
              (setq-local agentedit-review--session session)
              (cl-letf (((symbol-function 'agentedit-review--ediff-really-quit)
                         (lambda () (error "injected teardown error"))))
                (agentedit-review--accept)))
            (sleep-for 0.05)
            (should (equal (buffer-string) "new"))
            (should (= (agentedit-review-session-accepted session) 1))
            (should (eq (agentedit-review-session-state session)
                        'partial-failure))
            (should-not (buffer-live-p control))
            (should-not (gethash source agentedit-review--sessions))))
      (when (buffer-live-p control)
        (kill-buffer control))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest agentedit-review-skip-teardown-failure-names-completed-record ()
  (let ((source (generate-new-buffer " *AgentEdit skip failure source*"))
        (control (generate-new-buffer " *AgentEdit skip failure control*"))
        terminal-message)
    (unwind-protect
        (with-current-buffer source
          (insert (concat "\\agentedit{first}{Reason.}{old}{new}\n"
                          "\\agentedit{second}{Reason.}{old}{new}"))
          (if agentedit-review-test--use-auctex
              (LaTeX-mode)
            (latex-mode))
          (buffer-enable-undo)
          (goto-char (point-min))
          (let ((session
                 (agentedit-review--make-session
                  :source source
                  :records (agentedit-review--scan-records (point-min))
                  :state 'reviewing
                  :control control
                  :lock-key source)))
            (puthash source session agentedit-review--sessions)
            (with-current-buffer control
              (setq-local agentedit-review--session session)
              (cl-letf (((symbol-function 'agentedit-review--ediff-really-quit)
                         (lambda () (error "injected teardown error"))))
                (agentedit-review--skip)))
            (sleep-for 0.05)
            (setq terminal-message (agentedit-review--terminal-message session))
            (should (equal (buffer-string)
                           (concat "\\agentedit{first}{Reason.}{old}{new}\n"
                                   "\\agentedit{second}{Reason.}{old}{new}")))
            (should (= (agentedit-review-session-skipped session) 1))
            (should (eq (agentedit-review-session-state session) 'failed))
            (should (string-match-p "Skip recorded for first" terminal-message))
            (should (string-match-p "No source text changed" terminal-message))
            (should-not (string-match-p "second" terminal-message))
            (should-not (gethash source agentedit-review--sessions))))
      (when (buffer-live-p control)
        (kill-buffer control))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest agentedit-review-stale-teardown-failure-releases-lock ()
  (let ((source (generate-new-buffer " *AgentEdit stale source*"))
        (control (generate-new-buffer " *AgentEdit stale control*")))
    (unwind-protect
        (with-current-buffer source
          (insert "\\agentedit{id}{Reason.}{old}{new}")
          (if agentedit-review-test--use-auctex
              (LaTeX-mode)
            (latex-mode))
          (buffer-enable-undo)
          (goto-char (point-min))
          (let* ((record (car (agentedit-review--scan-records (point-min))))
                 (session (agentedit-review--make-session
                           :source source
                           :records (list record)
                           :state 'reviewing
                           :control control
                           :lock-key source)))
            (puthash source session agentedit-review--sessions)
            (goto-char (+ 2 (marker-position
                             (agentedit-review-record-start record))))
            (delete-char 1)
            (insert "X")
            (let ((changed (buffer-string)))
              (with-current-buffer control
                (setq-local agentedit-review--session session)
                (cl-letf (((symbol-function
                            'agentedit-review--ediff-really-quit)
                           (lambda () (error "injected teardown error"))))
                  (agentedit-review--accept)))
              (sleep-for 0.05)
              (should (equal (buffer-string) changed)))
            (should (eq (agentedit-review-session-state session) 'stale))
            (should-not (buffer-live-p control))
            (should-not (gethash source agentedit-review--sessions))))
      (when (buffer-live-p control)
        (kill-buffer control))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(provide 'agentedit-review-tests)

;;; agentedit-review-tests.el ends here
