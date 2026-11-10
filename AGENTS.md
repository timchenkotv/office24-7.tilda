# Office24-7 Development Rules

## Authoritative workspace

- Develop and test only on `wlab`.
- Canonical path: `/srv/wlab/projects/office24-7.tilda`.
- User-facing path: `/home/queen/Projects/office24-7.tilda` (symlink to the canonical path).
- Do not use the former Mac workspace for development, testing, deployment, or as a source of truth.
- Do not delete the former Mac copy. The owner will remove it separately after accepting the migration.

## Repository and production

- GitHub: `timchenkotv/office24-7.tilda`, branch `main`.
- Production Git remote: `vm240`, URL `ssh://root@tilda-sites/srv/git/office24-7.tilda.git`.
- Production VM: SSH alias `tilda-sites` on `wlab` (`172.16.7.40`).
- Public site: `https://office24-7.ru/`.
- Production document root: `/srv/www/office24-7.ru/current/www`.
- Pushing `main` to `vm240` invokes the production `post-receive` deployment hook.
- The production VM mirrors `main` to GitHub with its repository-specific deploy key. Do not copy that private key to `wlab`.

## Safety

- Read `docs/WLAB_HANDOFF.md` before making changes.
- Never modify or delete unrelated files or production releases.
- Never commit credentials, private keys, cookies, backups, or generated database/archive payloads.
- Before deployment, require a clean worktree and run `scripts/verify-wlab.sh`.
- Deploy only through `scripts/deploy-wlab.sh`; it verifies the local tree, VM release, GitHub mirror, and public URLs.
- Forms in this static archive intentionally remain visible but do not submit. Do not silently enable them.
- `site.office24-7.ru` is retired and must not redirect to the production site.

## Required checks

Run from the project root on `wlab`:

```bash
./scripts/verify-wlab.sh
```

For local viewing:

```bash
python3 -m http.server 9035 --directory www
```

Then open `http://127.0.0.1:9035/` through an SSH tunnel or a browser available on `wlab`.

