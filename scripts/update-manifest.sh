#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: update-manifest.sh \
  --service-name <name> \
  --environment <dev|prod> \
  --registry <host[:port]> \
  --image-tag <tag> \
  [--repository-root <path>] \
  [--branch <name>] \
  [--push-attempts <1-5>]
EOF
}

service_name=''
environment_name=''
registry=''
image_tag=''
repository_root="$PWD"
branch='main'
push_attempts=3

while (($# > 0)); do
  case "$1" in
    --service-name)
      service_name="${2:-}"
      shift 2
      ;;
    --environment)
      environment_name="${2:-}"
      shift 2
      ;;
    --registry)
      registry="${2:-}"
      shift 2
      ;;
    --image-tag)
      image_tag="${2:-}"
      shift 2
      ;;
    --repository-root)
      repository_root="${2:-}"
      shift 2
      ;;
    --branch)
      branch="${2:-}"
      shift 2
      ;;
    --push-attempts)
      push_attempts="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$service_name" =~ ^[a-z0-9-]+$ ]]; then
  echo 'service-name must contain only lowercase letters, numbers, and hyphens' >&2
  exit 2
fi
if [[ "$environment_name" != 'dev' && "$environment_name" != 'prod' ]]; then
  echo 'environment must be dev or prod' >&2
  exit 2
fi
if [[ ! "$registry" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  echo 'registry is not a valid registry hostname' >&2
  exit 2
fi
if [[ ! "$image_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo 'image-tag contains unsupported characters' >&2
  exit 2
fi
if [[ ! "$branch" =~ ^[A-Za-z0-9._/-]+$ || "$branch" == /* || "$branch" == *'..'* ]]; then
  echo 'branch contains unsupported characters' >&2
  exit 2
fi
if [[ ! "$push_attempts" =~ ^[1-5]$ ]]; then
  echo 'push-attempts must be between 1 and 5' >&2
  exit 2
fi
if [[ ! -d "$repository_root" ]]; then
  echo "Repository root does not exist: $repository_root" >&2
  exit 1
fi

repository_root="$(cd "$repository_root" && pwd -P)"
relative_manifest_path="deploy/helm/$service_name/values-$environment_name.yaml"
manifest_path="$repository_root/$relative_manifest_path"
update_branch="pipeline/$service_name-$environment_name-$image_tag"
start_marker='# BEGIN AZURE PIPELINES MANAGED IMAGE'
end_marker='# END AZURE PIPELINES MANAGED IMAGE'

if [[ ! -f "$manifest_path" ]]; then
  echo "Manifest does not exist: $manifest_path" >&2
  exit 1
fi
if [[ "$(git -C "$repository_root" rev-parse --is-inside-work-tree)" != 'true' ]]; then
  echo "Repository root is not a Git working tree: $repository_root" >&2
  exit 1
fi

echo "##[section]Refresh origin/$branch"
git -C "$repository_root" fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"
git -C "$repository_root" checkout -B "$update_branch" "refs/remotes/origin/$branch"
git -C "$repository_root" config user.name 'azure-pipelines[bot]'
git -C "$repository_root" config user.email 'azure-pipelines@users.noreply.github.com'

managed_block="$start_marker
image:
  repository: $registry/$service_name
  tag: \"$image_tag\"
appVersion: \"$image_tag\"
$end_marker"

start_count="$(grep -Fxc "$start_marker" "$manifest_path" || true)"
end_count="$(grep -Fxc "$end_marker" "$manifest_path" || true)"
temporary_manifest="$(mktemp "$manifest_path.XXXXXX")"
cleanup() {
  rm -f -- "$temporary_manifest"
}
trap cleanup EXIT

if [[ "$start_count" == '1' && "$end_count" == '1' ]]; then
  awk \
    -v start_marker="$start_marker" \
    -v end_marker="$end_marker" \
    -v managed_block="$managed_block" '
      $0 == start_marker {
        print managed_block
        inside_managed_block = 1
        replaced = 1
        next
      }
      inside_managed_block && $0 == end_marker {
        inside_managed_block = 0
        next
      }
      !inside_managed_block { print }
      END {
        if (inside_managed_block || !replaced) {
          exit 42
        }
      }
    ' "$manifest_path" > "$temporary_manifest"
elif [[ "$start_count" == '0' && "$end_count" == '0' ]]; then
  if grep -Eq '^image:[[:space:]]*$|^appVersion:[[:space:]]*' "$manifest_path"; then
    echo "Manifest already contains unmanaged image or appVersion keys: $relative_manifest_path" >&2
    exit 1
  fi

  awk -v managed_block="$managed_block" '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) {
        last--
      }
      for (line = 1; line <= last; line++) {
        print lines[line]
      }
      if (last > 0) {
        print ""
      }
      print managed_block
    }
  ' "$manifest_path" > "$temporary_manifest"
else
  echo "Manifest contains an invalid managed image block: $relative_manifest_path" >&2
  exit 1
fi

mv -- "$temporary_manifest" "$manifest_path"
git -C "$repository_root" add -- "$relative_manifest_path"

if git -C "$repository_root" diff --cached --quiet; then
  manifest_commit="$(git -C "$repository_root" rev-parse HEAD)"
  echo "Manifest already points to $registry/$service_name:$image_tag"
  echo '##vso[task.setvariable variable=manifestChanged;isOutput=true]false'
  echo "##vso[task.setvariable variable=manifestCommit;isOutput=true]$manifest_commit"
  exit 0
fi

commit_message="chore(manifest): update $service_name $environment_name to $image_tag [skip ci]"
git -C "$repository_root" commit -m "$commit_message"

for ((attempt = 1; attempt <= push_attempts; attempt++)); do
  echo "##[section]Push manifest update (attempt $attempt/$push_attempts)"
  if git -C "$repository_root" push origin "HEAD:refs/heads/$branch"; then
    manifest_commit="$(git -C "$repository_root" rev-parse HEAD)"
    echo "Updated $relative_manifest_path to $registry/$service_name:$image_tag"
    echo "Manifest commit: $manifest_commit"
    echo '##vso[task.setvariable variable=manifestChanged;isOutput=true]true'
    echo "##vso[task.setvariable variable=manifestCommit;isOutput=true]$manifest_commit"
    exit 0
  fi

  if ((attempt == push_attempts)); then
    echo "Unable to push manifest after $push_attempts attempts" >&2
    exit 1
  fi

  echo "Manifest push raced with another update; rebasing attempt $attempt"
  git -C "$repository_root" fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  if ! git -C "$repository_root" rebase "refs/remotes/origin/$branch"; then
    git -C "$repository_root" rebase --abort || true
    echo 'Manifest update conflicts with a concurrent change' >&2
    exit 1
  fi
done
