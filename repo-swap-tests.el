;;; repo-swap-tests.el --- Tests for repo-swap -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'recentf)
(require 'repo-swap)

(defun repo-swap-test--write-file (file text)
  "Write TEXT to FILE, creating parent directories."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert text)))

(ert-deftest repo-swap-test-remembered-root-produces-candidate ()
  "A remembered checkout containing the same relative file is a candidate."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "ShapeShift/" sandbox))
         (root-b (expand-file-name "ShapeShift_featureWork/" sandbox))
         (relative "Assets/Lua/testmodule.lua")
         (file-a (expand-file-name relative root-a))
         (file-b (expand-file-name relative root-b))
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-include-sibling-roots nil)
         (repo-swap-use-modpatch-contexts nil)
         (repo-swap--known-roots nil))
    (unwind-protect
        (progn
          (repo-swap-test--write-file file-a "return 'a'\n")
          (repo-swap-test--write-file file-b "return 'b'\n")
          (setq repo-swap--known-roots
                (list (repo-swap--canonical-directory root-a)
                      (repo-swap--canonical-directory root-b)))
          (let ((candidates
                 (repo-swap--candidate-files
                  file-a
                  (repo-swap--canonical-directory root-a))))
            (should (= (length candidates) 1))
            (should
             (repo-swap--same-file-name-p
              (plist-get (car candidates) :file)
              file-b))))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-all-known-roots-retains-valid-directories ()
  "Valid roots must survive candidate-root filtering."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "a/" sandbox))
         (root-b (expand-file-name "b/" sandbox))
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-include-sibling-roots nil)
         (repo-swap-use-modpatch-contexts nil))
    (unwind-protect
        (progn
          (make-directory root-a t)
          (make-directory root-b t)
          (setq repo-swap--known-roots
                (list (repo-swap--canonical-directory root-b)))
          (let ((roots
                 (repo-swap--all-known-roots
                  (repo-swap--canonical-directory root-a))))
            (should (= (length roots) 2))
            (should (cl-some
                     (lambda (root)
                       (repo-swap--same-file-name-p root root-a))
                     roots))
            (should (cl-some
                     (lambda (root)
                       (repo-swap--same-file-name-p root root-b))
                     roots))))
      (delete-directory sandbox t))))


(ert-deftest repo-swap-test-unique-root-label-uses-basename-when-unique ()
  "A unique checkout basename is sufficient for the mode-line label."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "left/ShapeShift/" sandbox))
         (root-b (expand-file-name "right/OtherRepo/" sandbox)))
    (unwind-protect
        (progn
          (make-directory root-a t)
          (make-directory root-b t)
          (should
           (equal
            (repo-swap--unique-root-label root-a (list root-a root-b))
            "ShapeShift")))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-unique-root-label-adds-parent-for-duplicate-basename ()
  "Duplicate checkout basenames gain one parent component."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "left/ShapeShift/" sandbox))
         (root-b (expand-file-name "right/ShapeShift/" sandbox)))
    (unwind-protect
        (progn
          (make-directory root-a t)
          (make-directory root-b t)
          (should
           (equal
            (repo-swap--unique-root-label root-a (list root-a root-b))
            "left/ShapeShift"))
          (should
           (equal
            (repo-swap--unique-root-label root-b (list root-a root-b))
            "right/ShapeShift")))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-unique-root-label-keeps-adding-parents ()
  "Disambiguation keeps walking upward while suffixes remain identical."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "left/Projects/ShapeShift/" sandbox))
         (root-b (expand-file-name "right/Projects/ShapeShift/" sandbox)))
    (unwind-protect
        (progn
          (make-directory root-a t)
          (make-directory root-b t)
          (should
           (equal
            (repo-swap--unique-root-label root-a (list root-a root-b))
            "left/Projects/ShapeShift"))
          (should
           (equal
            (repo-swap--unique-root-label root-b (list root-a root-b))
            "right/Projects/ShapeShift")))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-mode-line-shows-unique-root-label-in-brackets ()
  "The dynamic lighter includes the disambiguated checkout label."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "left/ShapeShift/" sandbox))
         (root-b (expand-file-name "right/ShapeShift/" sandbox))
         (file-a (expand-file-name "Assets/Lua/testmodule.lua" root-a))
         (file-b (expand-file-name "Assets/Lua/testmodule.lua" root-b))
         (repo-swap-show-root-in-mode-line t)
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-use-modpatch-contexts nil)
         (repo-swap--known-roots nil))
    (unwind-protect
        (progn
          (repo-swap-test--write-file file-a "return true\n")
          (repo-swap-test--write-file file-b "return false\n")
          (setq repo-swap--known-roots
                (list (repo-swap--canonical-directory root-a)
                      (repo-swap--canonical-directory root-b)))
          (with-temp-buffer
            (setq buffer-file-name file-a)
            (setq-local repo-swap--buffer-root
                        (repo-swap--canonical-directory root-a))
            (should
             (equal (repo-swap--mode-line-lighter)
                    " RepoSwap[left/ShapeShift]"))))
      (delete-directory sandbox t))))


