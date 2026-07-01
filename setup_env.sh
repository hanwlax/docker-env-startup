#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Root Docker dev env bootstrap for SSH containers
#
# Includes:
#   - apt update/install
#   - zsh
#   - oh-my-zsh
#   - tmux
#   - private hanwlax/.tmux config
#   - catppuccin-tmux
#   - codex (via npm)
#   - colbymchenry/codegraph
#   - proxy env
#   - node v24.15 PATH
# ============================================================

# ----------------------------
# Config
# ----------------------------

TMUX_REPO="${TMUX_REPO:-git@github.com:hanwlax/.tmux.git}"

PROXY_URL="${PROXY_URL:-http://127.0.0.1:7899}"

# Node.js 下载和解压配置。
NODE_VERSION="${NODE_VERSION:-v24.18.0}"
NODE_ARCH="${NODE_ARCH:-linux-arm64}"
NODE_TARBALL="node-${NODE_VERSION}-${NODE_ARCH}.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_TARBALL}"
NODE_HOME="${NODE_HOME:-/home/hanwlax/node-${NODE_VERSION}-${NODE_ARCH}}"

# npm 全局安装和缓存目录。
NPM_PREFIX="${NPM_PREFIX:-/home/hanwlax/node}"

INSTALL_CODEX="${INSTALL_CODEX:-1}"
INSTALL_CODEGRAPH="${INSTALL_CODEGRAPH:-1}"
INSTALL_CATPPUCCIN="${INSTALL_CATPPUCCIN:-1}"

CATPPUCCIN_TMUX_REF="${CATPPUCCIN_TMUX_REF:-v2.3.0}"

# 默认生成 root 的 SSH key。
GENERATE_SSH_KEY="${GENERATE_SSH_KEY:-1}"

# 生成 key 后等待用户把 key 添加到 GitHub。
WAIT_FOR_GITHUB_KEY_CONFIRM="${WAIT_FOR_GITHUB_KEY_CONFIRM:-1}"

# 是否执行 GitHub SSH 测试。
TEST_GITHUB_SSH="${TEST_GITHUB_SSH:-1}"

# Docker 中 chsh 经常不稳定，所以默认在 ~/.bashrc 里自动进入 zsh。
AUTO_START_ZSH_FROM_BASH="${AUTO_START_ZSH_FROM_BASH:-1}"

# CodeGraph 目标 agent。
CODEGRAPH_TARGET="${CODEGRAPH_TARGET:-codex}"

# ----------------------------
# Utils
# ----------------------------

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

append_once() {
  local file="$1"
  local line="$2"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  grep -Fqx "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

replace_block() {
  local file="$1"
  local name="$2"
  local content="$3"

  local begin="# >>> ${name} >>>"
  local end="# <<< ${name} <<<"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  local tmp
  tmp="$(mktemp)"

  if grep -Fq "$begin" "$file"; then
    awk -v begin="$begin" -v end="$end" -v content="$content" '
      $0 == begin {
        print begin
        print content
        in_block = 1
        next
      }
      $0 == end {
        print end
        in_block = 0
        next
      }
      in_block != 1 {
        print
      }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    {
      cat "$file"
      printf '\n%s\n' "$begin"
      printf '%s\n' "$content"
      printf '%s\n' "$end"
    } > "$tmp"
    mv "$tmp" "$file"
  fi
}

as_root_check() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script is designed for root Docker containers. Current uid=$(id -u)."
  fi
}

download_nodejs() {
  if [ -d "$NODE_HOME" ]; then
    log "Node.js already exists at $NODE_HOME, skipping download."
    return 0
  fi

  log "Downloading Node.js ${NODE_VERSION} for ${NODE_ARCH}..."
  curl -fSL -o "/tmp/${NODE_TARBALL}" "$NODE_URL"

  log "Extracting Node.js to /home/hanwlax/..."
  tar -xJf "/tmp/${NODE_TARBALL}" -C /home/hanwlax/

  rm -f "/tmp/${NODE_TARBALL}"
  log "Node.js extracted to $NODE_HOME"
}

