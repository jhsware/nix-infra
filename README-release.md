1. Update version in pubspec.yaml
2. Commit and push
3. Run the [Github build action](https://github.com/jhsware/nix-infra/actions/workflows/release-linux.yml)

A [draft release](https://github.com/jhsware/nix-infra/releases) with a linux binary is created

4. Buld the macOS binaries

```sh
./build.sh build-macos --env=./.env
```

5. Run the macOS release command 

```sh
./build.sh release-macos --env=./.env
```

6. Upload the signed installer to the draft release and:
- add a tag
- title should be same as tag
- add description

7. Publish the release
