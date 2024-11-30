#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $0)
WORK_DIR=${WORK_DIR:-"./TEST_INFRA"}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"24.05"}
TEMPLATE_REPO="git@github.com:jhsware/nix-infra-test.git"
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
CLUSTER_NODES="registry001 service001 worker001 ingress001"

if [[ "teardown ssh" == *"$1"* ]]; then
  CMD="$1"
  shift
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

echoLog() {
  echo "$1"
  echo "$1" >> cluster_log.log
}

printTime() {
  local _start=$1; local _end=$2; local _secs=$((_end-_start))
  printf '%02dh:%02dm:%02ds' $(($_secs/3600)) $(($_secs%3600/60)) $(($_secs%60))
}

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Missing env-var HCLOUD_TOKEN. Load through .env-file that is specified through --env."
  exit 1
fi

testCluster() {
  source $SCRIPT_DIR/check.sh
  checkNixos "$CTRL $CLUSTER_NODES"
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

if [ "$CMD" = "ssh" ]; then
  HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i "$WORK_DIR/ssh/$SSH_KEY"
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
    return 1
  fi
}

$NIX_INFRA init -d $WORK_DIR --batch

# We need to add the ssh-key for it to work for some reason
ssh-add $WORK_DIR/ssh/$SSH_KEY

echoLog "Starting..."
for i in {1..5}; do
  _start=`date +%s`
  $NIX_INFRA provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$CTRL $CLUSTER_NODES"
  res=$?
  _provision=`date +%s`
  if [ $res -ne 0 ]; then
    echoLog "ERROR: Provisioning failed! Cleaning up..."
  else
    echoLog "SUCCESS: $(printTime $_start $_provision)"
  fi
  tearDownCluster
  sleep 60
done
