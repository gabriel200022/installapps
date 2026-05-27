#!/bin/bash

# =====================================================================
# 🔥 REPARARE INSTANTĂ MEDIU MDM (HEXNODE) 🔥
# =====================================================================
get_logged_in_user() {
  /usr/bin/stat -f "%Su" /dev/console 2>/dev/null || echo ""
}

get_home_dir() {
  local logged_in_user
  local home_dir
  logged_user="$(get_logged_in_user)"
  if [[ -n "$logged_user" && "$logged_user" != "root" ]]; then
    home_dir="$(dscl . -read "/Users/$logged_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  else
    home_dir="/var/root"
  fi
  echo "${home_dir:-/var/root}"
}

REAL_USER="$(get_logged_in_user)"
REAL_HOME="$(get_home_dir)"

export USER="${REAL_USER:-root}"
export HOME="$REAL_HOME"
export LOGNAME="${REAL_USER:-root}"

# =====================================================================
# Regulile stricte de siguranță (ajustate pentru toleranță la suprascriere)
# =====================================================================
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -euo pipefail

ARCH="$(uname -m)"
WORK_DIR="/var/hexnodeApp"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "MDM Environment Patched Successfully:"
echo "-> USER: $USER | HOME: $HOME"
echo "----------------------------------------------------"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is not installed"
  exit 1
fi

run_cmd_as_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

attach_dmg() {
  hdiutil attach "$1" -nobrowse | sed -n 's/^.*\/Volumes\//\/Volumes\//p' | head -n 1
}

detach_dmg() {
  hdiutil detach "$1" >/dev/null 2>&1 || true
}

github_latest_asset() {
  local owner="$1"
  local repo="$2"
  local pattern="$3"
  curl -s "https://api.github.com/repos/${owner}/${repo}/releases/latest" \
    | grep -E "browser_download_url.*${pattern}" \
    | head -n 1 \
    | cut -d '"' -f 4
}

kill_app() {
  local app_path="$1"
  local app_name
  app_name="$(basename "$app_path" .app)"

  echo "Closing $app_name if running..."
  run_cmd_as_root pkill -x "$app_name" 2>/dev/null || true
  run_cmd_as_root pkill -f "$app_path/Contents/MacOS" 2>/dev/null || true
  sleep 1

  if [ -d "$app_path" ]; then
    echo "Removing existing $app_path to prevent override errors..."
    run_cmd_as_root rm -rf "$app_path" 2>/dev/null || true
  fi
}

# --- METODE UTILITIES ---

install_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew via Enterprise Tarball Method..."
    local home_dir shell_profile logged_user brew_target_dir
    logged_user="$(get_logged_in_user)"
    home_dir="$(get_home_dir)"
    shell_profile="$home_dir/.zshrc"

    if [ "$ARCH" = "arm64" ]; then
      brew_target_dir="/opt/homebrew"
    else
      brew_target_dir="/usr/local/Homebrew"
    fi

    mkdir -p "$brew_target_dir"
    curl -sL https://github.com/Homebrew/brew/tarball/master | tar xz -m --strip-components 1 -C "$brew_target_dir"
    chown -R "$logged_user:admin" "$brew_target_dir"

    mkdir -p "$home_dir/Library/Caches/Homebrew"
    chown -R "$logged_user:staff" "$home_dir/Library/Caches/Homebrew"

    if [ "$ARCH" = "arm64" ]; then
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$shell_profile"
      eval "$(/opt/homebrew/bin/brew shellenv)" || true
    else
      echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$shell_profile"
      eval "$(/usr/local/bin/brew shellenv)" || true
    fi

    echo "🔄 Inițializare finală a pachetelor..."
    sudo -u "$logged_user" "$brew_target_dir/bin/brew" update --force || true
    echo "Homebrew installed successfully via Tarball!"
  else
    echo "Homebrew is already installed."
  fi
}

install_nvm() {
  local home_dir shell_profile
  home_dir="$(get_home_dir)"
  shell_profile="$home_dir/.zshrc"

  if [ ! -d "$home_dir/.nvm" ]; then
    echo "Installing NVM (Node Version Manager)..."
    HOME="$home_dir" curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash || true

    echo 'export NVM_DIR="$HOME/.nvm"' >> "$shell_profile"
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> "$shell_profile"
    
    export NVM_DIR="$home_dir/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" || true

    echo "Installing latest Node.js 20..."
    nvm install 20 || true
    nvm alias default 20 || true
    echo "NVM and Node.js 20 installed successfully."
  else
    echo "NVM is already installed."
  fi
}

# --- METODE APLICAȚII (Cu protecție la suprascriere) ---

install_telegram() {
  echo "Installing Telegram (Latest)..."
  kill_app "/Applications/Telegram.app"
  curl -o Telegram.dmg -JL "https://telegram.org/dl/macos"
  local mp
  mp="$(attach_dmg Telegram.dmg)"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/ || true
  detach_dmg "$mp"
  rm -f Telegram.dmg
}

install_google_drive() {
  echo "Installing Google Drive (Latest)..."
  curl -o GoogleDrive.dmg -JL "https://dl.google.com/drive-file-stream/GoogleDrive.dmg"
  local mp pkg
  mp="$(attach_dmg GoogleDrive.dmg)"
  pkg="$(find "$mp" -name "*.pkg" -maxdepth 3 | head -n 1)"
  run_cmd_as_root installer -pkg "$pkg" -target / || true
  detach_dmg "$mp"
  rm -f GoogleDrive.dmg
}

