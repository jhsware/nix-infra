#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $0)
WORK_DIR="../HA_CLUSTER_TEST"
NIX_INFRA="dart run --verbosity=error bin/nix_infra.dart"
NIXOS_VERSION="24.05"
TEMPLATE_REPO="git@github.com:jhsware/nix-infra-ha-cluster.git"
SSH_KEY="nixinfra"
CTRL="etcd001 etcd002 etcd003"
CLUSTER_NODES="registry001 service001 service002 service003 worker001 worker002 ingress001"

if [[ "teardown update test" == *"$1"* ]]; then
  CMD="$1"
fi

for i in "$@"; do
  case $i in
    --env=*)
    ENV="${i#*=}"
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

source $ENV

testCluster() {
  source $SCRIPT_DIR/check.sh
  checkNixos "$CTRL $CLUSTER_NODES"
  checkEtcd "$CTRL"
  checkWireguard "$CLUSTER_NODES"
  checkConfd "$CLUSTER_NODES"
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
    --target="$CLUSTER_NODES" \
    --node-module="node_types/cluster_node.nix" \
    --ctrl-nodes="$CTRL" \
    --rebuild
  exit 0
fi

if [ "$CMD" = "test" ]; then
  testCluster
  exit 0
fi

rm -rf $WORK_DIR;
git clone $TEMPLATE_REPO $WORK_DIR

env=$(cat <<EOF
# NOTE: The following secrets are required for various operations
# by the nix-infra CLI. Make sure they are encrypted when not in use
SSH_KEY=$(echo $SSH_KEY)
# The following token is needed to perform provisioning and discovery
HCLOUD_TOKEN=$(echo $HCLOUD_TOKEN)
# Root password for the created certificate authority and CA intermediate.
# This needs to be kept secret and should not be stored here in a real deployment!
CA_PASS=my_ca_password
# The intermediate can be revoked so while it needs to be kept secret, it is less
# of a risk than the root password
INTERMEDIATE_CA_PASS=my_ca_inter_password
# Password for the secrets that are stored in this repo
# These need to be kept secret.
SECRETS_PWD=my_secrets_password
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
    --target="registry001 worker001 worker002" \
    --node-module="node_types/cluster_node.nix" \
    --service-group="frontends backends" \
    --ctrl-nodes="$CTRL"

$NIX_INFRA init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="service001 service002 service003" \
    --node-module="node_types/cluster_node.nix" \
    --service-group="services" \
    --ctrl-nodes="$CTRL"

$NIX_INFRA init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --target="ingress001" \
    --node-module="node_types/ingress_node.nix" \
    --service-group="services" \
    --ctrl-nodes="$CTRL"

$NIX_INFRA update-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  --nixos-version=$NIXOS_VERSION \
  --target="$CLUSTER_NODES" \
  --node-module="node_types/cluster_node.nix" \
  --ctrl-nodes="$CTRL"

$NIX_INFRA cmd -d $WORK_DIR --target="$CLUSTER_NODES" "nixos-rebuild switch --fast"
$NIX_INFRA cmd -d $WORK_DIR --target="$CLUSTER_NODES" "systemctl restart confd"

_end=`date +%s`

echo "******************************************"
printTime() {
  local _start=$1; local _end=$2; local _secs=$((_end-_start))
  printf '%02dh:%02dm:%02ds' $(($_secs/3600)) $(($_secs%3600/60)) $(($_secs%60))
}
printf '** Total %s\n' $(printTime $_start $_end)
printf '** - provision  %s\n' $(printTime $_start $_provision)
printf '** - init_ctrl  %s\n' $(printTime $_provision $_init_ctrl)
printf '** - init_nodes %s\n' $(printTime $_init_ctrl $_end)
echo "******************************************"

testCluster

echo "******************************************"

tearDownCluster

echo "***************** DONE *******************"