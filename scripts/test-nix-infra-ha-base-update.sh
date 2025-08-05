#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $0)
WORK_DIR=${WORK_DIR:-"./TEST_INFRA_HA"}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"24.11"}
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
SERVICE="service001 service002 service003"
OTHER="registry001 worker001 worker002 ingress001"
CLUSTER_NODES="$SERVICE $OTHER"

__help_text__=$(cat <<EOF
Examples:

test-nix-infra-ha-base.sh --env=.env-test
test-nix-infra-ha-base.sh --env=.env-test --no-teardown
test-nix-infra-ha-base.sh teardown --env=.env-test

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

if [[ "create teardown pull publish update test test-apps ssh cmd etcd action port-forward" == *"$1"* ]]; then
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

source $SCRIPT_DIR/check.sh
cmd () { # Override the local declaration
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$1" "$2"
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
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-pod: ";        echo -n $(systemctl is-active podman-app-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-pod: ";        echo -n $(systemctl is-active podman-app-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-mongodb-pod: ";echo -n $(systemctl is-active podman-app-mongodb-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-mongodb-pod: ";echo -n $(systemctl is-active podman-app-mongodb-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-redis-pod: ";echo -n $(systemctl is-active podman-app-redis-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-redis-pod: ";echo -n $(systemctl is-active podman-app-redis-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-elasticsearch-pod: ";echo -n $(systemctl is-active podman-app-elasticsearch-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-elasticsearch-pod: ";echo -n $(systemctl is-active podman-app-elasticsearch-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-mariadb-pod: ";echo -n $(systemctl is-active podman-app-mariadb-pod.service)' &
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-mariadb-pod: ";echo -n $(systemctl is-active podman-app-mariadb-pod.service)' &
  wait # Wait for all process to complete
  # Check that apps are responding locally
  echo "Do apps responds locally?"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-pod: ";         curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11211/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-pod: ";         curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11211/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-mongodb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11311/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-mongodb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11311/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-redis-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11411/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-redis-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11411/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-elasticsearch-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11511/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-elasticsearch-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11511/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-mariadb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11611/ping' & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" 'printf "app-mariadb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11611/ping' & # > pong
  wait # Wait for all process to complete
  # Check that apps are reachable from ingress node
  echo "Can apps be reached from ingress?"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-pod: ';         curl -s http://127.0.0.1:11211/ping" & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl -s http://127.0.0.1:11311/ping" & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-redis-pod: '; curl -s http://127.0.0.1:11411/ping" & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-elasticsearch-pod: '; curl -s http://127.0.0.1:11511/ping" & # > pong
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mariadb-pod: '; curl -s http://127.0.0.1:11611/ping" & # > pong
  wait # Wait for all process to complete
  # Check that app has correct functionality
  echo "Do apps function properly?"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-pod: ';         curl --max-time 2 -s http://127.0.0.1:11211/hello" # > hello world!
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=1&message=hello'" # > 1
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=2&message=bye'" # > 2
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=3&message=hello_world'" # > 3
  
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=1&message=hello'" # > 1
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=2&message=bye'" # > 2
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=3&message=hello_world'" # > 3
  # wait # Wait for all process to complete
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s http://127.0.0.1:11311/db/1" # > hello
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s http://127.0.0.1:11311/db/2" # > bye
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mongodb-pod: '; curl --max-time 2 -s http://127.0.0.1:11311/db/3" # > hello_world

  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/db/1" # > hello
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/db/2" # > bye
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/db/3" # > hello_world
  # wait # Wait for all process to complete
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-redis-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11411/db?id=1&message=hello'" # > 1
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-elasticsearch-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11511/db?id=1&message=hello'" # > 1
  # wait
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-redis-pod: '; curl --max-time 2 -s http://127.0.0.1:11411/db/1" # > hello
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="ingress001" "printf 'app-elasticsearch-pod: '; curl --max-time 2 -s http://127.0.0.1:11511/db/1" # > hello
  # wait
  # $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" "journalctl -n 20 -u podman-app-redis*"
  # $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker002" "journalctl -n 20 -u podman-app-elastic*"
}

publishImageToRegistry() {
    local IMAGE_NAME=$1
    local FILE=$2
    local IMAGE_TAG=$3
    $NIX_INFRA registry publish-image -d $WORK_DIR --batch \
      --target="registry001" \
      --image-name="$IMAGE_NAME" \
      --image-tag="$IMAGE_TAG" \
      --file="$FILE"
}

tearDownCluster() {
  $NIX_INFRA cluster destroy -d $WORK_DIR --batch \
      --target="$CLUSTER_NODES" \
      --ctrl-nodes="$CTRL"

  $NIX_INFRA cluster destroy -d $WORK_DIR --batch \
      --target="$CTRL" \
      --ctrl-nodes="$CTRL"

  $NIX_INFRA ssh-key remove -d $WORK_DIR --batch --name="$SSH_KEY"
}

if [ "$CMD" = "teardown" ]; then
  tearDownCluster
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

  $NIX_INFRA cluster port-forward -d $WORK_DIR --env="$WORK_DIR/.env" \
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
  
  $NIX_INFRA cluster deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --target="$REST"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "nixos-rebuild switch --fast"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "systemctl restart confd"


  

  $NIX_INFRA secrets store -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --secret="mysql://root:your-secure-password@[%%service001.overlayIp%%]:3306,[%%service003.overlayIp%%]:3306/db?&connectTimeout=10000&connectionLimit=10&multipleStatements=true" \
    --name="mariadb.connectionString"

  # ls  $WORK_DIR/app_modules
  $NIX_INFRA cluster deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --target="$REST"
  # $NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "nixos-rebuild switch --fast"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "ls /etc/nixos/app_modules"
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
  publishImageToRegistry app-pod "$WORK_DIR/app_images/app-pod.tar.gz" "1.0"
  publishImageToRegistry app-mongodb-pod "$WORK_DIR/app_images/app-mongodb-pod.tar.gz" "1.0"
  publishImageToRegistry app-mariadb-pod "$WORK_DIR/app_images/app-mariadb-pod.tar.gz" "1.0"
  exit 0
fi

if [ "$CMD" = "pull" ]; then
  # Fallback if ssh terminal isn't working as expected:
  # HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i $WORK_DIR/ssh/$SSH_KEY
  git -C $WORK_DIR pull
  exit 0
fi

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  # Fallback if ssh terminal isn't working as expected:
  # HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i $WORK_DIR/ssh/$SSH_KEY
  $NIX_INFRA cluster ssh -d $WORK_DIR --target="$REST"
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
  $NIX_INFRA cluster action -d $WORK_DIR --target="$_target" --app-module="$module" \
    --cmd="$cmd" # --env-vars="ELASTIC_PASSWORD="
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 cmd --env=$ENV --target=[node] [cmd goes here]"
    exit 1
  fi
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "etcd" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 etcd --env=$ENV [etcd cmd goes here]"
    exit 1
  fi
  $NIX_INFRA cluster etcd -d $WORK_DIR --ctrl-nodes="$CTRL" "$REST"
  exit 0
fi
