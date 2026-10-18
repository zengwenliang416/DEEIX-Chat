#!/bin/sh
set -eu

fail() {
  printf 'Build failed: %s\n' "$*" >&2
  exit 1
}

SHA=${1:-${CI_COMMIT_SHA:-}}
case "$SHA" in ''|*[!0-9a-f]*) fail 'a full lowercase Git SHA is required' ;; esac
[ "${#SHA}" -eq 40 ] || fail 'Git SHA must contain exactly 40 characters'
if [ -n "${EXPECTED_COMMIT:-}" ]; then
  [ "$EXPECTED_COMMIT" = "$SHA" ] ||
    fail 'dev HEAD changed: CI_COMMIT_SHA does not match EXPECTED_COMMIT'
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
BUILDER=${BUILDX_BUILDER:-deeix-chat-production}
IMAGE="local/deeix-chat:$SHA"
VERSION=$(tr -d '\r\n' < "$REPO_ROOT/VERSION")
case "$VERSION" in ''|*[!A-Za-z0-9.+-]*) fail 'VERSION contains unsupported characters' ;; esac
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The same client metadata directory is used when the host creates this builder.
# The builder container has a 2 CPU / 3 GiB limit and serial BuildKit execution.
docker buildx inspect "$BUILDER" >/dev/null 2>&1 ||
  fail "builder $BUILDER is unavailable; initialize it using the production README"
docker buildx inspect --bootstrap "$BUILDER" >/dev/null

TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' 0
trap 'exit 130' INT
trap 'exit 143' TERM

# Preserve the repository's build path. Only the temporary copy adds bounded Go
# parallelism and a test target; the runtime target remains the root Dockerfile's.
awk '
  { print }
  /^FROM[[:space:]]+.*[[:space:]]+AS[[:space:]]+frontend-builder[[:space:]]*$/ {
    print "ENV NODE_OPTIONS=--max-old-space-size=2048"
    print "ENV NEXT_TELEMETRY_DISABLED=1"
    frontend_matched++
  }
  /^FROM[[:space:]]+.*[[:space:]]+AS[[:space:]]+backend-builder[[:space:]]*$/ {
    print "ENV GOMAXPROCS=2"
    print "ENV GOFLAGS=-p=2"
    matched++
  }
  END { if (matched != 1 || frontend_matched != 1) exit 1 }
' "$REPO_ROOT/Dockerfile" > "$TEMP_DIR/Dockerfile" ||
  fail 'expected exactly one frontend-builder and backend-builder stage in the root Dockerfile'

cat >> "$TEMP_DIR/Dockerfile" <<'EOF'

FROM backend-builder AS api-tests
RUN --mount=type=cache,id=go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=go-build,target=/root/.cache/go-build \
    CGO_ENABLED=1 go test -p 2 ./...
EOF

docker buildx build \
  --builder "$BUILDER" \
  --platform linux/amd64 \
  --file "$TEMP_DIR/Dockerfile" \
  --target api-tests \
  --build-arg "GIT_COMMIT=$SHA" \
  --build-arg "BUILD_TIME=$BUILD_TIME" \
  --output type=cacheonly \
  "$REPO_ROOT"

# Next.js build runs its TypeScript check (ignoreBuildErrors is not enabled).
docker buildx build \
  --builder "$BUILDER" \
  --platform linux/amd64 \
  --file "$TEMP_DIR/Dockerfile" \
  --target runtime \
  --build-arg "GIT_COMMIT=$SHA" \
  --build-arg "BUILD_TIME=$BUILD_TIME" \
  --label "org.opencontainers.image.revision=$SHA" \
  --label "org.opencontainers.image.version=$VERSION" \
  --label "org.opencontainers.image.created=$BUILD_TIME" \
  --label 'org.opencontainers.image.source=https://github.com/zengwenliang416/DEEIX-Chat' \
  --provenance=false \
  --load \
  --tag "$IMAGE" \
  "$REPO_ROOT"

[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE")" = "$SHA" ] ||
  fail 'runtime image revision label does not match the requested commit'
printf 'Built and tested %s (version %s).\n' "$IMAGE" "$VERSION"