(ert-deftest repo-swap-test-mode-line-hides-root-label-without-peer-file ()
  "The bracketed checkout label is absent when no known peer contains the file."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "left/ShapeShift/" sandbox))
         (root-b (expand-file-name "right/ShapeShift/" sandbox))
         (file-a (expand-file-name "Assets/Lua/testmodule.lua" root-a))
         (repo-swap-show-root-in-mode-line t)
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-use-modpatch-contexts nil)
         (repo-swap--known-roots nil))
    (unwind-protect
        (progn
          (repo-swap-test--write-file file-a "return true\n")
          (make-directory root-b t)
          (setq repo-swap--known-roots
                (list (repo-swap--canonical-directory root-a)
                      (repo-swap--canonical-directory root-b)))
          (with-temp-buffer
            (setq buffer-file-name file-a)
            (setq-local repo-swap--buffer-root
                        (repo-swap--canonical-directory root-a))
            (should (equal (repo-swap--mode-line-lighter)
                           " RepoSwap"))))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-mode-line-disambiguates-only-among-peer-file-roots ()
  "Known roots lacking the viewed file do not lengthen the checkout label."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "left/ShapeShift/" sandbox))
         (stale-root (expand-file-name "right/ShapeShift/" sandbox))
         (peer-root (expand-file-name "other/ShapeShift_featureWork/" sandbox))
         (relative "Assets/Lua/testmodule.lua")
         (file-a (expand-file-name relative root-a))
         (peer-file (expand-file-name relative peer-root))
         (repo-swap-show-root-in-mode-line t)
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-use-modpatch-contexts nil)
         (repo-swap--known-roots nil))
    (unwind-protect
        (progn
          (repo-swap-test--write-file file-a "return 'a'\n")
          (repo-swap-test--write-file peer-file "return 'peer'\n")
          (make-directory stale-root t)
          (setq repo-swap--known-roots
                (mapcar #'repo-swap--canonical-directory
                        (list root-a stale-root peer-root)))
          (with-temp-buffer
            (setq buffer-file-name file-a)
            (setq-local repo-swap--buffer-root
                        (repo-swap--canonical-directory root-a))
            (should (equal (repo-swap--mode-line-lighter)
                           " RepoSwap[ShapeShift]"))))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-recentf-target-redirects-into-preferred-root ()
  "A recent file in another known checkout redirects into the current root."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "ShapeShift/" sandbox))
         (root-b (expand-file-name "ShapeShift_featureWork/" sandbox))
         (relative "Assets/Lua/testmodule.lua")
         (file-a (expand-file-name relative root-a))
         (file-b (expand-file-name relative root-b))
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-include-sibling-roots nil)
         (repo-swap-use-modpatch-contexts nil)
         (repo-swap--known-roots nil))
    (unwind-protect
        (progn
          (repo-swap-test--write-file file-a "return 'a'\n")
          (repo-swap-test--write-file file-b "return 'b'\n")
          (setq repo-swap--known-roots
                (list (repo-swap--canonical-directory root-a)
                      (repo-swap--canonical-directory root-b)))
          (should
           (repo-swap--same-file-name-p
            (repo-swap--recentf-target-file file-a root-b)
            file-b)))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-recentf-target-keeps-exact-path-when-peer-missing ()
  "A recent file keeps its exact path when the preferred checkout lacks it."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "ShapeShift/" sandbox))
         (root-b (expand-file-name "ShapeShift_featureWork/" sandbox))
         (relative "Assets/Lua/only-in-a.lua")
         (file-a (expand-file-name relative root-a))
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-include-sibling-roots nil)
         (repo-swap-use-modpatch-contexts nil)
         (repo-swap--known-roots nil))
    (unwind-protect
        (progn
          (repo-swap-test--write-file file-a "return 'a'\n")
          (make-directory root-b t)
          (setq repo-swap--known-roots
                (list (repo-swap--canonical-directory root-a)
                      (repo-swap--canonical-directory root-b)))
          (should
           (repo-swap--same-file-name-p
            (repo-swap--recentf-target-file file-a root-b)
            file-a)))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-recentf-action-keeps-exact-path-when-disabled ()
  "The recentf wrapper preserves normal recentf behavior when integration is off."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (file (expand-file-name "sample.lua" sandbox))
         (repo-swap-integrate-recentf nil)
         (opened nil)
         (repo-swap--recentf-original-action
          (lambda (target) (setq opened target))))
    (unwind-protect
        (progn
          (repo-swap-test--write-file file "return true\n")
          (repo-swap-recentf-open-file file nil)
          (should (repo-swap--same-file-name-p opened file)))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-recentf-integration-wraps-and-restores-action ()
  "Installing recentf integration replaces and then restores its action."
  (require 'recentf)
  (let ((original-action recentf-menu-action)
        (repo-swap--recentf-original-action nil))
    (unwind-protect
        (progn
          (repo-swap--install-recentf-integration)
          (should (eq recentf-menu-action
                      #'repo-swap-recentf-open-file))
          (repo-swap--remove-recentf-integration)
          (should (eq recentf-menu-action original-action)))
      (setq recentf-menu-action original-action)
      (dolist (function repo-swap--recentf-origin-functions)
        (when (fboundp function)
          (advice-remove function
                         #'repo-swap--capture-recentf-origin))))))

(ert-deftest repo-swap-test-combined-switcher-switches-live-buffer-normally ()
  "A live-buffer choice from the combined switcher uses switch-to-buffer."
  (let ((target (generate-new-buffer "repo-swap-target")))
    (unwind-protect
        (let ((table (list (cons "[Buffer] repo-swap-target"
                                 (list :type 'buffer :buffer target)))))
          (cl-letf (((symbol-function 'repo-swap--switch-buffer-completion-table)
                     (lambda () table))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _args) "[Buffer] repo-swap-target")))
            (repo-swap-switch-buffer-or-recentf)
            (should (eq (current-buffer) target))))
      (when (buffer-live-p target)
        (kill-buffer target)))))

(ert-deftest repo-swap-test-combined-switcher-opens-recent-through-wrapper ()
  "A recent choice from the combined switcher uses repo-swap's recentf wrapper."
  (let* ((file "c:/example/Assets/Lua/testmodule.lua")
         (table (list (cons "[Recent] testmodule.lua"
                            (list :type 'recent :file file))))
         (called-file nil)
         (called-root nil))
    (cl-letf (((symbol-function 'repo-swap--switch-buffer-completion-table)
               (lambda () table))
              ((symbol-function 'repo-swap--current-root-noerror)
               (lambda () "c:/example-root/"))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) "[Recent] testmodule.lua"))
              ((symbol-function 'repo-swap-recentf-open-file)
               (lambda (selected-file preferred-root)
                 (setq called-file selected-file)
                 (setq called-root preferred-root))))
      (repo-swap-switch-buffer-or-recentf)
      (should (equal called-file file))
      (should (equal called-root "c:/example-root/")))))



(ert-deftest repo-swap-test-command-origin-captures-recentf-like-command ()
  "The pre-command hook uses the cached buffer root for recent-file commands."
  (let ((this-command 'consult-recent-file)
        (repo-swap--buffer-root "j:/Projects/ShapeShift_featureWork/")
        (repo-swap--command-origin-root nil))
    (cl-letf (((symbol-function 'repo-swap--current-root-noerror)
               (lambda () (error "Cached buffer root should have been used"))))
      (repo-swap--capture-command-origin)
      (should (equal repo-swap--command-origin-root
                     "j:/Projects/ShapeShift_featureWork/")))))

(ert-deftest repo-swap-test-command-origin-clears-for-unrelated-command ()
  "An unrelated command clears stale recentf origin without scanning the root."
  (let ((this-command 'next-line)
        (repo-swap--buffer-root "j:/Projects/ShapeShift_featureWork/")
        (repo-swap--command-origin-root "c:/Projects/ShapeShift/"))
    (cl-letf (((symbol-function 'repo-swap--current-root-noerror)
               (lambda () (error "Unrelated commands must not resolve roots"))))
      (repo-swap--capture-command-origin)
      (should-not repo-swap--command-origin-root))))

(ert-deftest repo-swap-test-recentf-preferred-root-keeps-command-origin ()
  "The invoking checkout wins over the buffer active when the action runs."
  (let ((repo-swap--command-origin-root "j:/Projects/ShapeShift_featureWork/")
        (repo-swap--recentf-origin-root "c:/Projects/ShapeShift/"))
    (cl-letf (((symbol-function 'repo-swap--current-root-noerror)
               (lambda () "c:/Projects/ShapeShift/")))
      (should
       (equal (repo-swap--recentf-preferred-root)
              "j:/Projects/ShapeShift_featureWork/")))))

(ert-deftest repo-swap-test-find-file-noselect-advice-redirects-consult-recent-file ()
  "A recent-file command's low-level file open is redirected."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (root-a (expand-file-name "ShapeShift/" sandbox))
         (root-b (expand-file-name "ShapeShift_featureWork/" sandbox))
         (relative "Assets/Lua/testmodule.lua")
         (file-a (expand-file-name relative root-a))
         (file-b (expand-file-name relative root-b))
         (repo-swap-mode t)
         (repo-swap-integrate-recentf t)
         (repo-swap-remember-roots t)
         (repo-swap-extra-roots nil)
         (repo-swap-include-sibling-roots nil)
         (repo-swap-use-modpatch-contexts nil)
         (repo-swap--known-roots nil)
         (repo-swap--active-recentf-origin-root nil)
         (repo-swap--active-recentf-command nil)
         (repo-swap--redirecting-recentf nil)
         (recentf-list nil)
         opened)
    (unwind-protect
        (progn
          (repo-swap-test--write-file file-a "return 'a'\n")
          (repo-swap-test--write-file file-b "return 'b'\n")
          (setq repo-swap--known-roots
                (mapcar #'repo-swap--canonical-directory
                        (list root-a root-b)))
          (setq repo-swap--active-recentf-origin-root
                (repo-swap--canonical-directory root-b))
          (setq repo-swap--active-recentf-command 'consult-recent-file)
          (setq recentf-list (list file-a))
          (repo-swap--find-file-noselect-around
           (lambda (target &rest _args) (setq opened target))
           file-a)
          (should (repo-swap--same-file-name-p opened file-b)))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-find-file-noselect-advice-leaves-ordinary-find-file-alone ()
  "A low-level open outside a retained recentf command remains exact."
  (let* ((sandbox (make-temp-file "repo-swap-test-" t))
         (file (expand-file-name "ShapeShift/sample.lua" sandbox))
         (repo-swap-mode t)
         (repo-swap-integrate-recentf t)
         (repo-swap--active-recentf-origin-root nil)
         (repo-swap--redirecting-recentf nil)
         (recentf-list nil)
         opened)
    (unwind-protect
        (progn
          (repo-swap-test--write-file file "return true\n")
          (setq recentf-list (list file))
          (repo-swap--find-file-noselect-around
           (lambda (target &rest _args) (setq opened target))
           file)
          (should (repo-swap--same-file-name-p opened file)))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-recentf-command-around-retains-origin-dynamically ()
  "The origin survives for the complete dynamic extent of a recentf command."
  (let ((repo-swap--buffer-root "j:/Projects/ShapeShift_featureWork/")
        (repo-swap--active-recentf-origin-root nil)
        (repo-swap--active-recentf-command nil)
        (this-command 'consult-recent-file)
        seen-root
        seen-command)
    (repo-swap--recentf-command-around
     (lambda ()
       (setq seen-root repo-swap--active-recentf-origin-root)
       (setq seen-command repo-swap--active-recentf-command)))
    (should (equal seen-root "j:/Projects/ShapeShift_featureWork/"))
    (should (eq seen-command 'consult-recent-file))))

(ert-deftest repo-swap-test-version-command-reports-current-version ()
  "The interactive version command identifies the loaded build."
  (should (equal repo-swap-version "0.1.9"))
  (should (commandp 'repo-swap-version))
  (should (equal (repo-swap-version) "0.1.9")))


(ert-deftest repo-swap-test-ivy-switch-buffer-is-explicit-integration-command ()
  "Ivy virtual recent files are recognized despite a non-recentf command name."
  (should (memq 'ivy-switch-buffer repo-swap-recentf-command-functions))
  (should (memq 'ivy-switch-buffer-other-window
                repo-swap-recentf-command-functions)))

(ert-deftest repo-swap-test-ivy-switch-buffer-command-retains-origin-dynamically ()
  "Ivy C-x b retains the checkout while its virtual-buffer action runs."
  (let ((repo-swap--buffer-root "j:/Projects/ShapeShift_featureWork/")
        (repo-swap--active-recentf-origin-root nil)
        (repo-swap--active-recentf-command nil)
        (this-command 'ivy-switch-buffer)
        seen-root
        seen-command)
    (repo-swap--recentf-command-around
     (lambda ()
       (setq seen-root repo-swap--active-recentf-origin-root)
       (setq seen-command repo-swap--active-recentf-command)))
    (should (equal seen-root "j:/Projects/ShapeShift_featureWork/"))
    (should (eq seen-command 'ivy-switch-buffer))))

(ert-deftest repo-swap-test-install-advises-loaded-ivy-switch-buffer ()
  "Refreshing integration advises Ivy's virtual-buffer entry command."
  (let ((had-function (fboundp 'ivy-switch-buffer))
        (old-function (and (fboundp 'ivy-switch-buffer)
                           (symbol-function 'ivy-switch-buffer)))
        (repo-swap--advised-recentf-commands nil))
    (unwind-protect
        (progn
          (fset 'ivy-switch-buffer (lambda () (interactive)))
          (repo-swap--install-recentf-command-advice)
          (should
           (advice-member-p #'repo-swap--recentf-command-around
                            'ivy-switch-buffer)))
      (advice-remove 'ivy-switch-buffer #'repo-swap--recentf-command-around)
      (if had-function
          (fset 'ivy-switch-buffer old-function)
        (fmakunbound 'ivy-switch-buffer)))))



(ert-deftest repo-swap-test-required-ivy-command-survives-older-custom-list ()
  "An older customization cannot accidentally remove Ivy integration."
  (let ((repo-swap-recentf-command-functions
         '(consult-recent-file counsel-recentf helm-recentf)))
    (should (memq 'ivy-switch-buffer
                  (repo-swap--recentf-command-symbols)))
    (should (repo-swap--explicit-recentf-command-p
             'ivy-switch-buffer))))

(ert-deftest repo-swap-test-installer-loads-autoload-before-advising ()
  "Explicit autoloaded commands are loaded before advice is attached."
  (let* ((sandbox (make-temp-file "repo-swap-autoload-test-" t))
         (library-base (expand-file-name "repo-swap-fake-ivy" sandbox))
         (library-file (concat library-base ".el"))
         (command 'repo-swap-test-autoloaded-switch-buffer)
         (repo-swap-recentf-command-functions (list command))
         (repo-swap-recentf-command-regexp "\\`never-match\\'")
         (repo-swap--advised-recentf-commands nil))
    (unwind-protect
        (progn
          (with-temp-file library-file
            (insert "(defun repo-swap-test-autoloaded-switch-buffer ()\n"
                    "  (interactive)\n"
                    "  'loaded)\n"))
          (when (fboundp command)
            (fmakunbound command))
          (autoload command library-base nil t)
          (should (repo-swap--autoloaded-function-p command))
          (repo-swap--install-recentf-command-advice)
          (should-not (repo-swap--autoloaded-function-p command))
          (should (advice-member-p
                   #'repo-swap--recentf-command-around command))
          (should (equal (repo-swap--command-advice-status command)
                         "advised")))
      (when (fboundp command)
        (advice-remove command #'repo-swap--recentf-command-around)
        (fmakunbound command))
      (delete-directory sandbox t))))

(ert-deftest repo-swap-test-debug-integration-is-an-interactive-command ()
  "The detailed integration diagnostic is available through M-x."
  (should (commandp 'repo-swap-debug-integration)))


(ert-deftest repo-swap-test-key-bindings-reinstalled-after-reload ()
  "New bindings are added even when an older keymap already exists."
  (let ((repo-swap-mode-map (make-sparse-keymap)))
    ;; Simulate a keymap retained from a version before `C-c b' existed.
    (define-key repo-swap-mode-map (kbd "C-c r s")
                #'repo-swap-open-same-file)
    (should-not (lookup-key repo-swap-mode-map (kbd "C-c b")))
    (repo-swap--install-key-bindings)
    (should (eq (lookup-key repo-swap-mode-map (kbd "C-c b"))
                #'repo-swap-switch-buffer-or-recentf))))

(provide 'repo-swap-tests)

;;; repo-swap-tests.el ends here
