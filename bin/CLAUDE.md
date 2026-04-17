# bin/ — MarkEdit CLI Tools

## Files

- `markedit` — open files in MarkEdit.app from the terminal
- `markedit-plugins` — plugin manager (install, update, search, remove)
- `markedit-switcher.lua` — Hammerspoon module: quick-switch between open MarkEdit windows (Cmd+Shift+E)
- `install-cli.sh` — installs CLI tools to `~/.local/bin` and optionally links Hammerspoon module

## Installing

```bash
bin/install-cli.sh           # prompts before overwriting existing tools
bin/install-cli.sh --upgrade # skips confirmation, good for updates
```

## markedit-plugins

Plugins install to:
```
~/Library/Containers/app.cyan.markedit/Data/Documents/scripts/
```

Override with `MARKEDIT_SCRIPTS_DIR` env var. The directory is created
on first run if missing.

All plugins (including themes) go into `scripts/` — there is no
separate `styles/` directory.

### Config files (inside scripts/)

- `plugins.json` — list of installed plugins (auto-created if missing)
- `plugins.lock.json` — locked versions and hashes
- `.plugins-cache.json` — GitHub org repo cache (TTL: 1 hour)

### Commands

```
markedit-plugins search [query]   browse/install interactively (curses picker)
markedit-plugins add <repo>       add and install a plugin
markedit-plugins remove <repo>    remove a plugin
markedit-plugins update [repo]    update all or one plugin
markedit-plugins install          install all plugins from plugins.json
markedit-plugins status           show installed plugins and update status
markedit-plugins list             list available plugins from GitHub org
```

Repo names are flexible: `vim`, `MarkEdit-vim`, or `MarkEdit-app/MarkEdit-vim`
all resolve to the same thing.

### search picker controls

- `↑/↓` or `j/k` — move cursor
- `space` — toggle selection (installed plugins are skipped)
- `enter` — install selected
- `q` / `esc` / `ctrl+c` — quit without installing

## Commit conventions

- One file per commit, atomic
- Commit order matters: `markedit` → `markedit-plugins` → `install-cli.sh`
  (installer always last, after the tools it installs exist)
- Use fixup + rebase --autosquash for iterative fixes
- Never include unrelated deletions in a commit

## markedit-switcher.lua

Hammerspoon module that provides a quick-switch chooser (Cmd+Shift+E)
for jumping between open MarkEdit windows. Only active when MarkEdit
is the frontmost app.

Requires [Hammerspoon](https://www.hammerspoon.org/). The installer
auto-detects `~/.hammerspoon/` — if present, it symlinks the module
and adds the `require` to `init.lua`. If Hammerspoon is not installed,
it silently skips.
