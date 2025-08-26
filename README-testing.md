## Model Context Protocol Server
```sh
dart run --verbosity=error /Users/jhsware/DEV/nix-infra/bin/nix_infra_mcp.dart
npx @modelcontextprotocol/inspector dart --verbosity=error /Users/jhsware/DEV/nix-infra/bin/nix_infra_mcp.dart
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
TEMPLATE_REPO="../nix-infra-ha-cluster" ../nix-infra-ha-cluster/__test__/run-tests.sh create --branch=mariadb-cluster --env=.env-test --no-teardown | tee test.log
TEST_NIX_INFRA/__test__/run-tests.sh run --env=.env-test mariadb
TEST_NIX_INFRA/__test__/run-tests.sh action --env=.env-test mariadb status
TEST_NIX_INFRA/__test__/run-tests.sh reset --env=.env-test
TEST_NIX_INFRA/__test__/run-tests.sh run --env=.env-test other-test
TEST_NIX_INFRA/__test__/run-tests.sh teardown --env=.env-test
```