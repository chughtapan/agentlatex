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

(cl-defstruct (agentedit-review-record
               (:constructor agentedit-review--make-record))
  id reason original edited start end snapshot source)

(cl-defstruct (agentedit-review-session
               (:constructor agentedit-review--make-session))
  source records (index 0) (accepted 0) (rejected 0) (skipped 0)
  (state 'starting) pending-action pending-announcement control
  projection-a projection-b cleanup-in-progress cleanup-complete lock-key
  sources lock-keys
  last-error applied-decision completed-decision completed-record)

(defconst agentedit-review--transitions
  '((starting . (reviewing finished failed))
    (reviewing . (deciding aborting failed))
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
  "Parse one braced argument at POSITION for the marker at MARKER-POSITION.
Return a list of the payload and the position after its closing brace."
  (save-excursion
    (goto-char position)
    (skip-chars-forward " \t\r\n")
    (unless (eq (char-after) ?{)
      (agentedit-review--line-error marker-position
                                    "expected four braced arguments"))
    (let* ((open (point))
           (close (condition-case nil (scan-sexps open 1) (scan-error nil))))
      (unless close
        (agentedit-review--line-error marker-position
                                      "unterminated braced argument"))
      (list (buffer-substring-no-properties (1+ open) (1- close)) close))))

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
                   "[ \t]*\\(?:%.*\\)?$")))
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

(defun agentedit-review--scan-records (origin)
  "Return valid review records whose control word begins at or after ORIGIN."
  (let ((records nil)
        (ids (make-hash-table :test #'equal))
        (cursor (point-min)))
    (while (< cursor (point-max))
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
              (let ((word (buffer-substring-no-properties (1+ cursor) word-end)))
                (cond
                 ((string= word "verb")
                  (setq cursor (agentedit-review--verb-end word-end cursor)))
                 ((string= word "begin")
                  (let ((parsed (agentedit-review--parse-environment-name word-end)))
                    (if (and parsed
                             (member (car parsed)
                                     agentedit-review-verbatim-environments))
                        (setq cursor
                              (agentedit-review--verbatim-end
                               (car parsed) (cadr parsed) cursor))
                      (setq cursor word-end))))
                 ((string= word "agentedit")
                  (if (< cursor origin)
                      (let ((end (condition-case nil
                                     (let ((scan word-end))
                                       (dotimes (_ 4)
                                         (setq scan
                                               (cadr
                                                (agentedit-review--parse-braced-at
                                                 scan cursor))))
                                       scan)
                                   (user-error word-end))))
                        (setq cursor end))
                    (let* ((record (agentedit-review--parse-record cursor word-end))
                           (id (agentedit-review-record-id record)))
                      (when (gethash id ids)
                        (agentedit-review--line-error
                         cursor "duplicate marker ID %s" id))
                      (puthash id t ids)
                      (push record records)
                      (setq cursor (marker-position
                                    (agentedit-review-record-end record))))))
                 (t (setq cursor word-end))))))))))
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
      (add-hook 'kill-buffer-hook #'agentedit-review--projection-killed nil t))
    buffer))

