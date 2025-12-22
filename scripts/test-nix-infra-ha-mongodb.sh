#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
WORK_DIR=${WORK_DIR:-"./TEST_INFRA_HA"}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"25.05"}
TEMPLATE_REPO=${TEMPLATE_REPO:-"git@github.com:jhsware/nix-infra-test.git"}
TEMPLATE_REPO_BRANCH=${TEMPLATE_REPO_BRANCH:-"main"}
SSH_KEY="nixinfra"
SSH_EMAIL=${SSH_EMAIL:-your-email@example.com}

CERT_MAIL=${CERT_MAIL:-your-email@example.com}
CERT_COUNTRY_CODE=${CERT_COUNTRY_CODE:-SE}
CERT_STATE_PROVINCE=${CERT_STATE_PROVINCE:-Sweden}
CERT_COMPANY=${CERT_COMPANY:-Your COmpany Inc}

CA_PASS=${CA_PASS:-my_ca_password}
INTERMEDIATE_CA_PASS=${INTERMEDIATE_CA_PASS:-my_ca_inter_password}
SECRETS_PWD=${SECRETS_PWD:-my_secrets_password}

CTRL="etcd001 etcd002 etcd003"
SERVICE="service001 service002 service003"
OTHER="registry001 worker001 worker002 ingress001"
CLUSTER_NODES="$SERVICE $OTHER"

__help_text__=$(cat <<EOF
Examples:

test-nix-infra-ha-base.sh --env=.env-test
test-nix-infra-ha-base.sh --env=.env-test --no-teardown
test-nix-infra-ha-base.sh destroy --env=.env-test

# Interact with a node
test-nix-infra-ha-base.sh ssh --env=.env-test service001
test-nix-infra-ha-base.sh cmd --env=.env-test --target=service001 ls -alh
test-nix-infra-ha-base.sh port-forward --env=.env-test --target=service001 --port-mapping=80:80
# ssh -i ./TEST_INFRA_HA/ssh/nixinfra -N -L 27017:localhost
:27017 root@[server-ip]

# Query the etcd database
test-nix-infra-ha-base.sh etcd --env=.env-test --target=etcd001 get --prefix /nodes

# The action is hardcoded in this script, edit to try different stuff
test-nix-infra-ha-base.sh action --env=.env-test --target=service001 args to action
EOF
)

if [[ "create destroy pull publish update test test-apps ssh cmd etcd action port-forward" == *"$1"* ]]; then
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
    --branch=*)
    TEMPLATE_REPO_BRANCH="${i#*=}"
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
  source "$ENV"
fi

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Missing env-var HCLOUD_TOKEN. Load through .env-file that is specified through --env."
  exit 1
fi

source "$SCRIPT_DIR/check.sh"
cmd () { # Override the local declaration
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$1" "$2"
}

testCluster() {
  checkNixos "$CTRL $CLUSTER_NODES"
  checkEtcd "$CTRL"
  checkWireguard "$CLUSTER_NODES"
  checkConfd "$CLUSTER_NODES"
}

testApps() {
  # Check that apps are running
  echo "Are apps active?"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" 'printf "app-mongodb-pod: ";echo -n $(systemctl is-active podman-app-mongodb-pod.service)' &
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker002" 'printf "app-mongodb-pod: ";echo -n $(systemctl is-active podman-app-mongodb-pod.service)' &
  wait # Wait for all process to complete
  # Check that apps are responding locally
  echo "Do apps responds locally?"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" 'printf "app-mongodb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11311/ping' & # > pong
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker002" 'printf "app-mongodb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11311/ping' & # > pong
  wait # Wait for all process to complete
  # Check that apps are reachable from ingress node
  echo "Can apps be reached from ingress?"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "printf 'app-mongodb-pod: '; curl -s http://127.0.0.1:11311/ping" & # > pong
  # Check that app has correct functionality
  echo "Do apps function properly?"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=1&message=hello'" # > 1
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=2&message=bye'" # > 2
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=3&message=hello_world'" # > 3

  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s http://127.0.0.1:11311/db/1" # > hello
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s http://127.0.0.1:11311/db/2" # > bye
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s http://127.0.0.1:11311/db/3" # > hello_world
}

publishImageToRegistry() {
    local IMAGE_NAME=$1
    local FILE=$2
    local IMAGE_TAG=$3
    $NIX_INFRA registry publish-image -d "$WORK_DIR" --batch \
      --target="registry001" \
      --image-name="$IMAGE_NAME" \
      --image-tag="$IMAGE_TAG" \
      --file="$FILE"
}

