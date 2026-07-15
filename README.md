# repo-swap.el

Version 0.1.9

`repo-swap.el` is a small Emacs global minor mode for jumping between the same relative file in different local checkouts, worktrees, or clones.

Example:

```text
C:/Users/user/Documents/Visual Studio 2015/Projects/ShapeShift/Assets/Lua/testmodule.lua
J:/Projects/ShapeShift_featureWork/Assets/Lua/testmodule.lua
```

From either file, `repo-swap-open-same-file` computes `Assets/Lua/testmodule.lua`, finds another known root containing that relative path, and opens it. Repo Swap does not diff, sync, patch, or rewrite either file.

## Install with use-package

Put `repo-swap.el` in:

```text
~/.emacs.d/repo-swap/repo-swap.el
```

Then use:

```elisp
(add-to-list 'load-path
             (expand-file-name "repo-swap" user-emacs-directory))

(use-package repo-swap
  :ensure nil
  :demand t

  :init
  ;; nil = keep the old buffer; t = kill it; 'ask = ask each time.
  (setq repo-swap-kill-old-buffer nil)

  ;; Remember encountered checkout roots across Emacs sessions.
  (setq repo-swap-remember-roots t)

  ;; Do not enumerate sibling directories automatically.
  (setq repo-swap-include-sibling-roots nil)

  ;; Persistent remembered-root location.
  (setq repo-swap-known-roots-file
        (expand-file-name "repo-swap/known-roots.el"
                          user-emacs-directory))

  ;; Extra roots that should always be considered.
  (setq repo-swap-extra-roots nil)

  ;; Use loaded ModPatch contexts as additional known roots.
  (setq repo-swap-use-modpatch-contexts t)

  ;; Prefer a ModPatch context when identifying the current root.
  (setq repo-swap-prefer-modpatch-root t)

  ;; Show Git branch names in the checkout picker.
  (setq repo-swap-show-git-branch t)

  ;; Show RepoSwap[checkout-name] in the mode line.
  (setq repo-swap-show-root-in-mode-line t)

  ;; Opt in: make built-in recentf prefer the current checkout's copy.
  (setq repo-swap-integrate-recentf t)

  ;; Include recent files in the C-c b buffer switcher.
  (setq repo-swap-switch-buffer-include-recentf t)

  ;; Recognize loaded recent-file commands by name.  This is the default.
  (setq repo-swap-recentf-command-regexp
        "\\(?:recentf\\|recent-file\\)")

  ;; Explicit recent-file command entry points retained across minibuffer use.
  ;; Loaded matching commands are also discovered automatically.
  (setq repo-swap-recentf-command-functions
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
          counsel-switch-buffer-other-window))

  ;; Log command entry and origin/source/target decisions to *Messages*.
  (setq repo-swap-debug nil)

  :config
  (repo-swap-mode 1))
```

`repo-swap-integrate-recentf` defaults to `nil`; the example deliberately enables it so you can try the feature.

## Commands

- `M-x repo-swap-open-same-file` / `C-c r s`  
  Open the same relative file in another known checkout.

- `M-x repo-swap-switch-buffer-or-recentf` / `C-c b`  
  Offer live buffers and recent files in one completion list. A live-buffer choice uses normal `switch-to-buffer`. A recent-file choice follows `repo-swap-integrate-recentf`: redirected when enabled, exact recentf path when disabled.

- `M-x repo-swap-remember-current-root` / `C-c r r`  
  Add the current checkout root to the user-local known-roots file.

- `M-x repo-swap-list-known-roots` / `C-c r l`  
  Show remembered roots and loaded ModPatch roots.

- `M-x repo-swap-refresh-recentf-integration`  
  Reinstall or remove the recentf wrapper after changing `repo-swap-integrate-recentf` while Repo Swap is already running.

- `M-x repo-swap-debug-recentf-target`  
  Choose a recent file and report the invoking root, source checkout, selected target, current `recentf-menu-action`, and whether redirection would occur.

- `M-x repo-swap-version`  
  Report the loaded Repo Swap version, exact source file, recentf integration state, number of advised recent-file commands, and Ivy advice status.

- `M-x repo-swap-debug-integration`  
  Show detailed status for every built-in and configured recent-file/switch-buffer entry point, including whether it is missing, still an autoload stub, loaded without advice, or advised.

Normal live-buffer choices from `C-x b` remain unchanged.  With Ivy virtual buffers and recentf integration enabled, recent-file choices from `C-x b` are Repo-Swap-aware.

## Recentf integration

The integration is disabled by default:

```elisp
(setq repo-swap-integrate-recentf nil)
```

Enable it before `repo-swap-mode` starts:

```elisp
(setq repo-swap-integrate-recentf t)
```

Suppose you are currently working in:

```text
J:/Projects/ShapeShift_featureWork/
```

and recentf contains:

```text
C:/.../ShapeShift/Assets/Lua/testmodule.lua
```

