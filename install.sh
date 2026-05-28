#!/bin/bash
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -euo pipefail

ARCH="$(uname -m)"
WORK_DIR="/var/hexnodeApp"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

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
    echo "Removing existing $app_path..."
    run_cmd_as_root rm -rf "$app_path" 2>/dev/null || true
  fi
}

get_logged_in_user() {
  /usr/bin/stat -f "%Su" /dev/console 2>/dev/null || echo ""
}

get_home_dir() {
  local logged_in_user
  local home_dir
  logged_in_user="$(get_logged_in_user)"
  if [[ -n "$logged_in_user" && "$logged_in_user" != "root" ]]; then
    home_dir="$(dscl . -read "/Users/$logged_in_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  else
    home_dir="/var/root"
  fi
  echo "${home_dir:-/var/root}"
}

# --- UTILITIES ---

install_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew via Tarball Method..."
    local home_dir shell_profile logged_user brew_target_dir
    logged_user="$(get_logged_in_user)"
    home_dir="$(get_home_dir)"
    shell_profile="$home_dir/.zshrc"

    if [ "$ARCH" = "arm64" ]; then
      brew_target_dir="/opt/homebrew"
    else
      brew_target_dir="/usr/local/Homebrew"
    fi

    echo "Target directory: $brew_target_dir for user: $logged_user"
    run_cmd_as_root mkdir -p "$brew_target_dir"
    curl -sL https://github.com/Homebrew/brew/tarball/master | run_cmd_as_root tar xz -m --strip-components 1 -C "$brew_target_dir"
    
    run_cmd_as_root chown -R "$logged_user:admin" "$brew_target_dir"
    run_cmd_as_root mkdir -p "$home_dir/Library/Caches/Homebrew"
    run_cmd_as_root chown -R "$logged_user:staff" "$home_dir/Library/Caches/Homebrew"

    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$shell_profile"
    
    set +e
    sudo -u "$logged_user" "$brew_target_dir/bin/brew" update --force
    set -e
    echo "Homebrew installed successfully."
  else
    echo "Homebrew is already installed."
  fi
}

install_nvm() {
  local home_dir shell_profile logged_user
  logged_user="$(get_logged_in_user)"
  home_dir="$(get_home_dir)"
  shell_profile="$home_dir/.zshrc"

  if [ ! -d "$home_dir/.nvm" ]; then
    echo "Installing NVM (Node Version Manager)..."
    set +e
    HOME="$home_dir" curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    
    echo 'export NVM_DIR="$HOME/.nvm"' >> "$shell_profile"
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> "$shell_profile"
    
    export NVM_DIR="$home_dir/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    sudo -u "$logged_user" -i bash -c "export NVM_DIR='$home_dir/.nvm'; [ -s \$NVM_DIR/nvm.sh ] && \. \$NVM_DIR/nvm.sh; nvm install 20 && nvm alias default 20"
    set -e
    echo "NVM and Node.js 20 installed successfully."
  else
    echo "NVM is already installed."
  fi
}

# --- APLICAȚII ---

install_telegram() {
  echo "Installing Telegram..."
  curl -o Telegram.dmg -JL "https://telegram.org/dl/macos"
  local mp
  mp="$(attach_dmg Telegram.dmg)"
  kill_app "/Applications/Telegram.app"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/
  detach_dmg "$mp"
  rm -f Telegram.dmg
}

install_google_drive() {
  echo "Installing Google Drive..."
  curl -o GoogleDrive.dmg -JL "https://dl.google.com/drive-file-stream/GoogleDrive.dmg"
  local mp pkg
  mp="$(attach_dmg GoogleDrive.dmg)"
  pkg="$(find "$mp" -name "*.pkg" -maxdepth 3 | head -n 1)"
  run_cmd_as_root installer -pkg "$pkg" -target /
  detach_dmg "$mp"
  rm -f GoogleDrive.dmg
}

install_compass() {
  echo "Installing MongoDB Compass..."
  local compass_url mp
  compass_url="$(github_latest_asset "mongodb-js" "compass" "darwin-arm64\\.dmg")"
  curl -o mongodb-compass.dmg -JL "$compass_url"
  mp="$(attach_dmg mongodb-compass.dmg)"
  kill_app "/Applications/MongoDB Compass.app"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/
  detach_dmg "$mp"
  rm -f mongodb-compass.dmg
}

install_postman() {
  echo "Installing Postman..."
  local postman_url
  if [ "$ARCH" = "arm64" ]; then
    postman_url="https://dl.pstmn.io/download/latest/osx_arm64"
  else
    postman_url="https://dl.pstmn.io/download/latest/osx_64"
  fi

  curl -L -o Postman.zip "$postman_url"
  kill_app "/Applications/Postman.app"
  unzip -o Postman.zip -d /Applications/ >/dev/null
  rm -f Postman.zip
}