install_compass() {
  echo "Installing MongoDB Compass (Latest Release)..."
  kill_app "/Applications/MongoDB Compass.app"
  local compass_url mp pattern
  if [ "$ARCH" = "arm64" ]; then
    pattern="darwin-arm64\\.dmg"
  else
    pattern="darwin-x64\\.dmg"
  fi
  compass_url="$(github_latest_asset "mongodb-js" "compass" "$pattern")"
  curl -o mongodb-compass.dmg -JL "$compass_url"
  mp="$(attach_dmg mongodb-compass.dmg)"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/ || true
  detach_dmg "$mp"
  rm -f mongodb-compass.dmg
}

install_postman() {
  echo "Installing Postman (Latest)..."
  kill_app "/Applications/Postman.app"
  local postman_url
  if [ "$ARCH" = "arm64" ]; then
    postman_url="https://dl.pstmn.io/download/latest/osx_arm64"
  else
    postman_url="https://dl.pstmn.io/download/latest/osx_64"
  fi
  curl -L -o Postman.zip "$postman_url"
  unzip -o Postman.zip -d /Applications/ >/dev/null || true
  rm -f Postman.zip
}

install_vscode() {
  echo "Installing VS Code (Latest Stable)..."
  kill_app "/Applications/Visual Studio Code.app"
  local vscode_url
  if [ "$ARCH" = "arm64" ]; then
    vscode_url="https://update.code.visualstudio.com/latest/darwin-arm64/stable"
  else
    vscode_url="https://update.code.visualstudio.com/latest/darwin/stable"
  fi
  curl -L -o VSCode.zip "$vscode_url"
  unzip -o VSCode.zip -d /Applications >/dev/null || true
  rm -f VSCode.zip
}

install_iterm2() {
  echo "Installing iTerm2 (Latest Stable Release)..."
  kill_app "/Applications/iTerm.app"
  local iterm_url
  iterm_url="$(github_latest_asset "gnachman" "iTerm2" "iTerm2-.*\\.zip")"
  if [ -z "$iterm_url" ]; then
    iterm_url="$(curl -s https://iterm2.com/downloads.html | grep -Eo 'https://iterm2\.com/downloads/stable/iTerm2-[0-9_]+\.zip' | head -n 1)"
  fi
  curl -o iTerm2.zip -JL "$iterm_url"
  unzip -o iTerm2.zip -d /Applications >/dev/null || true
  rm -f iTerm2.zip
}

install_docker() {
  echo "Installing Docker Desktop (Latest)..."
  kill_app "/Applications/Docker.app"
  local docker_url mp
  if [ "$ARCH" = "arm64" ]; then
    docker_url="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
  else
    docker_url="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
  fi
  curl -L -o Docker.dmg "$docker_url"
  mp="$(attach_dmg Docker.dmg)"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/ || true
  detach_dmg "$mp"
  rm -f Docker.dmg
}

install_chrome() {
  echo "Reinstalling Google Chrome (Latest)..."
  local dmg_path mount_point src_app dest_app tmp_app tmp_dir user_dir base_name

  run_cmd_as_root pkill -9 "Google Chrome" 2>/dev/null || true
  sleep 1
  run_cmd_as_root rm -rf "/Applications/Google Chrome.app" || true

  for user_dir in /Users/*; do
    [[ -d "$user_dir" ]] || continue
    base_name="$(basename "$user_dir")"
    [[ "$base_name" == "Shared" ]] && continue
    run_cmd_as_root rm -rf "$user_dir/Library/Application Support/Google/Chrome" || true
    run_cmd_as_root rm -rf "$user_dir/Library/Caches/Google/Chrome" || true
  done

  tmp_dir="$(mktemp -d)"
  dmg_path="$tmp_dir/googlechrome.dmg"
  mount_point="$tmp_dir/mnt"
  mkdir -p "$mount_point"

  curl -L -o "$dmg_path" "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
  hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null

  src_app="$mount_point/Google Chrome.app"
  dest_app="/Applications/Google Chrome.app"

  if [[ -d "$src_app" ]]; then
    run_cmd_as_root ditto "$src_app" "$dest_app" || true
    run_cmd_as_root xattr -dr com.apple.quarantine "$dest_app" 2>/dev/null || true
  fi

  hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
  rm -rf "$tmp_dir" || true
}

install_pritunl() {
  echo "Reinstalling Pritunl (Latest Release)..."
  kill_app "/Applications/Pritunl.app"
  local pritunl_url
  pritunl_url="$(github_latest_asset "pritunl" "pritunl-client-electron" "Pritunl\\.pkg\\.zip")"
  curl -L --fail --silent --show-error -o Pritunl.pkg.zip "$pritunl_url"
  unzip -o Pritunl.pkg.zip >/dev/null || true
  run_cmd_as_root installer -pkg Pritunl.pkg -target / || true
  rm -f Pritunl.pkg.zip Pritunl.pkg
}

# --- MAIN RUNNER ---

main() {
  local arg="${1:-${HEXNODE_APP_ARGUMENT:-all}}"
  arg="$(echo "$arg" | tr '[:upper:]' '[:lower:]')"

  echo "Working dir: $PWD"
  echo "Arch: $ARCH"
  echo "App argument: $arg"
  echo "--------------"

  if [ "$arg" = "all" ] || [ -z "$arg" ]; then
    run_app brew
    run_app nvm
    run_app telegram
    run_app googledrive
    run_app compass
    run_app chrome
    run_app postman
    run_app vscode
    run_app iterm2
    run_app pritunl
    run_app docker
  else
    run_app "$arg"
  fi

  echo "Install completed successfully."
}

main "$@"
