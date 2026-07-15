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

(provide 'repo-swap-tests)

;;; repo-swap-tests.el ends here
