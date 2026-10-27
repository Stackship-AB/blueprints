#!/usr/bin/env bash
#
# Mirror all upstream images referenced by the n8n blueprint into the
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

TARGET_REGISTRY="${TARGET_REGISTRY:-registry.stackship.se/blueprints/n8n}"
CONTAINER_CLI="${CONTAINER_CLI:-docker}"
REQUIRED_PLATFORMS="${REQUIRED_PLATFORMS:-linux/amd64,linux/arm64}"

# Upstream images, keyed by the repo path used under $TARGET_REGISTRY.
# Keep this list in sync with template.yaml — tags must match the image
# lines referenced there.
IMAGES=(
    "n8n|n8nio/n8n:2.45.4"
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
