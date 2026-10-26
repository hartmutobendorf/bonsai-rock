#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/spread/lib/common.sh"

artifact=$(realpath "${1:?usage: test_rootless_podman.sh <final-rock>}")
test "$(id -u)" -ne 0
test "$(podman --runtime crun info --format '{{.Host.Security.Rootless}}')" = true
podman unshare cat /proc/self/uid_map /proc/self/gid_map

name=bonsai-rootless-smoke
image=localhost/bonsai-rootless-smoke:latest
cleanup() {
    podman logs "$name" 2>&1 | tail -80 || true
    podman rm --force "$name" >/dev/null 2>&1 || true
    podman rmi "$image" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Import to a named local image without relying on an archive's embedded tag.
podman unshare skopeo copy "oci-archive:$artifact" "containers-storage:$image"
test "$(podman image inspect "$image" --format '{{.Config.User}}')" = 1000:1000
podman --runtime crun run -d --name "$name" -p 127.0.0.1::8080 "$image"
address=$(podman port "$name" 8080/tcp)
wait_http "http://$address/health" 60 3
curl -fsS --max-time 10 --compressed "http://$address/" | grep -Fi '<html' >/dev/null
curl -fsS --max-time 10 "http://$address/v1/models" | grep -Fi 'bonsai-1.7b' >/dev/null
reply=$(curl -fsS --max-time 330 -X POST "http://$address/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d '{"model":"bonsai-1.7b","max_tokens":8,"messages":[{"role":"user","content":"Hello"}]}')
printf '%s' "$reply" | grep -Fq '"choices"'
printf '%s' "$reply" | grep -Fq '"content"'
podman top "$name" user group | awk '
    NR > 1 { if ($1 != "_daemon_" || $2 != "_daemon_") exit 1; count++ }
    END { if (count < 2) exit 1 }
'
