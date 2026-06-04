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
    echo "Removing old binary $app_path..."
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

# =====================================================================
# 📥 METODE INSTALARE (Inclusiv Xcode CLT)
# =====================================================================

install_xcode_clt() {
  echo "Checking Xcode Command Line Tools..."
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Installing Xcode Command Line Tools silențios..."
    local clt_placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    run_cmd_as_root touch "$clt_placeholder"
    
    local clt_label
    clt_label=$(softwareupdate -l | grep -E "\*.*Command Line" | head -n 1 | awk -F"*" '{print $2}' | sed -e 's/^ *//' | tr -d '\n')
    
    if [ -n "$clt_label" ]; then
      echo "📥 Descărcare și instalare din serverele Apple: $clt_label"
      run_cmd_as_root softwareupdate -i "$clt_label" --verbose
      echo "✅ Xcode Command Line Tools a fost instalat cu succes!"
    else
      echo "⚠️ Nu s-a putut detecta eticheta online. Se încearcă fallback-ul nativ..."
      run_cmd_as_root xcode-select --install >/dev/null 2>&1 || true
      sleep 5
    fi
    run_cmd_as_root rm -f "$clt_placeholder"
  else
    echo "Xcode Command Line Tools is already installed."
  fi
}

install_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew via Tarball Method..."
    local home_dir shell_profile logged_user brew_target_dir
    logged_user="$(get_logged_in_user)"
    home_dir="$(get_home_dir)"
    shell_profile="$home_dir/.zshrc"
    if [ "$ARCH" = "arm64" ]; then brew_target_dir="/opt/homebrew"; else brew_target_dir="/usr/local/Homebrew"; fi

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
    echo "Installing NVM (Node Version Manager) Enterprise..."
    mkdir -p "$home_dir/.nvm"
    curl -o "$WORK_DIR/nvm_install.sh" -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh
    export HOME="$home_dir"
    export USER="$logged_user"
    /bin/bash "$WORK_DIR/nvm_install.sh"
    rm -f "$WORK_DIR/nvm_install.sh"
    run_cmd_as_root touch "$shell_profile"
    run_cmd_as_root chmod 644 "$shell_profile"
    run_cmd_as_root bash -c "cat << 'EOF' >> '$shell_profile'
export NVM_DIR=\"$home_dir/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
[ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
EOF"
    run_cmd_as_root chown -R "$logged_user:staff" "$home_dir/.nvm"
    run_cmd_as_root chown "$logged_user:staff" "$shell_profile"
    echo "Installing Node.js 20..."
    set +e
    sudo -u "$logged_user" HOME="$home_dir" /bin/bash -c "
      export NVM_DIR='$home_dir/.nvm'
      if [ -s '\$NVM_DIR/nvm.sh' ]; then
        . '\$NVM_DIR/nvm.sh'
        nvm install 20
        nvm alias default 20
      fi
    "
    set -e
    echo "NVM and Node.js 20 installed successfully."
  else
    echo "NVM is already installed."
  fi
}

install_telegram() {
  echo "Installing Telegram..."
  curl -o Telegram.dmg -JL "https://telegram.org/dl/macos"
  local mp; mp="$(attach_dmg Telegram.dmg)"
  kill_app "/Applications/Telegram.app"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/
  detach_dmg "$mp"; rm -f Telegram.dmg
}

install_google_drive() {
  echo "Installing Google Drive..."
  curl -o GoogleDrive.dmg -JL "https://dl.google.com/drive-file-stream/GoogleDrive.dmg"
  local mp pkg; mp="$(attach_dmg GoogleDrive.dmg)"
  pkg="$(find "$mp" -name "*.pkg" -maxdepth 3 | head -n 1)"
  run_cmd_as_root installer -pkg "$pkg" -target /
  detach_dmg "$mp"; rm -f GoogleDrive.dmg
}

install_compass() {
  echo "Installing MongoDB Compass..."
  local compass_url mp; compass_url="$(github_latest_asset "mongodb-js" "compass" "darwin-arm64\\.dmg")"
  curl -o mongodb-compass.dmg -JL "$compass_url"
  mp="$(attach_dmg mongodb-compass.dmg)"
  kill_app "/Applications/MongoDB Compass.app"
  cp -R "$(find "$mp" -name "*.app" -maxdepth 2 | head -n 1)" /Applications/
  detach_dmg "$mp"; rm -f mongodb-compass.dmg
}

install_postman() {
  echo "Installing Postman..."
  local postman_url; if [ "$ARCH" = "arm64" ]; then postman_url="https://dl.pstmn.io/download/latest/osx_arm64"; else postman_url="https://dl.pstmn.io/download/latest/osx_64"; fi
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
  echo "Installing iTerm2