tearDownCluster() {
  $NIX_INFRA cluster destroy -d "$WORK_DIR" --batch \
      --target="$CLUSTER_NODES" \
      --ctrl-nodes="$CTRL"

  $NIX_INFRA cluster destroy -d "$WORK_DIR" --batch \
      --target="$CTRL" \
      --ctrl-nodes="$CTRL"

  $NIX_INFRA ssh-key remove -d "$WORK_DIR" --batch --name="$SSH_KEY"
}

if [ "$CMD" = "destroy" ]; then
  tearDownCluster
  exit 0
fi

if [ "$CMD" = "port-forward" ]; then
  if [ -z "$TARGET" ] || [ -z "$PORT_MAPPING" ]; then
    echo "Usage: $0 port-forward --env=$ENV --port-mapping=[local:remote]"
    exit 1
  fi

  OLD_IFS=$IFS  # Save current IFS
  IFS=: read -r LOCAL_PORT REMOTE_PORT <<< "$PORT_MAPPING"
  IFS=$OLD_IFS  # Restore IFS to original value

  $NIX_INFRA cluster port-forward -d "$WORK_DIR" --env="$WORK_DIR/.env" \
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
  #$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$REST" "ls /etc/nixos/app_modules"
  exit 0
fi

if [ "$CMD" = "test" ]; then
  testCluster
  exit 0
fi

if [ "$CMD" = "test-apps" ]; then
  testApps
  exit 0
fi

if [ "$CMD" = "publish" ]; then
  echo Publish applications...
  publishImageToRegistry app-mongodb-pod "$WORK_DIR/app_images/app-mongodb-pod.tar.gz" "1.0"
  exit 0
fi

if [ "$CMD" = "pull" ]; then
  # Fallback if ssh terminal isn't working as expected:
  # HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i "$WORK_DIR"/ssh/$SSH_KEY
  git -C "$WORK_DIR" pull
  exit 0
fi

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  # Fallback if ssh terminal isn't working as expected:
  # HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i "$WORK_DIR"/ssh/$SSH_KEY
  $NIX_INFRA cluster ssh -d "$WORK_DIR" --target="$REST"
  exit 0
fi

