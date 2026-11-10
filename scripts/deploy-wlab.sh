#!/bin/sh
set -eu

if [ "$(hostname -s)" != "wlab" ]; then
    echo "Refusing to deploy: run this script on wlab." >&2
    exit 1
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

if [ "$(git branch --show-current)" != "main" ]; then
    echo "Refusing to deploy: the active branch must be main." >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Refusing to deploy: commit or remove worktree changes first." >&2
    git status --short >&2
    exit 1
fi

./scripts/verify-wlab.sh

head_sha=$(git rev-parse HEAD)
git push vm240 main:main

vm_sha=$(ssh tilda-sites 'git --git-dir=/srv/git/office24-7.tilda.git rev-parse main')
if [ "$vm_sha" != "$head_sha" ]; then
    echo "VM240 commit mismatch: local=$head_sha vm=$vm_sha" >&2
    exit 1
fi

ssh tilda-sites \
    'GIT_SSH_COMMAND="ssh -i /srv/git/github/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" git --git-dir=/srv/git/office24-7.tilda.git push git@github.com:timchenkotv/office24-7.tilda.git main:main'

github_sha=$(ssh tilda-sites \
    'GIT_SSH_COMMAND="ssh -i /srv/git/github/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" git --git-dir=/srv/git/office24-7.tilda.git ls-remote git@github.com:timchenkotv/office24-7.tilda.git refs/heads/main' \
    | awk '{print $1}')
if [ "$github_sha" != "$head_sha" ]; then
    echo "GitHub commit mismatch: local=$head_sha github=$github_sha" >&2
    exit 1
fi

current_release=$(ssh tilda-sites 'readlink -f /srv/www/office24-7.ru/current')
case "$current_release" in
    *"$(printf '%s' "$head_sha" | cut -c1-12)"*) ;;
    *)
        echo "Production release does not contain $head_sha: $current_release" >&2
        exit 1
        ;;
esac

for path in / /about /price_coworking_rent /robots.txt /sitemap.xml /sitemap-store.xml /sitemap-feeds.xml; do
    status=$(curl -sS -o /dev/null -w '%{http_code}' "https://office24-7.ru$path")
    if [ "$status" != "200" ]; then
        echo "Public check failed: $path returned $status" >&2
        exit 1
    fi
done

echo "Deployed and verified $head_sha"
