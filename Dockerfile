FROM dart:3.5.4

# Resolve app dependencies.
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get --enforce-lockfile

# Copy app source code and AOT compile it.
COPY . .

RUN dart compile exe --verbosity error --target-os linux -o bin/nix-infra bin/nix_infra.dart

CMD ["cp", "bin/nix-infra /output/"]