if [ "$CMD" = "action" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 action [target] [cmd]"
    exit 1
  fi
  
  read -r module cmd < <(echo "$REST")
  _target=${TARGET:-"service001"}
  # (cd "$WORK_DIR" && git fetch origin && git reset --hard origin/$(git branch --show-current))
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="$_target" --app-module="$module" \
    --cmd="$cmd" # --env-vars="ELASTIC_PASSWORD="
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 cmd --env=$ENV --target=[node] [cmd goes here]"
    exit 1
  fi
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "etcd" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 etcd --env=$ENV [etcd cmd goes here]"
    exit 1
  fi
  $NIX_INFRA cluster etcd -d "$WORK_DIR" --ctrl-nodes="$CTRL" "$REST"
  exit 0
fi

if [ "$CMD" = "create" ]; then
  rm -rf "$WORK_DIR";
  git clone -b "$TEMPLATE_REPO_BRANCH" "$TEMPLATE_REPO" "$WORK_DIR"

  env=$(cat <<EOF
# NOTE: The following secrets are required for various operations
# by the nix-infra CLI. Make sure they are encrypted when not in use
SSH_KEY=$(echo $SSH_KEY)
SSH_EMAIL=$(echo $SSH_EMAIL)

# The following token is needed to perform provisioning and discovery
HCLOUD_TOKEN=$(echo $HCLOUD_TOKEN)

# Certificate Authority
CERT_EMAIL=$(echo $CERT_MAIL)
CERT_COUNTRY_CODE=$(echo $CERT_COUNTRY_CODE)
CERT_STATE_PROVINCE=$(echo $CERT_STATE_PROVINCE)
CERT_COMPANY=$(echo $CERT_COMPANY)
# Root password for the created certificate authority and CA intermediate.
# This needs to be kept secret and should not be stored here in a real deployment!
CA_PASS=$(echo $CA_PASS)
# The intermediate can be revoked so while it needs to be kept secret, it is less
# of a risk than the root password
INTERMEDIATE_CA_PASS=$(echo $INTERMEDIATE_CA_PASS)

# Password for the secrets that are stored in this repo
# These need to be kept secret.
SECRETS_PWD=$(echo $SECRETS_PWD)
EOF
)
  echo "$env" > "$WORK_DIR"/.env
fi


cleanupOnFail() {
  if [ $1 -ne 0 ]; then
    echo "$2"
    tearDownCluster
    exit 1
  fi
}

if [ "$CMD" = "create" ]; then
  _start=$(date +%s)

  $NIX_INFRA init -d "$WORK_DIR" --batch

  # We need to add the ssh-key for it to work for some reason
  ssh-add "$WORK_DIR"/ssh/$SSH_KEY

  # We split the provisioning calls so we can select --placement-groups
  # where it makes sense. Since provisioning takes a while we run
  # them in parallel as background jobs.
  $NIX_INFRA cluster provision -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$CTRL" \
      --placement-group="ctrl-plane" &
  pid1=$!
  $NIX_INFRA cluster provision -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$SERVICE" \
      --placement-group="service-workers" &
  pid2=$!
  $NIX_INFRA cluster provision -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$OTHER" &
  pid3=$!

  for pid in $pid1 $pid2 $pid3; do
    wait "$pid"
    cleanupOnFail $? "WARNING: Provisioning failed! Cleaning up..."
  done

  _provision=$(date +%s)

  $NIX_INFRA cluster init-ctrl -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --cluster-uuid="d6b76143-bcfa-490a-8f38-91d79be62fab" \
      --target="$CTRL"

  _init_ctrl=$(date +%s)

  $NIX_INFRA cluster init-node -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --target="registry001" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="" \
      --ctrl-nodes="$CTRL" &

  $NIX_INFRA cluster init-node -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --target="worker001 worker002" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="backends services" \
      --ctrl-nodes="$CTRL" &

  $NIX_INFRA cluster init-node -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --target="service001 service002 service003" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="services" \
      --ctrl-nodes="$CTRL" &

  $NIX_INFRA cluster init-node -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --target="ingress001" \
      --node-module="node_types/ingress_node.nix" \
      --service-group="frontends" \
      --ctrl-nodes="$CTRL" &

  wait # Wait for all backround processes to complete

  _init_nodes=$(date +%s)

  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="registry001" "nixos-rebuild switch --fast; systemctl restart confd"

  # Deploy service nodes sequentially to allow cluster to form properly
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service001" "nixos-rebuild switch --fast; systemctl restart confd"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service002" "nixos-rebuild switch --fast; systemctl restart confd"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service003" "nixos-rebuild switch --fast; systemctl restart confd"

  # This takes a while and allows DBs to form clusters during upload
  publishImageToRegistry app-mongodb-pod "$WORK_DIR/app_images/app-mongodb-pod.tar.gz" "1.0"

  # Workers
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001 worker002" "nixos-rebuild switch --fast; systemctl restart confd"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="ingress001" "nixos-rebuild switch --fast; systemctl restart confd"

  _end=$(date +%s)

  # Testing cluster to allow services and apps some time to spin up and form clusters
  echo "******************************************"
  testCluster
  echo "******************************************"

  echo -e "\n** MongoDB **"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="init" --env-vars="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]"

  echo "...INSTALLING APPS"

  echo -e "\n** MongoDB **"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-db --database=hello"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-db --database=test"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-admin --database=test --username=test-admin"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-admin --database=hello --username=hello-admin"
  
  echo "******************************************"

  testApps

  echo "******************************************"

  echo -e "\n** MongoDB **"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="status"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="dbs"
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="users"

  if [[ "$TEARDOWN" != "no" ]]; then
    tearDownCluster
  fi

  _after_teardown=$(date +%s)

  echo "            **              **            "
  echo "            **              **            "
  echo "******************************************"

  printTime() {
    local _start=$1; local _end=$2; local _secs=$((_end-_start))
    printf '%02dh:%02dm:%02ds' $((_secs/3600)) $((_secs%3600/60)) $((_secs%60))
  }
  printf '+ provision  %s\n' "$(printTime "$_start" "$_provision")"
  printf '+ init ctrl  %s\n' "$(printTime "$_provision" "$_init_ctrl")"
  printf '+ init nodes  %s\n' "$(printTime "$_provision" "$_init_nodes")"
  printf '+ install apps %s\n' "$(printTime "$_init_nodes" "$_end")"
  printf '= SUM %s\n' "$(printTime "$_start" "$_end")"
  printf '> TEST TIME %s\n' "$(printTime "$_start" "$_after_teardown")"

  echo "***************** DONE *******************"
fi