update_etc_environment() {
  log "Updating /etc/environment..."
  cat > /etc/environment <<'EOF'
PATH="/home/hanwlax/node-v24.18.0-linux-arm64/bin:/usr/local/python3.11.15/bin:/usr/local/Ascend/cann-9.0.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
http_proxy="http://127.0.0.1:7899"
https_proxy="http://127.0.0.1:7899"
HTTP_PROXY="http://127.0.0.1:7899"
HTTPS_PROXY="http://127.0.0.1:7899"
no_proxy=127.0.0.1,localhost,local,.local,.modelscope.cn
NO_PROXY="$no_proxy"
TERM="xterm-256color"
LANG="en_US.UTF-8"
LANGUAGE="en_US:en"
LC_ALL="en_US.UTF-8"
EOF
  log "/etc/environment updated."
}

update_apt_sources() {
  log "Updating apt sources to Huawei mirror..."
  sed -i "s@http://.*ubuntu.com@http://repo.huaweicloud.com@g" /etc/apt/sources.list
  log "apt sources updated."
}

install_ssh_server() {
  log "Installing openssh-server and autossh..."
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    openssh-server \
    autossh

  read -r -p "请输入 SSH 端口号: " ssh_port
  if [ -z "$ssh_port" ]; then
    die "SSH 端口号不能为空。"
  fi

  log "Configuring sshd on port $ssh_port..."
  sed -i "s/^#\?Port .*/Port $ssh_port/" /etc/ssh/sshd_config
  sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config

  mkdir -p /run/sshd
  log "sshd configured: Port=$ssh_port, PermitRootLogin=prohibit-password"
}

setup_authorized_keys() {
  local ssh_dir="/root/.ssh"
  local auth_keys="$ssh_dir/authorized_keys"
  local pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJTF6QWJR0PR8klqf9X4eT8W+MU8hie+R4ru+1/0Dyfk hanbo39@huawei.com"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$auth_keys"
  chmod 600 "$auth_keys"

  if ! grep -Fq "$pubkey" "$auth_keys"; then
    echo "$pubkey" >> "$auth_keys"
    log "Public key added to $auth_keys"
  else
    warn "Public key already exists in $auth_keys"
  fi
}

setup_runtime_path() {
  if [ -d "$NODE_HOME/bin" ]; then
    export PATH="$NODE_HOME/bin:$PATH"
  elif [ -d "$NODE_HOME" ]; then
    export PATH="$NODE_HOME:$PATH"
  fi

  export PATH="$NPM_PREFIX/bin:$PATH"

  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
}

setup_npm_dirs() {
  log "Configuring npm prefix and cache under $NPM_PREFIX..."
  mkdir -p "$NPM_PREFIX"
  npm config set prefix "$NPM_PREFIX"
  npm config set cache "$NPM_PREFIX/cache"
}

apt_install_base() {
  log "Running apt update..."
  apt update

  log "Installing base packages..."
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssh-client \
    tmux \
    zsh \
    vim \
    less \
    jq \
    unzip \
    xz-utils \
    procps \
    nodejs \
    npm

  log "Base packages installed."
}

setup_ssh_config_github_443() {
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  cat > /root/.ssh/config <<'EOF'
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  TCPKeepAlive yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
EOF

  chmod 600 /root/.ssh/config

  touch /root/.ssh/known_hosts
  chmod 644 /root/.ssh/known_hosts

  if has_cmd ssh-keyscan; then
    # github.com 的 443 SSH 入口实际 host 是 ssh.github.com。
    ssh-keyscan -p 443 -H ssh.github.com >> /root/.ssh/known_hosts 2>/dev/null || true
  fi

  log "Configured GitHub SSH via ssh.github.com:443"
}

setup_ssh_key() {
  setup_ssh_config_github_443

  if [ "$GENERATE_SSH_KEY" != "1" ]; then
    warn "GENERATE_SSH_KEY=0, skip SSH key generation."
    return 0
  fi

  if [ ! -f /root/.ssh/id_ed25519 ]; then
    log "Generating SSH key for root..."
    ssh-keygen -t ed25519 -C "root-docker-hanwlax" -f /root/.ssh/id_ed25519 -N ""
  else
    warn "SSH key already exists: /root/.ssh/id_ed25519"
  fi

  chmod 600 /root/.ssh/id_ed25519
  chmod 644 /root/.ssh/id_ed25519.pub

  echo
  log "Add this public key to GitHub SSH keys:"
  echo "------------------------------------------------------------"
  cat /root/.ssh/id_ed25519.pub
  echo "------------------------------------------------------------"
  echo

  if [ "$WAIT_FOR_GITHUB_KEY_CONFIRM" = "1" ]; then
    echo "把上面的 public key 添加到 GitHub 后，按 Enter 继续。"
    echo "GitHub path: Settings -> SSH and GPG keys -> New SSH key"
    read -r -p "Press Enter after adding the SSH key to GitHub..."
  fi
}