When the feature is enabled, Repo Swap checks whether this exists:

```text
J:/Projects/ShapeShift_featureWork/Assets/Lua/testmodule.lua
```

If it exists, recentf opens that feature-work copy. If the selected recent file is not under another known checkout, or the corresponding file does not exist in the current checkout, recentf opens its original exact path.

The current checkout is captured before recentf opens its dialog, so the dialog buffer itself does not lose the destination context.

Repo Swap also recognizes recent-file commands that bypass
`recentf-menu-action`.  It wraps loaded recent-file entry commands for their
entire dynamic execution, so the checkout active before the completion UI opens
survives recursive minibuffer commands.  The eventual low-level
`find-file-noselect` call is redirected only when its path is actually present
in `recentf-list`.  This covers `find-file`, `find-file-other-window`, Consult,
Counsel, Helm, and similar front ends without changing ordinary file opens.

Known entry points are listed in `repo-swap-recentf-command-functions`, and
loaded interactive commands whose names match
`repo-swap-recentf-command-regexp` are discovered automatically.  Required
built-in adapters such as `ivy-switch-buffer` are always considered even when
an older customization of `repo-swap-recentf-command-functions` omits them.
Explicit autoloaded commands are loaded before advice is attached, preventing
their real definition from replacing an advised autoload stub.  Add a custom
front end to the configurable list and refresh the integration when necessary.

If you change the setting after Repo Swap is already enabled:

```elisp
(setq repo-swap-integrate-recentf t)
(repo-swap-refresh-recentf-integration)
```


## Debugging recentf redirection

Temporarily enable decision logging:

```elisp
(setq repo-swap-debug t)
```

Then invoke the recent-file command again and inspect `*Messages*`.  You should
first see an `entered command=... origin=...` line.  A later decision line
includes the command, preferred checkout, source checkout, exact recentf path,
and final target.

You can also inspect a path without opening it:

```text
M-x repo-swap-debug-recentf-target
```

For a `ShapeShift` entry opened while working in `ShapeShift_featureWork`, the
important fields should resemble:

```text
preferred=.../ShapeShift_featureWork/
source=.../ShapeShift/
target=.../ShapeShift_featureWork/<same-relative-file>
redirected=t
```

After replacing or reloading `repo-swap.el`, reapply the advice without
restarting Emacs:

```elisp
(repo-swap-refresh-recentf-integration)
```

Confirm the exact loaded build and path with:

```text
M-x repo-swap-version
```

Version 0.1.9 reports only advice that is still attached to the current final
function definitions.  Run `M-x repo-swap-debug-integration` for per-command
status.

## Combined buffer/recent-file switcher

`C-c b` acts like a broader `C-x b`:

```text
[Buffer] testmodule.lua
[Buffer] *Messages*
[Recent] GameSim.cpp — C:/.../GameSim.cpp
```

- Selecting `[Buffer] ...` switches to that existing buffer normally.
- Selecting `[Recent] ...` opens the file.
- When recentf integration is enabled, the recent entry is redirected into the checkout active when `C-c b` was invoked.
- When integration is disabled, the exact path stored by recentf is opened.

Disable recent-file candidates while retaining the command as a buffer switcher:

```elisp
(setq repo-swap-switch-buffer-include-recentf nil)
```

## Mode-line checkout label

The bracketed checkout label appears only when the currently viewed relative
file exists in at least one other currently known checkout.  This makes the
label a direct signal that the file is swappable right now:

```text
RepoSwap[ShapeShift_featureWork]
```

When no other known checkout contains that file, the mode line simply shows:

```text
RepoSwap
```

If matching checkout basenames collide, parent components are added until unique:

```text
RepoSwap[left/ShapeShift]
RepoSwap[right/ShapeShift]
```

If one parent is still insufficient:

```text
RepoSwap[left/Projects/ShapeShift]
RepoSwap[right/Projects/ShapeShift]
```

Disable the label with:

```elisp
(setq repo-swap-show-root-in-mode-line nil)
```

## Root discovery

The current root is found in this order:

1. The current buffer's ModPatch v2 context, when available.
2. The nearest `.modpatch-project.el`, `.git`, or `.hg` marker.
3. The `project.el` root.
4. The VC root.

Candidate target roots come from:

- remembered roots when `repo-swap-remember-roots` is non-nil;
- `repo-swap-extra-roots`;
- loaded ModPatch v2 contexts;
- sibling directories only when `repo-swap-include-sibling-roots` is non-nil.

Remembered roots are enabled by default. Sibling scanning is disabled by default.

## ModPatch support

ModPatch v2 does not retain one permanent registry of every checkout. It has one `.modpatch-project.el` manifest per checkout and in-memory contexts for projects loaded during the current Emacs session.

Repo Swap uses those loaded contexts when available and maintains its own lightweight `known-roots.el` file, so roots remain available across restarts without requiring sibling scans.

## Running tests

The suite now contains 27 ERT tests:

