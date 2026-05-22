# Third-party Sources

This directory holds upstream projects that TeleDrive depends on but does not own.

## Teldrive

- Path: `third_party/teldrive`
- Upstream: `https://github.com/tgdrive/teldrive.git`
- Current local snapshot: `d400a2df41db17ba220cd06973fc8df5c6f2854c`
- Current upstream version file: `1.8.3`

Recommended steady-state management model: Git submodule.

The parent `D:\code\TeleDrive` directory is allowed to start as a non-git workspace. In that bootstrap state, `third_party/teldrive` can remain a normal upstream clone. Once the parent project is initialized as a git repository, register the same path as a submodule so the parent repo pins an exact Teldrive commit without copying Teldrive history into the parent history.

## Rules

- Do not edit upstream Teldrive files on an untracked, anonymous state.
- Keep local Teldrive changes on a named branch inside `third_party/teldrive`, then export them as patches or upstream PRs.
- Update by fetching upstream and checking out a specific commit, tag, or `origin/main`.
- Do not use `git reset --hard`, `git clean`, or parent-history rewrites for routine upstream management.
- Build custom images from the checked-out source; do not modify runtime compose files as part of the third-party update step.

## Scripts

Run scripts from the project root with Windows PowerShell:

```powershell
.\scripts\teldrive-init.ps1
.\scripts\teldrive-update.ps1 -Ref origin/main
.\scripts\teldrive-patch.ps1 -Mode Status
.\scripts\teldrive-build-image.ps1 -ImageTag local/teldrive:dev
```

Full workflow details live in `docs/teldrive-subproject.md`.