install_vscode() {
  echo "Installing VS Code..."
  curl -L -o VSCode.zip "https://update.code.visualstudio.com/latest/darwin-universal/stable"
  kill_app "/Applications/Visual Studio Code.app"
  unzip -o VSCode.zip -d /Applications >/dev/null
  rm -f VSCode.zip
}

install_iterm2() {
  echo "Installing iTerm2..."
  local iterm_url
  iterm_url="$(curl -s https://iterm2.com/downloads.html | grep -Eo 'https://iterm2\.com/downloads/stable/iTerm2-[0-9_]+\.zip' | head -n 1)"
  curl -o iTerm2.zip -JL "$iterm_url"
  kill_app "/Applications/iTerm.app"
  unzip -o iTerm2.zip -d /Applications >/dev/null
  rm -f iTerm2.zip
}

install_docker() {
  echo "Installing Docker Desktop..."
  local docker_url mp
  if [ "$ARCH" = "arm64" ]; then
    docker_url="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
  else
    docker_url="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
  fi

  curl -L -o Docker.dmg "$docker_url"
  mp="$(attach_dmg Docker.dmg)"
  kill_app "/Applications/Docker.app"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/
  detach_dmg "$mp"
  rm -f Docker.dmg
}

install_chrome() {
  echo "Reinstalling Google Chrome..."
  local dmg_path mount_point src_app dest_app tmp_app tmp_dir user_dir base_name installed_ver

  run_cmd_as_root pkill -9 "Google Chrome" 2>/dev/null || true
  sleep 2

  run_cmd_as_root rm -rf "/Applications/Google Chrome.app"

  for user_dir in /Users/*; do
    [[ -d "$user_dir" ]] || continue
    base_name="$(basename "$user_dir")"
    [[ "$base_name" == "Shared" ]] && continue

    run_cmd_as_root rm -rf "$user_dir/Library/Application Support/Google/Chrome" || true
    run_cmd_as_root rm -rf "$user_dir/Library/Caches/Google/Chrome" || true
    run_cmd_as_root rm -rf "$user_dir/Library/Google/GoogleSoftwareUpdate" || true
  done

  run_cmd_as_root rm -rf "/Library/Google/GoogleSoftwareUpdate" || true
  run_cmd_as_root rm -rf "/Library/Application Support/Google/Chrome" || true

  tmp_dir="$(mktemp -d)"
  dmg_path="$tmp_dir/googlechrome.dmg"
  mount_point="$tmp_dir/mnt"
  mkdir -p "$mount_point"

  curl -L -o "$dmg_path" "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
  hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null

  src_app="$mount_point/Google Chrome.app"
  dest_app="/Applications/Google Chrome.app"
  tmp_app="/Applications/.Google Chrome.app.tmp"

  if [[ ! -d "$src_app" ]]; then
    hdiutil detach "$mount_point" -force >/dev/null || true
    rm -rf "$tmp_dir" || true
    echo "Google Chrome.app not found in DMG."
    exit 1
  fi

  run_cmd_as_root rm -rf "$tmp_app" || true
  run_cmd_as_root ditto "$src_app" "$tmp_app"
  run_cmd_as_root xattr -dr com.apple.quarantine "$tmp_app" 2>/dev/null || true
  run_cmd_as_root rm -rf "$dest_app" || true
  run_cmd_as_root mv "$tmp_app" "$dest_app"
  run_cmd_as_root chown -R root:wheel "$dest_app" || true
  run_cmd_as_root chmod -R go-w "$dest_app" || true

  hdiutil detach "$mount_point" >/dev/null || hdiutil detach "$mount_point" -force >/dev/null || true
  rm -rf "$tmp_dir" || true

  installed_ver="$(/usr/bin/defaults read "$dest_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
  if [[ -n "$installed_ver" ]]; then
    echo "Google Chrome installed version: $installed_ver"
  fi
}

install_pritunl() {
  echo "Reinstalling Pritunl..."
  local process="/Applications/Pritunl.app"
  local home_dir app_name script_name bundle_identifier
  home_dir="$(get_home_dir)"
  export HOME="$home_dir"

  if [ -e "$process/Contents/Info.plist" ]; then
    echo "Pritunl found, starting cleanup..."
    bundle_identifier=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$process/Contents/Info.plist" 2>/dev/null || true)
    app_name="$(basename "$process" .app)"
    script_name="$(basename "$0")"

    local process_lines
    process_lines="$(pgrep -afil "$app_name" 2>/dev/null | grep -v "$script_name" || true)"
    if [ -n "$process_lines" ]; then
      echo "Killing running Pritunl processes..."
      echo "$process_lines" | awk '{print $1}' | while IFS= read -r pid; do
        [ -n "$pid" ] && run_cmd_as_root kill "$pid" 2>/dev/null || true
      done
    fi

    echo "Removing existing Pritunl app..."
    run_cmd_as_root rm -rf "$process" || true

    local locations=(
      "$home_dir/Library"
      "$home_dir/Library/Application Scripts"
      "$home_dir/Library/Application Support"
      "$home_dir/Library/Containers"
      "$home_dir/Library/Caches"
      "$home_dir/Library/HTTPStorages"
      "$home_dir/Library/Group Containers"
      "$home_dir/Library/LaunchAgents"
      "$home_dir/Library/Logs"
      "$home_dir/Library/Preferences"
      "$home_dir/Library/Preferences/ByHost"
      "$home_dir/Library/Saved Application State"
      "$home_dir/Library/WebKit"
      "/Library"
      "/Library/Application Support"
      "/Library/Caches"
      "/Library/LaunchAgents"
      "/Library/LaunchDaemons"
      "/Library/Logs"
      "/Library/Preferences"
      "/Library/PrivilegedHelperTools"
      "/private/var/db/receipts"
      "$(getconf DARWIN_USER_CACHE_DIR | sed 's/\/$//')"
      "$(getconf DARWIN_USER_TEMP_DIR | sed 's/\/$//')"
    )
    local location
    echo "Cleaning residual paths by app name..."
    for location in "${locations[@]}"; do
      [[ -d "$location" ]] || continue
      find "$location" -maxdepth 1 -iname "*$app_name*" -prune -print 2>/dev/null \
        | while IFS= read -r p; do
            [ -n "$p" ] && run_cmd_as_root rm -rf "$p" 2>/dev/null || true
          done || true
    done

    if [ -n "${bundle_identifier:-}" ]; then
      echo "Cleaning residual paths by bundle identifier..."
      for location in "${locations[@]}"; do
        [[ -d "$location" ]] || continue
        find "$location" -maxdepth 1 -iname "*$bundle_identifier*" -prune -print 2>/dev/null \
          | while IFS= read -r p; do
              [ -n "$p" ] && run_cmd_as_root rm -rf "$p" 2>/dev/null || true
            done || true
      done
    fi

    echo "Removing known Pritunl paths..."
    run_cmd_as_root rm -rf "/Library/Application Support/Pritunl" 2>/dev/null || true
    run_cmd_as_root rm -rf "/var/lib/pritunl-client" 2>/dev/null || true
    run_cmd_as_root rm -rf "$home_dir/Library/Preferences/com.pritunl."* 2>/dev/null || true
    run_cmd_as_root rm -rf "$home_dir/Library/Application Support/Pritunl" 2>/dev/null || true
    run_cmd_as_root rm -f "/Library/Application Support/Pritunl/pritunl-client.json" 2>/dev/null || true
  else
    echo "Pritunl not installed, installing fresh."
  fi

  echo "Downloading latest Pritunl package..."
  curl -L --fail --silent --show-error -o Pritunl.pkg.zip \
    https://github.com/pritunl/pritunl-client-electron/releases/latest/download/Pritunl.pkg.zip
  echo "Extracting package..."
  unzip -o Pritunl.pkg.zip >/dev/null
  echo "Installing package..."
  run_cmd_as_root installer -pkg Pritunl.pkg -target /
  echo "Cleaning installer files..."
  rm -f Pritunl.pkg.zip Pritunl.pkg
  echo "Pritunl reinstall completed."
}

usage() {
  cat <<EOF
Usage: $0 [app]

If no app is provided, installs all apps.
Allowed values:
  brew
  nvm
  telegram
  googledrive
  compass
  postman
  vscode
  iterm2
  chrome
  pritunl
  docker
EOF
}

run_app() {
  case "$1" in
    brew) install_brew ;;
    nvm) install_nvm ;;
    telegram) install_telegram ;;
    googledrive) install_google_drive ;;
    compass) install_compass ;;
    postman) install_postman ;;
    vscode) install_vscode ;;
    iterm2) install_iterm2 ;;
    chrome) install_chrome ;;
    pritunl) install_pritunl ;;
    docker) install_docker ;;
    *)
      echo "Unknown app argument: $1"
      usage
      exit 1
      ;;
  esac
}

main() {
  # Citim argumentul direct ($1) dacă e rulat manual, SAU din variabila exportată de Hexnode ($HEXNODE_APP_ARGUMENT)
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

  echo "Install completed."
}

main "$@"
