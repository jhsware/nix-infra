## Model Context Protocol Server
```sh
dart run --verbosity=error path/to/nix-infra/bin/nix_infra_mcp.dart
npx @modelcontextprotocol/inspector dart --verbosity=error path/to/nix-infra/bin/nix_infra_mcp.dart
../scripts/claude.sh 
```

## Running Tests

Install the test script
```sh
curl -sSL https://raw.githubusercontent.com/jhsware/nix-infra-ha-cluster/main/scripts/get-test.sh | bash
```

Create a test cluster, run it and tear it down
```sh
nix-infra-test/run-tests.sh --no-teardown | tee test-cluster.log
nix-infra-test/run-tests.sh run [module-name] | tee test.log
nix-infra-test/run-tests.sh reset
nix-infra-test/run-tests.sh run [module-name] | tee test.log
nix-infra-test/run-tests.sh teardown
```


Dev notes:
```sh
git clone ../nix-infra-ha-cluster/ --branch=mongodb-test TEST_NIX_INFRA
cp .env-test TEST_NIX_INFRA/.env
cd TEST_NIX_INFRA
__test__/run-tests.sh create | tee cluster.log
__test__/run-tests.sh run mongodb --no-teardown


__test__/run-tests.sh run --env=.env-test mariadb
__test__/run-tests.sh action --env=.env-test mariadb status
__test__/run-tests.sh reset --env=.env-test
__test__/run-tests.sh run --env=.env-test other-test
__test__/run-tests.sh teardown --env=.env-test

(cd TEST_NIX_INFRA; __test__/run-tests.sh run mongodb mariadb keydb elasticsearch | tee test.log)



TEMPLATE_REPO="../nix-infra-ha-cluster" scripts/test-nix-infra-ha-mongodb.sh --branch=mongodb-test --env=.env-test --no-teardown | tee cluster.log
scripts/test-nix-infra-ha-mongodb.sh teardown --env=.env-test

TEMPLATE_REPO="../nix-infra-ha-cluster" ../nix-infra-ha-cluster/__test__/run-tests.sh create --branch=mongodb-test --env=.env-test --no-teardown | tee test.log
```