```bat
"C:\Users\user\Downloads\emacs-28.2\bin\emacs.exe" -Q --batch ^
  -L "%APPDATA%\.emacs.d\repo-swap" ^
  -l "%APPDATA%\.emacs.d\repo-swap\repo-swap-tests.el" ^
  -f ert-run-tests-batch-and-exit
```

## Changelog

### 0.1.9

- Fixed the use-package example accidentally overriding the newer default command list without Ivy switch-buffer entry points.
- Treat Ivy and other required built-in integration entry points as mandatory even when an older user customization omits them.
- Load explicit autoloaded commands before attaching advice so the final byte-compiled definition cannot replace an advised autoload stub.
- Make `M-x repo-swap-version` count only advice still attached to current definitions and distinguish `autoload-not-advised` from `loaded-not-advised`.
- Added `M-x repo-swap-debug-integration` for per-command diagnostics.
- Added three regression tests, bringing the suite to 27 tests.

### 0.1.8

- Integrate Ivy virtual recent buffers selected through `ivy-switch-buffer` / `C-x b`.
- Preserve the invoking checkout while Ivy opens a virtual recent file through its switch-buffer action.
- Extend `M-x repo-swap-version` with `ivy=advised`, `ivy=loaded-not-advised`, or `ivy=not-loaded` status.
- Added three Ivy integration regression tests, bringing the suite to 24 tests.

### 0.1.7

- Keep the invoking checkout dynamically bound for the complete recent-file command, including recursive minibuffer sessions.
- Redirect at `find-file-noselect`, covering `find-file-other-window` and completion front ends that bypass `recentf-menu-action`.
- Automatically advise loaded recent-file commands and refresh advice after libraries load.
- Added `M-x repo-swap-version`, including source path and recentf-advice status.
- Fixed the ERT harness so `recentf-list` is dynamically bound under lexical binding.
- Expanded the suite to 21 tests.

### 0.1.6

- Preserve the checkout active before the recent-file command instead of trusting the action-time buffer.
- Support recent-file commands such as `consult-recent-file` and `counsel-recentf` that call `find-file` directly.
- Keep ordinary `find-file` exact even when its path is already in `recentf-list`.
- Added `repo-swap-debug`, `repo-swap-debug-recentf-target`, and five ERT regression tests.

### 0.1.5

- Show the bracketed checkout label only when the currently viewed relative file exists in another currently known checkout.
- Disambiguate the label only against roots that contain that same file.
- Added ERT coverage for absent peer files and stale same-basename roots.

### 0.1.4

- Added opt-in Repo-Swap-aware recentf opening through `repo-swap-integrate-recentf`.
- Added exact-path fallback when the corresponding file is absent from the active checkout.
- Added `repo-swap-refresh-recentf-integration` for runtime setting changes.
- Added `repo-swap-switch-buffer-or-recentf`, bound to `C-c b`.
- Kept ordinary `C-x b` unchanged.
- Added six ERT tests for recentf resolution, integration lifecycle, and the combined switcher.

### 0.1.3

- Added a dynamic mode-line checkout label such as `RepoSwap[ShapeShift_featureWork]`.
- Added shortest-unique-suffix disambiguation for roots sharing the same basename.
- Added `repo-swap-show-root-in-mode-line`, enabled by default.
- Added ERT coverage for one-level and multi-level parent disambiguation.

### 0.1.2

- Fixed candidate-root filtering so valid remembered, extra, ModPatch, and sibling roots are retained instead of discarded.
- Added ERT coverage for swapping the same relative file between two remembered checkout roots.


### Ivy `C-x b` virtual recent files

When `ivy-use-virtual-buffers` is non-nil, Ivy adds `recentf-list` entries to
`ivy-switch-buffer` as virtual buffers.  These are not opened through a command
whose name contains `recentf`; Ivy's switch-buffer action resolves the virtual
candidate and opens its stored file path itself.

Repo Swap explicitly wraps `ivy-switch-buffer` and
`ivy-switch-buffer-other-window`, so the existing opt-in setting also applies
to recent-file candidates selected from Ivy's `C-x b`:

```elisp
(setq repo-swap-integrate-recentf t)
```

Live buffer selections remain ordinary buffer switches.  Only an Ivy virtual
candidate whose target is present in `recentf-list` is eligible for checkout
redirection.

After reloading while Ivy is already active, run:

```elisp
(repo-swap-refresh-recentf-integration)
(repo-swap-version)
```

The version message should report `ivy=advised`.  Other statuses are:

- `ivy=missing`: Ivy is unavailable.
- `ivy=autoload-not-advised`: only the autoload stub exists; refresh should load and advise the final definition.
- `ivy=loaded-not-advised`: Ivy is loaded but advice is missing.

Version 0.1.9 protects required Ivy entry points from being removed by an older
`repo-swap-recentf-command-functions` customization.  It also loads autoloaded
entry points before attaching advice.