test_github_ssh() {
  if [ "$TEST_GITHUB_SSH" != "1" ]; then
    return 0
  fi

  log "Testing GitHub SSH connection through port 443..."

  set +e
  ssh -T git@github.com
  local rc=$?
  set -e

  # GitHub 成功认证时通常返回 1，并打印：
  # Hi <user>! You've successfully authenticated, but GitHub does not provide shell access.
  # 所以 rc=1 也可能是成功。
  if [ "$rc" -eq 1 ] || [ "$rc" -eq 0 ]; then
    log "GitHub SSH test finished. If you saw 'successfully authenticated', it is OK."
  else
    die "GitHub SSH test failed. Check whether the public key has been added to GitHub."
  fi
}

install_oh_my_zsh() {
  if [ -d /root/.oh-my-zsh ]; then
    warn "Oh My Zsh already exists: /root/.oh-my-zsh"
  else
    log "Installing Oh My Zsh..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  fi

  touch /root/.zshrc

  if ! grep -q 'source \$ZSH/oh-my-zsh.sh' /root/.zshrc; then
    cat >> /root/.zshrc <<'EOF'

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source $ZSH/oh-my-zsh.sh
EOF
  fi

  log "Oh My Zsh configured."
}

setup_zsh_env() {
  log "Writing proxy and PATH into /root/.zshrc..."

  local node_path_line
  if [ -d "$NODE_HOME/bin" ]; then
    node_path_line="export PATH=\"$NODE_HOME/bin:\$PATH\""
  else
    node_path_line="export PATH=\"$NODE_HOME:\$PATH\""
  fi

  local block
  block="$(cat <<EOF
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export no_proxy=127.0.0.1,localhost,local,.local,.modelscope.cn
export NO_PROXY="\$no_proxy"
export TERM="xterm-256color"

$node_path_line
export PATH="$NPM_PREFIX/bin:\$HOME/.local/bin:\$HOME/bin:\$PATH"
EOF
)"

  replace_block /root/.zshrc "docker-dev-env" "$block"

  if [ "$AUTO_START_ZSH_FROM_BASH" = "1" ]; then
    append_once /root/.bashrc 'if [ -t 1 ] && command -v zsh >/dev/null 2>&1 && [ -z "$ZSH_VERSION" ]; then exec zsh; fi'
  fi

  log "zsh env configured."
}

install_tmux_config() {
  log "Installing private tmux config from: $TMUX_REPO"

  cd /root

  if [ -e /root/.tmux ] && [ ! -d /root/.tmux/.git ]; then
    mv /root/.tmux "/root/.tmux.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  if [ -d /root/.tmux/.git ]; then
    log "Updating existing /root/.tmux..."
    git -C /root/.tmux remote set-url origin "$TMUX_REPO"
    git -C /root/.tmux fetch --all --tags
    git -C /root/.tmux pull --ff-only
  else
    log "Cloning private tmux repo..."
    git clone --single-branch "$TMUX_REPO" /root/.tmux
  fi

  if [ ! -f /root/.tmux/.tmux.conf ]; then
    die "Missing /root/.tmux/.tmux.conf in private repo."
  fi

  if [ ! -f /root/.tmux/.tmux.conf.local ]; then
    die "Missing /root/.tmux/.tmux.conf.local in private repo."
  fi

  ln -s -f /root/.tmux/.tmux.conf /root/.tmux.conf
  ln -s -f /root/.tmux/.tmux.conf.local /root/.tmux.conf.local

  log "tmux symlinks configured:"
  ls -l /root/.tmux.conf /root/.tmux.conf.local
}

