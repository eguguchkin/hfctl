# shellcheck shell=bash
pull_model() {  # pull_model <tag> — идемпотентно (sha256-верификация внутри hipfire pull)
  local tag="$1"
  log "тяну модель $tag"
  podman run --rm -v "$MODELS_DIR:/home/hipfire/.hipfire/models" "$IMAGE" \
    hipfire pull "$tag" --yes 2>&1 | tail -2
}

pull_profile_models() {  # все модели + draft профиля
  local prof="$1" tag draft
  podman image exists "$IMAGE" || podman pull "$IMAGE" >/dev/null || podman pull "$IMAGE"
  for tag in $(profile_field "$prof" 2); do
    pull_model "$tag"
  done
  draft=$(profile_field "$prof" 3)
  [ "$draft" != "-" ] && [ -n "$draft" ] && pull_model "$draft" || true
}
