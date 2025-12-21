#!/usr/bin/env bash
WORK_DIR=${WORK_DIR:-"$(dirname "$0")"}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"25.05"}
SSH_KEY="nixinfra"
SSH_EMAIL=${SSH_EMAIL:-your-email@example.com}
ENV=${ENV:-.env}
SECRETS_PWD=${SECRETS_PWD:-my_secrets_password}
TEST_NODES=${TEST_NODES:-"testnode001"}

read -r -d '' __help_text__ <<EOF || true
nix-infra-machine Test Runner
=============================

Usage: $0 <command> [options]

Commands:
  create [name]       Create a new test server on Hetzner Cloud
  convert             Convert different linux distributions to NixOS
  destroy             Tear down all test machines
  status              Run basic health checks on machines
  images              List available Hetzner Cloud system images
  
  ssh <node>          SSH into a node

Options:
  --env=<file>        Environment file (default: .env)

Examples:
  # Create a new test server
  $0 create testnode001
  
  # Run the full test cycle
  $0 convert
  $0 destroy
EOF

if [[ "create convert destroy status ssh images" == *"$1"* ]]; then
  CMD="$1"
  shift
else
  echo "$__help_text__"
  exit 1
fi

for i in "$@"; do
  case $i in
    --help)
    echo "$__help_text__"
    exit 0
    ;;
    --env=*)
    ENV="${i#*=}"
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

if [ "$ENV" != "" ] && [ -f "$ENV" ]; then
  source $ENV
fi

# Check for nix-infra CLI if using default
if [ "$NIX_INFRA" = "nix-infra" ] && ! command -v nix-infra >/dev/null 2>&1; then
  echo "The 'nix-infra' CLI is required for this script to work."
  echo "Visit https://github.com/jhsware/nix-infra for installation instructions."
  exit 1
fi

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Missing env-var HCLOUD_TOKEN. Load through .env-file that is specified through --env."
  exit 1
fi

# Source shared helpers
source "$WORK_DIR/shared.sh"


# ============================================================================
# Hetzner Cloud Commands
# ============================================================================

if [ "$CMD" = "images" ]; then
  curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
    https://api.hetzner.cloud/v1/images | jq -r '.images[] | select(.type=="system") | .name'
  exit 0
fi

