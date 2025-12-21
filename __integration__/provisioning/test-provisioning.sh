#!/usr/bin/env bash
WORK_DIR=${WORK_DIR:-"$(dirname "$0")"}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"25.05"}
SSH_KEY="nixinfra"
SSH_EMAIL=${SSH_EMAIL:-your-email@example.com}
ENV=${ENV:-.env}
SECRETS_PWD=${SECRETS_PWD:-my_secrets_password}
TEST_NODES=${TEST_NODES:-"testnode001"}

# # Check for nix-infra CLI if using default
# if [ "$NIX_INFRA" = "nix-infra" ] && ! command -v nix-infra >/dev/null 2>&1; then
#   echo "The 'nix-infra' CLI is required for this script to work."
#   echo "Visit https://github.com/jhsware/nix-infra for installation instructions."
#   exit 1
# fi

read -r -d '' __help_text__ <<EOF || true
nix-infra-machine Test Runner
=============================

Usage: $0 <command> [options]

Commands:
  convert             Convert different linux distributions to NixOS
  destroy             Tear down all test machines
  status              Run basic health checks on machines
  upgrade <nodes>     Upgrade NixOS version on nodes
  
  ssh <node>          SSH into a node

Options:
  --env=<file>        Environment file (default: .env)

Examples:
  # Run the full test cycle
  $0 create --env=.env
  $0 destroy --env=.env
EOF

if [[ "convert upgrade destroy status ssh images" == *"$1"* ]]; then
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

echo workdir: $WORK_DIR
echo path to env: $ENV
if [ "$ENV" != "" ] && [ -f "$ENV" ]; then
  source $ENV
fi

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Missing env-var HCLOUD_TOKEN. Load through .env-file that is specified through --env."
  exit 1
fi

# Source shared helpers
source "$WORK_DIR/shared.sh"


if [ "$CMD" = "images" ]; then
  curl -H "Authorization: Bearer $HCLOUD_TOKEN" \
    https://api.hetzner.cloud/v1/images | jq -r '.images[] | select(.type=="system") | .name'
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

if [ "$CMD" = "upgrade" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 upgrade --env=$ENV [node1 node2 ...]"
    exit 1
  fi
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$REST" "nixos-rebuild switch --upgrade"
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
# Create Command - Provision and Initialize Test Fleet
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

    echo "*** Rebuild $TEST_NODES with $image ***"
    curl -X POST \
      -H "Authorization: Bearer $HCLOUD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"image\":\"$image\"}" \
      -s -o /dev/null https://api.hetzner.cloud/v1/servers/115789511/actions/rebuild
    
    echo -n "Allow rebuild to progress... "
    for i in {1..10}; do
      echo -n "z"
      sleep 0.2
      echo -n "z"
      sleep 0.2
      echo -n "Z"
      sleep 0.6
    done
    echo

    echo "Verify installed system:"
    $NIX_INFRA fleet cmd -d "$WORK_DIR" --env="$ENV" --target="$TEST_NODES" "uname -a; cat /etc/os-release"
    
    echo "*** Provisioning NixOS $NIXOS_VERSION ***"
    $NIX_INFRA fleet provision -d "$WORK_DIR" --batch --env="$ENV" \
        --nixos-version="$NIXOS_VERSION" \
        --ssh-key=$SSH_KEY \
        --location=hel1 \
        --machine-type=cpx21 \
        --node-names="$TEST_NODES"

    _provision=$(date +%s)

    echo -n "Allow rebuild to stabilise... "
    for i in {1..10}; do
      echo -n "z"
      sleep 0.2
      echo -n "z"
      sleep 0.2
      echo -n "Z"
      sleep 0.6
    done
    echo

    # Verify the operation of the test fleet
    echo "******************************************"
    testFleet "$TEST_NODES"
    echo "Base image: $image"
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
  printf '= SUM %s\n' "$(printTime $_start $_end)"
  echo "***************** DONE *******************"
fi
