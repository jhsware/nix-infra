#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $0)
WORK_DIR=${WORK_DIR:-"./TEST_INFRA_MACHINE"}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"24.11"}
TEMPLATE_REPO=${TEMPLATE_REPO:-"git@github.com:jhsware/nix-infra-machine.git"}
SSH_KEY="nixinfra-machine"
SSH_EMAIL=${SSH_EMAIL:-your-email@example.com}

SECRETS_PWD=${SECRETS_PWD:-my_secrets_password}

NODES="node001"

__help_text__=$(cat <<EOF
Examples:

test-nix-infra-machine.sh --env=.env-test
test-nix-infra-machine.sh --env=.env-test --no-teardown
test-nix-infra-machine.sh teardown --env=.env-test

# Interact with a node
test-nix-infra-machine.sh ssh --env=.env-test service001
test-nix-infra-machine.sh cmd --env=.env-test --target=service001 ls -alh
test-nix-infra-machine.sh port-forward --env=.env-test --target=service001 --port-mapping=80:80
# ssh -i ./TEST_INFRA_HA/ssh/nixinfra -N -L 27017:localhost

# The action is hardcoded in this script, edit to try different stuff
test-nix-infra-machine.sh action --env=.env-test --target=service001 args to action
EOF
)

if [[ "create teardown update test test-apps ssh cmd action port-forward" == *"$1"* ]]; then
  CMD="$1"
  shift
else
  CMD="create"
fi

for i in "$@"; do
  case $i in
    --env=*)
    ENV="${i#*=}"
    shift
    ;;
    --target=*)
    TARGET="${i#*=}"
    shift
    ;;
    --no-teardown)
    TEARDOWN=no
    shift
    ;;
    --port-mapping=*)
    PORT_MAPPING="${i#*=}"
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

if [ "$ENV" != "" ]; then
  source $ENV
fi

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Missing env-var HCLOUD_TOKEN. Load through .env-file that is specified through --env."
  exit 1
fi

testMachines() {
  source $SCRIPT_DIR/check.sh
  checkNixos "$NODES"
}

testApps() {
  source $SCRIPT_DIR/check.sh

  # Check that apps are running
  echo "Are apps active?"
  $NIX_INFRA cmd -d $WORK_DIR --target="node001" 'printf "app-pod: ";        echo -n $(systemctl is-active podman-app-pod.service)' &
  wait # Wait for all process to complete
}

tearDown() {
  $NIX_INFRA destroy -d $WORK_DIR --batch \
      --target="$NODES"
  $NIX_INFRA remove-ssh-key -d $WORK_DIR --batch --ssh-key-name="$SSH_KEY"
}

if [ "$CMD" = "teardown" ]; then
  tearDown
  exit 0
fi

if [ "$CMD" = "port-forward" ]; then
  if [ -z "$TARGET" ] || [ -z "$PORT_MAPPING" ]; then
    echo "Usage: $0 port-forward --env=$ENV --port-mapping=[local:remote]"
    exit 1
  fi

  OLD_IFS=$IFS  # Save current IFS
  IFS=: read LOCAL_PORT REMOTE_PORT <<< "$PORT_MAPPING"
  IFS=$OLD_IFS  # Restore IFS to original value

  $NIX_INFRA port-forward -d $WORK_DIR --env="$WORK_DIR/.env" \
    --target="$TARGET" \
    --local-port="$LOCAL_PORT" \
    --remote-port="$REMOTE_PORT"
  exit 0
fi

