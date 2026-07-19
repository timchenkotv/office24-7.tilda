# office24-7.ru static export

Fresh static export of `https://office24-7.ru/` for independent hosting at
`https://site.office24-7.ru/`.

## Contents

- `www/`: deployable site root with all downloaded pages and static assets.
- `scripts/mirror-site-fresh.pl`: fresh crawler and URL localizer.
- `scripts/finalize-site.pl`: compatibility routes, static forms, and local news feed setup.
- `scripts/audit-local.py`: local page/resource integrity audit.
- `scripts/audit-live.py`: independent comparison against all live sitemap pages.
- `reports/`: sitemap, URL map, compatibility routes, and audit evidence.
- `ops/`: VM and edge nginx configurations plus the Git deployment hook.

## Verified export

- 180 of 180 sitemap pages fetched and present locally.
- 1,140 live static resource URLs independently checked.
- 0 missing local assets.
- 0 page structure mismatches.
- 27,597 local references checked.
- 0 missing local references.
- 0 remote Tilda resource attributes in HTML/CSS.
- 31 compatibility routes cover stale links that return 404 on the source site.
- 3 Tilda feed posts and their images are archived behind local `/api/getfeed/`.
- Forms remain visible but submission is intentionally blocked.

See `reports/live-audit.json` and `reports/local-audit.json` for machine-readable
results.

## Deployment target

- Proxmox VM: `240` (`tilda-sites`)
- VM IP: `172.16.8.40`
- Site path: `/srv/www/site.office24-7.ru`
- Bare Git repository: `/srv/git/office24-7.tilda.git`
- Public URL: `https://site.office24-7.ru/`
