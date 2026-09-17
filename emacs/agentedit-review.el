;;; agentedit-review.el --- Review AgentLaTeX edits with Ediff -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: AgentLaTeX contributors
;; Keywords: tex, tools
;; Package-Requires: ((emacs "29.4"))

;;; Commentary:

;; Run `agentedit-review' in a direct, widened TeX buffer.  It reviews the
;; current AUCTeX document when available, or the current built-in TeX buffer;
;; a prefix argument forces current-buffer review.  Each AgentLaTeX marker is
;; shown as an Ediff comparison.  The control buffer adds A (accept), R
;; (reject), and S (skip); q stops the pass.

;;; Code:

(require 'cl-lib)
(require 'ediff)
(require 'face-remap)
(require 'subr-x)
(require 'button)

(declare-function TeX-auto-parse "tex" ())
(declare-function TeX-master-file "tex" (&optional extension nondirectory ask))
(declare-function ediff-install-fine-diff-if-necessary "ediff-diff" (n))
(declare-function ediff-jump-to-difference "ediff-util" (difference-number))
(defvar TeX-auto-file)
(defvar TeX-master)
(defvar ediff-auto-refine)
(defvar ediff-current-difference)
(defvar ediff-current-diff-overlay-A)
(defvar ediff-current-diff-overlay-B)
(defvar ediff-number-of-differences)

(defgroup agentedit-review nil
  "Review AgentLaTeX provenance markers with Ediff."
  :group 'tex
  :prefix "agentedit-review-")

(defface agentedit-review-original-label
  '((((class color) (min-colors 16777216) (background dark))
     :foreground "#ff717c" :weight bold)
    (((class color) (min-colors 16777216) (background light))
     :foreground "#a51d2d" :weight bold)
    (((class color) (min-colors 16)) :foreground "red" :weight bold)
    (t :weight bold :inverse-video t))
  "Face for labels identifying original AgentEdit text."
  :group 'agentedit-review)

(defface agentedit-review-proposed-label
  '((((class color) (min-colors 16777216) (background dark))
     :foreground "#73da91" :weight bold)
    (((class color) (min-colors 16777216) (background light))
     :foreground "#176b35" :weight bold)
    (((class color) (min-colors 16)) :foreground "green" :weight bold)
    (t :weight bold :underline t))
  "Face for labels identifying proposed AgentEdit text."
  :group 'agentedit-review)

(defface agentedit-review-original-hunk
  '((((class color) (min-colors 16777216) (background dark))
     :background "#382428" :inverse-video nil :extend t)
    (((class color) (min-colors 16777216) (background light))
     :background "#fde8ea" :inverse-video nil :extend t)
    (((class color) (min-colors 16))
     :background "red" :foreground "white" :inverse-video nil :extend t)
    (t :inverse-video t :extend t))
  "Face for the current whole hunk in the original projection."
  :group 'agentedit-review)

(defface agentedit-review-proposed-hunk
  '((((class color) (min-colors 16777216) (background dark))
     :background "#20372a" :inverse-video nil :extend t)
    (((class color) (min-colors 16777216) (background light))
     :background "#e1f4e7" :inverse-video nil :extend t)
    (((class color) (min-colors 16))
     :background "green" :foreground "black" :inverse-video nil :extend t)
    (t :weight bold :underline t :inverse-video nil :extend t))
  "Face for the current whole hunk in the proposed projection."
  :group 'agentedit-review)

(defface agentedit-review-original-fine
  '((((class color) (min-colors 16777216) (background dark))
     :background "#74313a" :foreground "#ffd9dc" :weight bold
     :strike-through "#ff717c" :inverse-video nil)
    (((class color) (min-colors 16777216) (background light))
     :background "#f5bec4" :foreground "#721422" :weight bold
     :strike-through "#a51d2d" :inverse-video nil)
    (((class color) (min-colors 16))
     :background "red" :foreground "white" :weight bold
     :strike-through t :inverse-video nil)
    (t :weight bold :strike-through t :inverse-video t))
  "Face for changed characters in the original projection."
  :group 'agentedit-review)

(defface agentedit-review-proposed-fine
  '((((class color) (min-colors 16777216) (background dark))
     :background "#2e6742" :foreground "#dcffe6" :weight bold
     :underline (:color "#73da91" :style line) :inverse-video nil)
    (((class color) (min-colors 16777216) (background light))
     :background "#aee0bd" :foreground "#104b27" :weight bold
     :underline (:color "#176b35" :style line) :inverse-video nil)
    (((class color) (min-colors 16))
     :background "green" :foreground "black" :weight bold
     :underline t :inverse-video nil)
    (t :weight bold :underline t :inverse-video nil))
  "Face for changed characters in the proposed projection."
  :group 'agentedit-review)

(defcustom agentedit-review-verbatim-environments
  '("verbatim" "verbatim*" "Verbatim" "Verbatim*" "lstlisting" "minted")
  "Environment names whose contents the AgentEdit scanner ignores."
  :type '(repeat string)
  :group 'agentedit-review)

(defcustom agentedit-review-auto-save t
  "Save the owning source after each confirmed accept or reject.
Saving writes the entire source buffer, including existing unsaved edits.
The invocation buffer's value is captured for the entire review session,
including an AUCTeX project.  Set nil before review for manual saving."
  :type 'boolean
  :safe #'booleanp
  :group 'agentedit-review)

(defconst agentedit-review-format-version "blocks-v1"
  "Readable source format supported by this loaded reviewer.")

(cl-defstruct (agentedit-review-record
               (:constructor agentedit-review--make-record))
  id reason original edited start end snapshot source framed whitespace left-context right-context
  decision result source-line)

(cl-defstruct (agentedit-review-session
               (:constructor agentedit-review--make-session))
  source records (index 0) (accepted 0) (rejected 0) (skipped 0)
  (state 'starting) pending-action pending-announcement control
  projection-a projection-b cleanup-in-progress cleanup-complete lock-key
  sources lock-keys
  last-error applied-decision completed-decision completed-record
  view draft edit-entry full-context files auto-save report recovery timer
  (custom 0) save-confirmed teardown-in-progress)

(cl-defstruct (agentedit-review-view
               (:constructor agentedit-review--make-view-data))
  text start end pending diagnostics tick prefix suffix offset fallback)

(cl-defstruct (agentedit-review-file
               (:constructor agentedit-review--make-file))
  source path filename tick scope-start scope-line details outside outside-details diagnostics
  (accepted 0) (custom 0) (rejected 0) (skipped 0)
  (save-status 'untouched) saved-tick error)

(defconst agentedit-review--transitions
  '((starting . (reviewing finished failed))
    (reviewing . (editing deciding aborting stale failed))
    (editing . (reviewing aborting stale failed))
    (deciding . (reviewing finished stale partial-failure failed))))

(defvar agentedit-review--sessions (make-hash-table :test #'eq)
  "Active AgentEdit sessions keyed by canonical source buffer.")

(defvar-local agentedit-review--session nil)
(defvar-local agentedit-review--projection-role nil)
(defvar-local agentedit-review--display-pass nil)
(defvar-local agentedit-review--display-id nil)
(defvar-local agentedit-review--display-reason nil)
(defvar-local agentedit-review--display-source nil)
(defvar-local agentedit-review--display-location nil)
(defvar-local agentedit-review--header-required nil)
(defvar-local agentedit-review--header-reason nil)
(defvar-local agentedit-review--header-location nil)
(defvar-local agentedit-review--mode-controls nil)
(defvar-local agentedit-review--mode-counts nil)
(defvar-local agentedit-review--mode-status nil)
(defvar-local agentedit-review--fragment-start nil)
(defvar-local agentedit-review--fragment-end nil)
(defvar-local agentedit-review--fragment-overlay nil)
(defvar agentedit-review--changing-projection nil)
(defvar agentedit-review--display-diagnostics nil)
(defvar agentedit-review--last-session nil)

(defconst agentedit-review--minimum-emacs-version '(29 4)
  "Oldest Emacs major and minor release supported by AgentEdit review.")

(defun agentedit-review--terminal-state-p (state)
  "Return non-nil when STATE is terminal."
  (memq state '(aborting stale partial-failure failed finished)))

(defun agentedit-review--transition (session next)
  "Move SESSION to NEXT if that state transition is legal."
  ;; source -> scan -> Ediff -> decide -> cleanup -> next Ediff / terminal
  ;; starting -> reviewing -> deciding -> reviewing ...; all failures terminal.
  (let* ((current (agentedit-review-session-state session))
         (allowed (alist-get current agentedit-review--transitions)))
    (unless (memq next allowed)
      (error "Illegal AgentEdit state transition: %s -> %s" current next))
    (setf (agentedit-review-session-state session) next)))

(defun agentedit-review--canonical-buffer (buffer)
  "Return the buffer used to lock review sessions for BUFFER."
  (or (buffer-base-buffer buffer) buffer))

(defun agentedit-review--record-source (record)
  "Return the live source buffer that owns RECORD."
  (or (agentedit-review-record-source record)
      (marker-buffer (agentedit-review-record-start record))))

(defun agentedit-review--session-sources (session)
  "Return every source buffer participating in SESSION."
  (or (agentedit-review-session-sources session)
      (and (agentedit-review-session-source session)
           (list (agentedit-review-session-source session)))))

(defun agentedit-review--lock-session (session buffers)
  "Lock BUFFERS for SESSION, or signal if one already has a review."
  (let ((keys (delete-dups
               (mapcar #'agentedit-review--canonical-buffer buffers))))
    (dolist (key keys)
      (when (gethash key agentedit-review--sessions)
        (user-error "An AgentEdit review is already active for %s"
                    (agentedit-review--source-label key))))
    (setf (agentedit-review-session-lock-keys session) keys
          (agentedit-review-session-lock-key session) (car keys))
    (dolist (key keys)
      (puthash key session agentedit-review--sessions))))

(defun agentedit-review--validate-environments ()
  "Validate `agentedit-review-verbatim-environments'."
  (unless (and (proper-list-p agentedit-review-verbatim-environments)
               (cl-every (lambda (name)
                           (and (stringp name) (not (string-empty-p name))))
                         agentedit-review-verbatim-environments))
    (user-error
     "AgentEdit verbatim environments must be a list of nonempty strings")))

(defun agentedit-review--auctex-mode-p ()
  "Return non-nil when the current buffer uses an AUCTeX-derived mode."
  (and (fboundp 'TeX-mode) (derived-mode-p 'TeX-mode)))

