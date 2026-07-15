;;; repo-swap-tests.el --- Tests for repo-swap -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
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
            (should
             (equal (repo-swap--mode-line-lighter)
                    " RepoSwap[left/ShapeShift]"))))
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

(provide 'repo-swap-tests)

;;; repo-swap-tests.el ends here
