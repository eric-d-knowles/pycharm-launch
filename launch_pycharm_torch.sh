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
# Expand $HOME for ControlPath
CONTROL_PATH="$HOME/.ssh/control-torch-%C"

cleanup() {
  local close_socket="${1:-yes}"
  set +e

  # Only run SSH cleanup commands if control socket exists
  if ssh -o ControlPath="$CONTROL_PATH" -O check torch 2>/dev/null; then
    # Cancel jobs and kill salloc (using control socket if available)
    if [[ "$close_socket" == "yes" ]]; then
      printf "  Cancelling jobs... "
    fi
    ssh -q -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" torch 'scancel -u "$USER" 2>/dev/null' || true
    if [[ "$close_socket" == "yes" ]]; then
      printf "done\n"
    fi

    if [[ "$close_socket" == "yes" ]]; then
      printf "  Killing processes... "
    fi
    ssh -q -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" torch 'pkill -u "$USER" salloc 2>/dev/null' || true
    if [[ "$close_socket" == "yes" ]]; then
      printf "done\n"
    fi
    sleep 1

    # Clean remote dir
    if [[ "$close_socket" == "yes" ]]; then
      printf "  Cleaning remote dir... "
    fi
    ssh -q -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" torch 'rm -rf /scratch/$USER/.jb 2>/dev/null; mkdir -p /scratch/$USER/.jb' || true
    if [[ "$close_socket" == "yes" ]]; then
      printf "done\n"
    fi
  fi

  # Kill local tunnels - but NOT the control master
  # Look for SSH processes with -N (no command) and -L (port forwarding)
  pkill -f "ssh -N.*-L.*torch" 2>/dev/null || true

  # Also kill any SSH processes listening on common ports
  lsof -ti :8888 2>/dev/null | xargs kill -9 2>/dev/null || true

  # Close control socket (only if requested)
  if [[ "$close_socket" == "yes" ]]; then
    ssh -q -O exit -o ControlPath="$CONTROL_PATH" torch 2>/dev/null || true
  fi

  set -e
}

trap cleanup INT TERM

clear
printf "${CYA}${BLD}"
printf "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n"
printf "┃          PyCharm Remote Development Launcher          ┃\n"
printf "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\n"
printf "${RST}\n"

# Clean up stale control socket if it exists
if ! ssh -o ControlPath="$CONTROL_PATH" -O check torch 2>/dev/null; then
  # Control socket exists but is not responding - remove it
  rm -f "$HOME"/.ssh/control-torch-* 2>/dev/null || true
fi

# Establish control master connection
# Use -o to override any ControlMaster=no in config
if ! ssh -o ControlMaster=yes -o ControlPath="$CONTROL_PATH" -o ControlPersist=10m -fN torch; then
  printf "${RED}Failed to start control master${RST}\n"
  exit 1
fi

# Wait for control socket to be created
for i in {1..50}; do
  if ssh -o ControlPath="$CONTROL_PATH" -O check torch 2>/dev/null; then
    break
  fi
  sleep 0.1
done

# Verify the control master is working
if ! ssh -o ControlPath="$CONTROL_PATH" -O check torch 2>/dev/null; then
  printf "${RED}Control master not responding${RST}\n"
  ls -la ~/.ssh/control-* 2>&1 | head -3
  exit 1
fi

# Cleanup previous session (but don't close the control socket we just created)
printf "Cleaning up previous session... "
cleanup "no"
printf "${GRN}✓${RST}\n"

# Upload remote script
printf "Uploading launcher script... "
if [[ ! -f "$LOCAL_REMOTE_SCRIPT" ]]; then
  printf "${RED}✗${RST}\n"
  printf "${RED}Error: Remote script not found at %s${RST}\n" "$LOCAL_REMOTE_SCRIPT"
  exit 1
fi

cat "$LOCAL_REMOTE_SCRIPT" | ssh -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" torch 'cat > /tmp/remote_launcher.sh && chmod +x /tmp/remote_launcher.sh'
printf "${GRN}✓${RST}\n"

# Run remote script
if ! ssh -t -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" torch '/tmp/remote_launcher.sh'; then
  printf "\n${RED}✗${RST} Remote launcher failed\n"
  exit 1
fi

# Fetch session info
printf "\n\n${BLD}Local Startup${RST}\n"
printf "Fetching session info... "
if ! ssh -q -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" torch 'cat /scratch/$USER/.jb/session_info' > /tmp/session_info_$$; then
  printf "${RED}✗${RST}\n"
  printf "${RED}Failed to get session info${RST}\n"
  exit 1
fi

# Parse session info
# shellcheck disable=SC1090
source /tmp/session_info_$$
rm -f /tmp/session_info_$$
printf "${GRN}✓${RST}\n"

# Create tunnel to compute node via login node
printf "Creating SSH tunnel... "

# First, start an SSH tunnel on the login node to the compute node (in background)
ssh -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" torch \
  "nohup ssh -N -f -L ${REMOTE_PORT}:127.0.0.1:${REMOTE_PORT} ${NODE} > /dev/null 2>&1 &"

# Wait a moment for the remote tunnel to establish
sleep 2

# Now create the local tunnel to the login node
ssh -N -f -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" -o ExitOnForwardFailure=yes \
  -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" torch

printf "${GRN}✓${RST}\n"

# Generate local join link if JOIN_URL is available
if [[ -n "${JOIN_URL:-}" ]]; then
  JOIN_LOCAL=$(echo "$JOIN_URL" | sed -E "s|^tcp://127\.0\.0\.1:[0-9]+(.*)$|tcp://localhost:${LOCAL_PORT}\1|")

  printf "\n${GRN}CONNECTION READY${RST}\n\n"
  printf "${BLD}Gateway Link:${RST}\n"
  printf "${GRN}%s${RST}\n\n" "$JOIN_LOCAL"
fi