(defun agentedit-review--auctex-project-capable-p ()
  "Return non-nil when the current buffer exposes required AUCTeX APIs."
  (and (agentedit-review--auctex-mode-p)
       (fboundp 'TeX-master-file)
       (fboundp 'TeX-auto-parse)
       (boundp 'TeX-master)
       (boundp 'TeX-auto-file)))

(defun agentedit-review--supported-mode-p ()
  "Return non-nil if the current major mode is supported."
  (or (memq major-mode '(tex-mode plain-tex-mode latex-mode))
      (agentedit-review--auctex-mode-p)))

(defun agentedit-review--supported-emacs-version-p ()
  "Return non-nil when the running Emacs meets the supported minimum."
  (pcase-let ((`(,minimum-major ,minimum-minor)
               agentedit-review--minimum-emacs-version))
    (or (> emacs-major-version minimum-major)
        (and (= emacs-major-version minimum-major)
             (>= emacs-minor-version minimum-minor)))))

(defun agentedit-review--check-ediff-compatibility ()
  "Signal unless the supported Ediff teardown contract is available."
  (unless (and (agentedit-review--supported-emacs-version-p)
               (fboundp 'ediff-really-quit))
    (error "AgentEdit Ediff compatibility check failed")))

(defun agentedit-review--preflight ()
  "Reject a source buffer that is outside the v0 support contract."
  (unless (agentedit-review--supported-emacs-version-p)
    (user-error "AgentEdit review requires Emacs 29.4 or newer"))
  (unless (agentedit-review--supported-mode-p)
    (user-error
     "AgentEdit review requires built-in TeX mode or an AUCTeX-derived mode"))
  (unless (syntax-table-p (syntax-table))
    (user-error "AgentEdit review requires an initialized TeX syntax table"))
  (when (buffer-base-buffer)
    (user-error "AgentEdit review does not support indirect buffers"))
  (when (buffer-narrowed-p)
    (user-error "AgentEdit review requires a widened buffer"))
  (when buffer-read-only
    (user-error "AgentEdit review requires a writable buffer"))
  (when (eq buffer-undo-list t)
    (user-error "AgentEdit review requires undo to be enabled"))
  (agentedit-review--validate-environments)
  (condition-case error-data
      (agentedit-review--check-ediff-compatibility)
    (error (user-error "%s" (error-message-string error-data)))))

(defun agentedit-review--line-error (position format-string &rest args)
  "Signal a user error at POSITION using FORMAT-STRING and ARGS."
  (save-excursion
    (goto-char position)
    (apply #'user-error
           (concat "AgentEdit line " (number-to-string (line-number-at-pos))
                   ": " format-string)
           args)))

(defun agentedit-review--control-word-end (position)
  "Return the end of a TeX control word beginning at POSITION, or nil.
POSITION must point at a backslash."
  (let ((next (1+ position)))
    (when (and (< next (point-max))
               (let ((char (char-after next)))
                 (and char
                      (or (and (>= char ?a) (<= char ?z))
                          (and (>= char ?A) (<= char ?Z))))))
      (save-excursion
        (goto-char next)
        (skip-chars-forward "A-Za-z")
        (point)))))

(defun agentedit-review--parse-braced-at (position marker-position)
  "Parse a raw braced argument at POSITION for MARKER-POSITION.
Ordinary TeX comments and escaped control symbols do not balance braces."
  (save-excursion
    (goto-char position)
    (skip-chars-forward " \t\r\n")
    (unless (eq (char-after) ?{)
      (agentedit-review--line-error marker-position "expected four braced arguments"))
    (let ((open (point)) (depth 1))
      (forward-char)
      (while (and (> depth 0) (< (point) (point-max)))
        (pcase (char-after)
          (?\\ (forward-char (min 2 (- (point-max) (point)))))
          (?% (forward-line 1))
          (?{ (setq depth (1+ depth)) (forward-char))
          (?} (setq depth (1- depth)) (forward-char))
          (_ (forward-char))))
      (unless (= depth 0)
        (agentedit-review--line-error marker-position "unterminated braced argument"))
      (list (buffer-substring-no-properties (1+ open) (1- (point))) (point)))))

(defun agentedit-review--exact-marker-in-tex-p (text)
  "Return non-nil if TEXT contains a visible exact AgentEdit control word.
TeX comments, `\\verb' tokens, and configured verbatim environments are
opaque, matching the top-level record scanner."
  (with-temp-buffer
    (insert text)
    (let ((cursor (point-min))
          found)
      (while (and (< cursor (point-max)) (not found))
        (goto-char cursor)
        (let ((char (char-after)))
          (cond
           ((eq char ?%)
            (setq cursor (min (point-max) (1+ (line-end-position)))))
           ((not (eq char ?\\))
            (setq cursor (1+ cursor)))
           (t
            (let ((word-end (agentedit-review--control-word-end cursor)))
              (if (not word-end)
                  (setq cursor (min (point-max) (+ cursor 2)))
                (let ((word
                       (buffer-substring-no-properties (1+ cursor) word-end)))
                  (cond
                   ((string= word "verb")
                    (setq cursor (agentedit-review--verb-end word-end cursor)))
                   ((string= word "begin")
                    (let ((parsed
                           (agentedit-review--parse-environment-name word-end)))
                      (if (and parsed
                               (member (car parsed)
                                       agentedit-review-verbatim-environments))
                          (setq cursor
                                (agentedit-review--verbatim-end
                                 (car parsed) (cadr parsed) cursor))
                        (setq cursor word-end))))
                   ((string= word "agentedit")
                    (setq found t))
                   (t (setq cursor word-end))))))))))
      found)))

(defun agentedit-review--parse-record (start word-end)
  "Parse an AgentEdit record beginning at START after WORD-END."
  (let ((cursor word-end)
        arguments)
    (dotimes (_ 4)
      (pcase-let ((`(,argument ,end)
                   (agentedit-review--parse-braced-at cursor start)))
        (push argument arguments)
        (setq cursor end)))
    (setq arguments (nreverse arguments))
    (pcase-let ((`(,id ,reason ,original ,edited) arguments))
      (when (or (string-empty-p id) (string-empty-p reason)
                (string-empty-p (agentedit-review--normalize-one-line id))
                (string-empty-p (agentedit-review--normalize-one-line reason)))
        (agentedit-review--line-error
         start "ID and reason must contain visible text"))
      (when (cl-some #'agentedit-review--exact-marker-in-tex-p arguments)
        (agentedit-review--line-error start "nested \\agentedit marker"))
      (let ((start-marker (copy-marker start t))
            (end-marker (copy-marker cursor nil)))
        (agentedit-review--make-record
         :id id :reason reason :original original :edited edited
         :start start-marker :end end-marker
         :snapshot (buffer-substring-no-properties start cursor)
         :source (current-buffer))))))

(defun agentedit-review--parse-environment-name (position)
  "Return (NAME END) for a braced environment name at POSITION, or nil."
  (save-excursion
    (goto-char position)
    (skip-chars-forward " \t\r\n")
    (when (eq (char-after) ?{)
      (let* ((open (point))
             (close (condition-case nil (scan-sexps open 1) (scan-error nil))))
        (when close
          (list (buffer-substring-no-properties (1+ open) (1- close)) close))))))

(defun agentedit-review--verbatim-end (name content-start begin-position)
  "Find the line-oriented end of NAME after CONTENT-START.
BEGIN-POSITION is used to locate an unterminated-environment error."
  (save-excursion
    (goto-char content-start)
    (let ((case-fold-search nil)
          (terminator
           (concat "^[ \t]*\\\\end{" (regexp-quote name) "}"
                   "[ \t]*\\(?:%[^\r\n]*\\)?\r?$")))
      (unless (re-search-forward terminator nil t)
        (agentedit-review--line-error
         begin-position "unterminated %s environment" name))
      (min (point-max) (1+ (line-end-position))))))

(defun agentedit-review--verb-end (word-end marker-position)
  "Return the end of a verb token after WORD-END.
MARKER-POSITION is used for located errors."
  (save-excursion
    (goto-char word-end)
    (when (eq (char-after) ?*)
      (forward-char 1))
    (let ((delimiter (char-after)))
      (when (or (null delimiter) (memq delimiter '(?\s ?\t ?\r ?\n)))
        (agentedit-review--line-error marker-position
                                      "invalid \\verb delimiter"))
      (forward-char 1)
      (unless (search-forward (char-to-string delimiter) (line-end-position) t)
        (agentedit-review--line-error marker-position
                                      "unterminated \\verb token"))
      (point))))

(defconst agentedit-review--banner-regexp
  "[ \t]*%%% AGENTEDIT\\(?:[ \t:]\\|\r?$\\)")

(defun agentedit-review--left-context (position)
  "Return the physical line prefix before POSITION."
  (save-excursion
    (goto-char position)
    (buffer-substring-no-properties (line-beginning-position) position)))

(defun agentedit-review--right-context (position)
  "Return the first suffix character at POSITION, or the empty EOF witness."
  (buffer-substring-no-properties position (min (point-max) (1+ position))))

(defun agentedit-review--parse-frame (banner separator)
  "Parse a visible BANNER owning the active left SEPARATOR and complete tail."
  (goto-char banner)
  (unless (looking-at "%%% AGENTEDIT START: \\([A-Za-z0-9][A-Za-z0-9._:-]*\\) %%%\r?\n")
    (agentedit-review--line-error banner "malformed or orphan AGENTEDIT banner"))
  (let ((id (match-string-no-properties 1))
        (macro (match-end 0)))
    (unless (and separator
                 (member (buffer-substring-no-properties separator banner)
                         '("%\n" "%\r\n")))
      (agentedit-review--line-error banner "missing active left %% separator"))
    (goto-char macro)
    (unless (looking-at (regexp-quote "\\agentedit{"))
      (agentedit-review--line-error banner "START must be followed by agentedit and its ID"))
    (let* ((record (agentedit-review--parse-record macro (+ macro 10)))
           (cursor (+ macro 10))
           (arguments (list (agentedit-review-record-id record)
                            (agentedit-review-record-reason record)
                            (agentedit-review-record-original record)
                            (agentedit-review-record-edited record))))
      (unless (equal id (car arguments))
        (agentedit-review--line-error banner "frame ID does not match macro ID"))
      (dolist (argument arguments)
        (goto-char cursor)
        (unless (if (= cursor (+ macro 10))
                    (looking-at "{")
                  (looking-at "\r?\n[ \t]*{"))
          (agentedit-review--line-error banner "each argument must start on a new line"))
        (setq cursor (+ (match-end 0) (length argument) 1)))
      (goto-char cursor)
      (unless (looking-at
               (concat "\\([ \t\r\n]*\\)%\r?\n%%% AGENTEDIT END: "
                       (regexp-quote id) " %%%\r?\n"))
        (agentedit-review--line-error banner "missing right separator, matching END, or END newline"))
      (let ((whitespace (match-string-no-properties 1)) (end (match-end 0)))
        (when (or (string-match-p "\r" (replace-regexp-in-string "\r\n" "" whitespace))
                  (memq (char-after end) '(?\s ?\t ?\r ?\n)))
          (agentedit-review--line-error banner "retain ordinary right whitespace before the separator"))
        (set-marker (agentedit-review-record-start record) separator)
        (set-marker (agentedit-review-record-end record) end)
        (setf (agentedit-review-record-framed record) t
              (agentedit-review-record-whitespace record) whitespace
              (agentedit-review-record-snapshot record)
              (buffer-substring-no-properties separator end)
              (agentedit-review-record-left-context record)
              (agentedit-review--left-context separator)
              (agentedit-review-record-right-context record)
              (agentedit-review--right-context end))
        record))))

(defun agentedit-review--scan-records (origin &optional display-origin)
  "Return records at ORIGIN or later, including a frame containing ORIGIN.
Legacy calls retain their control-word origin semantics.
For display discovery, DISPLAY-ORIGIN allows malformed or duplicate legacy
records before that position to remain outside strict queue validation."
  (let ((records nil) (ids (make-hash-table :test #'equal))
        (cursor (point-min)) separator)
    (cl-labels
        ((collect (record)
           (let ((id (agentedit-review-record-id record)))
             (unless (and display-origin (< cursor display-origin))
               (when (gethash id ids)
                 (agentedit-review--line-error cursor "duplicate marker ID %s" id))
               (puthash id t ids))
             (push record records))))
      (while (< cursor (point-max))
        (goto-char cursor)
        (pcase (char-after)
          (?%
           (let ((line-start (line-beginning-position)))
             (if (and (string-match-p "\\`[ \t]*\\'"
                                      (buffer-substring-no-properties line-start cursor))
                      (save-excursion (goto-char line-start)
                                      (looking-at agentedit-review--banner-regexp)))
                 (let ((record (agentedit-review--parse-frame line-start separator)))
                   (setq cursor (marker-position (agentedit-review-record-end record))
                         separator nil)
                   (when (> cursor origin) (collect record)))
               (setq separator (when (looking-at "%\r?\n") cursor)
                     cursor (min (point-max) (1+ (line-end-position)))))))
          (?\\
           (let ((word-end (agentedit-review--control-word-end cursor)))
             (if (not word-end)
                 (setq cursor (min (point-max) (+ cursor 2)))
               (let ((word (buffer-substring-no-properties (1+ cursor) word-end)))
                 (cond
                  ((string= word "verb")
                   (setq cursor (agentedit-review--verb-end word-end cursor)))
                  ((string= word "begin")
                   (let ((parsed (agentedit-review--parse-environment-name word-end)))
                     (setq cursor
                           (if (and parsed (member (car parsed) agentedit-review-verbatim-environments))
                               (agentedit-review--verbatim-end (car parsed) (cadr parsed) cursor)
                             word-end))))
                  ((string= word "agentedit")
                   (if (< cursor origin)
                       (setq cursor
                             (condition-case nil
                                 (let ((scan word-end))
                                   (dotimes (_ 4)
                                     (setq scan (cadr (agentedit-review--parse-braced-at scan cursor))))
                                   scan)
                               (user-error word-end)))
                     (let ((record
                            (if (and display-origin (< cursor display-origin))
                                (condition-case problem
                                    (agentedit-review--parse-record cursor word-end)
                                  (user-error
                                   (push (error-message-string problem)
                                         agentedit-review--display-diagnostics)
                                   nil))
                              (agentedit-review--parse-record cursor word-end))))
                       (if record
                           (progn
                             (collect record)
                             (setq cursor (marker-position (agentedit-review-record-end record))))
                         (setq cursor word-end)))))
                  (t (setq cursor word-end)))))))
          (_ (setq cursor (1+ cursor))))))
    (nreverse records)))

(defun agentedit-review--normalize-one-line (text)
  "Normalize TEXT for literal one-line display without changing provenance."
  (string-trim
   (replace-regexp-in-string
    "[[:space:][:cntrl:]]+" " " text nil 'literal)))

(defun agentedit-review--source-label (source)
  "Return a one-line display label for SOURCE."
  (with-current-buffer source
    (agentedit-review--normalize-one-line
     (or buffer-file-name (buffer-name)))))

(defun agentedit-review--record-line (record)
  "Return RECORD's current one-based source line."
  (let ((marker (agentedit-review-record-start record)))
    (unless (marker-position marker)
      (error "AgentEdit marker no longer has a source position"))
    (with-current-buffer (marker-buffer marker)
      (line-number-at-pos marker))))

(defun agentedit-review--temporary-name (side id)
  "Return a safe unique temporary buffer name for SIDE and ID."
  (let* ((clean (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" id))
         (short (truncate-string-to-width clean 40 nil nil t)))
    (generate-new-buffer-name
     (format " *AgentEdit %s %s*" side (if (string-empty-p short) "edit" short)))))

(defun agentedit-review--projection-header (side)
  "Return a persistent pane label for projection SIDE."
  (if (string= side "original")
      (list (propertize " − ORIGINAL "
                        'face 'agentedit-review-original-label)
            (propertize "· reject keeps this" 'face 'shadow))
    (list (propertize " + PROPOSED "
                      'face 'agentedit-review-proposed-label)
          (propertize "· accept keeps this" 'face 'shadow))))

(defun agentedit-review--install-projection-visuals (side)
  "Install buffer-local Ediff highlighting and a pane label for SIDE."
  (pcase side
    ("original"
     (face-remap-add-relative
      'ediff-current-diff-A 'agentedit-review-original-hunk)
     (face-remap-add-relative
      'ediff-fine-diff-A 'agentedit-review-original-fine))
    ("edited"
     (face-remap-add-relative
      'ediff-current-diff-B 'agentedit-review-proposed-hunk)
     (face-remap-add-relative
      'ediff-fine-diff-B 'agentedit-review-proposed-fine)))
  (setq-local header-line-format (agentedit-review--projection-header side)))

(defun agentedit-review--file-state (session source)
  "Return SESSION's accounting entry for SOURCE."
  (cl-find source (agentedit-review-session-files session)
           :key #'agentedit-review-file-source :test #'eq))

(defun agentedit-review--note-current-file-error (session message)
  "Record MESSAGE on SESSION's current owning file when known."
  (let* ((record (if (or (agentedit-review-session-applied-decision session)
                         (agentedit-review-session-pending-action session))
                     (agentedit-review-session-completed-record session)
                   (agentedit-review--current-record session)))
         (file (and record (agentedit-review--file-state
                            session (agentedit-review--record-source record)))))
    (when file (setf (agentedit-review-file-error file) message))))

(defun agentedit-review--initialize-files (session)
  "Capture source witnesses and initialize SESSION's persistent accounting."
  (setf (agentedit-review-session-files session)
        (mapcar
         (lambda (source)
           (with-current-buffer source
             (let* ((records (cl-remove-if-not
                              (lambda (record)
                                (eq source (agentedit-review--record-source record)))
                              (agentedit-review-session-records session)))
                    (origin (if records (agentedit-review-record-start (car records)) (point-max)))
                    (agentedit-review--display-diagnostics nil)
                    (details (save-excursion
                               (agentedit-review--scan-records (point-min) origin))))
               (dolist (record records)
                 (setf (agentedit-review-record-source-line record)
                       (agentedit-review--record-line record)))
               (agentedit-review--make-file
                :source source :path (or buffer-file-name (buffer-name))
                :filename buffer-file-name :tick (buffer-chars-modified-tick)
                :scope-start (copy-marker origin) :scope-line (line-number-at-pos origin)
                :details details :diagnostics agentedit-review--display-diagnostics
                :outside-details (agentedit-review--outside-details details records)
                :outside (length (agentedit-review--outside-details details records))))))
         (agentedit-review--session-sources session))))

(defun agentedit-review--save-preflight (session record)
  "Check the source and disk target before SESSION applies or saves RECORD."
  (agentedit-review--source-ready record)
  (when (agentedit-review-session-auto-save session)
    (let* ((source (agentedit-review--record-source record))
           (file (agentedit-review--file-state session source)))
      (with-current-buffer source
        (unless buffer-file-name
          (user-error "Source has no filename; save it first or set agentedit-review-auto-save nil and restart"))
        (unless (and file (equal buffer-file-name (agentedit-review-file-filename file)))
          (user-error "Source filename changed; inspect the source and restart review"))
        (unless (verify-visited-file-modtime source)
          (user-error "Source file changed on disk; reconcile it before saving and restart review"))))))

(defun agentedit-review--expected-source (record replacement)
  "Return the exact source expected after resolving RECORD to REPLACEMENT."
  (with-current-buffer (agentedit-review--record-source record)
    (concat (buffer-substring-no-properties (point-min) (agentedit-review-record-start record))
            replacement (agentedit-review-record-whitespace record)
            (buffer-substring-no-properties (agentedit-review-record-end record) (point-max)))))

(defun agentedit-review--save-decision (session record expected)
  "Save RECORD's owning source for SESSION and verify EXPECTED text.
Do not retry an applied decision.  A failed save never implies rollback."
  (let* ((source (agentedit-review--record-source record))
         (file (agentedit-review--file-state session source)))
    (with-current-buffer source
      (unless (equal expected (buffer-substring-no-properties (point-min) (point-max)))
        (error "Source changed while applying the decision; inspect it before continuing"))
      (when file
        (setf (agentedit-review-file-tick file) (buffer-chars-modified-tick)
              (agentedit-review-file-save-status file)
              (if (agentedit-review-session-auto-save session) 'unconfirmed 'manual)))
      (when (agentedit-review-session-auto-save session)
        (agentedit-review--save-preflight session record)
        (message "AgentEdit: saving %s..." (agentedit-review-file-path file))
        (save-buffer)
        (unless (and (buffer-live-p source)
                     (equal buffer-file-name (agentedit-review-file-filename file))
                     (not (buffer-modified-p))
                     (equal expected (buffer-substring-no-properties (point-min) (point-max)))
                     (verify-visited-file-modtime source))
          (error "Save changed the text/target or left the source unsaved; inspect source and save hooks"))
        ;; A write hook may claim success without writing.  Verify through
        ;; normal file handlers and the source's coding system as well.
        (let ((filename buffer-file-name)
              (coding-system-for-read buffer-file-coding-system))
          (unless (equal expected
                         (with-temp-buffer
                           (insert-file-contents filename)
                           (buffer-substring-no-properties (point-min) (point-max))))
            (error "Saved file does not match the applied source; inspect file and save hooks")))
        (setf (agentedit-review-file-save-status file) 'saved
              (agentedit-review-file-saved-tick file) (buffer-chars-modified-tick)
              (agentedit-review-file-tick file) (buffer-chars-modified-tick)
              (agentedit-review-session-save-confirmed session) t)))))

(defun agentedit-review--record-decision (session record kind)
  "Count applied KIND for RECORD in SESSION exactly once."
  (let* ((file (agentedit-review--file-state session (agentedit-review--record-source record)))
         (custom (and (eq kind 'accept)
                      (agentedit-review-session-view session)
                      (not (equal (agentedit-review-session-draft session)
                                  (agentedit-review-record-edited record))))))
    (setf (agentedit-review-record-decision record) kind
          (agentedit-review-record-result record)
          (and (eq kind 'accept) (agentedit-review-session-draft session)))
    (pcase kind
      ('accept
       (cl-incf (agentedit-review-session-accepted session))
       (when custom (cl-incf (agentedit-review-session-custom session)))
       (when file
         (cl-incf (agentedit-review-file-accepted file))
         (when custom (cl-incf (agentedit-review-file-custom file)))))
      ('reject
       (cl-incf (agentedit-review-session-rejected session))
       (when file (cl-incf (agentedit-review-file-rejected file))))
      ('skip
       (cl-incf (agentedit-review-session-skipped session))
       (when file (cl-incf (agentedit-review-file-skipped file)))))
    (when (and file (not (eq kind 'skip)))
      (setf (agentedit-review-file-save-status file)
            (if (agentedit-review-session-auto-save session) 'unconfirmed 'manual)))
    (setf (agentedit-review-session-completed-decision session) kind
          (agentedit-review-session-completed-record session) record)
    (cl-incf (agentedit-review-session-index session))))

(defun agentedit-review--file-save-label (file)
  "Return the historical save outcome and current source status for FILE."
  (let ((source (agentedit-review-file-source file)))
    (concat
     (pcase (agentedit-review-file-save-status file)
       ('saved "Saved at last decision")
       ('unconfirmed "Applied; save not confirmed")
       ('manual "Applied; manual save")
       (_ "No decision saved by this review"))
     (if (buffer-live-p source) "" "; source buffer closed"))))

(defun agentedit-review--report-button (label buffer &optional position)
  "Insert a keyboard-activatable LABEL visiting BUFFER at POSITION."
  (insert-text-button
   label 'follow-link t
   'action (lambda (_button)
             (unless (buffer-live-p buffer)
               (user-error "Buffer is closed; reopen the source file using its path"))
             (pop-to-buffer buffer)
             (when position
               (with-current-buffer buffer
                 (goto-char (max (point-min) (min position (point-max)))))))))

(defun agentedit-review--render-report (session)
  "Render SESSION's persistent report without depending on live Ediff panes."
  (let ((buffer (or (and (buffer-live-p (agentedit-review-session-report session))
                         (agentedit-review-session-report session))
                    (generate-new-buffer "*AgentEdit report*"))))
    (setf (agentedit-review-session-report session) buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (print-escape-newlines t)
            (print-escape-control-characters t))
        (erase-buffer)
        (insert (format "AgentEdit review · %s\n\n" (agentedit-review-session-state session)))
        (insert (if (agentedit-review-session-auto-save session)
                    "AUTO-SAVE: confirmed A/R saves the entire owning source, including existing unsaved edits.\n"
                  "MANUAL: decisions remain in source buffers; save with your normal Emacs workflow.\n"))
        (insert "Counts describe the selected review queue. Pending outside its scope are separate.\n")
        (insert "Record strings are quoted so embedded newlines and controls cannot resemble report fields.\n")
        (insert "g refresh · TAB/RET follow links · q close report\n\n")
        (when (agentedit-review-session-last-error session)
          (insert "Stopped: " (agentedit-review-session-last-error session) "\n")
          (insert (if (agentedit-review-session-applied-decision session)
                      "The decision is already applied. Inspect the owning source, resolve the problem, C-x C-s, then M-x agentedit-review for remaining records.\n"
                    "No current decision was applied. Inspect the source and recovered draft, then M-x agentedit-review against the current text.\n")))
        (when (buffer-live-p (agentedit-review-session-recovery session))
          (agentedit-review--report-button "Open recovered draft"
                                          (agentedit-review-session-recovery session))
          (insert " — retained until you close it; not durable across Emacs exit.\n"))
        (dolist (file (agentedit-review-session-files session))
          (let* ((source (agentedit-review-file-source file))
                 (records (cl-remove-if-not
                           (lambda (record) (eq source (agentedit-review--record-source record)))
                           (agentedit-review-session-records session)))
                 (unvisited (- (length records) (agentedit-review-file-accepted file)
                               (agentedit-review-file-rejected file) (agentedit-review-file-skipped file))))
            (insert "\n" (agentedit-review-file-path file) "\n")
            (insert (format "Review scope: queue from source line %s at entry.\n"
                            (or (agentedit-review-file-scope-line file) "unknown")))
            (dolist (diagnostic (agentedit-review-file-diagnostics file))
              (insert "Context diagnostic: " diagnostic "\n"))
            (when (buffer-live-p source)
              (agentedit-review--report-button "Visit source" source)
              (insert " · "))
            (insert (agentedit-review--file-save-label file))
            (when (buffer-live-p source)
              (with-current-buffer source
                (when (and (agentedit-review-file-saved-tick file)
                           (/= (buffer-chars-modified-tick) (agentedit-review-file-saved-tick file)))
                  (with-current-buffer buffer (insert "; modified since verified save"))))
              (when (buffer-modified-p source) (insert "; currently unsaved")))
            (insert "\n")
            (insert (format "%d accepted (%d custom), %d rejected, %d skipped, %d unvisited; %d unresolved in this review.\n"
                            (agentedit-review-file-accepted file) (agentedit-review-file-custom file)
                            (agentedit-review-file-rejected file) (agentedit-review-file-skipped file)
                            unvisited (+ unvisited (agentedit-review-file-skipped file))))
            (insert (format "%d pending outside review scope at last comparison.\n"
                            (or (agentedit-review-file-outside file) 0)))
            (when (agentedit-review-file-error file)
              (insert "Error: " (agentedit-review-file-error file) "\n"))
            (dolist (record records)
              (insert (format "\n  %S · %s\n  Reason: %S\n  Original: %S\n  Proposed: %S\n"
                              (agentedit-review-record-id record)
                              (or (agentedit-review-record-decision record) 'unvisited)
                              (agentedit-review-record-reason record)
                              (agentedit-review-record-original record)
                              (agentedit-review-record-edited record)))
              (insert (format "  Source: %s:%s (line at entry)\n"
                              (agentedit-review-file-path file)
                              (or (agentedit-review-record-source-line record) "unknown")))
              (when (and (buffer-live-p source)
                         (marker-position (agentedit-review-record-start record)))
                (insert "  ")
                (agentedit-review--report-button "Visit record" source (agentedit-review-record-start record))
                (insert "\n"))
              (when (agentedit-review-record-result record)
                (insert (format "  Applied result: %S\n" (agentedit-review-record-result record)))))
            (dolist (record (agentedit-review-file-outside-details file))
              (insert (format "\n  Pending outside scope: %S\n  Reason: %S\n  Original: %S\n  Proposed: %S\n"
                              (agentedit-review-record-id record) (agentedit-review-record-reason record)
                              (agentedit-review-record-original record) (agentedit-review-record-edited record))))))
        (insert "\nCommands in AgentEdit panes/control:\n"
                "C-c e edit · C-c o original seed · C-c p proposal seed\n"
                "C-c C-c stage (no source change) · C-c C-k cancel edit\n"
                "C-c w paragraph/full current file · C-c l report\n"
                "Control: A apply result, R keep original, S skip, q confirm stop.\n"
                "E/? remain native Ediff help. While EDITING, stage/cancel before A/R/S or C-c w.\n")
        (delay-mode-hooks (special-mode))
        (setq-local agentedit-review--session session)
        (local-set-key (kbd "g") #'agentedit-review-report)
        (goto-char (point-min))))
    buffer))

;;;###autoload
(defun agentedit-review-report ()
  "Show the active or latest AgentEdit session report.
The report survives completion, quit, and failure.  Use g to refresh live
source status and TAB/RET to visit source or recovered draft buffers."
  (interactive)
  (let ((session (or agentedit-review--session agentedit-review--last-session)))
    (unless session (user-error "No AgentEdit review has run in this Emacs session"))
    (pop-to-buffer (agentedit-review--render-report session))))

(defun agentedit-review--check-source-snapshot (session)
  "Refuse SESSION if the owning source changed outside its known decisions."
  (let* ((record (agentedit-review--current-record session))
         (source (agentedit-review--record-source record))
         (file (agentedit-review--file-state session source))
         (view (agentedit-review-session-view session)))
    (agentedit-review--source-ready record)
    (with-current-buffer source
      (when (or (and file (/= (buffer-chars-modified-tick)
                             (agentedit-review-file-tick file)))
                (and view (/= (buffer-chars-modified-tick)
                             (agentedit-review-view-tick view))))
        (signal 'agentedit-review-stale nil)))))

(defun agentedit-review--same-span-p (first second)
  "Return non-nil when FIRST and SECOND own the same live source span."
  (let ((first-start (marker-position (agentedit-review-record-start first)))
        (first-end (marker-position (agentedit-review-record-end first)))
        (second-start (marker-position (agentedit-review-record-start second)))
        (second-end (marker-position (agentedit-review-record-end second))))
    (and first-start first-end second-start second-end
         (eq (agentedit-review--record-source first)
             (agentedit-review--record-source second))
         (= first-start second-start)
         (= first-end second-end))))

(defun agentedit-review--outside-details (records queued)
  "Keep RECORDS outside QUEUED while their source markers are still live."
  (cl-remove-if
   (lambda (record)
     (cl-some (lambda (item) (agentedit-review--same-span-p record item)) queued))
   records))

(defun agentedit-review--build-view (session)
  "Build SESSION's clean original baseline and explicit source-span mapping."
  (agentedit-review--check-source-snapshot session)
  (let* ((active (agentedit-review--current-record session))
         (source (agentedit-review--record-source active))
         (file (agentedit-review--file-state session source))
         (origin (if file (agentedit-review-file-scope-start file)
                   (agentedit-review-record-start active)))
         (agentedit-review--display-diagnostics nil))
    (with-current-buffer source
      (save-excursion
        (let ((records (agentedit-review--scan-records (point-min) origin))
              (cursor (point-min)) (size 0) chunks pending start end)
          (dolist (record records)
            (let* ((left (marker-position (agentedit-review-record-start record)))
                   (right (marker-position (agentedit-review-record-end record)))
                   (prefix (buffer-substring-no-properties cursor left))
                   (original (agentedit-review-record-original record))
                   (whitespace (or (agentedit-review-record-whitespace record) ""))
                   (mapped-start (+ 1 size (length prefix)))
                   (mapped-end (+ mapped-start (length original))))
              (push prefix chunks)
              (push original chunks)
              (push whitespace chunks)
              (if (agentedit-review--same-span-p active record)
                  (progn
                    (unless (equal (agentedit-review-record-snapshot active)
                                   (agentedit-review-record-snapshot record))
                      (signal 'agentedit-review-stale nil))
                    (setq start mapped-start end mapped-end))
                (push (list record mapped-start mapped-end) pending))
              (setq size (+ size (length prefix) (length original) (length whitespace))
                    cursor right)))
          ;; A custom decision can hide a legacy marker without changing its bytes.
          (unless start (signal 'agentedit-review-stale nil))
          (push (buffer-substring-no-properties cursor (point-max)) chunks)
          (when file
            (setf (agentedit-review-file-diagnostics file) agentedit-review--display-diagnostics
                  (agentedit-review-file-details file) records
                  (agentedit-review-file-outside-details file)
                  (agentedit-review--outside-details records (agentedit-review-session-records session))
                  (agentedit-review-file-outside file)
                  (length (agentedit-review--outside-details
                           records (agentedit-review-session-records session)))))
          (agentedit-review--make-view-data
           :text (apply #'concat (nreverse chunks)) :start start :end end
           :pending (nreverse pending)
           :diagnostics (nreverse agentedit-review--display-diagnostics)
           :tick (buffer-chars-modified-tick)))))))

(defun agentedit-review--copy-text-settings (source)
  "Copy safe syntax and paragraph settings from SOURCE into this buffer.
Do not activate the source mode, its hooks, or file-local evaluation."
  (set-syntax-table (copy-syntax-table (with-current-buffer source (syntax-table))))
  (dolist (variable '(paragraph-start paragraph-separate
                     paragraph-ignore-fill-prefix fill-prefix))
    (set (make-local-variable variable) (buffer-local-value variable source)))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defun agentedit-review--paragraph-bounds (view source)
  "Return paragraph bounds enclosing VIEW's entire active span using SOURCE.
An empty insertion includes each available neighboring paragraph.
Return nil if the mode's paragraph rules cannot produce a usable interval."
  (condition-case nil
      (with-temp-buffer
        (insert (agentedit-review-view-text view))
        (agentedit-review--copy-text-settings source)
        (let ((start (agentedit-review-view-start view))
              (end (agentedit-review-view-end view)) left right)
          (goto-char (if (= start end) (max (point-min) (1- start)) start))
          (backward-paragraph)
          (setq left (point))
          (goto-char (if (= start end) (min (point-max) (1+ end))
                       (max start (1- end))))
          (forward-paragraph)
          (setq right (point))
          (when (and (<= left start) (>= right end) (< left right))
            (cons left right))))
    (error nil)))

(defun agentedit-review--select-context (session)
  "Set SESSION's common display prefix/suffix from its cached baseline."
  (let* ((view (agentedit-review-session-view session))
         (source (agentedit-review--record-source (agentedit-review--current-record session)))
         (text (agentedit-review-view-text view))
         (bounds (unless (agentedit-review-session-full-context session)
                   (agentedit-review--paragraph-bounds view source)))
         (left (if bounds (car bounds) 1))
         (right (if bounds (cdr bounds) (1+ (length text)))))
    (setf (agentedit-review-view-prefix view)
          (substring text (1- left) (1- (agentedit-review-view-start view)))
          (agentedit-review-view-suffix view)
          (substring text (1- (agentedit-review-view-end view)) (1- right))
          (agentedit-review-view-offset view) (1- left)
          (agentedit-review-view-fallback view)
          (and (not bounds) (not (agentedit-review-session-full-context session))))))

(defun agentedit-review--projection-before-change (start end)
  "Refuse a change outside the active editable result between START and END."
  (unless agentedit-review--changing-projection
    (unless (and agentedit-review--session
                 (equal agentedit-review--projection-role "edited")
                 (eq (agentedit-review-session-state agentedit-review--session) 'editing)
                 agentedit-review--fragment-start agentedit-review--fragment-end
                 (<= agentedit-review--fragment-start start)
                 (<= end agentedit-review--fragment-end))
      (user-error "Only the active result fragment is editable; use C-c e"))))

(defun agentedit-review--projection-after-change (&rest _ignored)
  "Keep active-fragment annotations accurate while the result is edited."
  (when (and agentedit-review--session
             (not agentedit-review--changing-projection)
             (eq (agentedit-review-session-state agentedit-review--session) 'editing))
    (agentedit-review--decorate-fragment agentedit-review--session "edited")))

(defun agentedit-review--projection-save-refused ()
  "Explain why a display projection cannot be saved as source."
  (interactive)
  (user-error "AgentEdit projection: stage with C-c C-c, then A to apply; C-c l visits source"))

(defun agentedit-review--native-mutation-refused ()
  "Keep native Ediff mutations from changing AgentEdit pane roles or context."
  (interactive)
  (user-error "AgentEdit keeps fixed panes; use C-c o/p to seed, C-c e to edit"))

(defun agentedit-review--install-context-keys ()
  "Install AgentEdit commands in the current owned buffer's local map."
  (use-local-map (copy-keymap (or (current-local-map) (make-sparse-keymap))))
  (dolist (binding '(("C-c e" . agentedit-review-edit)
                     ("C-c o" . agentedit-review-seed-original)
                     ("C-c p" . agentedit-review-seed-proposed)
                     ("C-c w" . agentedit-review-toggle-context)
                     ("C-c l" . agentedit-review-report)
                     ("C-c C-c" . agentedit-review-stage)
                     ("C-c C-k" . agentedit-review-cancel-edit)))
    (local-set-key (kbd (car binding)) (cdr binding))))

(defun agentedit-review--decorate-fragment (session side)
  "Label the active fragment in the current SESSION projection for SIDE."
  (let* ((view (agentedit-review-session-view session))
         (editing (eq (agentedit-review-session-state session) 'editing))
         (result (equal side "edited"))
         (draft (buffer-substring-no-properties
                 agentedit-review--fragment-start agentedit-review--fragment-end))
         (record (agentedit-review--current-record session))
         (face (if result 'agentedit-review-proposed-label 'agentedit-review-original-label))
         (scope (cond ((agentedit-review-session-full-context session) "full file")
                      ((agentedit-review-view-fallback view) "full-file fallback")
                      (t "paragraph"))))
    (setq-local header-line-format
                (list (propertize
                       (if result
                           (format " + RESULT · %s "
                                   (if editing "EDITING"
                                     (if (equal draft (agentedit-review-record-edited record))
                                         "PROPOSED" "CUSTOM")))
                         " − ORIGINAL ")
                       'face face)
                      (if (and result editing) "C-c C-c stage · C-c C-k cancel"
                        (if result "· accept keeps this" "· reject keeps this"))
                      (format " · %s" scope)
                      (cond ((string-empty-p draft) " · empty fragment")
                            ((not (string-match-p "[^ \t\r\n]" draft))
                             (format " · whitespace only (%d characters)" (length draft)))
                            (t ""))))
    (when (overlayp agentedit-review--fragment-overlay)
      (delete-overlay agentedit-review--fragment-overlay))
    (setq agentedit-review--fragment-overlay
          (make-overlay agentedit-review--fragment-start agentedit-review--fragment-end nil nil t))
    (overlay-put agentedit-review--fragment-overlay 'before-string
                 (propertize (if (string-empty-p draft) "[empty fragment]" "⟦") 'face face))
    (overlay-put agentedit-review--fragment-overlay 'after-string (propertize "⟧" 'face face))
    (remove-overlays nil nil 'agentedit-pending t)
    (dolist (pending (agentedit-review-view-pending view))
      (let* ((neighbor (car pending)) (start (cadr pending))
             (position (- start (agentedit-review-view-offset view))))
        (when (and result (>= start (agentedit-review-view-end view)))
          (cl-incf position (- (length draft) (length (agentedit-review-record-original record)))))
        (when (<= (point-min) position (point-max))
          (let ((overlay (make-overlay position position)))
            (overlay-put overlay 'agentedit-pending t)
            (overlay-put overlay 'before-string
                         (propertize (format "[pending %s] "
                                             (agentedit-review--normalize-one-line
                                              (agentedit-review-record-id neighbor)))
                                     'face 'shadow))))))))

(defun agentedit-review--fill-projection (session side)
  "Replace this projection's display using SESSION's staged draft and SIDE."
  (let* ((view (agentedit-review-session-view session))
         (record (agentedit-review--current-record session))
         (text (if (equal side "original") (agentedit-review-record-original record)
                 (agentedit-review-session-draft session)))
         (prefix (agentedit-review-view-prefix view))
         (suffix (agentedit-review-view-suffix view))
         (inhibit-read-only t) (agentedit-review--changing-projection t))
    (remove-overlays nil nil 'agentedit-pending t)
    (erase-buffer)
    (insert prefix text suffix)
    (setq agentedit-review--fragment-start (copy-marker (1+ (length prefix)))
          agentedit-review--fragment-end (copy-marker (+ 1 (length prefix) (length text)) t)
          buffer-undo-list nil)
    (set-buffer-modified-p nil)
    (goto-char agentedit-review--fragment-start)
    (agentedit-review--decorate-fragment session side)))

(defun agentedit-review--make-projection (session side text id)
  "Create a read-only projection owned by SESSION for SIDE from TEXT and ID."
  (let ((buffer (generate-new-buffer (agentedit-review--temporary-name side id))))
    (with-current-buffer buffer
      (insert text)
      (goto-char (point-min))
      (setq-local buffer-read-only t)
      (setq-local agentedit-review--session session)
      (setq-local agentedit-review--projection-role side)
      (agentedit-review--install-projection-visuals side)
      (when (string-match-p "\\`[ \t\r\n]*\\'" text)
        (setq-local header-line-format
                    (append header-line-format
                            (list (if (string-empty-p text) " · empty"
                                    (format " · whitespace only (%d characters)" (length text)))))))
      (when (and session (agentedit-review-session-view session))
        (agentedit-review--copy-text-settings
         (agentedit-review--record-source (agentedit-review--current-record session)))
        (agentedit-review--install-context-keys)
        (local-set-key [remap save-buffer] #'agentedit-review--projection-save-refused)
        (local-set-key [remap write-file] #'agentedit-review--projection-save-refused)
        (agentedit-review--fill-projection session side)
        (add-hook 'before-change-functions #'agentedit-review--projection-before-change nil t)
      (add-hook 'after-change-functions #'agentedit-review--projection-after-change nil t))
      (add-hook 'kill-buffer-hook #'agentedit-review--projection-killed nil t))
    buffer))

(defun agentedit-review--current-record (session)
  "Return SESSION's current record, or nil after the queue."
  (nth (agentedit-review-session-index session)
       (agentedit-review-session-records session)))

(defun agentedit-review--require-review (&optional editing)
  "Return the active contextual session; allow EDITING when non-nil."
  (let ((session agentedit-review--session))
    (unless (and session (agentedit-review-session-view session)
                 (memq (agentedit-review-session-state session)
                       (if editing '(reviewing editing) '(reviewing))))
      (user-error "Stage with C-c C-c or cancel with C-c C-k before deciding or changing context"))
    session))

(defun agentedit-review--live-draft (session)
  "Read SESSION's exact live result fragment, independent of selected window."
  (let ((buffer (agentedit-review-session-projection-b session)))
    (unless (buffer-live-p buffer) (error "Result projection was killed"))
    (with-current-buffer buffer
      (unless (and (markerp agentedit-review--fragment-start)
                   (markerp agentedit-review--fragment-end)
                   (eq (marker-buffer agentedit-review--fragment-start) buffer)
                   (eq (marker-buffer agentedit-review--fragment-end) buffer)
                   (<= (point-min) agentedit-review--fragment-start
                       agentedit-review--fragment-end (point-max)))
        (error "Result fragment boundaries changed"))
      (buffer-substring-no-properties agentedit-review--fragment-start
                                      agentedit-review--fragment-end))))

(defun agentedit-review--validate-projections (session)
  "Validate SESSION's fixed roles and all protected projection text."
  (agentedit-review--check-source-snapshot session)
  (let* ((view (agentedit-review-session-view session))
         (a (agentedit-review-session-projection-a session))
         (b (agentedit-review-session-projection-b session))
         (control (agentedit-review-session-control session))
         (record (agentedit-review--current-record session))
         (prefix (agentedit-review-view-prefix view))
         (suffix (agentedit-review-view-suffix view)))
    (unless (and (buffer-live-p a) (buffer-live-p b) (buffer-live-p control))
      (error "An AgentEdit comparison buffer was killed"))
    (with-current-buffer control
      (unless (and (eq ediff-buffer-A a) (eq ediff-buffer-B b))
        (error "Ediff pane roles changed; restart review")))
    (with-current-buffer a
      (unless (and (not (buffer-narrowed-p))
                   (equal (buffer-substring-no-properties (point-min) (point-max))
                          (concat prefix (agentedit-review-record-original record) suffix)))
        (error "Original projection changed; no decision applied")))
    (with-current-buffer b
      (let ((live (agentedit-review--live-draft session)))
        (when (and (not (eq (agentedit-review-session-state session) 'editing))
                   (not (equal live (agentedit-review-session-draft session))))
          (error "Result changed outside editing; use C-c e")))
      (unless (and (not (buffer-narrowed-p))
                   (= agentedit-review--fragment-start (1+ (length prefix)))
                   (equal prefix (buffer-substring-no-properties
                                  (point-min) agentedit-review--fragment-start))
                   (equal suffix (buffer-substring-no-properties
                                  agentedit-review--fragment-end (point-max))))
        (error "Protected result context changed; no decision applied")))))

(defun agentedit-review--preserve-draft (session &optional snapshot)
  "Preserve SESSION's changed live draft before any failed teardown.
This is idempotent and runs synchronously while killed panes are still live."
  (let* ((record (agentedit-review--current-record session))
         (draft (or snapshot (ignore-errors (agentedit-review--live-draft session))
                    (agentedit-review-session-draft session))))
    (when (and record (stringp draft)
               (not (agentedit-review-session-applied-decision session))
               (not (eq (agentedit-review-session-completed-decision session) 'skip))
               (not (eq (agentedit-review-session-state session) 'aborting))
               (not (equal draft (agentedit-review-record-edited record)))
               (not (buffer-live-p (agentedit-review-session-recovery session))))
      (let ((buffer (generate-new-buffer
                     (format "*AgentEdit recovered %s*"
                             (agentedit-review--normalize-one-line
                              (agentedit-review-record-id record))))))
        (with-current-buffer buffer
          (insert draft)
          (buffer-enable-undo)
          (setq-local header-line-format
                      (list "Recovered AgentEdit draft · "
                            (agentedit-review--normalize-one-line
                             (agentedit-review-record-id record))
                            " · inspect source before applying"))
          (goto-char (point-min)))
        (setf (agentedit-review-session-recovery session) buffer)))))

(defun agentedit-review--draft-failed (session problem)
  "Stop SESSION after draft or refresh PROBLEM without losing live text."
  (agentedit-review--preserve-draft session)
  (setf (agentedit-review-session-last-error session) (error-message-string problem))
  (agentedit-review--note-current-file-error session (error-message-string problem))
  (agentedit-review--transition session
                                (if (eq (car problem) 'agentedit-review-stale) 'stale 'failed))
  (condition-case nil
      (let ((control (agentedit-review-session-control session)))
        (if (buffer-live-p control)
            (with-current-buffer control (agentedit-review--ediff-really-quit))
          (agentedit-review--force-terminal-cleanup session)))
    ((error quit) (agentedit-review--force-terminal-cleanup session))))

(defun agentedit-review--refresh (session &optional context)
  "Refresh differences in SESSION without ending Ediff.
With CONTEXT, reconstruct both panes from the cached baseline."
  (message "AgentEdit: recomputing comparison...")
  (when context
    (agentedit-review--select-context session)
    (dolist (entry (list (cons (agentedit-review-session-projection-a session) "original")
                         (cons (agentedit-review-session-projection-b session) "edited")))
      (with-current-buffer (car entry)
        (agentedit-review--fill-projection session (cdr entry)))))
  ;; Ediff's window setup expects the control window to be selected, not
  ;; merely current-buffer.  Staging is also callable from either pane.
  (pop-to-buffer (agentedit-review-session-control session))
  (ediff-update-diffs)
  (with-current-buffer (agentedit-review-session-control session)
    (agentedit-review--install-control-visuals))
  (dolist (buffer (list (agentedit-review-session-projection-a session)
                       (agentedit-review-session-projection-b session)))
    (with-current-buffer buffer
      (agentedit-review--decorate-fragment session agentedit-review--projection-role)
      (goto-char agentedit-review--fragment-start)
      (let ((window (get-buffer-window buffer t)))
        (when window
          (set-window-point window (point))
          (with-selected-window window (recenter))))))
  (force-mode-line-update t))

;;;###autoload
(defun agentedit-review-edit ()
  "Edit only the active result fragment.
C-c C-c stages it without applying or saving; C-c C-k cancels this transaction."
  (interactive)
  (let ((session (agentedit-review--require-review t)))
    (condition-case problem
        (progn
          (agentedit-review--validate-projections session)
          (unless (eq (agentedit-review-session-state session) 'editing)
            (setf (agentedit-review-session-edit-entry session)
                  (agentedit-review-session-draft session))
            (agentedit-review--transition session 'editing))
          (pop-to-buffer (agentedit-review-session-projection-b session))
          (setq buffer-read-only nil)
          (buffer-enable-undo)
          (goto-char agentedit-review--fragment-start)
          (agentedit-review--decorate-fragment session "edited")
          (force-mode-line-update t)
          (message "Editing result fragment; context is read-only. C-c C-c stage, C-c C-k cancel."))
      ((error quit) (agentedit-review--draft-failed session problem)))))

(defun agentedit-review--seed (original)
  "Seed the live fragment with the ORIGINAL or proposed text, preserving entry."
  (let* ((session (agentedit-review--require-review t))
         (record (agentedit-review--current-record session))
         (live (agentedit-review--live-draft session)))
    (condition-case problem
        (progn
          (agentedit-review-edit)
          (when (eq (agentedit-review-session-state session) 'editing)
            (with-current-buffer (agentedit-review-session-projection-b session)
              (undo-boundary)
              (atomic-change-group
                (delete-region agentedit-review--fragment-start agentedit-review--fragment-end)
                (goto-char agentedit-review--fragment-start)
                (insert (if original (agentedit-review-record-original record)
                          (agentedit-review-record-edited record))))
              (undo-boundary)
              (goto-char agentedit-review--fragment-start)
              (agentedit-review--decorate-fragment session "edited"))))
      ((error quit)
       (agentedit-review--preserve-draft session live)
       (agentedit-review--draft-failed session problem)))))

(defun agentedit-review-seed-original ()
  "Start or continue editing from the original text; do not apply or save."
  (interactive)
  (agentedit-review--seed t))

(defun agentedit-review-seed-proposed ()
  "Start or continue editing from the proposal; cancel restores the entry draft."
  (interactive)
  (agentedit-review--seed nil))

(defun agentedit-review--end-edit (cancel)
  "Stage the live draft, or CANCEL to the snapshot from editing entry."
  (let* ((session (agentedit-review--require-review t))
         (live (agentedit-review--live-draft session)))
    (unless (eq (agentedit-review-session-state session) 'editing)
      (user-error "No edit transaction is active; use C-c e"))
    (condition-case problem
        (progn
          (agentedit-review--validate-projections session)
          (let ((draft (if cancel (agentedit-review-session-edit-entry session)
                         (agentedit-review--live-draft session))))
            ;; Keep live recovery material until refresh has succeeded.
            (setf (agentedit-review-session-draft session) draft)
            (when cancel
              (with-current-buffer (agentedit-review-session-projection-b session)
                (agentedit-review--fill-projection session "edited")))
            (agentedit-review--refresh session)
            (agentedit-review--transition session 'reviewing)
            (setf (agentedit-review-session-edit-entry session) nil)
            (with-current-buffer (agentedit-review-session-projection-b session)
              (setq buffer-read-only t)
              (set-buffer-modified-p nil)
              (agentedit-review--decorate-fragment session "edited"))
            (pop-to-buffer (agentedit-review-session-control session))
            (force-mode-line-update t)
            (message "AgentEdit: %s; no source change. A applies the result."
                     (if cancel "draft restored" "draft staged"))))
      ((error quit)
       (agentedit-review--preserve-draft session live)
       (agentedit-review--draft-failed session problem)))))

(defun agentedit-review-stage ()
  "Stage the active live draft and refresh Ediff, without applying or saving."
  (interactive)
  (agentedit-review--end-edit nil))

(defun agentedit-review-cancel-edit ()
  "Restore the draft from entry into editing, including changes made by seeds."
  (interactive)
  (agentedit-review--end-edit t))

(defun agentedit-review-toggle-context ()
  "Toggle paragraph and full current-source-file context, retaining the draft."
  (interactive)
  (let ((session (agentedit-review--require-review)))
    (condition-case problem
        (progn
          (agentedit-review--validate-projections session)
          (setf (agentedit-review-session-full-context session)
                (not (agentedit-review-session-full-context session)))
          (agentedit-review--refresh session t)
          (pop-to-buffer (agentedit-review-session-control session)))
      ((error quit) (agentedit-review--draft-failed session problem)))))

(defun agentedit-review--counts (session)
  "Return SESSION counts as a display string."
  (format "%d accepted, %d rejected, %d skipped"
          (agentedit-review-session-accepted session)
          (agentedit-review-session-rejected session)
          (agentedit-review-session-skipped session)))

(defun agentedit-review--unsaved-label (session)
  "Return the live source status text for SESSION."
  (let* ((sources (agentedit-review--session-sources session))
         (plural (> (length sources) 1))
         (modified (cl-some (lambda (source)
                              (and (buffer-live-p source)
                                   (buffer-modified-p source)))
                            sources)))
    (format "%s %s"
            (if plural "sources" "source")
            (if modified "unsaved" "unchanged"))))

(defun agentedit-review--truncate (text width)
  "Truncate TEXT to nonnegative WIDTH, adding an ellipsis when needed."
  (truncate-string-to-width text (max 0 width) nil nil "…"))

(defun agentedit-review--header-format ()
  "Compose the width-bounded AgentEdit control-buffer header."
  (let* ((width (max 20 (window-body-width)))
         (prefix (format "%s  ID: " agentedit-review--display-pass))
         (id-width (max 4 (- width (string-width prefix) 18)))
         (required (format "%s%s  Reason: "
                           prefix
                           (agentedit-review--truncate
                            agentedit-review--display-id id-width)))
         (location (format "  Source: %s:%s"
                           agentedit-review--display-source
                           agentedit-review--display-location))
         (reason-width (- width (string-width required)))
         (with-location (>= reason-width (+ 12 (string-width location)))))
    (setq agentedit-review--header-required
          (propertize required 'face 'mode-line-emphasis)
          agentedit-review--header-reason
          (agentedit-review--truncate
           agentedit-review--display-reason
           (if with-location (- reason-width (string-width location)) reason-width))
          agentedit-review--header-location (if with-location location ""))
    '(agentedit-review--header-required
      agentedit-review--header-reason
      agentedit-review--header-location)))

(defun agentedit-review--mode-line-format ()
  "Prioritize editing state, save policy, and actions at narrow widths."
  (let* ((session agentedit-review--session)
         (width (max 20 (window-body-width)))
         (editing (eq (agentedit-review-session-state session) 'editing))
         (record (agentedit-review--current-record session))
         (file (and record (agentedit-review--file-state session (agentedit-review--record-source record))))
         (policy (if (agentedit-review-session-auto-save session) "AUTO" "MANUAL"))
         (state (cond (editing "EDITING")
                      ((and record (agentedit-review-session-draft session)
                            (not (equal (agentedit-review-session-draft session)
                                        (agentedit-review-record-edited record)))) "CUSTOM")
                      (t "PROPOSED")))
         (saved (if (and file (eq (agentedit-review-file-save-status file) 'saved)) "saved" "unsaved"))
         (controls (if editing
                       (format "EDIT %s C-c C-c stage C-c C-k cancel" policy)
                     (format "%s %s %s A/R/S q" state policy saved)))
         (hints " · C-c e edit · C-c w context · C-c l report")
         (counts (concat " · " (agentedit-review--counts session))))
    (setq agentedit-review--mode-controls
          (propertize (agentedit-review--truncate controls width) 'face 'mode-line-emphasis)
          agentedit-review--mode-status
          (if (<= (+ (string-width controls) (string-width hints)) width) hints "")
          agentedit-review--mode-counts
          (if (<= (+ (string-width controls) (string-width hints) (string-width counts)) width)
              counts ""))
    '(agentedit-review--mode-controls agentedit-review--mode-status agentedit-review--mode-counts)))

(defun agentedit-review--install-control (session record)
  "Install SESSION controls and RECORD presentation in the current buffer."
  (setq-local agentedit-review--session session)
  (setq-local agentedit-review--display-pass
              (format "AgentEdit %d / %d"
                      (1+ (agentedit-review-session-index session))
                      (length (agentedit-review-session-records session))))
  (setq-local agentedit-review--display-id
              (agentedit-review--normalize-one-line
               (agentedit-review-record-id record)))
  (setq-local agentedit-review--display-reason
              (agentedit-review--normalize-one-line
               (agentedit-review-record-reason record)))
  (setq-local agentedit-review--display-source
              (agentedit-review--source-label
               (agentedit-review--record-source record)))
  (setq-local agentedit-review--display-location
              (number-to-string (agentedit-review--record-line record)))
  (use-local-map (copy-keymap (current-local-map)))
  (local-set-key (kbd "A") #'agentedit-review--accept)
  (local-set-key (kbd "R") #'agentedit-review--reject)
  (local-set-key (kbd "S") #'agentedit-review--skip)
  (local-set-key (kbd "q") #'agentedit-review--quit)
  (agentedit-review--install-context-keys)
  (dolist (key '("a" "b" "r" "w" "~"))
    (local-set-key (kbd key) #'agentedit-review--native-mutation-refused))
  (setq-local header-line-format '((:eval (agentedit-review--header-format))))
  (setq-local mode-line-format '((:eval (agentedit-review--mode-line-format))))
  (add-hook 'ediff-cleanup-hook #'agentedit-review--cleanup nil t)
  (add-hook 'kill-buffer-hook #'agentedit-review--control-killed nil t))

(defun agentedit-review--mark-current-hunk (overlay sign face)
  "Put display-only SIGN with FACE before current-difference OVERLAY."
  (when (overlayp overlay)
    (overlay-put overlay 'before-string
                 (propertize sign 'face face 'rear-nonsticky t))))

(defun agentedit-review--install-control-visuals ()
  "Enable the AgentEdit visual treatment in the current Ediff control buffer."
  (setq-local ediff-auto-refine 'on)
  (agentedit-review--mark-current-hunk
   ediff-current-diff-overlay-A "− " 'agentedit-review-original-label)
  (agentedit-review--mark-current-hunk
   ediff-current-diff-overlay-B "+ " 'agentedit-review-proposed-label)
  (when (> ediff-number-of-differences 0)
    (if (< ediff-current-difference 0)
        (ediff-jump-to-difference 1)
      (when (fboundp 'ediff-install-fine-diff-if-necessary)
        (ediff-install-fine-diff-if-necessary ediff-current-difference)))))

(defun agentedit-review--emit-announcement (session)
  "Emit and clear SESSION's one pending announcement."
  (let ((announcement (agentedit-review-session-pending-announcement session)))
    (when announcement
      (setf (agentedit-review-session-pending-announcement session) nil)
      (message "%s" announcement))))

(defun agentedit-review--open-current (session)
  "Open SESSION's current record in a new Ediff pair."
  (when (and (memq (agentedit-review-session-state session) '(starting deciding))
             (cl-every (lambda (key) (eq (gethash key agentedit-review--sessions) session))
                       (agentedit-review-session-lock-keys session)))
  (setf (agentedit-review-session-timer session) nil)
  (let* ((was-starting
          (eq (agentedit-review-session-state session) 'starting))
         (record (agentedit-review--current-record session))
         (id (agentedit-review-record-id record))
         buffer-a buffer-b
         (startup
          (lambda ()
            (setf (agentedit-review-session-control session) (current-buffer))
            (agentedit-review--install-control session record)
            (agentedit-review--install-control-visuals)
            (agentedit-review--transition session 'reviewing)
            (agentedit-review--emit-announcement session))))
    ;; The previous record is already accounted for before continuation.  A
    ;; failure while building this view belongs to the new owning file.
    (setf (agentedit-review-session-applied-decision session) nil
          (agentedit-review-session-completed-decision session) nil
          (agentedit-review-session-completed-record session) nil)
    (condition-case error-data
        (let ((ediff-startup-hook (cons startup ediff-startup-hook)))
          (message "AgentEdit: building contextual comparison...")
          (setf (agentedit-review-session-view session) nil
                (agentedit-review-session-draft session) (agentedit-review-record-edited record)
                (agentedit-review-session-edit-entry session) nil
                (agentedit-review-session-cleanup-complete session) nil)
          (setf (agentedit-review-session-view session) (agentedit-review--build-view session))
          (agentedit-review--select-context session)
          (setq buffer-a (agentedit-review--make-projection
                          session "original" (agentedit-review-record-original record) id))
          (setf (agentedit-review-session-projection-a session) buffer-a)
          (setq buffer-b
                (agentedit-review--make-projection
                 session "edited" (agentedit-review-record-edited record) id))
          (setf (agentedit-review-session-projection-b session) buffer-b)
          (ediff-buffers buffer-a buffer-b))
      ((error quit)
       (setf (agentedit-review-session-pending-announcement session) nil
             (agentedit-review-session-last-error session)
             (format "could not start Ediff: %s"
                     (error-message-string error-data)))
       (agentedit-review--note-current-file-error
        session (agentedit-review-session-last-error session))
       (unless (agentedit-review--terminal-state-p
                (agentedit-review-session-state session))
         (agentedit-review--transition session 'failed))
       (agentedit-review--force-terminal-cleanup session)
       (when was-starting
         (user-error "AgentEdit could not start Ediff: %s"
                     (error-message-string error-data))))))))

(defun agentedit-review--release (session)
  "Idempotently release temporary resources and terminal lock for SESSION."
  (when (memq (agentedit-review-session-state session) '(failed stale partial-failure))
    (agentedit-review--preserve-draft session))
  (unless (agentedit-review-session-cleanup-in-progress session)
    (setf (agentedit-review-session-cleanup-in-progress session) t)
    (unwind-protect
        (dolist (buffer (list (agentedit-review-session-projection-a session)
                              (agentedit-review-session-projection-b session)))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))
      (setf (agentedit-review-session-projection-a session) nil
            (agentedit-review-session-projection-b session) nil
            (agentedit-review-session-cleanup-in-progress session) nil)))
  (when (agentedit-review--terminal-state-p
         (agentedit-review-session-state session))
    (when (timerp (agentedit-review-session-timer session))
      (cancel-timer (agentedit-review-session-timer session)))
    (setf (agentedit-review-session-timer session) nil
          (agentedit-review-session-view session) nil)
    (agentedit-review--render-report session)
    (dolist (key (or (agentedit-review-session-lock-keys session)
                     (and (agentedit-review-session-lock-key session)
                          (list (agentedit-review-session-lock-key session)))))
      (when (eq (gethash key agentedit-review--sessions) session)
        (remhash key agentedit-review--sessions)))))

(defun agentedit-review--terminal-message (session)
  "Return the terminal status message for SESSION."
  (let ((counts (agentedit-review--counts session))
        (state (agentedit-review-session-state session))
        (record (agentedit-review--current-record session)))
    (pcase state
      ('finished
       (format "AgentEdit review complete: %s; %s%s."
               counts
               (format "%d files saved; %s"
                       (cl-count 'saved (agentedit-review-session-files session)
                                 :key #'agentedit-review-file-save-status)
                       (if (agentedit-review-session-auto-save session)
                           "see report for current file status" "manual save mode"))
               (if (> (agentedit-review-session-skipped session) 0)
                   "; skipped markers remain unresolved" "")))
      ('aborting
       (format "AgentEdit review stopped: %s; %d unvisited markers remain unchanged.%s"
               counts
               (- (length (agentedit-review-session-records session))
                  (agentedit-review-session-index session))
               (if (agentedit-review-session-last-error session)
                   (format " %s." (agentedit-review-session-last-error session))
                 "")))
      ('stale
       (format "Review stopped at %s: source changed. No decision applied. %s. Inspect this marker and restart.%s"
               (if record
                   (agentedit-review--normalize-one-line
                    (agentedit-review-record-id record))
                 "the current marker")
               counts
               (if (agentedit-review-session-last-error session)
                   (format " Ediff cleanup also failed: %s."
                           (agentedit-review-session-last-error session))
                 "")))
      ('partial-failure
       (format "%s: %s; %s; %s. See M-x agentedit-review-report."
               (cond ((agentedit-review-session-save-confirmed session) "Saved; review stopped")
                     ((not (agentedit-review-session-auto-save session)) "Applied; unsaved (manual mode); review stopped")
                     (t "Applied; save not confirmed"))
               (or (agentedit-review-session-last-error session)
                   "unknown error")
               counts
               (let* ((completed (agentedit-review-session-completed-record session))
                      (file (and completed (agentedit-review--file-state
                                            session (agentedit-review--record-source completed)))))
                 (if file (format "%s: %s" (agentedit-review-file-path file)
                                  (agentedit-review--file-save-label file))
                   "see per-file report"))))
      (_
       (if (eq (agentedit-review-session-completed-decision session) 'skip)
           (format "Skip recorded for %s, but Ediff teardown failed: %s. No source text changed; %s."
                   (agentedit-review--normalize-one-line
                    (agentedit-review-record-id
                     (agentedit-review-session-completed-record session)))
                   (or (agentedit-review-session-last-error session)
                       "unknown error")
                   counts)
         (format "AgentEdit review failed before applying %s: %s. No decision applied; %s."
                 (if record
                     (agentedit-review--normalize-one-line
                      (agentedit-review-record-id record))
                   "the current marker")
                 (or (agentedit-review-session-last-error session)
                     "unknown error")
                 counts))))))

(defun agentedit-review--cleanup ()
  "Release this record's panes; normal advancement waits for native teardown.
If Ediff is quit outside AgentEdit controls, stop the pass and rescue its draft."
  (let ((session agentedit-review--session))
    (when (and session (not (agentedit-review-session-cleanup-complete session)))
      (let ((external (not (agentedit-review-session-teardown-in-progress session))))
        (when external
          (setf (agentedit-review-session-last-error session)
                "Ediff was closed outside AgentEdit controls; review stopped"
                (agentedit-review-session-pending-action session) nil
                (agentedit-review-session-pending-announcement session) nil)
          (agentedit-review--note-current-file-error
           session (agentedit-review-session-last-error session))
          (unless (agentedit-review--terminal-state-p (agentedit-review-session-state session))
            (agentedit-review--transition
             session (if (agentedit-review-session-applied-decision session)
                         'partial-failure 'failed)))
          (agentedit-review--preserve-draft session))
        (setf (agentedit-review-session-cleanup-complete session) t)
        (agentedit-review--release session)
        (when external
          (setf (agentedit-review-session-timer session)
                (run-at-time 0 nil #'agentedit-review--finish-external-quit session)))))))

(defun agentedit-review--finish-external-quit (session)
  "Show terminal status after an externally invoked native Ediff quit."
  (setf (agentedit-review-session-timer session) nil)
  (when (and (agentedit-review--terminal-state-p (agentedit-review-session-state session))
             (cl-every (lambda (key) (not (gethash key agentedit-review--sessions)))
                       (agentedit-review-session-lock-keys session)))
    (agentedit-review--finish-terminal session (agentedit-review--terminal-message session))))

(defun agentedit-review--after-teardown (session)
  "Advance SESSION only after all native Ediff quit hooks returned successfully."
  (when (eq (agentedit-review-session-pending-action session) 'finish)
    (agentedit-review--transition session 'finished))
  (setf (agentedit-review-session-pending-action session) nil)
  (if (agentedit-review--terminal-state-p (agentedit-review-session-state session))
      (progn
        (agentedit-review--release session)
        (agentedit-review--finish-terminal session (agentedit-review--terminal-message session)))
    (setf (agentedit-review-session-timer session)
          (run-at-time 0 nil #'agentedit-review--open-current session))))

(defun agentedit-review--finish-terminal (session message-text)
  "Return to SESSION's source and show MESSAGE-TEXT after Ediff cleanup."
  (let* ((record (if (agentedit-review-session-applied-decision session)
                     (agentedit-review-session-completed-record session)
                   (agentedit-review--current-record session)))
         (source (if record (agentedit-review--record-source record)
                   (agentedit-review-session-source session))))
    (when (buffer-live-p source)
      (pop-to-buffer source)
      (when (eq (agentedit-review-session-state session) 'stale)
        (let ((marker (and record (agentedit-review-record-start record))))
          (when (and marker (marker-position marker))
            (goto-char marker)
            (recenter)))))
    (message "%s  M-x agentedit-review-report for per-file results." message-text)))

(defun agentedit-review--control-killed ()
  "Fallback cleanup when an AgentEdit control buffer dies abnormally."
  (let ((session agentedit-review--session))
    (when (and session
               (not (agentedit-review-session-cleanup-complete session)))
      (unless (agentedit-review--terminal-state-p
               (agentedit-review-session-state session))
        (setf (agentedit-review-session-last-error session)
              "control buffer was killed")
        (agentedit-review--note-current-file-error session "control buffer was killed")
        (pcase (agentedit-review-session-state session)
          ('reviewing (agentedit-review--transition session 'failed))
          ('editing (agentedit-review--transition session 'failed))
          ('starting (agentedit-review--transition session 'failed))
          ('deciding
           (agentedit-review--transition
            session
            (if (agentedit-review-session-applied-decision session)
                'partial-failure
              'failed)))))
      (agentedit-review--release session))))

(defun agentedit-review--projection-killed ()
  "Fail the owning pass when a projection is killed outside cleanup."
  (let ((session agentedit-review--session))
    (when (and session
               (not (agentedit-review-session-cleanup-in-progress session))
               (not (agentedit-review--terminal-state-p
                     (agentedit-review-session-state session))))
      (agentedit-review--preserve-draft session)
      (setf (agentedit-review-session-last-error session)
            (format "%s projection was killed"
                    (or agentedit-review--projection-role "review")))
      (agentedit-review--note-current-file-error
       session (agentedit-review-session-last-error session))
      (agentedit-review--transition
       session
       (if (agentedit-review-session-applied-decision session)
           'partial-failure
         'failed))
      (setf (agentedit-review-session-timer session)
            (run-at-time 0 nil #'agentedit-review--abort-after-projection-kill session)))))

(defun agentedit-review--abort-after-projection-kill (session)
  "Tear down SESSION after an externally killed projection."
  (let ((control (agentedit-review-session-control session)))
    (if (buffer-live-p control)
        (with-current-buffer control
          (condition-case error-data
              (agentedit-review--ediff-really-quit)
            ((error quit)
             (setf (agentedit-review-session-last-error session)
                   (format "%s; Ediff cleanup failed: %s"
                           (or (agentedit-review-session-last-error session)
                               "projection was killed")
                           (error-message-string error-data)))
             (agentedit-review--note-current-file-error
              session (agentedit-review-session-last-error session))
             (agentedit-review--force-terminal-cleanup session))))
      (agentedit-review--release session))))

(defun agentedit-review--ediff-really-quit ()
  "Quit the current AgentEdit Ediff session, then arrange safe advancement."
  (agentedit-review--check-ediff-compatibility)
  (let ((session agentedit-review--session))
    (setf (agentedit-review-session-teardown-in-progress session) t)
    (unwind-protect
        (progn
          (ediff-really-quit nil)
          (agentedit-review--after-teardown session))
      (setf (agentedit-review-session-teardown-in-progress session) nil))))

(defun agentedit-review--force-terminal-cleanup (session)
  "Release SESSION after Ediff cannot complete its own teardown."
  (setf (agentedit-review-session-pending-action session) nil
        (agentedit-review-session-pending-announcement session) nil)
  (agentedit-review--release session)
  (let ((control (agentedit-review-session-control session)))
    (when (buffer-live-p control)
      (setf (agentedit-review-session-cleanup-complete session) t)
      (kill-buffer control)))
  (agentedit-review--finish-terminal session (agentedit-review--terminal-message session)))

(defun agentedit-review--source-ready (record)
  "Signal unless RECORD's source remains safe to mutate."
  (let ((source (agentedit-review--record-source record)))
    (unless (buffer-live-p source)
      (error "source buffer was killed"))
    (with-current-buffer source
      (when buffer-read-only
        (error "source buffer became read-only"))
      (when (buffer-narrowed-p)
        (error "source buffer became narrowed; widen and restart"))
      (when (eq buffer-undo-list t)
        (error "undo became disabled")))))

(defun agentedit-review--validate-frame-context (record)
  "Refuse a stale RECORD and re-establish lexical visibility from buffer start."
  (let ((start (marker-position (agentedit-review-record-start record)))
        (end (marker-position (agentedit-review-record-end record))))
    (unless (and (equal (agentedit-review--left-context start)
                        (agentedit-review-record-left-context record))
                 (equal (agentedit-review--right-context end)
                        (agentedit-review-record-right-context record))
                 (condition-case nil
                     (cl-find-if
                      (lambda (fresh)
                        (and (agentedit-review-record-framed fresh)
                             (= start (marker-position (agentedit-review-record-start fresh)))
                             (= end (marker-position (agentedit-review-record-end fresh)))))
                      (save-excursion (agentedit-review--scan-records (point-min))))
                   (user-error nil)))
      (signal 'agentedit-review-stale nil))))

(defun agentedit-review--context-updates (session start end replacement)
  "Derive queued witnesses from the known splice START END REPLACEMENT.
Validate old witnesses before rebasing; never adopt arbitrary live context."
  (let* ((source (current-buffer))
         (before (buffer-substring-no-properties (point-min) (point-max)))
         (after (concat (substring before 0 (1- start)) replacement
                        (substring before (1- end))))
         (delta (- (length replacement) (- end start)))
         candidates updates)
    (dolist (record (nthcdr (1+ (agentedit-review-session-index session))
                            (agentedit-review-session-records session)))
      (when (and (agentedit-review-record-framed record)
                 (eq source (agentedit-review--record-source record)))
        (let ((left (marker-position (agentedit-review-record-start record)))
              (right (marker-position (agentedit-review-record-end record))))
          (push (list record left right (agentedit-review--left-context left)
                      (agentedit-review--right-context right)) candidates))))
    ;; Materialize the expected source once for all remaining records.
    (with-temp-buffer
      (insert after)
      (dolist (candidate candidates)
        (pcase-let* ((`(,record ,left ,right ,old-left ,old-right) candidate)
                     (new-context
                      (list (agentedit-review--left-context (+ left delta))
                            (agentedit-review--right-context (+ right delta)))))
          (unless (equal (list old-left old-right) new-context)
            (unless (and (equal old-left (agentedit-review-record-left-context record))
                         (equal old-right (agentedit-review-record-right-context record)))
              (signal 'agentedit-review-stale nil))
            (push (cons record new-context) updates)))))
    updates))

;; Own: P | % EOL START EOL macro(old,new) W % EOL END EOL | S
;; Keep: P | chosen W                                       | S
(defun agentedit-review--replace-current (session replacement)
  "Replace SESSION's current owned frame with REPLACEMENT and retained whitespace."
  (let* ((record (agentedit-review--current-record session))
         (start (agentedit-review-record-start record))
         (end (agentedit-review-record-end record))
         (source (agentedit-review--record-source record)))
    (agentedit-review--source-ready record)
    (unless (and (marker-position start) (marker-position end)
                 (eq (marker-buffer start) source) (eq (marker-buffer end) source))
      (error "marker position is no longer live"))
    (with-current-buffer source
      (unless (string= (buffer-substring-no-properties start end)
                       (agentedit-review-record-snapshot record))
        (signal 'agentedit-review-stale nil))
      (when (agentedit-review-record-framed record)
        (agentedit-review--validate-frame-context record))
      (let* ((text (concat replacement (agentedit-review-record-whitespace record)))
             (updates (agentedit-review--context-updates session start end text)))
        (undo-boundary)
        (atomic-change-group
          (delete-region start end)
          (goto-char start)
          (insert text)
          (dolist (update updates)
            (let ((queued (car update)))
              (unless (equal (cdr update)
                             (list (agentedit-review--left-context (agentedit-review-record-start queued))
                                   (agentedit-review--right-context (agentedit-review-record-end queued))))
                (signal 'agentedit-review-stale nil)))))
        (dolist (update updates)
          (setf (agentedit-review-record-left-context (car update)) (cadr update)
                (agentedit-review-record-right-context (car update)) (caddr update)))
        (undo-boundary)))))

(define-error 'agentedit-review-stale "AgentEdit source snapshot is stale")

(defun agentedit-review--next-announcement (session action record)
  "Return the combined ACTION and next-record announcement for SESSION.
RECORD is the record whose decision just completed."
  (let ((next (agentedit-review--current-record session)))
    (format "%s %s · Next %d / %d %s · Source: %s:%d · Reason: %s · A accept, R reject, S skip, q quit"
            action
            (agentedit-review--normalize-one-line
             (agentedit-review-record-id record))
            (1+ (agentedit-review-session-index session))
            (length (agentedit-review-session-records session))
            (agentedit-review--normalize-one-line
             (agentedit-review-record-id next))
            (agentedit-review--source-label (agentedit-review--record-source next))
            (agentedit-review--record-line next)
            (agentedit-review--normalize-one-line
             (agentedit-review-record-reason next)))))

(defun agentedit-review--decision-failed (session record problem)
  "Stop SESSION at RECORD after PROBLEM, retaining actual application/save facts."
  (let ((file (agentedit-review--file-state session (agentedit-review--record-source record))))
    (when file (setf (agentedit-review-file-error file) (error-message-string problem))))
  ;; A late Ediff hook may fail after its cleanup hook has already run.
  ;; Rescue describes the completed operation, even from a terminal state.
  (setf (agentedit-review-session-state session)
        (cond ((agentedit-review-session-applied-decision session) 'partial-failure)
              ((eq (car problem) 'agentedit-review-stale) 'stale)
              (t 'failed))
        (agentedit-review-session-last-error session) (error-message-string problem)
        (agentedit-review-session-pending-action session) nil
        (agentedit-review-session-pending-announcement session) nil)
  (condition-case cleanup-problem
      (let ((control (agentedit-review-session-control session)))
        (if (and (buffer-live-p control)
                 (not (agentedit-review-session-cleanup-complete session)))
            (with-current-buffer control (agentedit-review--ediff-really-quit))
          (agentedit-review--force-terminal-cleanup session)))
    ((error quit)
     (setf (agentedit-review-session-last-error session)
           (format "%s; Ediff cleanup failed: %s"
                   (error-message-string problem) (error-message-string cleanup-problem)))
     (agentedit-review--note-current-file-error
      session (agentedit-review-session-last-error session))
     (agentedit-review--force-terminal-cleanup session))))

(defun agentedit-review--custom-draft-p (session)
  "Return non-nil if SESSION has a staged or live custom result."
  (let ((record (agentedit-review--current-record session)))
    (and record (agentedit-review-session-view session)
         (not (equal (if (eq (agentedit-review-session-state session) 'editing)
                         (agentedit-review--live-draft session)
                       (agentedit-review-session-draft session))
                     (agentedit-review-record-edited record))))))

(defun agentedit-review--decision (kind)
  "Apply KIND once, verify saving if enabled, then advance after teardown."
  (let* ((session agentedit-review--session)
         (record (and session (agentedit-review--current-record session))))
    (unless (memq kind '(accept reject skip))
      (error "Unknown AgentEdit decision: %s" kind))
    (unless (and session (eq (agentedit-review-session-state session) 'reviewing))
      (user-error "Stage with C-c C-c or cancel with C-c C-k before A/R/S"))
    (when (or (not (and (eq kind 'skip) (agentedit-review--custom-draft-p session)))
              (y-or-n-p "Discard custom draft and skip this record? "))
      (agentedit-review--transition session 'deciding)
      (setf (agentedit-review-session-applied-decision session) nil
            (agentedit-review-session-save-confirmed session) nil
            (agentedit-review-session-completed-decision session) nil
            (agentedit-review-session-completed-record session) nil)
      (condition-case problem
          (let (expected)
            (agentedit-review--check-ediff-compatibility)
            (when (agentedit-review-session-view session)
              (agentedit-review--validate-projections session))
            (unless (eq kind 'skip)
              (agentedit-review--save-preflight session record)
              (let ((replacement (if (eq kind 'reject)
                                     (agentedit-review-record-original record)
                                   (if (agentedit-review-session-view session)
                                       (agentedit-review-session-draft session)
                                     (agentedit-review-record-edited record)))))
                (setq expected (agentedit-review--expected-source record replacement))
                (agentedit-review--replace-current session replacement))
              (setf (agentedit-review-session-applied-decision session) kind))
            (agentedit-review--record-decision session record kind)
            (when (agentedit-review-session-applied-decision session)
              (agentedit-review--save-decision session record expected))
            (if (agentedit-review--current-record session)
                (setf (agentedit-review-session-pending-action session) 'continue
                      (agentedit-review-session-pending-announcement session)
                      (agentedit-review--next-announcement
                       session
                       (format "%s; %s %s"
                               (pcase kind ('accept "Accepted") ('reject "Rejected") (_ "Skipped"))
                               (cond ((eq kind 'skip) "unchanged")
                                     ((agentedit-review-session-save-confirmed session) "Saved")
                                     (t "Applied; unsaved"))
                               (agentedit-review--source-label (agentedit-review--record-source record)))
                       record))
              (setf (agentedit-review-session-pending-action session) 'finish))
            (agentedit-review--ediff-really-quit))
        ((error quit) (agentedit-review--decision-failed session record problem))))))

(defun agentedit-review--accept ()
  "Apply the staged result as one undoable edit, saving under session policy."
  (interactive)
  (agentedit-review--decision 'accept))

(defun agentedit-review--reject ()
  "Restore this proposal's original, saving under session policy."
  (interactive)
  (agentedit-review--decision 'reject))

(defun agentedit-review--skip ()
  "Leave this wrapper unchanged, record a skip, and open the next proposal."
  (interactive)
  (agentedit-review--decision 'skip))

(defun agentedit-review--quit ()
  "Stop after confirmation; discard the current draft and keep applied edits."
  (interactive)
  (let ((session agentedit-review--session))
    (unless (and session
                 (memq (agentedit-review-session-state session) '(reviewing editing)))
      (user-error "No AgentEdit review is active"))
    (let ((remaining
           (- (length (agentedit-review-session-records session))
              (1+ (agentedit-review-session-index session)))))
      (when (y-or-n-p
             (format "Stop review? %s%s stay applied; current and %d unvisited markers stay unchanged "
                     (if (agentedit-review--custom-draft-p session) "Discard custom draft. " "")
                     (agentedit-review--counts session) remaining))
        (agentedit-review--transition session 'aborting)
        (condition-case error-data
            (agentedit-review--ediff-really-quit)
          ((error quit)
           (setf (agentedit-review-session-last-error session)
                 (format "Ediff cleanup failed while stopping: %s"
                         (error-message-string error-data)))
           (agentedit-review--note-current-file-error
            session (agentedit-review-session-last-error session))
           (agentedit-review--force-terminal-cleanup session)))))))

(defun agentedit-review--auctex-master-file ()
  "Return the absolute AUCTeX master for the current buffer.

When `TeX-master' is unresolved, use AUCTeX's native prompt and persistence
semantics."
  (unless (agentedit-review--auctex-project-capable-p)
    (user-error "Project review requires AUCTeX master and parser APIs"))
  (let ((master (TeX-master-file t nil t)))
    (unless (and master (not (string-empty-p master)))
      (user-error "No AUCTeX master file selected"))
    (let ((absolute (expand-file-name master default-directory)))
      (unless (file-readable-p absolute)
        (user-error "AUCTeX master is not readable: %s" absolute))
      absolute)))

(defun agentedit-review--auctex-inputs (buffer master-directory)
  "Return BUFFER's existing TeX inputs in AUCTeX parse order.
Resolve input paths relative to MASTER-DIRECTORY, as AUCTeX does for the
document compilation context."
  (with-current-buffer buffer
    (let ((TeX-auto-file nil)
          paths)
      (save-excursion
        (save-restriction
          (widen)
          ;; Parsing the live buffer avoids stale auto/ data and does not save
          ;; either the source or AUCTeX's generated style cache.
          (TeX-auto-parse)))
      (dolist (name TeX-auto-file (nreverse paths))
        (when (stringp name)
          (let* ((extension (file-name-extension name))
                 (candidate (expand-file-name name master-directory)))
            ;; AUCTeX normally removes the final TeX extension from inputs.
            (unless (and extension
                         (member (downcase extension) '("tex" "ltx")))
              (setq candidate (concat candidate ".tex")))
            (when (and (file-regular-p candidate)
                       (file-readable-p candidate))
              (push (file-truename candidate) paths))))))))

(defun agentedit-review--auctex-project-buffers (master-file)
  "Return AUCTeX source buffers reachable from MASTER-FILE in document order."
  (let ((master-directory (file-name-directory master-file))
        (seen (make-hash-table :test #'equal))
        buffers)
    (cl-labels
        ((visit
           (file)
           (let ((canonical (file-truename file)))
             (unless (gethash canonical seen)
               (puthash canonical t seen)
               (let ((buffer (find-file-noselect canonical)))
                 (push buffer buffers)
                 (dolist (input (agentedit-review--auctex-inputs
                                 buffer master-directory))
                   (visit input)))))))
      (visit master-file))
    (nreverse buffers)))

(defun agentedit-review--validate-project-ids (records)
  "Signal when RECORDS reuse an AgentEdit ID across source files."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (record records)
      (let* ((id (agentedit-review-record-id record))
             (previous (gethash id seen)))
        (when previous
          (user-error
           "Duplicate AgentEdit ID %s at %s:%d (first at %s:%d)"
           id
           (agentedit-review--source-label
            (agentedit-review--record-source record))
           (agentedit-review--record-line record)
           (agentedit-review--source-label
            (agentedit-review--record-source previous))
           (agentedit-review--record-line previous)))
        (puthash id record seen)))))

(defun agentedit-review--begin (source sources records empty-message)
  "Start a review from SOURCE across SOURCES and RECORDS.
Show EMPTY-MESSAGE when RECORDS is empty."
  (let ((session (agentedit-review--make-session
                  :source source :sources sources :records records
                  :auto-save (buffer-local-value 'agentedit-review-auto-save source))))
    (agentedit-review--lock-session session sources)
    (setq agentedit-review--last-session session)
    (condition-case error-data
        (progn
          (agentedit-review--initialize-files session)
          (dolist (record records)
            (agentedit-review--save-preflight session record))
          (if (null records)
            (progn
              (agentedit-review--transition session 'finished)
              (agentedit-review--release session)
              (agentedit-review--render-report session)
              (message "%s" empty-message))
          (let* ((record (agentedit-review--current-record session))
                 (record-source (agentedit-review--record-source record))
                 (location (format "%s:%d"
                                   (agentedit-review--source-label record-source)
                                   (agentedit-review--record-line record))))
            (setf (agentedit-review-session-pending-announcement session)
                  (format
                   "AgentEdit 1 / %d %s · %s · Reason: %s · A accept, R reject, S skip, q quit · C-c e edit, C-c w context, C-c l report · %s"
                   (length records)
                   (agentedit-review--normalize-one-line
                    (agentedit-review-record-id record))
                   location
                   (agentedit-review--normalize-one-line
                    (agentedit-review-record-reason record))
                   (if (agentedit-review-session-auto-save session)
                       "A/R saves the WHOLE owning source, including existing unsaved edits"
                     "MANUAL save: A/R leaves source buffers unsaved")))
            (agentedit-review--open-current session))))
      ((error quit)
       (unless (agentedit-review--terminal-state-p
                (agentedit-review-session-state session))
         (agentedit-review--transition session 'failed))
       (setf (agentedit-review-session-last-error session) (error-message-string error-data))
       (agentedit-review--release session)
       (signal (car error-data) (cdr error-data))))))

(defun agentedit-review--review-buffer ()
  "Review markers at or after point in the current TeX buffer."
  (agentedit-review--preflight)
  (let ((source (current-buffer))
        (origin (point))
        records)
    (message "Scanning AgentEdit markers from point...")
    (save-restriction
      (widen)
      (save-excursion
        (setq records (agentedit-review--scan-records origin))))
    (agentedit-review--begin
     source (list source) records "No AgentEdit markers at or after point.")))

(defun agentedit-review--review-project ()
  "Review every marker in the current AUCTeX master document.

The command honors `TeX-master', parses the live master and its inputs with
AUCTeX, and visits markers in document-file order.  If `TeX-master' is unset,
it uses AUCTeX's native master prompt.  Decisions are undoable.  A/R save
the individual source buffers by default."
  (agentedit-review--preflight)
  (unless (agentedit-review--auctex-project-capable-p)
    (user-error "Project review requires AUCTeX master and parser APIs"))
  (let* ((source (current-buffer))
         (master-file (agentedit-review--auctex-master-file))
         (buffers (progn
                    (message "Scanning AUCTeX document from %s..."
                             (file-name-nondirectory master-file))
                    (agentedit-review--auctex-project-buffers master-file)))
         records)
    (dolist (buffer buffers)
      (with-current-buffer buffer
        (condition-case error-data
            (agentedit-review--preflight)
          (user-error
           (user-error "%s: %s"
                       (agentedit-review--source-label buffer)
                       (error-message-string error-data))))
        (save-restriction
          (widen)
          (save-excursion
            (setq records
                  (nconc records
                         (agentedit-review--scan-records (point-min))))))))
    (agentedit-review--validate-project-ids records)
    (agentedit-review--begin
     source buffers records
     (format "No AgentEdit markers in AUCTeX document %s."
             (file-name-nondirectory master-file)))))

;;;###autoload
(defun agentedit-review (&optional file-only)
  "Review AgentLaTeX markers with session-local Ediff keys.

In an AUCTeX-derived mode, review the complete master document.  In a built-in
TeX mode, review the current buffer at or after point.  With prefix argument
FILE-ONLY, review the current buffer at or after point in either mode family.

Accept and reject each produce one undoable source edit.  Skip and quit leave
undecided wrappers unchanged.  With `agentedit-review-auto-save' non-nil (the
default), A/R saves the entire owning source, including existing unsaved text.
C-c e edits the result, C-c w expands context, and C-c l opens the report."
  (interactive "P")
  (if (or file-only (not (agentedit-review--auctex-mode-p)))
      (agentedit-review--review-buffer)
    (agentedit-review--review-project)))

(provide 'agentedit-review)

;;; agentedit-review.el ends here
