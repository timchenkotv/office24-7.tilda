# Office24-7: handoff to wlab

Updated: 2026-11-10 (Europe/Moscow)

## Current objective

All further development and testing of `office24-7.ru` must happen on `wlab`, not on the operator Mac. The Mac copy is retained only as a temporary, untouched fallback and must not be used as the source of truth.

## Workspace

- Canonical workspace: `/srv/wlab/projects/office24-7.tilda`
- Convenience symlink: `/home/queen/Projects/office24-7.tilda`
- Development host: `wlab` (`queen@172.16.7.77`)
- Public site: `https://office24-7.ru/`
- GitHub repository: `git@github.com:timchenkotv/office24-7.tilda.git`
- GitHub/default branch: `main`
- Production remote: `ssh://root@tilda-sites/srv/git/office24-7.tilda.git`
- Production VM alias on wlab: `tilda-sites` (`172.16.7.40`)

## What this project is

This is a self-contained static archive of the former Tilda site. It is not a redesign. Pages, images, icons, CSS, JavaScript, products, news posts, feeds, and compatibility routes were downloaded and localized so the public site does not need Tilda to render.

The deployable document root is `www/`. Historical crawl attempts and reports are kept because the migration request required the full Mac project to be preserved.

## Migration and development history

1. The Tilda site was crawled repeatedly because early mirrors missed assets and some menu/page routes.
2. All primary sitemap pages and assets were localized; root-relative links replaced external Tilda resource URLs.
3. Missing auxiliary sitemaps were discovered and archived:
   - `sitemap-store.xml`
   - `sitemap-feeds.xml`
   - `sitemap-feed-507669872412.xml`
4. Product pages and three Tilda feed/news posts referenced by those maps were added.
5. Canonical URLs and Open Graph URLs were normalized to `https://office24-7.ru/`.
6. Tilda telemetry and the Tilda fallback loader were removed. The fallback loader was important: it could rewrite local resource failures back to Tilda CDN and hide an incomplete archive.
7. Forms were deliberately left visible but guarded against submission. A replacement backend was postponed.
8. The site was deployed to VM240 and made public through the edge proxy with Let's Encrypt TLS.
9. `www.office24-7.ru` redirects to the apex domain while preserving path/query.
10. The retired `site.office24-7.ru` vhost was blackholed with nginx status `444`; it must not redirect anywhere. Its DNS record was still present at Reg.ru during the 2026-07 handoff because no authenticated Reg.ru session was available.
11. Canonical no-trailing-slash routes were configured to return `200` directly, avoiding unnecessary redirects for sitemap URLs.

## Last verified state before wlab migration

Git commit before the handoff documentation: `22fc16eabdb99e86a21457dd5920ae1b150390ae`.

Mac, VM240 bare `main`, active production release, and GitHub `main` all pointed to that commit before this handoff commit was created.

Local audit results on 2026-11-10:

- 245 HTML files
- 209 sitemap pages
- 1,419 deployed files
- about 215-220 MB for the deployable `www/` tree
- 28,292 local references checked
- 0 missing sitemap pages
- 0 missing local references
- 0 remote Tilda resource attributes
- 0 Tilda fallback scripts
- 206 pages containing visible forms
- 0 forms without the static submission guard
- 0 blocking SEO issues
- 7 inherited pages without descriptions
- 6 duplicate-title groups
- 28 duplicate-description groups

The seven SEO description warnings and duplicate metadata are inherited content-quality warnings, not migration blockers. Do not invent legal/marketing copy merely to silence the audit without owner approval.

Production checks on 2026-11-10 returned `200` for the home page, `/about`, `/price_coworking_rent`, and a representative `/tpost/...` page. `robots.txt` referenced all three top-level sitemaps.

## Explicitly excluded aborted request

On 2026-08-31 an instruction about adding fixed-ruble daily penalty modes to `calc_NST` was mistakenly sent in the Office24 project. Investigation found that `calc_NST` belongs to the separate `elegso.tilda` project. The owner stopped that task immediately. No Office24 files, databases, or production services were changed for it. Never implement or carry that request into this repository.

## Important files

- `www/`: deployable static site
- `scripts/mirror-site-fresh.pl`: crawler and localizer
- `scripts/finalize-site.pl`: HTML finalization, compatibility routes, local feed/forms adjustments
- `scripts/audit-local.py`: local resource and form-guard audit
- `scripts/audit-seo.py`: sitemap, canonical, metadata, and indexing audit
- `scripts/audit-live.py`: live-site comparison utility
- `scripts/verify-wlab.sh`: mandatory local verification on wlab
- `scripts/deploy-wlab.sh`: audited production and GitHub deployment from wlab
- `ops/nginx/`: tracked VM and edge nginx configuration
- `ops/hooks/post-receive`: production deployment hook
- `reports/`: crawl maps and machine-readable audit evidence

## Git topology

The repository copied from Mac initially had local branch `codex/office24-export`, while both GitHub and VM240 used `main`. During the wlab migration the local branch is normalized to `main` and set to track `vm240/main`. VM240 upload and receive packs run as `queen` through the existing VM-specific wlab key. Direct GitHub SSH authentication is intentionally not required on wlab: production VM240 already owns a repository-specific GitHub deploy key.

Normal deployment flow:

1. Work and commit on local `main` at wlab.
2. Run `./scripts/verify-wlab.sh`.
3. Run `./scripts/deploy-wlab.sh`.
4. The script pushes local `main` to VM240's bare repository.
5. VM240's hook creates a new immutable release and switches `current`.
6. The script asks VM240 to mirror the same `main` to GitHub using VM240's deploy key.
7. The script verifies local, VM, GitHub, and public HTTP state.

## Production topology

- Production VM: `tilda-sites` / VM240 / `172.16.7.40`
- Bare repo: `/srv/git/office24-7.tilda.git`
- Releases: `/srv/www/office24-7.ru/releases`
- Current symlink: `/srv/www/office24-7.ru/current`
- VM nginx source in repo: `ops/nginx/vm-office24-7.ru.conf`
- Edge TLS/nginx sources in repo: `ops/nginx/edge-office24-7.ru-*.conf`

The post-receive hook retains the latest five releases. Do not rewrite or delete release history casually.

## Validation commands

```bash
cd /srv/wlab/projects/office24-7.tilda
./scripts/verify-wlab.sh
git status --short
git log -5 --oneline --decorate
ssh tilda-sites 'git --git-dir=/srv/git/office24-7.tilda.git rev-parse main'
curl -fsSI https://office24-7.ru/
```

## Known intentional behavior

- Forms do not submit.
- Local asset paths retain `_external/...tildacdn...` directory names because those are archived local filenames, not network dependencies.
- `www.office24-7.ru` redirects to `office24-7.ru`.
- `site.office24-7.ru` must remain retired and must not redirect.
- Compatibility routes preserve obsolete links that existed on the source site.

## First task for a new chat

Read `AGENTS.md` and this file, run `./scripts/verify-wlab.sh`, inspect `git status`, and compare local `HEAD` with VM240 and GitHub before changing anything. Report any mismatch instead of overwriting it.

