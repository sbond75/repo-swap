;;; repo-swap.el --- Jump to the same relative file in another checkout -*- lexical-binding: t; -*-

;; Version: 0.1.8
;; Package-Requires: ((emacs "27.1"))
;; Keywords: files, convenience, vc

;;; Commentary:

;; repo-swap.el is a small global minor mode for moving between local
;; checkouts/worktrees/clones of the same project.  From a file-visiting
;; buffer, it computes the file's path relative to the current project root,
;; finds other known roots that contain the same relative file, and opens the
;; chosen copy.  It can optionally kill the original buffer after switching.
;;
;; ModPatch integration is optional.  When ModPatch v2 is loaded, repo-swap
;; can use loaded ModPatch contexts as known roots, and a current ModPatch
;; buffer's context root takes priority over generic project/git discovery.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project nil t)
(require 'vc nil t)

(defgroup repo-swap nil
  "Jump between equivalent files in sibling checkouts."
  :group 'files
  :prefix "repo-swap-")

(defconst repo-swap-version "0.1.8"
  "Current repo-swap package version.")

(defcustom repo-swap-kill-old-buffer nil
  "Whether `repo-swap-open-same-file' kills the original buffer.

nil means keep the original buffer.
t means kill it after opening the target buffer.
`ask' means ask each time."
  :type '(choice (const :tag "Keep old buffer" nil)
                 (const :tag "Kill old buffer" t)
                 (const :tag "Ask" ask))
  :group 'repo-swap)

(defcustom repo-swap-extra-roots nil
  "Extra checkout roots always considered by repo-swap.

Each entry should be a directory containing a repository/project checkout."
  :type '(repeat directory)
  :group 'repo-swap)

(defcustom repo-swap-known-roots-file
  (expand-file-name "repo-swap/known-roots.el" user-emacs-directory)
  "User-local file where repo-swap remembers roots it has seen."
  :type 'file
  :group 'repo-swap)

(defcustom repo-swap-remember-roots t
  "When non-nil, use persistent remembered checkout roots.

When enabled, repo-swap reads `repo-swap-known-roots-file', automatically
remembers checkout roots encountered while visiting files, and writes updated
roots back to that file.  When nil, the remembered-roots file is neither read
nor written, and its roots are not used as swap candidates."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-include-sibling-roots nil
  "When non-nil, scan sibling directories for other checkouts.

This is disabled by default so repo-swap does not enumerate nearby directories
unless explicitly requested."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-sibling-parent-levels 1
  "How many ancestor levels to scan for sibling checkout directories.

The default 1 scans direct siblings of the current checkout root.  For example,
from J:/Projects/test_featureWork2 it scans direct children of J:/Projects.
Avoid large values near drive roots because that can be noisy and slow."
  :type 'integer
  :group 'repo-swap)

(defcustom repo-swap-root-marker-files
  '(".modpatch-project.el" ".git" ".hg")
  "Files or directories that make a directory look like a checkout root."
  :type '(repeat string)
  :group 'repo-swap)

(defcustom repo-swap-use-modpatch-contexts t
  "When non-nil, include loaded ModPatch v2 context roots as candidates."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-show-git-branch t
  "When non-nil, show Git branch names in completion labels when available."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-show-root-in-mode-line t
  "When non-nil, show the current checkout's unique directory name in the mode line.

The bracketed label is shown only when the currently visited relative file also
exists in at least one other currently known checkout.  The label starts with
the checkout directory's basename.  If another matching checkout has the same
basename, parent directory components are prepended until the label is unique,
for example `[worktrees/ShapeShift]'."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-prefer-modpatch-root t
  "When non-nil, use the current buffer's ModPatch context root first."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-integrate-recentf nil
  "When non-nil, open recentf entries in the current checkout when possible.

Suppose the current buffer belongs to checkout B, but a selected recentf entry
names a file in known checkout A.  If checkout B contains the same relative
file, repo-swap opens B's copy.  Otherwise recentf keeps its exact-path
behavior.  This option is disabled by default.

Set this before enabling `repo-swap-mode'.  After changing it at runtime, call
`repo-swap-refresh-recentf-integration' or toggle `repo-swap-mode'."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-switch-buffer-include-recentf t
  "When non-nil, `repo-swap-switch-buffer-or-recentf' includes recent files.

Open buffers always use normal `switch-to-buffer' behavior.  Recent-file
entries use repo-swap redirection only when `repo-swap-integrate-recentf' is
non-nil; otherwise they open their exact stored path."
  :type 'boolean
  :group 'repo-swap)

(defcustom repo-swap-recentf-command-regexp
  "\\(?:recentf\\|recent-file\\)"
  "Regexp identifying commands that open entries from a recent-file list.

This supplements built-in recentf's `recentf-menu-action' hook.  It lets the
integration recognize commands such as `consult-recent-file' and
`counsel-recentf', which commonly call `find-file' directly.  The command must
also be opening a path currently present in `recentf-list', so ordinary
`find-file' calls are not redirected."
  :type 'regexp
  :group 'repo-swap)

(defcustom repo-swap-recentf-command-functions
  '(recentf-open
    recentf-open-files
    recentf-open-more-files
    recentf-open-most-recent-file
    consult-recent-file
    counsel-recentf
    helm-recentf
    ivy-switch-buffer
    ivy-switch-buffer-other-window
    counsel-switch-buffer
    counsel-switch-buffer-other-window)
  "Commands whose entire execution should retain the invoking checkout.

Repo Swap advises loaded functions in this list, plus loaded interactive
commands whose names match `repo-swap-recentf-command-regexp'.  The explicit
Ivy switch-buffer entries are intentional: with `ivy-use-virtual-buffers', a
recent file is presented as a virtual buffer and opened from `C-x b', even
though the command name contains neither \"recentf\" nor \"recent-file\".

Retaining the origin for the command's complete dynamic extent is important
because completion front ends enter a recursive minibuffer; by the time they
open a file, `this-command' may be a minibuffer command rather than the
original recent-file or virtual-buffer command.

After adding a command at runtime, call
`repo-swap-refresh-recentf-integration'."
  :type '(repeat function)
  :group 'repo-swap)

(defcustom repo-swap-debug nil
  "When non-nil, log recentf redirection decisions to *Messages*."
  :type 'boolean
  :group 'repo-swap)

(defvar repo-swap--known-roots nil
  "Cached list of user-local known roots.")

(defvar repo-swap--recentf-original-action nil
  "Recentf action saved before repo-swap installs its wrapper.")

(defvar repo-swap--recentf-origin-root nil
  "Checkout root captured when a built-in recentf command opened a dialog.")

(defvar repo-swap--command-origin-root nil
  "Checkout root captured for compatibility with older integration paths.")

(defvar repo-swap--active-recentf-origin-root nil
  "Dynamically bound checkout root for an active recent-file command.")

(defvar repo-swap--active-recentf-command nil
  "Dynamically bound recent-file command currently opening a file.")

(defvar repo-swap--advised-recentf-commands nil
  "Recent-file commands currently carrying repo-swap around advice.")

(defvar repo-swap--redirecting-recentf nil
  "Non-nil while repo-swap is delegating an already redirected file open.")

(defconst repo-swap--recentf-origin-functions
  '(recentf-open recentf-open-files recentf-open-more-files
    recentf-open-most-recent-file)
  "Recentf entry points advised to remember the originating checkout.")

(defvar-local repo-swap--buffer-root nil
  "Canonical checkout root associated with the current buffer.")

(defun repo-swap--file-directory-p (path)
  "Return non-nil when PATH names an existing directory."
  (and path (file-directory-p path)))

(defun repo-swap--canonical-directory (directory)
  "Return canonical DIRECTORY with a trailing slash.

This resolves Windows short names, symlinks and case quirks where possible."
  (file-name-as-directory
   (file-truename
    (directory-file-name
     (expand-file-name directory)))))


(defun repo-swap--safe-canonical-directory (directory)
  "Return canonical DIRECTORY, or nil if DIRECTORY is unavailable."
  (when (and directory (file-directory-p directory))
    (ignore-errors
      (repo-swap--canonical-directory directory))))

(defun repo-swap--canonical-file (file)
  "Return canonical FILE name where possible."
  (file-truename (expand-file-name file)))

(defun repo-swap--same-file-name-p (a b)
  "Return non-nil when A and B name the same file/directory."
  (string-equal (repo-swap--canonical-file a)
                (repo-swap--canonical-file b)))

(defun repo-swap--root-marker-p (directory)
  "Return non-nil if DIRECTORY has any `repo-swap-root-marker-files'."
  (cl-some
   (lambda (marker)
     (file-exists-p (expand-file-name marker directory)))
   repo-swap-root-marker-files))

(defun repo-swap--path-under-root-p (path root)
  "Return non-nil if PATH is inside ROOT."
  (let* ((path-key (repo-swap--canonical-file path))
         (root-key (repo-swap--canonical-directory root)))
    (string-prefix-p root-key path-key t)))

(defun repo-swap--relative-name (file root)
  "Return FILE relative to ROOT, using canonical names."
  (file-relative-name (repo-swap--canonical-file file)
                      (repo-swap--canonical-directory root)))

(defun repo-swap--read-sexp-file (file)
  "Read and return the first Lisp object from FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (read (current-buffer)))))

(defun repo-swap--write-sexp-file (object file)
  "Write OBJECT to FILE as pretty-printed Lisp."
  (make-directory (file-name-directory file) t)
  (let ((print-length nil)
        (print-level nil))
    (with-temp-file file
      (let ((standard-output (current-buffer)))
        (prin1 object)
        (terpri)))))

(defun repo-swap--load-known-roots ()
  "Load `repo-swap--known-roots' from disk when persistence is enabled."
  (setq repo-swap--known-roots
        (when repo-swap-remember-roots
          (let ((object (repo-swap--read-sexp-file
                         repo-swap-known-roots-file)))
            (when (and (listp object)
                       (eq (plist-get object :version) 1))
              (mapcar #'repo-swap--canonical-directory
                      (cl-remove-if-not #'repo-swap--file-directory-p
                                        (plist-get object :roots)))))))
  (force-mode-line-update t)
  repo-swap--known-roots)

(defun repo-swap--save-known-roots ()
  "Save `repo-swap--known-roots' to disk."
  (when repo-swap-remember-roots
    (repo-swap--write-sexp-file
     (list :version 1
           :roots (sort (delete-dups (copy-sequence repo-swap--known-roots))
                        #'string-lessp))
     repo-swap-known-roots-file)))

(defun repo-swap--remember-root (root)
  "Remember ROOT in the user-local known-roots file."
  (when (and repo-swap-remember-roots root (file-directory-p root))
    (unless repo-swap--known-roots
      (repo-swap--load-known-roots))
    (let ((canonical (repo-swap--canonical-directory root)))
      (unless (cl-some (lambda (known)
                         (string-equal known canonical))
                       repo-swap--known-roots)
        (push canonical repo-swap--known-roots)
        (repo-swap--save-known-roots)
        (force-mode-line-update t)))))

(defun repo-swap--modpatch-current-root ()
  "Return current buffer's ModPatch context root, or nil."
  (when (and repo-swap-use-modpatch-contexts
             repo-swap-prefer-modpatch-root
             (boundp 'modpatch--context)
             modpatch--context
             (fboundp 'modpatch--context-root))
    (repo-swap--canonical-directory
     (modpatch--context-root modpatch--context))))

(defun repo-swap--nearest-marker-root (file)
  "Return nearest root marker directory above FILE, or nil."
  (let ((directory (file-name-directory (expand-file-name file)))
        found)
    (cl-dolist (marker repo-swap-root-marker-files)
      (let ((root (locate-dominating-file directory marker)))
        (when (and root
                   (or (not found)
                       (> (length (repo-swap--canonical-directory root))
                          (length (repo-swap--canonical-directory found)))))
          (setq found root))))
    (when found
      (repo-swap--canonical-directory found))))

(defun repo-swap--project-root (file)
  "Return project.el root for FILE, or nil."
  (when (fboundp 'project-current)
    (let ((default-directory (file-name-directory (expand-file-name file))))
      (when-let ((project (project-current nil)))
        (when (fboundp 'project-root)
          (repo-swap--canonical-directory (project-root project)))))))

(defun repo-swap-current-root ()
  "Return the best checkout root for the current buffer."
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (or (repo-swap--modpatch-current-root)
      (repo-swap--nearest-marker-root buffer-file-name)
      (repo-swap--project-root buffer-file-name)
      (when (fboundp 'vc-root-dir)
        (let ((root (vc-root-dir)))
          (when root
            (repo-swap--canonical-directory root))))
      (user-error "Could not determine a checkout/project root for %s"
                  buffer-file-name)))

(defun repo-swap--current-root-noerror ()
  "Return the current buffer's checkout root, or nil without signaling."
  (when buffer-file-name
    (ignore-errors (repo-swap-current-root))))

(defun repo-swap--modpatch-context-roots ()
  "Return roots from loaded ModPatch contexts."
  (let (roots)
    (when (and repo-swap-use-modpatch-contexts
               (boundp 'modpatch--contexts)
               (hash-table-p modpatch--contexts)
               (fboundp 'modpatch--context-root))
      (maphash
       (lambda (_key context)
         (let ((root (ignore-errors (modpatch--context-root context))))
           (when (and root (file-directory-p root))
             (push (repo-swap--canonical-directory root) roots))))
       modpatch--contexts))
    roots))

(defun repo-swap--parent-directory (directory)
  "Return parent directory of DIRECTORY, or nil at filesystem root."
  (let* ((dir (repo-swap--canonical-directory directory))
         (parent (file-name-directory (directory-file-name dir))))
    (when (and parent
               (not (string-equal (repo-swap--canonical-directory parent) dir)))
      (repo-swap--canonical-directory parent))))

(defun repo-swap--sibling-roots (root)
  "Return candidate checkout roots near ROOT."
  (let ((ancestor root)
        roots)
    (dotimes (_ (max 0 repo-swap-sibling-parent-levels))
      (setq ancestor (repo-swap--parent-directory ancestor))
      (when (and ancestor (file-directory-p ancestor))
        (dolist (child (directory-files ancestor t directory-files-no-dot-files-regexp t))
          (when (and (file-directory-p child)
                     (repo-swap--root-marker-p child))
            (push (repo-swap--canonical-directory child) roots)))))
    roots))

(defun repo-swap--all-known-roots (current-root)
  "Return all known root candidates for CURRENT-ROOT."
  (when (and repo-swap-remember-roots
             (null repo-swap--known-roots))
    (repo-swap--load-known-roots))
  (delete-dups
   (cl-remove-if-not
    #'identity
    (mapcar
     #'repo-swap--safe-canonical-directory
     (append
      (list current-root)
      repo-swap-extra-roots
      (when repo-swap-remember-roots
        repo-swap--known-roots)
      (repo-swap--modpatch-context-roots)
      (when repo-swap-include-sibling-roots
        (repo-swap--sibling-roots current-root)))))))

(defun repo-swap--mode-line-known-roots (current-root)
  "Return inexpensive known roots used to disambiguate CURRENT-ROOT.

This deliberately does not scan sibling directories during mode-line redisplay.
Remembered roots, explicitly configured roots, and loaded ModPatch contexts are
included."
  (when (and repo-swap-remember-roots
             (null repo-swap--known-roots))
    (repo-swap--load-known-roots))
  (delete-dups
   (cl-remove-if-not
    #'identity
    (mapcar
     #'repo-swap--safe-canonical-directory
     (append
      (list current-root)
      repo-swap-extra-roots
      (when repo-swap-remember-roots
        repo-swap--known-roots)
      (repo-swap--modpatch-context-roots))))))

(defun repo-swap--mode-line-peer-roots (current-file current-root)
  "Return known roots other than CURRENT-ROOT containing CURRENT-FILE's relative path.

Only inexpensive currently known roots are considered: remembered roots,
`repo-swap-extra-roots', and loaded ModPatch contexts.  Sibling directories are
not scanned during mode-line redisplay."
  (when (and current-file current-root
             (file-exists-p current-file)
             (ignore-errors
               (repo-swap--path-under-root-p current-file current-root)))
    (let* ((relative (repo-swap--relative-name current-file current-root))
           (current-canonical (repo-swap--canonical-file current-file))
           peers)
      (dolist (root (repo-swap--mode-line-known-roots current-root))
        (let ((target (expand-file-name relative root)))
          (when (and (file-exists-p target)
                     (not (string-equal current-canonical
                                        (repo-swap--canonical-file target))))
            (push root peers))))
      (delete-dups peers))))

(defun repo-swap--root-components (root)
  "Return ROOT's path components from outermost to innermost.

Windows drive names are retained as components, allowing labels such as
`C:/Projects/ShapeShift' when the drive is needed for uniqueness."
  (split-string
   (subst-char-in-string
    ?\\ ?/
    (directory-file-name (repo-swap--canonical-directory root)))
   "/" t))

(defun repo-swap--root-suffix-label (root component-count)
  "Return the last COMPONENT-COUNT path components of ROOT joined by `/'."
  (let* ((components (repo-swap--root-components root))
         (length (length components))
         (start (max 0 (- length component-count))))
    (string-join (nthcdr start components) "/")))

(defun repo-swap--label-equal-p (a b)
  "Return non-nil when root labels A and B should be treated as equal."
  (if (memq system-type '(windows-nt ms-dos cygwin))
      (string-equal (downcase a) (downcase b))
    (string-equal a b)))

(defun repo-swap--unique-root-label (root roots)
  "Return the shortest unique suffix label for ROOT among ROOTS.

The checkout basename is used when unique.  Otherwise parent components are
prepended one at a time until the label differs from every other root."
  (let* ((canonical-root (repo-swap--canonical-directory root))
         (canonical-roots
          (delete-dups
           (cl-remove-if-not
            #'identity
            (mapcar #'repo-swap--safe-canonical-directory
                    (cons canonical-root roots)))))
         (max-components (length (repo-swap--root-components canonical-root)))
         (component-count 1)
         label
         unique)
    (while (and (<= component-count max-components)
                (not unique))
      (setq label (repo-swap--root-suffix-label
                   canonical-root component-count))
      (setq unique
            (not
             (cl-some
              (lambda (other-root)
                (and (not (repo-swap--same-file-name-p
                           canonical-root other-root))
                     (repo-swap--label-equal-p
                      label
                      (repo-swap--root-suffix-label
                       other-root component-count))))
              canonical-roots)))
      (unless unique
        (setq component-count (1+ component-count))))
    (or label
        (file-name-nondirectory
         (directory-file-name canonical-root)))))

(defun repo-swap--refresh-buffer-root ()
  "Refresh the checkout root cached for the current buffer."
  (setq-local repo-swap--buffer-root
              (when buffer-file-name
                (ignore-errors (repo-swap-current-root))))
  (force-mode-line-update))

(defun repo-swap--mode-line-lighter ()
  "Return the dynamic mode-line lighter for `repo-swap-mode'."
  (let ((base " RepoSwap"))
    (if (and repo-swap-show-root-in-mode-line buffer-file-name)
        (let* ((root (or repo-swap--buffer-root
                         (progn
                           (repo-swap--refresh-buffer-root)
                           repo-swap--buffer-root)))
               (peer-roots (and root
                                (repo-swap--mode-line-peer-roots
                                 buffer-file-name root))))
          (if peer-roots
              (format "%s[%s]"
                      base
                      (repo-swap--unique-root-label
                       root
                       (cons root peer-roots)))
            base))
      base)))

(defun repo-swap--longest-containing-root (file roots)
  "Return the deepest member of ROOTS containing FILE, or nil."
  (let ((best nil))
    (dolist (root roots best)
      (when (and root
                 (ignore-errors (repo-swap--path-under-root-p file root))
                 (or (null best)
                     (> (length root) (length best))))
        (setq best root)))))

(defun repo-swap--recentf-target-file (file preferred-root)
  "Return FILE redirected into PREFERRED-ROOT when a matching copy exists.

FILE is redirected only when it belongs to another known checkout and the same
relative file exists beneath PREFERRED-ROOT.  Otherwise return FILE's exact
expanded path."
  (let* ((exact-file (expand-file-name file))
         (preferred (repo-swap--safe-canonical-directory preferred-root)))
    (if (or (null preferred)
            (not (file-exists-p exact-file)))
        exact-file
      (let* ((roots (repo-swap--all-known-roots preferred))
             (source-root (repo-swap--longest-containing-root exact-file roots)))
        (if (or (null source-root)
                (repo-swap--same-file-name-p source-root preferred))
            exact-file
          (let* ((relative (repo-swap--relative-name exact-file source-root))
                 (target (expand-file-name relative preferred)))
            (if (file-exists-p target)
                (repo-swap--canonical-file target)
              exact-file)))))))

(defun repo-swap--recentf-fallback-action ()
  "Return the recentf action that repo-swap should delegate to."
  (if (and repo-swap--recentf-original-action
           (not (eq repo-swap--recentf-original-action
                    #'repo-swap-recentf-open-file)))
      repo-swap--recentf-original-action
    #'find-file))

(defun repo-swap--capture-command-origin ()
  "Capture a recent-file command origin for compatibility and diagnostics.

The primary integration now uses `repo-swap--recentf-command-around', which
keeps the origin dynamically bound for the complete command, including any
recursive minibuffer session.  Unrelated commands clear the compatibility
value so it cannot become a stale fallback."
  (setq repo-swap--command-origin-root
        (when (repo-swap--recentf-command-p)
          (or repo-swap--buffer-root
              (repo-swap--current-root-noerror)))))

(defun repo-swap--capture-recentf-origin (&rest _ignored)
  "Remember the checkout before a built-in recentf command changes buffers."
  (setq repo-swap--recentf-origin-root
        (or repo-swap--active-recentf-origin-root
            repo-swap--command-origin-root
            (repo-swap--current-root-noerror))))

(defun repo-swap--recentf-command-p (&optional command)
  "Return non-nil when COMMAND looks like a recent-file opener."
  (let ((name (and (symbolp (or command this-command))
                   (symbol-name (or command this-command)))))
    (and name
         (string-match-p repo-swap-recentf-command-regexp name))))

(defun repo-swap--recentf-command-symbols ()
  "Return loaded commands that should retain recentf origin state."
  (let ((symbols (copy-sequence repo-swap-recentf-command-functions)))
    (mapatoms
     (lambda (symbol)
       (when (and (fboundp symbol)
                  (commandp symbol)
                  (not (string-prefix-p "repo-swap-" (symbol-name symbol)))
                  (repo-swap--recentf-command-p symbol))
         (push symbol symbols))))
    (delete-dups symbols)))

(defun repo-swap--recentf-command-around (original &rest arguments)
  "Call ORIGINAL with ARGUMENTS while preserving the invoking checkout."
  (let* ((origin (or repo-swap--buffer-root
                     (repo-swap--current-root-noerror)))
         (repo-swap--active-recentf-origin-root origin)
         (repo-swap--active-recentf-command this-command)
         (repo-swap--command-origin-root origin))
    (when repo-swap-debug
      (message "repo-swap recentf: entered command=%S origin=%S"
               this-command origin))
    (apply original arguments)))

(defun repo-swap--install-recentf-command-advice ()
  "Advise all currently loaded recent-file entry commands."
  (dolist (function (repo-swap--recentf-command-symbols))
    (when (and (fboundp function)
               (not (advice-member-p
                     #'repo-swap--recentf-command-around function)))
      (advice-add function :around #'repo-swap--recentf-command-around)
      (push function repo-swap--advised-recentf-commands))))

(defun repo-swap--remove-recentf-command-advice ()
  "Remove command-level recentf origin advice installed by Repo Swap."
  (dolist (function (delete-dups repo-swap--advised-recentf-commands))
    (when (fboundp function)
      (advice-remove function #'repo-swap--recentf-command-around)))
  (setq repo-swap--advised-recentf-commands nil))

(defun repo-swap--after-load-refresh-recentf-advice (&rest _ignored)
  "Attach recentf command advice after another library is loaded."
  (when (and repo-swap-mode repo-swap-integrate-recentf)
    (repo-swap--install-recentf-command-advice)))

(defun repo-swap--recentf-listed-file-p (file)
  "Return non-nil when FILE is currently present in `recentf-list'."
  (and (stringp file)
       (boundp 'recentf-list)
       (cl-some
        (lambda (recent)
          (ignore-errors (repo-swap--same-file-name-p file recent)))
        recentf-list)))

(defun repo-swap--recentf-preferred-root (&optional explicit-root)
  "Return the preferred checkout for a recent-file open.

EXPLICIT-ROOT wins.  Otherwise prefer the dynamically retained root of the
active recent-file command, then compatibility/dialog captures, and only then
inspect the action-time buffer."
  (or explicit-root
      repo-swap--active-recentf-origin-root
      repo-swap--command-origin-root
      repo-swap--recentf-origin-root
      (repo-swap--current-root-noerror)))

(defun repo-swap--debug-recentf-decision (file preferred-root target source)
  "Log a recentf decision involving FILE, PREFERRED-ROOT, TARGET and SOURCE."
  (when repo-swap-debug
    (message "repo-swap recentf: command=%S origin=%S source=%S exact=%S target=%S"
             (or repo-swap--active-recentf-command this-command)
             preferred-root source (expand-file-name file) target)))

(defun repo-swap--recentf-decision (file preferred-root)
  "Return a plist describing how FILE maps into PREFERRED-ROOT."
  (let* ((exact-file (expand-file-name file))
         (preferred (repo-swap--safe-canonical-directory preferred-root))
         (roots (and preferred (repo-swap--all-known-roots preferred)))
         (source-root (and roots
                           (repo-swap--longest-containing-root exact-file roots)))
         (target (if repo-swap-integrate-recentf
                     (repo-swap--recentf-target-file exact-file preferred)
                   exact-file)))
    (list :file exact-file
          :preferred-root preferred
          :source-root source-root
          :target target
          :redirected (not (repo-swap--same-file-name-p exact-file target)))))

(defun repo-swap--find-file-noselect-around (original file &rest arguments)
  "Redirect a recent FILE before calling ORIGINAL with FILE and ARGUMENTS.

Advising `find-file-noselect' catches `find-file', `find-file-other-window',
and recent-file front ends that choose a different display function.  The
advice is inert unless it runs within a command wrapped by
`repo-swap--recentf-command-around' and FILE is present in `recentf-list'."
  (if (or repo-swap--redirecting-recentf
          (not repo-swap-mode)
          (not repo-swap-integrate-recentf)
          (null repo-swap--active-recentf-origin-root)
          (not (repo-swap--recentf-listed-file-p file)))
      (apply original file arguments)
    (let* ((root repo-swap--active-recentf-origin-root)
           (decision (repo-swap--recentf-decision file root))
           (target (plist-get decision :target)))
      (repo-swap--debug-recentf-decision
       file root target (plist-get decision :source-root))
      (let ((repo-swap--redirecting-recentf t))
        (apply original target arguments)))))

;;;###autoload
(defun repo-swap-recentf-open-file (file &optional preferred-root)
  "Open recent FILE, preferring the originating checkout when possible.

PREFERRED-ROOT is mainly for callers such as
`repo-swap-switch-buffer-or-recentf'.  When nil, use the checkout captured
before the current recent-file command or dialog."
  (let* ((root (repo-swap--recentf-preferred-root preferred-root))
         (decision (repo-swap--recentf-decision file root))
         (target (plist-get decision :target)))
    (repo-swap--debug-recentf-decision
     file root target (plist-get decision :source-root))
    (unwind-protect
        (let ((repo-swap--redirecting-recentf t))
          (funcall (repo-swap--recentf-fallback-action) target))
      (setq repo-swap--recentf-origin-root nil))))

;;;###autoload
(defun repo-swap-debug-recentf-target (file)
  "Explain where recent FILE would open and why."
  (interactive
   (progn
     (require 'recentf)
     (unless recentf-list
       (user-error "recentf-list is empty"))
     (list (completing-read "Debug recent file: " recentf-list nil t))))
  (let* ((root (repo-swap--recentf-preferred-root))
         (decision (repo-swap--recentf-decision file root)))
    (message
     "repo-swap debug: command=%S integration=%S action=%S origin=%S dialog-origin=%S preferred=%S source=%S target=%S redirected=%S"
     this-command repo-swap-integrate-recentf
     (and (boundp 'recentf-menu-action) recentf-menu-action)
     repo-swap--command-origin-root repo-swap--recentf-origin-root
     (plist-get decision :preferred-root)
     (plist-get decision :source-root)
     (plist-get decision :target)
     (plist-get decision :redirected))
    decision))

(defun repo-swap--install-recentf-integration ()
  "Install repo-swap's opt-in recentf integration."
  (require 'recentf)
  ;; Clean up advice used by 0.1.6 when this file is reloaded in place.
  (remove-hook 'pre-command-hook #'repo-swap--capture-command-origin)
  (when (fboundp 'repo-swap--find-file-around)
    (advice-remove 'find-file #'repo-swap--find-file-around))
  (unless (eq recentf-menu-action #'repo-swap-recentf-open-file)
    (setq repo-swap--recentf-original-action recentf-menu-action)
    (setq recentf-menu-action #'repo-swap-recentf-open-file))
  (unless (advice-member-p #'repo-swap--find-file-noselect-around
                           'find-file-noselect)
    (advice-add 'find-file-noselect :around
                #'repo-swap--find-file-noselect-around))
  (dolist (function repo-swap--recentf-origin-functions)
    (when (and (fboundp function)
               (not (advice-member-p
                     #'repo-swap--capture-recentf-origin function)))
      (advice-add function :before #'repo-swap--capture-recentf-origin)))
  (add-hook 'after-load-functions
            #'repo-swap--after-load-refresh-recentf-advice)
  (repo-swap--install-recentf-command-advice))

(defun repo-swap--remove-recentf-integration ()
  "Remove repo-swap's recentf integration and restore the prior action."
  (when (and (boundp 'recentf-menu-action)
             (eq recentf-menu-action #'repo-swap-recentf-open-file))
    (setq recentf-menu-action
          (or repo-swap--recentf-original-action #'find-file)))
  ;; Remove both current and pre-0.1.7 integration hooks/advice.
  (remove-hook 'pre-command-hook #'repo-swap--capture-command-origin)
  (remove-hook 'after-load-functions
               #'repo-swap--after-load-refresh-recentf-advice)
  (when (fboundp 'repo-swap--find-file-around)
    (advice-remove 'find-file #'repo-swap--find-file-around))
  (advice-remove 'find-file-noselect #'repo-swap--find-file-noselect-around)
  (repo-swap--remove-recentf-command-advice)
  (dolist (function repo-swap--recentf-origin-functions)
    (when (fboundp function)
      (advice-remove function #'repo-swap--capture-recentf-origin)))
  (setq repo-swap--recentf-origin-root nil)
  (setq repo-swap--command-origin-root nil))

;;;###autoload
(defun repo-swap-refresh-recentf-integration ()
  "Apply the current value of `repo-swap-integrate-recentf'."
  (interactive)
  (if (and repo-swap-mode repo-swap-integrate-recentf)
      (repo-swap--install-recentf-integration)
    (repo-swap--remove-recentf-integration))
  (message "repo-swap recentf integration: %s"
           (if (and repo-swap-mode repo-swap-integrate-recentf)
               "enabled"
             "disabled")))

;;;###autoload
(defun repo-swap-version ()
  "Display the loaded Repo Swap version, source and integration status."
  (interactive)
  (let* ((source (or (symbol-file 'repo-swap-mode 'defun)
                     (locate-library "repo-swap")
                     "unknown"))
         (integration (and repo-swap-mode repo-swap-integrate-recentf))
         (advised (delete-dups
                   (copy-sequence repo-swap--advised-recentf-commands)))
         (advised-count (length advised))
         (ivy-loaded (fboundp 'ivy-switch-buffer))
         (ivy-advised (and ivy-loaded
                           (advice-member-p
                            #'repo-swap--recentf-command-around
                            'ivy-switch-buffer))))
    (message "repo-swap %s (loaded from %s; recentf=%s; advised-commands=%d; ivy=%s)"
             repo-swap-version source
             (if integration "enabled" "disabled")
             advised-count
             (cond (ivy-advised "advised")
                   (ivy-loaded "loaded-not-advised")
                   (t "not-loaded")))
    repo-swap-version))

(defun repo-swap--git-string (root &rest args)
  "Run git in ROOT with ARGS and return trimmed output, or nil."
  (when (executable-find "git")
    (with-temp-buffer
      (let ((exit-code (apply #'process-file "git" nil t nil
                              "-C" root args)))
        (when (and (integerp exit-code) (zerop exit-code))
          (string-trim (buffer-string)))))))

(defun repo-swap--root-label (root)
  "Return a human-readable label for ROOT."
  (let* ((name (file-name-nondirectory (directory-file-name root)))
         (branch (and repo-swap-show-git-branch
                      (or (repo-swap--git-string root "branch" "--show-current")
                          (let ((commit (repo-swap--git-string root
                                                               "rev-parse"
                                                               "--short"
                                                               "HEAD")))
                            (when (and commit (not (string-empty-p commit)))
                              (format "detached:%s" commit)))))))
    (if (and branch (not (string-empty-p branch)))
        (format "%s [%s]" name branch)
      name)))

(defun repo-swap--candidate-files (current-file current-root)
  "Return candidate target files equivalent to CURRENT-FILE under CURRENT-ROOT."
  (let* ((relative (repo-swap--relative-name current-file current-root))
         (current-canonical (repo-swap--canonical-file current-file))
         candidates)
    (dolist (root (repo-swap--all-known-roots current-root))
      (let ((target (expand-file-name relative root)))
        (when (and (file-exists-p target)
                   (not (string-equal current-canonical
                                      (repo-swap--canonical-file target))))
          (push (list :root root
                      :file (repo-swap--canonical-file target)
                      :relative relative)
                candidates))))
    (sort candidates
          (lambda (a b)
            (string-lessp (plist-get a :root)
                          (plist-get b :root))))))

(defun repo-swap--completion-table (candidates)
  "Return completion table alist for CANDIDATES."
  (let ((seen (make-hash-table :test 'equal))
        rows)
    (dolist (candidate candidates)
      (let* ((root (plist-get candidate :root))
             (label-base (format "%s — %s"
                                 (repo-swap--root-label root)
                                 root))
             (count (1+ (gethash label-base seen 0)))
             (label (if (= count 1)
                        label-base
                      (format "%s <%d>" label-base count))))
        (puthash label-base count seen)
        (push (cons label candidate) rows)))
    (nreverse rows)))

(defun repo-swap--should-kill-old-buffer-p (buffer override)
  "Return non-nil when BUFFER should be killed after switch.

OVERRIDE comes from an interactive prefix argument."
  (cond
   (override
    (y-or-n-p (format "Kill old buffer %s? " (buffer-name buffer))))
   ((eq repo-swap-kill-old-buffer 'ask)
    (y-or-n-p (format "Kill old buffer %s? " (buffer-name buffer))))
   (repo-swap-kill-old-buffer t)
   (t nil)))

;;;###autoload
(defun repo-swap-open-same-file (&optional ask-kill-old)
  "Open the same relative file from another checkout.

The current buffer's checkout root is found using ModPatch context, nearest root
markers, project.el, or VC.  Candidates are other known roots containing the same
relative path.  With prefix argument ASK-KILL-OLD, ask whether to kill the old
buffer regardless of `repo-swap-kill-old-buffer'."
  (interactive "P")
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((old-buffer (current-buffer))
         (current-file (repo-swap--canonical-file buffer-file-name))
         (current-root (repo-swap-current-root)))
    (unless (repo-swap--path-under-root-p current-file current-root)
      (user-error "%s is not under root %s" current-file current-root))
    (repo-swap--remember-root current-root)
    (let* ((candidates (repo-swap--candidate-files current-file current-root))
           (table (repo-swap--completion-table candidates)))
      (unless table
        (user-error "No other known checkout contains %s"
                    (repo-swap--relative-name current-file current-root)))
      (let* ((choice (completing-read "Open same file in checkout: "
                                      table nil t))
             (candidate (cdr (assoc choice table)))
             (target (plist-get candidate :file))
             (kill-old (repo-swap--should-kill-old-buffer-p
                        old-buffer ask-kill-old)))
        (find-file target)
        (repo-swap--remember-root (plist-get candidate :root))
        (when (and kill-old (buffer-live-p old-buffer)
                   (not (eq old-buffer (current-buffer))))
          (kill-buffer old-buffer))
        (message "repo-swap: opened %s"
                 (abbreviate-file-name target))))))

(defun repo-swap--switch-buffer-completion-table ()
  "Return completion rows for live buffers and optional recent files."
  (let ((seen (make-hash-table :test 'equal))
        rows)
    (dolist (buffer (buffer-list))
      (let* ((name (buffer-name buffer))
             (label (format "[Buffer] %s" name)))
        (puthash name t seen)
        (push (cons label (list :type 'buffer :buffer buffer)) rows)))
    (when repo-swap-switch-buffer-include-recentf
      (require 'recentf)
      (unless recentf-mode
        (recentf-mode 1))
      (dolist (file recentf-list)
        (let ((buffer (get-file-buffer file)))
          (unless (and buffer (gethash (buffer-name buffer) seen))
            (let ((label (format "[Recent] %s — %s"
                                 (file-name-nondirectory file)
                                 (abbreviate-file-name file))))
              (push (cons label (list :type 'recent :file file)) rows))))))
    (nreverse rows)))

;;;###autoload
(defun repo-swap-switch-buffer-or-recentf ()
  "Switch to an open buffer or open a recent file.

Open-buffer choices use normal `switch-to-buffer' behavior.  Recent-file
choices open their exact recentf path unless `repo-swap-integrate-recentf' is
non-nil, in which case the same relative file in the originating checkout is
preferred when it exists."
  (interactive)
  (let* ((origin-root (repo-swap--current-root-noerror))
         (table (repo-swap--switch-buffer-completion-table))
         (choice (completing-read "Switch to buffer or recent file: "
                                  table nil t nil 'buffer-name-history))
         (item (cdr (assoc choice table))))
    (pcase (plist-get item :type)
      ('buffer
       (switch-to-buffer (plist-get item :buffer)))
      ('recent
       (repo-swap-recentf-open-file
        (plist-get item :file) origin-root))
      (_
       (user-error "No buffer or recent file selected")))))

;;;###autoload
(defun repo-swap-remember-current-root ()
  "Remember the current buffer's checkout root."
  (interactive)
  (unless repo-swap-remember-roots
    (user-error "Persistent remembered roots are disabled"))
  (let ((root (repo-swap-current-root)))
    (repo-swap--remember-root root)
    (message "repo-swap: remembered %s" root)))

;;;###autoload
(defun repo-swap-list-known-roots ()
  "Display roots currently known to repo-swap."
  (interactive)
  (when (and repo-swap-remember-roots
             (null repo-swap--known-roots))
    (repo-swap--load-known-roots))
  (with-current-buffer (get-buffer-create "*repo-swap roots*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "repo-swap known roots\n\n")
      (insert (format "Remembered-roots file: %s\n"
                      (if repo-swap-remember-roots
                          (abbreviate-file-name repo-swap-known-roots-file)
                        "disabled")))
      (insert (format "Sibling scanning: %s\n\n"
                      (if repo-swap-include-sibling-roots
                          "enabled"
                        "disabled")))
      (dolist (root (sort (delete-dups
                           (append
                            (when repo-swap-remember-roots
                              (copy-sequence repo-swap--known-roots))
                            repo-swap-extra-roots
                            (repo-swap--modpatch-context-roots)))
                          #'string-lessp))
        (insert root "\n"))
      (goto-char (point-min))
      (special-mode))
    (display-buffer (current-buffer))))

(defun repo-swap--maybe-remember-current-root ()
  "Cache and optionally remember the current checkout root after visiting a file."
  (when (and repo-swap-mode buffer-file-name)
    (ignore-errors
      (repo-swap--refresh-buffer-root)
      (when repo-swap-remember-roots
        (repo-swap--remember-root repo-swap--buffer-root)))))

(defvar repo-swap-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c r s") #'repo-swap-open-same-file)
    (define-key map (kbd "C-c r r") #'repo-swap-remember-current-root)
    (define-key map (kbd "C-c r l") #'repo-swap-list-known-roots)
    (define-key map (kbd "C-c b") #'repo-swap-switch-buffer-or-recentf)
    map)
  "Keymap for `repo-swap-mode'.")

;;;###autoload
(define-minor-mode repo-swap-mode
  "Global minor mode for jumping between equivalent files in local checkouts."
  :global t
  :lighter (:eval (repo-swap--mode-line-lighter))
  :keymap repo-swap-mode-map
  (if repo-swap-mode
      (progn
        (when repo-swap-remember-roots
          (repo-swap--load-known-roots))
        (add-hook 'find-file-hook #'repo-swap--maybe-remember-current-root)
        (when repo-swap-integrate-recentf
          (repo-swap--install-recentf-integration))
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (when buffer-file-name
              (repo-swap--maybe-remember-current-root)))))
    (remove-hook 'find-file-hook #'repo-swap--maybe-remember-current-root)
    (repo-swap--remove-recentf-integration)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (setq repo-swap--buffer-root nil)))
    (force-mode-line-update t)))

(with-eval-after-load 'recentf
  (when (and repo-swap-mode repo-swap-integrate-recentf)
    (repo-swap--install-recentf-integration)))

(provide 'repo-swap)

;;; repo-swap.el ends here
