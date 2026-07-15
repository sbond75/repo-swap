# repo-swap.el

Version 0.1.3

`repo-swap.el` is a small Emacs global minor mode for jumping between the same relative file in different local checkouts/worktrees/clones.

Example:

```text
C:/Users/user/Documents/Visual Studio 2015/Projects/test/Assets/Lua/testmodule.lua
J:/Projects/test_featureWork2/Assets/Lua/testmodule.lua
```

When invoked from the first file, `repo-swap-open-same-file` finds the current project root, computes `Assets/Lua/testmodule.lua`, finds other known roots that contain that relative file, and opens the selected copy.

It does not diff, sync, patch, or rewrite anything. The action is just:

1. Open the target file in a new/current buffer.
2. Optionally kill the original buffer, controlled by `repo-swap-kill-old-buffer`.

## Install

Put `repo-swap.el` in `~/.emacs.d/repo-swap/` or any directory on your load path.

```elisp
(add-to-list 'load-path
             (expand-file-name "repo-swap" user-emacs-directory))
(require 'repo-swap)
(repo-swap-mode 1)
```

Suggested settings:

```elisp
(setq repo-swap-kill-old-buffer 'ask) ;; nil, t, or 'ask

;; Enabled by default: remember roots across Emacs restarts.
(setq repo-swap-remember-roots t)

;; Disabled by default: do not enumerate sibling directories automatically.
(setq repo-swap-include-sibling-roots nil)

;; This is already the default; customize it if you prefer another location.
(setq repo-swap-known-roots-file
      (expand-file-name "repo-swap/known-roots.el" user-emacs-directory))

;; Enabled by default: show the current checkout in the mode line.
(setq repo-swap-show-root-in-mode-line t)
```

## Mode-line checkout label

When `repo-swap-mode` is enabled, file-visiting buffers show the current checkout
beside `RepoSwap`, for example:

```text
RepoSwap[ShapeShift_featureWork]
```

The shortest unique suffix of the checkout path is used. If several known roots
share the same directory basename, Repo Swap prepends parent directory components
until the labels are unique:

```text
RepoSwap[left/ShapeShift]
RepoSwap[right/ShapeShift]
```

If those parents are also identical, it keeps walking upward:

```text
RepoSwap[left/Projects/ShapeShift]
RepoSwap[right/Projects/ShapeShift]
```

The roots considered for disambiguation are remembered roots, explicit
`repo-swap-extra-roots`, and loaded ModPatch contexts. Sibling directories are
not scanned during mode-line redisplay. Disable the label with:

```elisp
(setq repo-swap-show-root-in-mode-line nil)
```

## Commands

- `M-x repo-swap-open-same-file` / `C-c r s`
  Open the same relative file in another known checkout.

- `M-x repo-swap-remember-current-root` / `C-c r r`
  Add the current checkout root to the user-local known-roots file.

- `M-x repo-swap-list-known-roots` / `C-c r l`
  Show remembered roots and loaded ModPatch roots.

## Root discovery

The current root is found in this order:

1. Current buffer's ModPatch v2 context, when available.
2. Nearest root marker such as `.modpatch-project.el`, `.git`, or `.hg`.
3. `project.el` root.
4. VC root.

Candidate target roots come from:

- user-local remembered roots when `repo-swap-remember-roots` is non-nil;
- `repo-swap-extra-roots`;
- loaded ModPatch v2 contexts;
- sibling directories next to the current checkout only when `repo-swap-include-sibling-roots` is non-nil.

Remembered roots are enabled by default. Sibling scanning is disabled by default.

## ModPatch support

ModPatch v2 does not maintain one complete permanent registry of every checkout. It has:

- `.modpatch-project.el` in each repo/worktree, which records associations for that repo only;
- user-local runtime state files under `modpatch-state-directory`;
- in-memory contexts for ModPatch projects that have been loaded in the current Emacs session.

`repo-swap` uses loaded ModPatch contexts when available. It also keeps its own lightweight user-local `known-roots.el` file so it does not depend on ModPatch being loaded first. Sibling scanning is optional and disabled by default.

## Suggested config with ModPatch

```elisp
(add-to-list 'load-path
             (expand-file-name "modpatch" user-emacs-directory))
(load-file (expand-file-name "modpatch/modpatch.el" user-emacs-directory))

(add-to-list 'load-path
             (expand-file-name "repo-swap" user-emacs-directory))
(require 'repo-swap)

(setq repo-swap-kill-old-buffer nil) ;; keep old buffer by default
(setq repo-swap-remember-roots t) ;; default
(setq repo-swap-include-sibling-roots nil) ;; default
(setq repo-swap-show-root-in-mode-line t) ;; default
(repo-swap-mode 1)
```



## Discovery settings

### Remembered roots

`repo-swap-remember-roots` defaults to `t`. When enabled, repo-swap:

- reads roots from `repo-swap-known-roots-file`;
- automatically remembers roots encountered while visiting files;
- writes newly discovered roots back to that file;
- uses those roots as swap candidates.

Set it to `nil` to disable all reading, writing, and use of the remembered-roots file:

```elisp
(setq repo-swap-remember-roots nil)
```

The file location is configurable:

```elisp
(setq repo-swap-known-roots-file
      (expand-file-name "repo-swap/known-roots.el" user-emacs-directory))
```

### Sibling scanning

`repo-swap-include-sibling-roots` defaults to `nil`. Enable it explicitly when you want repo-swap to enumerate sibling directories beside the current checkout:

```elisp
(setq repo-swap-include-sibling-roots t)
```


## Changelog

### 0.1.3

- Added a dynamic mode-line checkout label such as `RepoSwap[ShapeShift_featureWork]`.
- Added shortest-unique-suffix disambiguation for roots sharing the same basename.
- Added `repo-swap-show-root-in-mode-line`, enabled by default.
- Added ERT coverage for one-level and multi-level parent disambiguation.

### 0.1.2

- Fixed candidate-root filtering so valid remembered, extra, ModPatch, and sibling roots are retained instead of discarded.
- Added ERT coverage for swapping the same relative file between two remembered checkout roots.
