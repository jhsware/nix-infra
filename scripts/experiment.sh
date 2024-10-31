#!/usr/bin/env nix-shell
#!nix-shell -i /bin/bash
WORK_DIR="../TEST_INFRA"
NIX_INFRA="dart run --verbosity=error bin/nix_infra.dart"
NIXOS_VERSION="24.05"
SSH_KEY="nixinfra"
CTRL="etcd001"

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

$NIX_INFRA init -d $WORK_DIR --batch

# We need to ssh-add for the key to be picked up by dartssh2
ssh-add $WORK_DIR/ssh/$SSH_KEY

$NIX_INFRA provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --ssh-key=$SSH_KEY \
    --location=hel1 \
    --machine-type=cpx21 \
    --node-names="test001"

$NIX_INFRA destroy -d $WORK_DIR --batch \
    --target="test001" \
    --ctrl-nodes="$CTRL"

$NIX_INFRA remove-ssh-key -d $WORK_DIR --batch --ssh-key-name="$SSH_KEY"