(__test__/run-tests.sh create | tee cluster.log) && (__test__/run-tests.sh run keydb mongodb | tee test.log) && (__test__/run-tests.sh destroy | tee -a cluster.log)
(cd TEST_NIX_INFRA/; __test__/run-tests.sh teardown)
NIXOS_VERSION="24.05" __test__/provision-test.sh upgrade
NIXOS_VERSION="24.11" __test__/provision-test.sh upgrade
NIXOS_VERSION="25.05" __test__/provision-test.sh upgrade
TEMPLATE_REPO="../nix-infra-ha-cluster" ../nix-infra-ha-cluster/__test__/run-tests.sh --env=.env-test --no-teardown --force --branch=mariadb-cluster
__test__/run-tests.sh create
__test__/run-tests.sh destroy
__test__/run-tests.sh version
__test__/run-tests.sh action --target=service001 --debug --env-vars="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]" mongodb init
__test__/run-tests.sh action --target=service001 --debug mongodb init --env-vars="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]"
__test__/run-tests.sh action --target=service001 init
__test__/run-tests.sh action --target=service001 mongodb init
__test__/run-tests.sh action --target=service001 mongodb init --debug
__test__/run-tests.sh action --target=service001 mongodb init --debug --env-vars="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]"
__test__/run-tests.sh action --target=service001 mongodb init --debug --env="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]"
__test__/run-tests.sh action mongodb dbs
__test__/run-tests.sh action mongodb status
__test__/run-tests.sh action mongodb users
__test__/run-tests.sh cmd --target=service001 "cat /etc/nixos/configuration.nix | head -n 8"
__test__/run-tests.sh cmd --target=service002 "cat /etc/nixos/configuration.nix | head -n 8"
__test__/run-tests.sh cmd --target=service002 "nixos-version"
__test__/run-tests.sh cmd --target=worker001 "cat /etc/nixos/configuration.nix | head -n 8"
__test__/run-tests.sh cmd --target=worker001 "nixos-version"
__test__/run-tests.sh cmd worker001 "cat /etc/nixos/configuration.nix | head -n 8"
__test__/run-tests.sh cmd worker001 "nixos-version"
__test__/run-tests.sh create
__test__/run-tests.sh create --force --no-teardown
__test__/run-tests.sh create | tee cluster.log
__test__/run-tests.sh destroy
__test__/run-tests.sh reset
__test__/run-tests.sh reset mongodb
__test__/run-tests.sh run --no-teardown mongodb
__test__/run-tests.sh run keydb
__test__/run-tests.sh run mariadb elasticsearch mongodb keydb
__test__/run-tests.sh run mongodb
__test__/run-tests.sh run mongodb --no-teardown
__test__/run-tests.sh run mongodb mariadb keydb elasticsearch
__test__/run-tests.sh run mongodb mariadb keydb elasticsearch | tee test.log
__test__/run-tests.sh ssh etcd001
__test__/run-tests.sh ssh service001
__test__/run-tests.sh ssh service001exit
__test__/run-tests.sh ssh service001exit    7  __test__/run-tests.sh ssh worker001
__test__/run-tests.sh ssh service001exit[B
__test__/run-tests.sh ssh worker001
__test__/run-tests.sh teardown
../scripts/claude.sh

chmod 755 __test__/provision-test.sh