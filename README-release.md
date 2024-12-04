1. Update version in pubspec.yaml
2. Commit and push
3. Run the [Github build action](https://github.com/jhsware/nix-infra/actions/workflows/release-linux.yml)

A [draft release](https://github.com/jhsware/nix-infra/releases) with a linux binary is created

4. Run the macOS release command 

```sh
./build.sh release --env=./.env
```

5. Upload the signed installer to the draft release and:
- add a tag
- title should be same as tag
- add description

6. Publish the release
