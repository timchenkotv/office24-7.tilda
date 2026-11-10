#!/bin/sh
set -eu

if [ "$(hostname -s)" != "wlab" ]; then
    echo "Refusing to run: office24-7 development is authoritative on wlab." >&2
    exit 1
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

python3 scripts/audit-local.py
python3 scripts/audit-seo.py
git diff --check

test -f www/index.html
test -f www/robots.txt
test -f www/sitemap.xml
test -f www/sitemap-store.xml
test -f www/sitemap-feeds.xml

echo "wlab verification passed for $(git rev-parse --short HEAD)"