if [ "$CMD" = "update" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 update --env=$ENV [node1 node2 ...]"
    exit 1
  fi
  (cd "$WORK_DIR" && git fetch origin && git reset --hard origin/$(git branch --show-current))
  $NIX_INFRA update-machine -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="$REST" \
    --node-module="node_types/standalone_machine.nix" \
    --rebuild
  
  $NIX_INFRA deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --target="$REST"
  $NIX_INFRA cmd -d $WORK_DIR --target="$REST" "nixos-rebuild switch --fast"
  exit 0
fi

if [ "$CMD" = "test" ]; then
  testMachines
  exit 0
fi

if [ "$CMD" = "test-apps" ]; then
  testApps
  exit 0
fi

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  # This is the only way I get ssh to work properly right now
  # the nix-infra ssh command won't handle control codes right now.
  HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i $WORK_DIR/ssh/$SSH_KEY
  exit 0
fi

if [ "$CMD" = "action" ]; then
  # read action opts <<< "$REST"
  # if [ -z $action ]; then
  #   echo "Usage: $0 action [cmd] [opts]"
  #   exit 1
  # fi
  # (cd "$WORK_DIR" && git fetch origin && git reset --hard origin/$(git branch --show-current))
  $NIX_INFRA action -d $WORK_DIR --target="service001" --app-module="elasticsearch" \
    --cmd="$REST" # --env-vars="ELASTIC_PASSWORD="
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 cmd --env=$ENV --target=[node] [cmd goes here]"
    exit 1
  fi
  $NIX_INFRA cmd -d $WORK_DIR --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "create" ]; then
  rm -rf $WORK_DIR;
  git clone $TEMPLATE_REPO $WORK_DIR

  env=$(cat <<EOF
# NOTE: The following secrets are required for various operations
# by the nix-infra CLI. Make sure they are encrypted when not in use
SSH_KEY=$(echo $SSH_KEY)
SSH_EMAIL=$(echo $SSH_EMAIL)

# The following token is needed to perform provisioning and discovery
HCLOUD_TOKEN=$(echo $HCLOUD_TOKEN)

# Password for the secrets that are stored in this repo
# These need to be kept secret.
SECRETS_PWD=$(echo $SECRETS_PWD)
EOF
)
  echo "$env" > $WORK_DIR/.env
fi


cleanupOnFail() {
  if [ $1 -ne 0 ]; then
    echo "$2"
    tearDown
    exit 1
  fi
}

if [ "$CMD" = "create" ]; then
  _start=`date +%s`

  $NIX_INFRA init -d $WORK_DIR --no-cert-auth --batch

  # We need to add the ssh-key for it to work for some reason
  ssh-add $WORK_DIR/ssh/$SSH_KEY

  # We split the provisioning calls so we can select --placement-groups
  # where it makes sense. Since provisioning takes a while we run
  # them in parallel as background jobs.
  $NIX_INFRA provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$NODES"
  cleanupOnFail $? "ERROR: Provisioning failed! Cleaning up..."

  _provision=`date +%s`

  $NIX_INFRA init-machine -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --target="$NODES" \
      --node-module="node_types/standalone_machine.nix"

  # TODO: Is this really needed?
  $NIX_INFRA cmd -d $WORK_DIR --target="$NODES" "nixos-rebuild switch --fast"

  _init_nodes=`date +%s`

  # Now the nodes are up an running, let install apps
  echo "INSTALLING APPS..."

  $NIX_INFRA deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --target="$NODES" --no-overlay-network
  $NIX_INFRA cmd -d $WORK_DIR --target="$NODES" "nixos-rebuild switch --fast"
  
  echo "...INSTALLING APPS"

  _end=`date +%s`

  echo "******************************************"

  testMachines

  echo "******************************************"

  if [[ "$TEARDOWN" != "no" ]]; then
    tearDown
  fi

  _after_teardown=`date +%s`

  echo "            **              **            "
  echo "            **              **            "
  echo "******************************************"

  printTime() {
    local _start=$1; local _end=$2; local _secs=$((_end-_start))
    printf '%02dh:%02dm:%02ds' $(($_secs/3600)) $(($_secs%3600/60)) $(($_secs%60))
  }
  printf '+ provision  %s\n' $(printTime $_start $_provision)
  printf '+ init nodes  %s\n' $(printTime $_provision $_init_nodes)
  printf '+ install apps %s\n' $(printTime $_init_nodes $_end)
  printf '= SUM %s\n' $(printTime $_start $_end)
  printf '> TEST TIME %s\n' $(printTime $_start $_after_teardown)

  echo "***************** DONE *******************"
fi