# WLab CI

GitHub Actions for `timchenkotv/office24-7.tilda` run on the repository-scoped
VM780 `wlab-ci` runner with label `office247-ci`. Because the repository is
public, the workflow runs only for pushes to `main` or trusted `codex/**`
branches and for an explicit manual dispatch. Fork pull requests cannot use
the self-hosted runner.

The job executes the existing local archive and SEO audits and required-file
checks. It has no Docker, sudo, SSH login, production credentials or RFC1918
network access and never runs `scripts/deploy-wlab.sh`.
