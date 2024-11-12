#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $0)
WORK_DIR=${WORK_DIR:-"./TEST_INFRA"}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"24.05"}
TEMPLATE_REPO=${TEMPLATE_REPO:-"git@github.com:jhsware/nix-infra-test.git"}
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
CLUSTER_NODES="registry001 service001 service002 service003 worker001 worker002 ingress001"

if [[ "teardown publish update test test-apps ssh cmd etcd" == *"$1"* ]]; then
  CMD="$1"
  shift
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

testCluster() {
  source $SCRIPT_DIR/check.sh
  checkNixos "$CTRL $CLUSTER_NODES"
  checkEtcd "$CTRL"
  checkWireguard "$CLUSTER_NODES"
  checkConfd "$CLUSTER_NODES"
}

testApps() {
  source $SCRIPT_DIR/check.sh

  # Check that apps are running
  $NIX_INFRA cmd -d $WORK_DIR --target="worker001" "printf 'app-pod: ';        systemctl is-active podman-app-pod.service"
  $NIX_INFRA cmd -d $WORK_DIR --target="worker001" "printf 'app-mongodb-pod: ';systemctl is-active podman-app-mongodb-pod.service"

  # Check that apps are responding locally
  $NIX_INFRA cmd -d $WORK_DIR --target="worker001" 'printf "app-pod: ";         curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11211/ping' # > pong
  $NIX_INFRA cmd -d $WORK_DIR --target="worker001" 'printf "app-mongodb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11311/ping' # > pong

  # Check that apps are reachable from ingress node
  $NIX_INFRA cmd -d $WORK_DIR --target="ingress001" "printf 'app-pod: ';         curl -s http://127.0.0.1:11211/ping" # > pong
  $NIX_INFRA cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl -s http://127.0.0.1:11311/ping" # > pong

  # Check that app has correct functionality
  $NIX_INFRA cmd -d $WORK_DIR --target="ingress001" "printf 'app-pod: ';         curl -s http://127.0.0.1:11211/hello" # > hello world!
  $NIX_INFRA cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl -s 'http://127.0.0.1:11311/db?id=1&message=hello'" # > 1
  $NIX_INFRA cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl -s http://127.0.0.1:11311/db/1" # > hello
}

publishImageToRegistry() {
    local IMAGE_NAME=$1
    local FILE=$2
    $NIX_INFRA publish-image -d $WORK_DIR --batch \
    --target="registry001" \
    --image-name="$IMAGE_NAME" \
    --file="$FILE"
}

tearDownCluster() {
  $NIX_INFRA destroy -d $WORK_DIR --batch \
      --target="$CLUSTER_NODES" \
      --ctrl-nodes="$CTRL"

  $NIX_INFRA destroy -d $WORK_DIR --batch \
      --target="$CTRL" \
      --ctrl-nodes="$CTRL"

  $NIX_INFRA remove-ssh-key -d $WORK_DIR --batch --ssh-key-name="$SSH_KEY"
}

if [ "$CMD" = "teardown" ]; then
  tearDownCluster
  exit 0
fi

if [ "$CMD" = "update" ]; then
  (cd $WORK_DIR && git pull --force)
  $NIX_INFRA update-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="$REST" \
    --node-module="node_types/cluster_node.nix" \
    --ctrl-nodes="$CTRL" \
    --rebuild

  $NIX_INFRA deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --target="$TARGET"
  $NIX_INFRA cmd -d $WORK_DIR --target="$TARGET" "nixos-rebuild switch --fast"
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
  publishImageToRegistry app-pod "$WORK_DIR/app_images/app-pod.tar.gz"
  publishImageToRegistry app-mongodb-pod "$WORK_DIR/app_images/app-mongodb-pod.tar.gz"
  exit 0
fi

if [ "$CMD" = "ssh" ]; then
  hcloud server ssh $REST -i "$WORK_DIR/ssh/$SSH_KEY"
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  $NIX_INFRA cmd -d $WORK_DIR --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "etcd" ]; then
  $NIX_INFRA etcd -d $WORK_DIR --ctrl-nodes="$CTRL" "$REST"
  exit 0