install_catppuccin_tmux() {
  if [ "$INSTALL_CATPPUCCIN" != "1" ]; then
    return 0
  fi

  log "Installing catppuccin/tmux..."

  local parent="/root/.config/tmux/plugins/catppuccin"
  local dir="$parent/tmux"

  mkdir -p "$parent"

  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --tags --force
    git -C "$dir" checkout "$CATPPUCCIN_TMUX_REF"
    git -C "$dir" pull --ff-only || true
  else
    git clone -b "$CATPPUCCIN_TMUX_REF" https://github.com/catppuccin/tmux.git "$dir"
  fi

  append_once /root/.tmux.conf.local ''
  append_once /root/.tmux.conf.local '# Catppuccin tmux theme'
  append_once /root/.tmux.conf.local 'set -g @catppuccin_flavor "mocha"'
  append_once /root/.tmux.conf.local 'set -g @catppuccin_window_status_style "rounded"'
  append_once /root/.tmux.conf.local 'run ~/.config/tmux/plugins/catppuccin/tmux/catppuccin.tmux'

  log "catppuccin/tmux configured in /root/.tmux.conf.local"
}

install_codex() {
  if [ "$INSTALL_CODEX" != "1" ]; then
    return 0
  fi

  if has_cmd codex; then
    warn "codex already exists: $(command -v codex)"
    codex --version || true
    return 0
  fi

  log "Installing Codex CLI via npm..."
  npm install -g @openai/codex

  if has_cmd codex; then
    log "Codex installed: $(command -v codex)"
    codex --version || true
  else
    warn "Codex install finished, but codex is not in PATH yet. Try: exec zsh"
  fi
}

install_codegraph() {
  if [ "$INSTALL_CODEGRAPH" != "1" ]; then
    return 0
  fi

  setup_runtime_path

  if ! has_cmd npx; then
    die "npx not found. Check Node installation. Current PATH=$PATH"
  fi

  log "Installing CodeGraph with npx..."
  npx -y @colbymchenry/codegraph

  export PATH="/root/.local/bin:/root/bin:$PATH"

  if has_cmd codegraph; then
    log "Configuring CodeGraph for target=$CODEGRAPH_TARGET..."
    codegraph install --target="$CODEGRAPH_TARGET" --location=global --yes || \
      warn "codegraph install failed. You can retry manually: codegraph install --target=$CODEGRAPH_TARGET --location=global --yes"

    codegraph --version || true
  else
    warn "codegraph command not found after npx installer. Try opening a new shell: exec zsh"
  fi
}

try_set_default_shell() {
  if has_cmd zsh; then
    chsh -s "$(command -v zsh)" root 2>/dev/null || \
      warn "chsh failed or unavailable in Docker. ~/.bashrc auto-start zsh has been configured."
  fi
}

print_summary() {
  echo
  echo "================ Bootstrap Summary ================"
  echo "User:        $(id -un)"
  echo "Home:        $HOME"
  echo "Shell zsh:   $(command -v zsh || true)"
  echo "tmux:        $(tmux -V 2>/dev/null || echo not-found)"
  echo "git:         $(git --version 2>/dev/null || echo not-found)"
  echo "node:        $(node --version 2>/dev/null || echo not-found)"
  echo "npm:         $(npm --version 2>/dev/null || echo not-found)"
  echo "npx:         $(npx --version 2>/dev/null || echo not-found)"
  echo "codex:       $(command -v codex || echo not-found)"
  echo "codegraph:   $(command -v codegraph || echo not-found)"
  echo "tmux repo:   /root/.tmux"
  echo "tmux conf:   /root/.tmux.conf"
  echo "zshrc:       /root/.zshrc"
  echo "proxy:       $PROXY_URL"
  echo "NODE_HOME:   $NODE_HOME"
  echo "NPM_PREFIX:  $NPM_PREFIX"
  echo "GitHub SSH:  ssh.github.com:443 via Host github.com"
  echo "==================================================="
  echo
  echo "Next commands:"
  echo "  exec zsh"
  echo "  tmux source-file ~/.tmux.conf"
  echo
}

main() {
  as_root_check

  update_etc_environment
  update_apt_sources
  download_nodejs
  setup_runtime_path

  apt_install_base
  setup_runtime_path
  setup_npm_dirs

  install_ssh_server
  setup_authorized_keys

  setup_ssh_key
  test_github_ssh

  install_oh_my_zsh
  setup_zsh_env

  install_tmux_config
  install_catppuccin_tmux

  install_codex
  install_codegraph

  try_set_default_shell
  print_summary
}

main "$@"
