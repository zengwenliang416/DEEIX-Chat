#!/bin/sh
set -eu
umask 077

fail() {
  printf 'Deployment failed: %s\n' "$*" >&2
  exit 1
}

valid_sha() {
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 40 ]
}

SHA=${1:-${CI_COMMIT_SHA:-}}
valid_sha "$SHA" || fail 'a full lowercase 40-character Git SHA is required'
IMAGE="local/deeix-chat:$SHA"
ROOT=${DEEIX_DEPLOY_ROOT:-/opt/deeix-chat}
PROBE_IMAGE=${DEEIX_PROBE_IMAGE:-curlimages/curl:8.16.0}
PROJECT=deeix-chat-production
CONTAINER=deeix-chat-production-app
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "$ROOT" in /*) ;; *) fail 'DEEIX_DEPLOY_ROOT must be an absolute path' ;; esac
[ -d "$ROOT" ] || fail 'initialize the deployment root and private config.yaml first'
ROOT=$(CDPATH= cd -- "$ROOT" && pwd -P)
[ "$ROOT" != / ] || fail 'the deployment root cannot be /'
[ -f "$ROOT/config.yaml" ] && [ ! -L "$ROOT/config.yaml" ] ||
  fail 'a regular private config.yaml is required'
for directory in data storage backups; do
  [ ! -L "$ROOT/$directory" ] || fail "$directory cannot be a symbolic link"
done

# Avoid a caller's environment overriding the explicit, versioned image.env file.
unset DEEIX_CHAT_IMAGE COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES

LOCK="$ROOT/.deploy.lock"
mkdir "$LOCK" 2>/dev/null || fail 'another deployment owns .deploy.lock; inspect that job before removing a stale lock'
printf '%s\n' "$$" > "$LOCK/pid"
SUCCESS=0
TOUCHED_APP=0
HAD_OLD=0
SNAPSHOT_READY=0
FILES_CHANGED=0
MAINTENANCE_FLAG="$ROOT/maintenance.flag"
MAINTENANCE_PREEXISTED=0
MAINTENANCE_CREATED=0
BACKUP=
OLD_SHA=
OLD_IMAGE=
OLD_IMAGE_ID=

compose() {
  docker compose --project-name "$PROJECT" --project-directory "$ROOT" \
    --env-file "$ROOT/image.env" --file "$ROOT/compose.yaml" "$@"
}

safe_state() {
  # Never print application logs: first boot logs can contain the admin password.
  docker container inspect --format \
    'status={{.State.Status}} exit_code={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} started_at={{.State.StartedAt}} finished_at={{.State.FinishedAt}}' \
    "$CONTAINER" 2>/dev/null || true
}

enter_maintenance() {
  if [ -e "$MAINTENANCE_FLAG" ] || [ -L "$MAINTENANCE_FLAG" ]; then
    [ -f "$MAINTENANCE_FLAG" ] && [ ! -L "$MAINTENANCE_FLAG" ] || return 1
    MAINTENANCE_PREEXISTED=1
  else
    printf 'deployment=%s pid=%s\n' "$SHA" "$$" > "$LOCK/maintenance-owner" || return 1
    # Exclusive creation preserves an operator's flag even if it appears here.
    # A signal or partial write leaves maintenance enabled, never the reverse.
    (set -C; cat "$LOCK/maintenance-owner" > "$MAINTENANCE_FLAG") || return 1
    MAINTENANCE_CREATED=1
  fi
}

verify_maintenance() {
  [ -f "$MAINTENANCE_FLAG" ] && [ ! -L "$MAINTENANCE_FLAG" ] || return 1
  # Keep the public Host/SNI fixed and verify its TLS certificate while routing
  # directly to host Nginx. A CDN response must not stand in for this gate.
  docker run --rm --pull never --network host \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --user 65534:65534 "$PROBE_IMAGE" \
    --silent --show-error --head --noproxy '*' \
    --connect-timeout 3 --max-time 10 \
    --resolve deeix.motion-cover.com:443:127.0.0.1 \
    --write-out '\n%{http_code}\n' https://deeix.motion-cover.com/readyz \
    > "$LOCK/maintenance-response.txt" || return 1
  [ "$(tail -n 1 "$LOCK/maintenance-response.txt")" = 503 ] || return 1
  tr -d '\r' < "$LOCK/maintenance-response.txt" | \
    grep -Eiq '^X-DEEIX-Maintenance:[[:space:]]*deployment[[:space:]]*$'
}

leave_owned_maintenance() {
  if [ "$MAINTENANCE_PREEXISTED" -eq 1 ]; then
    printf 'Existing maintenance flag retained; public traffic remains closed.\n'
    return 0
  fi
  [ "$MAINTENANCE_CREATED" -eq 1 ] || return 0
  # Do not remove a flag replaced by an operator during this deployment.
  [ -f "$MAINTENANCE_FLAG" ] && [ ! -L "$MAINTENANCE_FLAG" ] &&
    cmp -s "$LOCK/maintenance-owner" "$MAINTENANCE_FLAG" || return 1
  rm -- "$MAINTENANCE_FLAG" || return 1
}

probe() {
  docker run --rm --pull never --network "container:$1" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --user 65534:65534 "$PROBE_IMAGE" \
    --silent --fail --connect-timeout 2 --max-time 6 \
    "http://127.0.0.1:8080$2"
}

wait_healthy() {
  expected_sha=$1
  attempt=1
  while [ "$attempt" -le 30 ]; do
    probe_id=$(docker container inspect --format '{{.Id}}' "$CONTAINER" 2>/dev/null) || probe_id=
    if [ -n "$probe_id" ] &&
      probe "$probe_id" /healthz > "$LOCK/health.json" 2>/dev/null &&
      grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$LOCK/health.json" &&
      probe "$probe_id" /readyz > "$LOCK/readiness.json" 2>/dev/null &&
      grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$LOCK/readiness.json" &&
      probe "$probe_id" /api/v1/version > "$LOCK/version.json" 2>/dev/null; then
      actual_sha=$(sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$LOCK/version.json")
      [ "$actual_sha" != "$expected_sha" ] || return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

persist_probes() {
  for state_file in health.json readiness.json version.json; do
    cp "$LOCK/$state_file" "$ROOT/.$state_file.tmp" || return 1
    mv "$ROOT/.$state_file.tmp" "$ROOT/$state_file" || return 1
  done
}

rollback() {
  # Reconfirm ingress isolation before restoring data. If the gate cannot be
  # proved, preserve the current data and leave maintenance for intervention.
  verify_maintenance || return 1
  # Stop every writer before replacing SQLite/WAL and local attachment files.
  rollback_id=$(docker container ls --all --filter "name=^/$CONTAINER$" --format '{{.ID}}') || return 1
  if [ -n "$rollback_id" ]; then
    docker stop --time 30 "$rollback_id" >/dev/null || return 1
  fi

  if [ "$HAD_OLD" -eq 0 ]; then
    printf 'First deployment stopped; data and the stopped container are retained at %s.\n' "$ROOT" >&2
    return 0
  fi

  if [ "$SNAPSHOT_READY" -eq 1 ] && [ "$FILES_CHANGED" -eq 1 ]; then
    mkdir "$BACKUP/restore" || return 1
    tar -xpf "$BACKUP/state.tar" -C "$BACKUP/restore" || return 1
    [ -d "$BACKUP/restore/data" ] && [ -d "$BACKUP/restore/storage" ] || return 1
    mv "$ROOT/data" "$BACKUP/failed-data" || return 1
    mv "$ROOT/storage" "$BACKUP/failed-storage" || return 1
    mv "$BACKUP/restore/data" "$ROOT/data" || return 1
    mv "$BACKUP/restore/storage" "$ROOT/storage" || return 1
    rmdir "$BACKUP/restore" || return 1
  fi

  if [ "$FILES_CHANGED" -eq 1 ]; then
    for restore_file in compose.yaml image.env config.yaml; do
      cp -p "$BACKUP/$restore_file" "$ROOT/.$restore_file.rollback" || return 1
      mv "$ROOT/.$restore_file.rollback" "$ROOT/$restore_file" || return 1
    done
  fi
  # A rebuild of the same SHA can move a tag. Restore the previous container's
  # exact image ID before starting the previous compose/image.env combination.
  docker tag "$OLD_IMAGE_ID" "$OLD_IMAGE" || return 1
  compose up --detach --no-deps --pull never --force-recreate app || return 1
  wait_healthy "$OLD_SHA" || return 1
  persist_probes || return 1
  if [ -f "$BACKUP/current-release.json" ]; then
    cp -p "$BACKUP/current-release.json" "$ROOT/.current-release.json.rollback" || return 1
    mv "$ROOT/.current-release.json.rollback" "$ROOT/current-release.json" || return 1
  else
    rm -f "$ROOT/current-release.json" || return 1
  fi
  printf 'Rollback verified: %s.\n' "$OLD_IMAGE" >&2
}

finish() {
  result=$1
  trap - 0 INT TERM
  set +e
  if [ "$SUCCESS" -ne 1 ]; then
    [ "$result" -ne 0 ] || result=1
    if [ -n "$BACKUP" ]; then
      safe_state > "$BACKUP/failed-container-state.txt"
      cat "$BACKUP/failed-container-state.txt" >&2
      for failed_probe in health.json readiness.json version.json; do
        if [ -f "$LOCK/$failed_probe" ]; then
          cp "$LOCK/$failed_probe" "$BACKUP/failed-$failed_probe"
        fi
      done
    fi
    if [ "$TOUCHED_APP" -eq 1 ]; then
      if rollback; then
        if [ "$HAD_OLD" -eq 1 ] && ! leave_owned_maintenance; then
          printf 'Old release restored, but maintenance could not be cleared; inspect %s.\n' "$MAINTENANCE_FLAG" >&2
        fi
      else
        printf 'Automatic rollback failed; maintenance is retained. Inspect %s.\n' "$BACKUP" >&2
        safe_state >&2
      fi
    fi
  fi
  rm -rf -- "$LOCK"
  exit "$result"
}
trap 'finish $?' 0
trap 'exit 130' INT
trap 'exit 143' TERM

IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE")
[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE")" = "$SHA" ] ||
  fail 'candidate image revision does not match the requested commit'
[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$IMAGE")" = linux/amd64 ] ||
  fail 'candidate image must target linux/amd64'
VERSION=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
case "$VERSION" in ''|*[!A-Za-z0-9.+-]*) fail 'candidate image version label is invalid' ;; esac
docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 || docker pull "$PROBE_IMAGE"

cp "$SCRIPT_DIR/compose.yaml" "$LOCK/compose.yaml"
printf 'DEEIX_CHAT_IMAGE=%s\n' "$IMAGE" > "$LOCK/image.env"
docker compose --project-name "$PROJECT" --project-directory "$ROOT" \
  --env-file "$LOCK/image.env" --file "$LOCK/compose.yaml" config --quiet

OLD_CONTAINER_ID=$(docker container ls --all --filter "name=^/$CONTAINER$" --format '{{.ID}}')
if [ -n "$OLD_CONTAINER_ID" ]; then
  [ "$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$OLD_CONTAINER_ID")" = "$PROJECT" ] ||
    fail 'existing container does not belong to this Compose project'
  [ "$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$OLD_CONTAINER_ID")" = app ] ||
    fail 'existing container does not belong to the app service'
  [ -f "$ROOT/compose.yaml" ] && [ -f "$ROOT/image.env" ] ||
    fail 'existing container requires its previous compose.yaml and image.env for rollback'
  OLD_IMAGE=$(docker container inspect --format '{{.Config.Image}}' "$OLD_CONTAINER_ID")
  OLD_IMAGE_ID=$(docker container inspect --format '{{.Image}}' "$OLD_CONTAINER_ID")
  OLD_SHA=$(docker container inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$OLD_CONTAINER_ID")
  valid_sha "$OLD_SHA" || fail 'previous container has no valid revision label'
  [ "$OLD_IMAGE" = "local/deeix-chat:$OLD_SHA" ] || fail 'previous container image reference is unexpected'
  [ "$(sed -n 's/^DEEIX_CHAT_IMAGE=//p' "$ROOT/image.env")" = "$OLD_IMAGE" ] ||
    fail 'previous image.env does not match the running container'
  docker image inspect "$OLD_IMAGE_ID" >/dev/null
  compose config --quiet
  HAD_OLD=1
fi

mkdir -p "$ROOT/data" "$ROOT/storage" "$ROOT/backups"
BACKUP_NAME="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$SHA" | cut -c 1-12)-$$"
BACKUP="$ROOT/backups/$BACKUP_NAME"
mkdir "$BACKUP"
for previous_file in config.yaml compose.yaml image.env current-release.json health.json readiness.json version.json; do
  if [ -f "$ROOT/$previous_file" ]; then
    cp -p "$ROOT/$previous_file" "$BACKUP/$previous_file"
  fi
done
printf '%s\n' "$IMAGE_ID" > "$BACKUP/candidate-image-id"
enter_maintenance || fail 'could not create or preserve the ingress maintenance flag'
verify_maintenance || fail 'Nginx maintenance gate must return HTTP 503 and X-DEEIX-Maintenance: deployment before touching the app'
cp "$LOCK/maintenance-response.txt" "$BACKUP/maintenance-response.txt"
if [ "$HAD_OLD" -eq 1 ]; then
  printf '%s\n' "$OLD_IMAGE_ID" > "$BACKUP/previous-image-id"
  TOUCHED_APP=1
  docker stop --time 30 "$OLD_CONTAINER_ID" >/dev/null
fi

# Stopping the process makes the database, WAL and attached files one consistent
# snapshot. Keep snapshots and failed data; retention is an operator decision.
tar -cpf "$BACKUP/state.tar" -C "$ROOT" data storage
SNAPSHOT_READY=1
FILES_CHANGED=1
cp "$LOCK/compose.yaml" "$ROOT/.compose.yaml.new"
mv "$ROOT/.compose.yaml.new" "$ROOT/compose.yaml"
cp "$LOCK/image.env" "$ROOT/.image.env.new"
mv "$ROOT/.image.env.new" "$ROOT/image.env"
TOUCHED_APP=1
compose up --detach --no-deps --pull never --force-recreate app

wait_healthy "$SHA" || fail 'health, readiness or exact commit verification did not pass'
persist_probes
printf '{"commit":"%s","version":"%s","image":"%s","image_id":"%s","deployed_at":"%s","backup":"%s","previous_commit":"%s"}\n' \
  "$SHA" "$VERSION" "$IMAGE" "$IMAGE_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BACKUP_NAME" "$OLD_SHA" \
  > "$ROOT/.current-release.json.new"
mv "$ROOT/.current-release.json.new" "$ROOT/current-release.json"
# Commit the healthy release before reopening ingress. A signal after flag
# removal must never enter rollback and discard newly acknowledged writes.
SUCCESS=1
leave_owned_maintenance || fail 'release is healthy but maintenance could not be cleared; inspect maintenance.flag'
printf 'Deployment verified: %s (version %s).\n' "$IMAGE" "$VERSION"