(defun agentedit-review--current-record (session)
  "Return SESSION's current record, or nil after the queue."
  (nth (agentedit-review-session-index session)
       (agentedit-review-session-records session)))

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
  "Compose the width-bounded AgentEdit control-buffer mode line."
  (let* ((session agentedit-review--session)
         (controls " A accept  R reject  S skip  q quit ")
         (counts (concat "  " (agentedit-review--counts session)))
         (status (concat "  " (agentedit-review--unsaved-label session)))
         (width (max 20 (window-body-width))))
    (setq agentedit-review--mode-controls
          (propertize controls 'face 'mode-line-emphasis)
          agentedit-review--mode-counts
          (if (>= width (+ (string-width controls) (string-width counts)))
              counts
            "")
          agentedit-review--mode-status
          (if (>= width (+ (string-width controls) (string-width counts)
                            (string-width status)))
              (propertize status 'face 'shadow)
            ""))
    '(agentedit-review--mode-controls
      agentedit-review--mode-counts
      agentedit-review--mode-status)))

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
  (let* ((was-starting
          (eq (agentedit-review-session-state session) 'starting))
         (record (agentedit-review--current-record session))
         (id (agentedit-review-record-id record))
         (buffer-a (agentedit-review--make-projection
                    session "original" (agentedit-review-record-original record) id))
         buffer-b
         (startup
          (lambda ()
            (setf (agentedit-review-session-control session) (current-buffer))
            (agentedit-review--install-control session record)
            (agentedit-review--install-control-visuals)
            (agentedit-review--transition session 'reviewing)
            (agentedit-review--emit-announcement session)
            (setf (agentedit-review-session-applied-decision session) nil
                  (agentedit-review-session-completed-decision session) nil
                  (agentedit-review-session-completed-record session) nil))))
    (setf (agentedit-review-session-projection-a session) buffer-a
          (agentedit-review-session-cleanup-complete session) nil)
    (condition-case error-data
        (let ((ediff-startup-hook (cons startup ediff-startup-hook)))
          (setq buffer-b
                (agentedit-review--make-projection
                 session "edited" (agentedit-review-record-edited record) id))
          (setf (agentedit-review-session-projection-b session) buffer-b)
          (ediff-buffers buffer-a buffer-b))
      (error
       (setf (agentedit-review-session-pending-announcement session) nil
             (agentedit-review-session-last-error session)
             (format "could not start Ediff: %s"
                     (error-message-string error-data)))
       (unless (agentedit-review--terminal-state-p
                (agentedit-review-session-state session))
         (agentedit-review--transition session 'failed))
       (agentedit-review--force-terminal-cleanup session)
       (when was-starting
         (user-error "AgentEdit could not start Ediff: %s"
                     (error-message-string error-data)))))))

(defun agentedit-review--release (session)
  "Idempotently release temporary resources and terminal lock for SESSION."
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
               counts (agentedit-review--unsaved-label session)
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
       (format "%s applied, but Ediff teardown failed: %s; %s; %s and normally undoable."
               (capitalize
                (symbol-name
                 (or (agentedit-review-session-applied-decision session)
                     'decision)))
               (or (agentedit-review-session-last-error session)
                   "unknown error")
               counts
               (agentedit-review--unsaved-label session)))
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
  "Primary Ediff cleanup hook for the current AgentEdit record."
  (let ((session agentedit-review--session))
    (when (and session
               (not (agentedit-review-session-cleanup-complete session)))
      (setf (agentedit-review-session-cleanup-complete session) t)
      (when (and (eq (agentedit-review-session-state session) 'deciding)
                 (eq (agentedit-review-session-pending-action session) 'finish))
        (setf (agentedit-review-session-pending-action session) nil)
        (agentedit-review--transition session 'finished))
      (when (eq (agentedit-review-session-pending-action session) 'continue)
        (setf (agentedit-review-session-pending-action session) nil))
      (agentedit-review--release session)
      (if (agentedit-review--terminal-state-p
           (agentedit-review-session-state session))
          (let ((message-text (agentedit-review--terminal-message session)))
            (setf (agentedit-review-session-pending-announcement session) nil)
            (run-at-time 0 nil #'agentedit-review--finish-terminal
                         session message-text))
        (run-at-time 0 nil #'agentedit-review--open-current session)))))

(defun agentedit-review--finish-terminal (session message-text)
  "Return to SESSION's source and show MESSAGE-TEXT after Ediff cleanup."
  (let* ((record (agentedit-review--current-record session))
         (source (if (and (eq (agentedit-review-session-state session) 'stale)
                          record)
                     (agentedit-review--record-source record)
                   (agentedit-review-session-source session))))
    (when (buffer-live-p source)
      (pop-to-buffer source)
      (when (eq (agentedit-review-session-state session) 'stale)
        (let ((marker (and record (agentedit-review-record-start record))))
          (when (and marker (marker-position marker))
            (goto-char marker)
            (recenter)))))
    (message "%s" message-text)))

(defun agentedit-review--control-killed ()
  "Fallback cleanup when an AgentEdit control buffer dies abnormally."
  (let ((session agentedit-review--session))
    (when (and session
               (not (agentedit-review-session-cleanup-complete session)))
      (unless (agentedit-review--terminal-state-p
               (agentedit-review-session-state session))
        (setf (agentedit-review-session-last-error session)
              "control buffer was killed")
        (pcase (agentedit-review-session-state session)
          ('reviewing (agentedit-review--transition session 'failed))
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
      (setf (agentedit-review-session-last-error session)
            (format "%s projection was killed"
                    (or agentedit-review--projection-role "review")))
      (agentedit-review--transition
       session
       (if (agentedit-review-session-applied-decision session)
           'partial-failure
         'failed))
      (run-at-time 0 nil #'agentedit-review--abort-after-projection-kill session))))

(defun agentedit-review--abort-after-projection-kill (session)
  "Tear down SESSION after an externally killed projection."
  (let ((control (agentedit-review-session-control session)))
    (if (buffer-live-p control)
        (with-current-buffer control
          (condition-case error-data
              (agentedit-review--ediff-really-quit)
            (error
             (setf (agentedit-review-session-last-error session)
                   (format "%s; Ediff cleanup failed: %s"
                           (or (agentedit-review-session-last-error session)
                               "projection was killed")
                           (error-message-string error-data)))
             (agentedit-review--force-terminal-cleanup session))))
      (agentedit-review--release session))))

(defun agentedit-review--ediff-really-quit ()
  "Quit the current AgentEdit Ediff session without prompting."
  (agentedit-review--check-ediff-compatibility)
  (ediff-really-quit nil))

(defun agentedit-review--force-terminal-cleanup (session)
  "Release SESSION after Ediff cannot complete its own teardown."
  (setf (agentedit-review-session-pending-action session) nil
        (agentedit-review-session-pending-announcement session) nil)
  (agentedit-review--release session)
  (let ((control (agentedit-review-session-control session)))
    (when (buffer-live-p control)
      (with-current-buffer control
        (setf (agentedit-review-session-cleanup-complete session) t))
      (kill-buffer control)))
  (run-at-time 0 nil #'agentedit-review--finish-terminal
               session (agentedit-review--terminal-message session)))

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

(defun agentedit-review--replace-current (session replacement)
  "Replace SESSION's current wrapper with REPLACEMENT atomically."
  (let* ((record (agentedit-review--current-record session))
         (start (agentedit-review-record-start record))
         (end (agentedit-review-record-end record))
         (source (agentedit-review--record-source record)))
    (agentedit-review--source-ready record)
    (unless (and (marker-position start) (marker-position end)
                 (eq (marker-buffer start) source)
                 (eq (marker-buffer end) source))
      (error "marker position is no longer live"))
    (with-current-buffer source
      (unless (string= (buffer-substring-no-properties start end)
                       (agentedit-review-record-snapshot record))
        (signal 'agentedit-review-stale nil))
      (undo-boundary)
      (atomic-change-group
        (delete-region start end)
        (goto-char start)
        (insert replacement))
      (undo-boundary))))

(define-error 'agentedit-review-stale "AgentEdit source snapshot is stale")

(defun agentedit-review--next-announcement (session action record)
  "Return the combined ACTION and next-record announcement for SESSION.
RECORD is the record whose decision just completed."
  (let ((next (agentedit-review--current-record session)))
    (format "%s %s · Next %d / %d %s · Reason: %s · A accept, R reject, S skip, q quit"
            action
            (agentedit-review--normalize-one-line
             (agentedit-review-record-id record))
            (1+ (agentedit-review-session-index session))
            (length (agentedit-review-session-records session))
            (agentedit-review--normalize-one-line
             (agentedit-review-record-id next))
            (agentedit-review--normalize-one-line
             (agentedit-review-record-reason next)))))

(defun agentedit-review--decision (kind)
  "Apply the current AgentEdit decision KIND and advance without saving."
  (let* ((session agentedit-review--session)
         (record (and session (agentedit-review--current-record session)))
         (mutated nil))
    (unless (memq kind '(accept reject skip))
      (error "Unknown AgentEdit decision: %s" kind))
    (unless (and session
                 (eq (agentedit-review-session-state session) 'reviewing))
      (user-error "No AgentEdit decision is currently available"))
    (agentedit-review--transition session 'deciding)
    (setf (agentedit-review-session-applied-decision session) nil
          (agentedit-review-session-completed-decision session) nil
          (agentedit-review-session-completed-record session) nil)
    (condition-case error-data
        (progn
          (agentedit-review--check-ediff-compatibility)
          (pcase kind
            ('accept
             (agentedit-review--replace-current
              session (agentedit-review-record-edited record))
             (setq mutated t)
             (setf (agentedit-review-session-applied-decision session) 'accept)
             (cl-incf (agentedit-review-session-accepted session)))
            ('reject
             (agentedit-review--replace-current
              session (agentedit-review-record-original record))
             (setq mutated t)
             (setf (agentedit-review-session-applied-decision session) 'reject)
             (cl-incf (agentedit-review-session-rejected session)))
            ('skip
             (cl-incf (agentedit-review-session-skipped session))))
          (setf (agentedit-review-session-completed-decision session) kind
                (agentedit-review-session-completed-record session) record)
          (cl-incf (agentedit-review-session-index session))
          (if (agentedit-review--current-record session)
              (setf (agentedit-review-session-pending-action session) 'continue
                    (agentedit-review-session-pending-announcement session)
                    (agentedit-review--next-announcement
                     session (capitalize (symbol-name kind)) record))
            (setf (agentedit-review-session-pending-action session) 'finish))
          (condition-case quit-error
              (agentedit-review--ediff-really-quit)
            (error
             (setf (agentedit-review-session-last-error session)
                   (error-message-string quit-error))
             (agentedit-review--transition
              session (if mutated 'partial-failure 'failed))
             (agentedit-review--force-terminal-cleanup session))))
      (agentedit-review-stale
       (agentedit-review--transition session 'stale)
       (setf (agentedit-review-session-pending-announcement session) nil)
       (condition-case quit-error
           (agentedit-review--ediff-really-quit)
         (error
          (setf (agentedit-review-session-last-error session)
                (error-message-string quit-error))
          (agentedit-review--force-terminal-cleanup session))))
      (error
       (agentedit-review--transition session 'failed)
       (setf (agentedit-review-session-pending-announcement session) nil
             (agentedit-review-session-last-error session)
             (error-message-string error-data))
       (condition-case quit-error
           (agentedit-review--ediff-really-quit)
         (error
          (setf (agentedit-review-session-last-error session)
                (format "%s; Ediff cleanup failed: %s"
                        (error-message-string error-data)
                        (error-message-string quit-error)))
          (agentedit-review--force-terminal-cleanup session)))))))

(defun agentedit-review--accept ()
  "Accept this proposal as one undoable source edit; do not save the buffer."
  (interactive)
  (agentedit-review--decision 'accept))

(defun agentedit-review--reject ()
  "Restore this proposal's original as one undoable edit; do not save."
  (interactive)
  (agentedit-review--decision 'reject))

(defun agentedit-review--skip ()
  "Leave this wrapper unchanged, record a skip, and open the next proposal."
  (interactive)
  (agentedit-review--decision 'skip))

(defun agentedit-review--quit ()
  "Stop this pass after confirmation; keep applied edits unsaved and undoable."
  (interactive)
  (let ((session agentedit-review--session))
    (unless (and session
                 (eq (agentedit-review-session-state session) 'reviewing))
      (user-error "No AgentEdit review is active"))
    (let ((remaining
           (- (length (agentedit-review-session-records session))
              (1+ (agentedit-review-session-index session)))))
      (when (y-or-n-p
             (format "Stop review? %s stay applied; current and %d unvisited markers stay unchanged "
                     (agentedit-review--counts session) remaining))
        (agentedit-review--transition session 'aborting)
        (condition-case error-data
            (agentedit-review--ediff-really-quit)
          (error
           (setf (agentedit-review-session-last-error session)
                 (format "Ediff cleanup failed while stopping: %s"
                         (error-message-string error-data)))
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
                  :source source :sources sources :records records)))
    (agentedit-review--lock-session session sources)
    (condition-case error-data
        (if (null records)
            (progn
              (agentedit-review--transition session 'finished)
              (agentedit-review--release session)
              (message "%s" empty-message))
          (let* ((record (agentedit-review--current-record session))
                 (record-source (agentedit-review--record-source record))
                 (location (format "%s:%d"
                                   (agentedit-review--source-label record-source)
                                   (agentedit-review--record-line record))))
            (setf (agentedit-review-session-pending-announcement session)
                  (format
                   "AgentEdit 1 / %d %s · %s · Reason: %s · A accept, R reject, S skip, q quit"
                   (length records)
                   (agentedit-review--normalize-one-line
                    (agentedit-review-record-id record))
                   location
                   (agentedit-review--normalize-one-line
                    (agentedit-review-record-reason record))))
            (agentedit-review--open-current session)))
      (error
       (unless (agentedit-review--terminal-state-p
                (agentedit-review-session-state session))
         (agentedit-review--transition session 'failed))
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
it uses AUCTeX's native master prompt.  Decisions remain unsaved and undoable
in the individual source buffers."
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
undecided wrappers unchanged.  This command never saves source buffers."
  (interactive "P")
  (if (or file-only (not (agentedit-review--auctex-mode-p)))
      (agentedit-review--review-buffer)
    (agentedit-review--review-project)))

(provide 'agentedit-review)

;;; agentedit-review.el ends here
