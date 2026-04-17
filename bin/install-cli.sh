#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# globals
# ──────────────────────────────────────────────

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$HOME/.local/bin"
TOOLS=(markedit markedit-plugins)
UPGRADE=false

# ──────────────────────────────────────────────
# helpers
# ──────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [--upgrade]

  --upgrade   overwrite existing tools without prompting
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upgrade) UPGRADE=true; shift ;;
      -h | --help) usage ;;
      *)
        echo "[error] unknown option: $1" >&2
        exit 1
        ;;
    esac
  done
}

check_sources() {
  local missing=false

  for tool in "${TOOLS[@]}"; do
    if [[ ! -f "$BIN_DIR/$tool" ]]; then
      echo "[error] source not found: $BIN_DIR/$tool" >&2
      missing=true
    fi
  done

  if [[ "$missing" == true ]]; then
    exit 1
  fi
}

confirm_overwrite() {
  local dest="$1"
  local response=""

  read -r -p "  $dest already exists. overwrite? [y/N] " response
  case "$response" in
    [yY][eE][sS] | [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

install_tool() {
  local tool="$1"
  local src="$BIN_DIR/$tool"
  local dest="$DEST_DIR/$tool"

  if [[ -e "$dest" ]] || [[ -L "$dest" ]]; then
    if [[ "$UPGRADE" == false ]] && ! confirm_overwrite "$dest"; then
      echo "  skipped $tool"
      return
    fi
  fi

  cp "$src" "$dest"
  chmod +x "$dest"
  echo "  installed $tool → $dest"
}

install_hammerspoon_module() {
  local hs_dir="$HOME/.hammerspoon"
  local src="$BIN_DIR/markedit-switcher.lua"
  local dest="$hs_dir/markedit-switcher.lua"

  if [[ ! -d "$hs_dir" ]]; then
    echo "  hammerspoon not found, skipping markedit-switcher"
    return
  fi

  if [[ ! -f "$src" ]]; then
    echo "[error] source not found: $src" >&2
    return
  fi

  if [[ -e "$dest" ]] || [[ -L "$dest" ]]; then
    if [[ "$UPGRADE" == false ]] && ! confirm_overwrite "$dest"; then
      echo "  skipped markedit-switcher.lua"
      return
    fi
    rm -f "$dest"
  fi

  ln -s "$src" "$dest"
  echo "  linked markedit-switcher.lua → $dest"

  if ! grep -q 'require("markedit-switcher")' "$hs_dir/init.lua" 2>/dev/null; then
    echo "" >> "$hs_dir/init.lua"
    echo 'require("markedit-switcher")' >> "$hs_dir/init.lua"
    echo "  added require(\"markedit-switcher\") to init.lua"
  fi
}

# ──────────────────────────────────────────────
# main
# ──────────────────────────────────────────────

main() {
  parse_args "$@"
  check_sources

  mkdir -p "$DEST_DIR"

  printf "installing MarkEdit CLI tools...\n\n"
  for tool in "${TOOLS[@]}"; do
    install_tool "$tool"
  done

  printf "\n"
  install_hammerspoon_module

  printf "\ndone. make sure %s is in your PATH.\n" "$DEST_DIR"
}

main "$@"
