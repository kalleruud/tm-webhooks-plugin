#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/.." && pwd)"
target="${1:-all}"
output_directory="${2:-$repository_root/dist}"
profile="${3:-production}"
if [[ "$target" == "diagnostics" ]]; then profile="diagnostics"; target="all"; fi
case "$profile" in
  production|diagnostics) ;;
  *) echo "Error: profile must be production or diagnostics" >&2; exit 1 ;;
esac

case "$target" in
  all|shared|unified) ;;
  *) echo "Error: target must be all, shared, or unified" >&2; exit 1 ;;
esac

if [[ ! -d "$repository_root/src" ]]; then
  echo "Error: Could not find $repository_root/src" >&2
  exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "Error: zip is required to package the plugin" >&2
  exit 1
fi

mkdir -p "$output_directory"
output_directory="$(cd -- "$output_directory" && pwd)"
manifest="$repository_root/info.toml"
if [[ ! -f "$manifest" ]]; then
  echo "Error: Could not find $manifest" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
cp -- "$manifest" "$stage/info.toml"
cp -R -- "$repository_root/src" "$stage/src"
artifact="$output_directory/tm-webhooks.op"
if [[ "$profile" == "diagnostics" ]]; then
  artifact="$output_directory/tm-webhooks-diagnostics.op"
  mkdir -p "$stage/diagnostics/generated"
  cp -- "$repository_root"/diagnostics/*.as "$stage/diagnostics/"
  cp -- "$repository_root"/diagnostics/generated/*.as "$stage/diagnostics/generated/"
  cp -- "$repository_root"/diagnostics/generated/*-api.json "$stage/diagnostics/generated/"
  # The define enables diagnostics-only entry points and the Update hook.
  sed -i 's/name = "TM Webhooks"/name = "TM Webhooks (Diagnostics)"/; /siteid = /d' "$stage/info.toml"
  printf '\ndefines = ["DIAGNOSTICS"]\n' >> "$stage/info.toml"
else
  # Strip even the guarded integration hook from production archive sources.
  sed '/^\/\/ DIAGNOSTICS_FRAME_PUMP_BEGIN$/,/^\/\/ DIAGNOSTICS_FRAME_PUMP_END$/d' "$stage/src/Main.as" > "$stage/src/Main.as.tmp"
  mv -- "$stage/src/Main.as.tmp" "$stage/src/Main.as"
fi
rm -f -- "$artifact"
(
  cd -- "$stage"
  zip -rq "$artifact" .
)
printf 'Created %s\n' "$artifact"