if [ "$CMD" = "create" ]; then
  node_name="${REST:-$TEST_NODES}"
  node_name="${node_name%% *}"  # Take first node if multiple provided
  
  if [ -z "$node_name" ]; then
    echo "Usage: $0 create [name]"
    exit 1
  fi

  # Check if SSH key exists on Hetzner Cloud, create if not
  ssh_key_id=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1/ssh_keys?name=$SSH_KEY" | jq -r '.ssh_keys[0].id')
  
  if [ -z "$ssh_key_id" ] || [ "$ssh_key_id" = "null" ]; then
    echo "SSH key '$SSH_KEY' not found on Hetzner Cloud, creating..."
    if [ ! -f "$WORK_DIR/ssh/${SSH_KEY}.pub" ]; then
      echo "Error: Public key file not found: $WORK_DIR/ssh/${SSH_KEY}.pub"
      exit 1
    fi
    pub_key=$(cat "$WORK_DIR/ssh/${SSH_KEY}.pub")
    ssh_key_id=$(curl -s -X POST \
      -H "Authorization: Bearer $HCLOUD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$SSH_KEY\",\"public_key\":\"$pub_key\"}" \
      https://api.hetzner.cloud/v1/ssh_keys | jq -r '.ssh_key.id')
    
    if [ -z "$ssh_key_id" ] || [ "$ssh_key_id" = "null" ]; then
      echo "Error: Failed to create SSH key on Hetzner Cloud"
      exit 1
    fi
    echo "Created SSH key with ID: $ssh_key_id"
  fi

  echo "Creating server '$node_name' on Hetzner Cloud..."
  
  response=$(curl -s -X POST \
    -H "Authorization: Bearer $HCLOUD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$node_name\",
      \"server_type\": \"cpx21\",
      \"image\": \"ubuntu-24.04\",
      \"location\": \"hel1\",
      \"ssh_keys\": [$ssh_key_id]
    }" \
    https://api.hetzner.cloud/v1/servers)
  
  server_id=$(echo "$response" | jq -r '.server.id')
  server_ip=$(echo "$response" | jq -r '.server.public_net.ipv4.ip')
  action_id=$(echo "$response" | jq -r '.action.id')
  error_msg=$(echo "$response" | jq -r '.error.message // empty')
  
  if [ -n "$error_msg" ]; then
    echo "Error: $error_msg"
    exit 1
  fi
  
  if [ -z "$server_id" ] || [ "$server_id" = "null" ]; then
    echo "Error: Failed to create server"
    echo "$response" | jq .
    exit 1
  fi

  echo -n "Waiting for server to be ready... "
  waitForActionToComplete "$action_id"

  # Update servers.yaml
  if [ -f "$WORK_DIR/servers.yaml" ]; then
    # Add new server entry using yq
    yq -i ".servers.$node_name.id = $server_id | .servers.$node_name.ip = \"$server_ip\" | .servers.$node_name.ssh_key = \"./ssh/$SSH_KEY\"" "$WORK_DIR/servers.yaml"
  else
    # Create new servers.yaml
    cat > "$WORK_DIR/servers.yaml" <<YAML
servers:
  $node_name:
    id: $server_id
    ip: $server_ip
    ssh_key: ./ssh/$SSH_KEY
YAML
  fi

  echo ""
  echo "========================================"
  echo "Server created successfully!"
  echo "========================================"
  echo "Node name:    $node_name"
  echo "Server ID:    $server_id"
  echo "IP address:   $server_ip"
  echo "SSH key:      $SSH_KEY"
  echo "========================================"
  
  exit 0
fi

# ============================================================================
# Fleet Management Commands
# ============================================================================

destroyFleet() {
  $NIX_INFRA fleet destroy -d "$WORK_DIR" --batch \
      --target="$TEST_NODES"

  $NIX_INFRA ssh-key remove -d "$WORK_DIR" --batch --name="$SSH_KEY"

  echo "Remove /secrets..."
  rm -rf "$WORK_DIR/secrets"
}

if [ "$CMD" = "destroy" ]; then
  destroyFleet
  exit 0
fi

if [ "$CMD" = "status" ]; then
  testFleet "$TEST_NODES"
  exit 0
fi

# ============================================================================
# Interactive Commands
# ============================================================================

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  $NIX_INFRA fleet ssh -d "$WORK_DIR" --env="$ENV" --target="$REST"
  exit 0
fi

# ============================================================================
# Convert Command - Rebuild and convert to Nixos
# ============================================================================

if [ "$CMD" = "convert" ]; then
  if [ -d "$WORK_DIR/secrets" ]; then
    echo "Found existing ./secrets, this appears to be a live project. Creating a test environment may destroy it."
    exit 1
  fi

  if [ ! -f "$ENV" ]; then
    read -r -d '' env <<EOF || true
# NOTE: The following secrets are required for various operations
# by the nix-infra CLI. Make sure they are encrypted when not in use
SSH_KEY=$SSH_KEY
SSH_EMAIL=$SSH_EMAIL

# The following token is needed to perform provisioning and discovery
HCLOUD_TOKEN=$HCLOUD_TOKEN

# Password for the secrets that are stored in this repo
# These need to be kept secret.
SECRETS_PWD=$SECRETS_PWD
EOF
    echo "$env" > "$WORK_DIR/.env"
  fi

  _start=$(date +%s)

  ssh-add "$WORK_DIR/ssh/$SSH_KEY"

  # ubuntu-22.04 ubuntu-24.04 debian-11 debian-12 centos-stream-9 centos-stream-10 rocky-9 rocky-10 alma-9 alma-10 fedora-41 opensuse-15 nixos-25.05
  for image in ubuntu-22.04 ubuntu-24.04 debian-11 debian-12 centos-stream-9 centos-stream-10 rocky-9 rocky-10 alma-9 alma-10 fedora-41 opensuse-15; do
    _start_test=$(date +%s)
    echo "*** Rebuild $TEST_NODES with $image ***"
    server_id=$(getServerId "${TEST_NODES%% *}")
    if [ -z "$server_id" ]; then
      echo "Failed to get server ID for ${TEST_NODES%% *}"
      exit 1
    fi
    action_id=$(curl -s -X POST \
      -H "Authorization: Bearer $HCLOUD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"image\":\"$image\"}" \
      https://api.hetzner.cloud/v1/servers/$server_id/actions/rebuild | jq -r '.action.id')
      #-s -o /dev/null https://api.hetzner.cloud/v1/servers/115946226/actions/rebuild

    echo -n "Wait for rebuild to complete... "
    waitForActionToComplete "$action_id"
    
    echo -n "Allow to stabilise... "
    snooze 10

    echo "Verify installed system:"
    showInstalledSystem "$TEST_NODES"
    
    _start_provision=$(date +%s)
    echo "*** Provisioning NixOS $NIXOS_VERSION ***"
    $NIX_INFRA fleet provision -d "$WORK_DIR" --batch --env="$ENV" \
        --nixos-version="$NIXOS_VERSION" \
        --ssh-key=$SSH_KEY \
        --location=hel1 \
        --machine-type=cpx21 \
        --node-names="$TEST_NODES"

    _end_provision=$(date +%s)

    echo -n "Allow rebuild to stabilise... "
    snooze 10
    showInstalledSystem "$TEST_NODES"

    # Verify the operation of the test fleet
    echo "******************************************"
    testFleet "$TEST_NODES"
    echo "Base image: $image"
    printf 'Provisioning time: %s\n' "$(printTime $_start_provision $_end_provision)"
    printf 'Total test time: %s\n' "$(printTime $_start_test $(date +%s))"
    echo "******************************************"
  done

  _end=$(date +%s)

  echo "            **              **            "
  echo "            **              **            "
  echo "******************************************"

  printTime() {
    local _start=$1; local _end=$2; local _secs=$((_end-_start))
    printf '%02dh:%02dm:%02ds' $((_secs/3600)) $((_secs%3600/60)) $((_secs%60))
  }
  printf 'TOTAL TEST TIME: %s\n' "$(printTime $_start $_end)"
  echo "***************** DONE *******************"
fi
