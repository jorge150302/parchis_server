# Production image. Credentials are NOT baked in: pass the service account
# at runtime, e.g. FIREBASE_SERVICE_ACCOUNT_JSON as a secret env var.
#
#   docker build -t parchis-server .
#   docker run -p 8080:8080 -e FIREBASE_SERVICE_ACCOUNT_JSON="$(cat service_account.json)" parchis-server

FROM dart:3.11.5 AS build
WORKDIR /src

COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart pub global activate dart_frog_cli 1.2.14 \
 && dart pub global run dart_frog_cli:dart_frog build

WORKDIR /src/build
RUN dart pub get --offline \
 && dart compile exe bin/server.dart -o bin/server

# Minimal runtime: the AOT binary plus the system libraries it needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /src/build/bin/server /app/bin/server
ENV PORT=8080
EXPOSE 8080
CMD ["/app/bin/server"]
