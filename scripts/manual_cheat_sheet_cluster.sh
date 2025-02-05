scripts/test-nix-infra-ha-base.sh ssh --env=.env-test service001
scripts/test-nix-infra-ha-base.sh cmd --env=.env-test --target="service001 service002 service003" systemctl status

scripts/test-nix-infra-ha-base.sh --env=.env-test
scripts/test-nix-infra-ha-base.sh --env=.env-test --no-teardown
scripts/test-nix-infra-ha-base.sh teardown --env=.env-test

# Required env vars to run steps from automation scripts
export NIX_INFRA="dart run --verbosity=error bin/nix_infra.dart"
export WORK_DIR="./TEST_INFRA_HA"
export SSH_KEY="nixinfra"
export NIXOS_VERSION="24.11"

export CTRL="etcd001 etcd002 etcd003"
export SERVICE="service001 service002 service003"
export OTHER="registry001 worker001 worker002 ingress001"
export CLUSTER_NODES="$SERVICE $OTHER"

# Manual steps to create cluster

$NIX_INFRA init -d $WORK_DIR --batch

ssh-add $WORK_DIR/ssh/$SSH_KEY

## Provision

$NIX_INFRA cluster provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$CTRL" \
      --placement-group="ctrl-plane"

$NIX_INFRA cluster provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$SERVICE" \
      --placement-group="service-workers"

$NIX_INFRA cluster provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$OTHER"

## Init nodes

$NIX_INFRA cluster init-ctrl -d $WORK_DIR --batch --debug --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --cluster-uuid="d6b76143-bcfa-490a-8f38-91d79be62fab" \
      --target="$CTRL"

$NIX_INFRA cluster init-node -d $WORK_DIR --batch --debug --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --target="registry001" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="" \
      --ctrl-nodes="$CTRL"

$NIX_INFRA cluster init-node -d $WORK_DIR --batch --debug --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --target="worker001 worker002" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="backends services" \
      --ctrl-nodes="$CTRL"

$NIX_INFRA cluster init-node -d $WORK_DIR --batch --debug --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --target="service001 service002 service003" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="services" \
      --ctrl-nodes="$CTRL"

$NIX_INFRA cluster init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --target="ingress001" \
      --node-module="node_types/ingress_node.nix" \
      --service-group="frontends" \
      --ctrl-nodes="$CTRL"

# Re-start evertyhing // Is this really required?
#  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$CLUSTER_NODES" "nixos-rebuild switch --fast"
#  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$CLUSTER_NODES" "systemctl restart confd"

$NIX_INFRA cluster deploy-apps -d $WORK_DIR --batch --debug --env="$WORK_DIR/.env" \
    --target="registry001"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="registry001" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="registry001" "systemctl restart confd"

$NIX_INFRA registry publish-image -d $WORK_DIR --batch \
      --target="registry001" \
      --image-name="app-pod" \
      --file="$WORK_DIR/app_images/app-pod.tar.gz"
$NIX_INFRA registry publish-image -d $WORK_DIR --batch \
      --target="registry001" \
      --image-name="app-mongodb-pod" \
      --file="$WORK_DIR/app_images/app-mongodb-pod.tar.gz"
$NIX_INFRA registry publish-image -d $WORK_DIR --batch \
      --target="registry001" \
      --image-name="app-elasticsearch-pod" \
      --file="$WORK_DIR/app_images/app-elasticsearch-pod.tar.gz"
$NIX_INFRA registry publish-image -d $WORK_DIR --batch \
      --target="registry001" \
      --image-name="app-redis-pod" \
      --file="$WORK_DIR/app_images/app-redis-pod.tar.gz"

$NIX_INFRA secrets store -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --secret="super_secret_secret" \
      --name="my.test"
$NIX_INFRA secrets store -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --secret="redis://default:SUPER_SECRET_PASSWORD@[%%service001.overlayIp%%]:6380" \
      --name="keydb.connectionString"
$NIX_INFRA secrets store -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --secret="http://127.0.0.1:9200" \
      --name="elasticsearch.connectionString"
  

$NIX_INFRA cluster deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --target="service001 service002 service003 worker001 worker002"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="service001 service002 service003 worker001 worker002" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="service001 service002 service003 worker001 worker002" "systemctl restart confd"

# Run the mongodb init script
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mongodb" --cmd="init" --env-vars="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]"