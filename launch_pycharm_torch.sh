#!/usr/bin/env bash

# Set working directory to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Local launcher - uploads and runs remote script, then creates tunnel
set -Eeuo pipefail

# Setup colors - professional terminal palette
if [[ -t 1 && -z ${NO_COLOR-} ]]; then
  # Text styles
  BLD=$'\e[1m'    # Bold
  DIM=$'\e[2m'    # Dim
  RST=$'\e[0m'    # Reset

  # Semantic colors
  RED=$'\e[31m'   # Errors
  GRN=$'\e[32m'   # Success
  YEL=$'\e[33m'   # Warnings/Info
  BLU=$'\e[34m'   # Prompts/Labels
  MAG=$'\e[35m'   # Highlights
  CYA=$'\e[36m'   # Headers
  GRY=$'\e[90m'   # Subdued text
else
  BLD=; DIM=; RST=; RED=; GRN=; YEL=; BLU=; MAG=; CYA=; GRY=
fi

SSH_CONFIG="$HOME/.ssh/config"
LOCAL_REMOTE_SCRIPT="remote_launcher_torch.sh"
CONTROL_PATH="$HOME/.ssh/control-torch-%r@%h:%p"

cleanup() {
  set +e

  # Cancel jobs and kill salloc (if control socket exists)
  if [[ -S "$CONTROL_PATH" ]]; then
    ssh -q -o ControlPath="$CONTROL_PATH" torch 'scancel -u "$USER" 2>/dev/null' || true
    ssh -q -o ControlPath="$CONTROL_PATH" torch 'pkill -u "$USER" salloc 2>/dev/null' || true
    sleep 1

    # Clean remote dir
    ssh -q -o ControlPath="$CONTROL_PATH" torch 'rm -rf /scratch/$USER/.jb 2>/dev/null; mkdir -p /scratch/$USER/.jb' || true
  fi

  # Kill local tunnels (matches ProxyJump to torch)
  pkill -f "ssh -N -f .*-J torch" 2>/dev/null || true

  # Close control socket
  ssh -q -O exit -o ControlPath="$CONTROL_PATH" torch 2>/dev/null || true

  set -e
}

trap cleanup INT TERM EXIT

clear
printf "${CYA}${BLD}"
printf "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n"
printf "┃          PyCharm Remote Development Launcher          ┃\n"
printf "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\n"
printf "${RST}\n"

# Cleanup previous session
printf "Cleaning up previous session... "
cleanup
printf "${GRN}✓${RST}\n"

# Establish control master connection
printf "Establishing connection to torch... "
ssh -o ControlMaster=yes -o ControlPath="$CONTROL_PATH" -o ControlPersist=10m -fN torch
printf "${GRN}✓${RST}\n"

# Upload remote script
printf "Uploading launcher script... "
if [[ ! -f "$LOCAL_REMOTE_SCRIPT" ]]; then
  printf "${RED}✗${RST}\n"
  printf "${RED}Error: Remote script not found at %s${RST}\n" "$LOCAL_REMOTE_SCRIPT"
  exit 1
fi

scp -q -o ControlPath="$CONTROL_PATH" "$LOCAL_REMOTE_SCRIPT" torch:/tmp/remote_launcher.sh
ssh -q -o ControlPath="$CONTROL_PATH" torch 'chmod +x /tmp/remote_launcher.sh'
printf "${GRN}✓${RST}\n"

# Run remote script
if ! ssh -t -o ControlPath="$CONTROL_PATH" torch '/tmp/remote_launcher.sh'; then
  printf "\n${RED}✗${RST} Remote launcher failed\n"
  exit 1
fi

# Fetch session info
printf "\n\n${BLD}Local Startup${RST}\n"
printf "Fetching session info... "
if ! ssh -q -o ControlPath="$CONTROL_PATH" torch 'cat /scratch/$USER/.jb/session_info' > /tmp/session_info_$$; then
  printf "${RED}✗${RST}\n"
  printf "${RED}Failed to get session info${RST}\n"
  exit 1
fi

# Parse session info
# shellcheck disable=SC1090
source /tmp/session_info_$$
rm -f /tmp/session_info_$$
printf "${GRN}✓${RST}\n"

# Get remote username from torch config
REMOTE_USER=$(ssh -G torch | grep "^user " | awk '{print $2}')
if [[ -z "$REMOTE_USER" ]]; then
  printf "${RED}Failed to get remote username${RST}\n"
  exit 1
fi

# Create tunnel
printf "Creating SSH tunnel... "

ssh -N -f -o ExitOnForwardFailure=yes \
  -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" -J torch "${REMOTE_USER}@${NODE}"
printf "${GRN}✓${RST}\n"

# Generate local join link if JOIN_URL is available
if [[ -n "${JOIN_URL:-}" ]]; then
  JOIN_LOCAL=$(echo "$JOIN_URL" | sed -E "s|^tcp://127\.0\.0\.1:[0-9]+(.*)$|tcp://localhost:${LOCAL_PORT}\1|")

  printf "\n${GRN}CONNECTION READY${RST}\n\n"
  printf "${BLD}Gateway Link:${RST}\n"
  printf "${GRN}%s${RST}\n\n" "$JOIN_LOCAL"
fi
