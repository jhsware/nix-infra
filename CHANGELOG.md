NOTE: This are pre 1.0 releases, this means there can be breaking changes on minor releases without clear warnings.

## 0.17.0-beta
- added support for converting RHEL-based servers to NixOS (self hosting)
- fixed bug in ascii progress bar that made it wander to the bottom of the screen
- removed static reference to .env

## 0.16.0-beta
- BREAKING: removed legacy commands
- added support for self hosting by configuring server.yaml file
- stability improvements
- documentation improvements
- clean up
- improved test coverage
- fixed test runner, test environment support for MCP tool
- added building linux binaries for MCPs (experimental)

## 0.15.0-beta
- improve MCP tools and docs

## 0.14.0-alpha
- improve safety guards for MCP tools

## 0.13.0-alpha
- split mcp sysops tool into cluster and machine

## 0.12.1-alpha
- fix NixOS upgrade command
- added an experimental MCP test runner (WIP)
- added filesystem access and initial safety guards to MCP tools

## 0.11.0-alpha
- BREAKING: new cli command structure with separate cluster and fleet operations

## 0.10.0-alpha
- added support of forming a fleet of standalone machines

## 0.9.6-alpha
- support placement groups to remove single point of failure due nodes being on the same physical machine

## 0.9.5-alpha
- more robust conversion to NixOS with retry

## 0.9.4-alpha
- improve secrets handling

## 0.9.2-alpha
- improving cluster formation

## 0.9.1-alpha
- added workflow to generate linux binary for releases

## 0.9.0-alpha
- first release, macOS only