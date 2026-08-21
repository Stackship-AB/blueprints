#!/usr/bin/env bash
#
# Mirror all upstream images referenced by the supabase blueprint into the
# Stackship registry so they can be scanned and served from a trusted source.
# Signature enforcement (cosign + admission policy) will be layered on later.
#
# Usage:
#   ./mirror-images.sh                # copy all platforms with buildx imagetools
#   DRY_RUN=1 ./mirror-images.sh      # print actions only
#
# Requires: docker buildx, jq, and an authenticated session against both
# docker.io and the target registry.

set -euo pipefail

TARGET_REGISTRY="${TARGET_REGISTRY:-registry.stackship.se/blueprints/supabase}"
CONTAINER_CLI="${CONTAINER_CLI:-docker}"
REQUIRED_PLATFORMS="${REQUIRED_PLATFORMS:-linux/amd64,linux/arm64}"

# Upstream images, keyed by the repo path used under $TARGET_REGISTRY.
# Keep this list in sync with components/*.yaml — tags must match the image
# lines referenced in each component manifest.
IMAGES=(
    "postgres|supabase/postgres:17.6.1.084"
    "gotrue|supabase/gotrue:v2.186.0"
    "realtime|supabase/realtime:v2.76.5"
    "storage-api|supabase/storage-api:v1.48.26"
    "postgres-meta|supabase/postgres-meta:v0.96.3"
    "postgrest|postgrest/postgrest:v14.8"
    "studio|supabase/studio:2026.04.08-sha-205cbe7"
    "kong|kong/kong:3.9.1"
    "imgproxy|darthsim/imgproxy:v3.30.1"
    "functions|supabase/edge-runtime:v1.71.2"
    "analytics|supabase/logflare:1.36.1"
    "vector|timberio/vector:0.53.0-alpine"
    "supervisor|supabase/supavisor:2.7.4"
)

run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "DRY-RUN: $*"
    else
        echo "+ $*"
        "$@"
    fi
}

collect_platforms() {
        local image_ref="$1"
        "$CONTAINER_CLI" buildx imagetools inspect --raw "$image_ref" \
                | jq -r '
                        if .manifests then
                            .manifests[]?.platform
                            | select(.os != null and .architecture != null)
                            | "\(.os)/\(.architecture)"
                        elif .os != null and .architecture != null then
                            "\(.os)/\(.architecture)"
                        else
                            empty
                        end
                    ' \
                | sort -u
}

assert_required_platforms() {
        local image_ref="$1"
        local platforms
        platforms="$(collect_platforms "$image_ref")"

        if [[ -z "$platforms" ]]; then
                echo "ERROR: could not resolve platforms for ${image_ref}" >&2
                exit 1
        fi

        IFS=',' read -r -a required <<< "$REQUIRED_PLATFORMS"
        for platform in "${required[@]}"; do
                if ! grep -qx "$platform" <<< "$platforms"; then
                        echo "ERROR: ${image_ref} is missing required platform ${platform}" >&2
                        echo "Found platforms:" >&2
                        echo "$platforms" >&2
                        exit 1
                fi
        done
}

mirror_one() {
    local target_repo="$1"
    local source_ref="$2"
    local tag="${source_ref##*:}"
    local target_ref="${TARGET_REGISTRY}/${target_repo}:${tag}"

    echo ""
    echo "=== ${source_ref}  ->  ${target_ref} ==="

    # Fail fast if upstream image does not publish the required architecture set.
    assert_required_platforms "$source_ref"

    # Preserve all upstream platforms (for example amd64 + arm64) instead of
    # re-publishing only the local host architecture.
    run "$CONTAINER_CLI" buildx imagetools create --tag "$target_ref" "$source_ref"

    # Ensure target registry reference still contains the required platforms.
    assert_required_platforms "$target_ref"
}

if ! "$CONTAINER_CLI" buildx version >/dev/null 2>&1; then
    echo "ERROR: docker buildx is required to mirror multi-arch images." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for platform verification." >&2
    exit 1
fi

for entry in "${IMAGES[@]}"; do
    mirror_one "${entry%%|*}" "${entry#*|}"
done

echo ""
echo "Mirrored ${#IMAGES[@]} images to ${TARGET_REGISTRY}."