fi

rm -rf $WORK_DIR;
git clone $TEMPLATE_REPO $WORK_DIR

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
echo "$env" > $WORK_DIR/.env

cleanupOnFail() {
  if [ $1 -ne 0 ]; then
    echo "$2"
    tearDownCluster
    exit 1
  fi
}

_start=`date +%s`

$NIX_INFRA init -d $WORK_DIR --batch

# We need to add the ssh-key for it to work for some reason
ssh-add $WORK_DIR/ssh/$SSH_KEY

$NIX_INFRA provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --ssh-key=$SSH_KEY \
    --location=hel1 \
    --machine-type=cpx21 \
    --node-names="$CTRL $CLUSTER_NODES"
cleanupOnFail $? "ERROR: Provisioning failed! Cleaning up..."

_provision=`date +%s`

$NIX_INFRA init-ctrl -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --cluster-uuid="d6b76143-bcfa-490a-8f38-91d79be62fab" \
    --target="$CTRL"

_init_ctrl=`date +%s`

$NIX_INFRA init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="registry001" \
    --node-module="node_types/cluster_node.nix" \
    --service-group="" \
    --ctrl-nodes="$CTRL" #&

$NIX_INFRA init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="worker001 worker002" \
    --node-module="node_types/cluster_node.nix" \
    --service-group="backends services" \
    --ctrl-nodes="$CTRL" #&

$NIX_INFRA init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="service001 service002 service003" \
    --node-module="node_types/cluster_node.nix" \
    --service-group="services" \
    --ctrl-nodes="$CTRL" #&

$NIX_INFRA init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="ingress001" \
    --node-module="node_types/ingress_node.nix" \
    --service-group="frontends" \
    --ctrl-nodes="$CTRL" #&

# TODO: When running multiple init-node in parallel, there can be conflicts causing the
# certificate generation to fail. This needs to be fixed
#wait # Wait for all backround processes to complete

$NIX_INFRA cmd -d $WORK_DIR --target="$CLUSTER_NODES" "nixos-rebuild switch --fast"
$NIX_INFRA cmd -d $WORK_DIR --target="$CLUSTER_NODES" "systemctl restart confd"

_init_nodes=`date +%s`

# Now the nodes are up an running, let install apps
echo "INSTALLING APPS..."

$NIX_INFRA deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  --target="registry001"
$NIX_INFRA cmd -d $WORK_DIR --target="registry001" "nixos-rebuild switch --fast"
$NIX_INFRA cmd -d $WORK_DIR --target="registry001" "systemctl restart confd"

publishImageToRegistry app-pod "$WORK_DIR/app_images/app-pod.tar.gz"
publishImageToRegistry app-mongodb-pod "$WORK_DIR/app_images/app-mongodb-pod.tar.gz"

$NIX_INFRA store-secret -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  --secret="super_secret_secret" \
  --save-as-secret="my.test"
echo "---"
$NIX_INFRA deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  --target="service001 service002 service003 worker001 worker002"
$NIX_INFRA cmd -d $WORK_DIR --target="service001 service002 service003 worker001 worker002" "nixos-rebuild switch --fast"
$NIX_INFRA cmd -d $WORK_DIR --target="service001 service002 service003 worker001 worker002" "systemctl restart confd"

$NIX_INFRA action -d $WORK_DIR --target="service001" --app-module="mongodb" --cmd="init" --env-vars="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]"
echo "...INSTALLING APPS"

_end=`date +%s`

echo "******************************************"

testCluster

echo "******************************************"

testApps

echo "******************************************"

if [[ "$TEARDOWN" != "no" ]]; then
  tearDownCluster
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
printf '+ init ctrl  %s\n' $(printTime $_provision $_init_ctrl)
printf '+ init nodes  %s\n' $(printTime $_provision $_init_nodes)
printf '+ install apps %s\n' $(printTime $_init_nodes $_end)
printf '= SUM %s\n' $(printTime $_start $_end)
printf '> TEST TIME %s\n' $(printTime $_start $_after_teardown)

echo "***************** DONE *******************"
