# OEC-73: Merge py-toolkit, Whitebeard and Wally into the ouestcharlie repo as a uv workspace

#status:open

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

py-toolkit, Whitebeard and Wally live in three separate git repos, but they are developed
and released as one unit:

- All three are at version `0.17.0` and are bumped together by `make bump`.
- Whitebeard and Wally already point at py-toolkit through
  `[tool.uv.sources] ouestcharlie-py-toolkit = { path = "../ouestcharlie-py-toolkit", editable = true }`.
- Most changes touch more than one repo, so the `ouestcharlie/Makefile` runs `git` and `gh`
  commands across repos with a `REPOS` bitmask (`branch`, `commit`, `push`, `pr`, `tag`, …).
- Each repo has its own `uv.lock`, `.venv`, pre-commit config and CI. The CI for Whitebeard
  and Wally checks out the py-toolkit repo as a second checkout to build against it.

Goal: move the three packages into the `ouestcharlie` repo, keeping git history, with
**one git repo and one uv workspace (one `uv.lock`)**. Each package **stays independent**:
its own `pyproject.toml`, its own PyPI name and its own wheel.

Out of scope: `ouestcharlie-imageproc` stays separate (native Rust build, own version line
`~=3.0`). Woof also stays separate, see Decisions.

---

## Changes

### 1. Target layout

```
ouestcharlie/
  pyproject.toml          # workspace root only: no [project], just workspace + shared settings
  uv.lock                 # single lock file
  .pre-commit-config.yaml
  .gitignore              # extended with .venv, .mypy_cache, .pytest_cache, .ruff_cache, dist
  .github/workflows/      # new: the ouestcharlie repo has no .github/ today
  packages/
    py-toolkit/   pyproject.toml, src/ouestcharlie_toolkit, tests/, README, LICENSE, LLD docs
    whitebeard/   pyproject.toml, src/whitebeard, tests/, profiling/, README, LICENSE, LLD
    wally/        pyproject.toml, src/wally, tests/, README, LICENSE, LLD
  design/, project/, assets/, ...   # existing content unchanged
```

### 2. Freeze the source repos

- Merge or close open PRs in the three repos, and delete merged branches (see Decisions,
  old branches).
- The last release is already tagged `v0.17.0` in each repo: check that nothing was merged
  to `master` after it.
- List open issues so they can be moved in step 7.

### 3. Import the code and keep its history

For each repo, on a fresh clone:

```bash
git filter-repo --to-subdirectory-filter packages/wally --tag-rename '':'wally-'
```

Then in `ouestcharlie`:

```bash
git remote add wally ../ouestcharlie-wally-rewritten
git fetch wally --tags
git merge --allow-unrelated-histories wally/master
```

- `git log` and `git blame` keep working on the moved files.
- Tags must be renamed: all three repos have a `v0.17.0` tag. The renamed tags
  (`wally-v0.17.0`, …) don't match the publish trigger `v[0-9]*`, so pushing them does not
  republish anything. The ouestcharlie repo has no tags today, so the first `vX.Y.Z` tag is
  free.

### 4. Workspace configuration

**File:** `pyproject.toml` (new, repo root)

```toml
[tool.uv.workspace]
members = ["packages/*"]

[dependency-groups]
dev = [
    "mypy>=2.3",
    "pre-commit>=4.5.1",
    "pytest>=9.0.2",
    "pytest-asyncio>=1.3.0",
    "ruff~=0.17.0",  # patch releases allowed; a minor bump (0.18) is deliberate
    # plus the per-package extras today: mcp[cli], httpx, types-python-dateutil, python-dotenv
]

[tool.ruff]
target-version = "py314"
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "SIM", "TID"]

[tool.ruff.lint.flake8-tidy-imports]
ban-relative-imports = "all"
```

**Files:** `packages/*/pyproject.toml`

```toml
# Before
[tool.uv.sources]
ouestcharlie-py-toolkit = { path = "../ouestcharlie-py-toolkit", editable = true }

# After
[tool.uv.sources]
ouestcharlie-py-toolkit = { workspace = true }
```

- Remove the per-package `[dependency-groups] dev` (moved to root).
- **Ruff settings are not merged across files.** Ruff uses the nearest `pyproject.toml`
  that has a `[tool.ruff]` table and ignores the others. Whitebeard and Wally keep their
  `per-file-ignores` (E402 in `__main__.py`), so their `[tool.ruff]` must extend the root:

```toml
[tool.ruff]
extend = "../../pyproject.toml"

[tool.ruff.lint.per-file-ignores]
"src/wally/__main__.py" = ["E402"]  # paths are relative to the package folder
```

  The shared settings (`target-version`, `line-length`, `lint.select` including `TID`, and
  `flake8-tidy-imports`) move to the root. py-toolkit has no per-package ruff settings left,
  so its `[tool.ruff]` table is removed.
- **mypy settings stay in each package.** `[tool.mypy]` and its overrides (py-toolkit's
  `ignore_missing_imports` for pyexiv2, pillow_heif and pyarrow) stay in
  `packages/*/pyproject.toml`. mypy reads the config from the folder it is run in, not
  from the checked folder, so every mypy call made from the root passes
  `--config-file packages/<name>/pyproject.toml` (see sections 5 and 6).
- Update `[project.urls]` for Wally and Whitebeard (they point at their own repos today).
- Delete the per-package `uv.lock` files. Run `uv sync --all-packages`.

### 5. Pre-commit

**File:** `.pre-commit-config.yaml` (repo root; the three package copies are deleted)

- `ruff check` and `ruff format`: one hook each, whole repo.
- `mypy`: one hook per package, each with its package's config (see section 4):

```yaml
- id: mypy-wally
  name: mypy (wally)
  entry: uv run --no-sync mypy --config-file packages/wally/pyproject.toml packages/wally/src
  language: system
  files: ^packages/wally/src/.*\.py$
  pass_filenames: false
```

### 6. CI and publishing

**Files:** `.github/workflows/ci.yml`, `.github/workflows/publish.yml` (replace the three
sets of `_build.yml`, `build.yml`, `publish.yml`)

- `ci.yml`: one job per package, with path filters (a py-toolkit change also runs the
  Whitebeard and Wally jobs). The second checkout of the py-toolkit repo goes away.
- **Each job installs only its own package.** The local root `.venv` holds all three packages
  and their dependencies, so a package that imports something it does not declare still
  passes locally. Today's CI catches this because it tests the installed wheel. Each job
  keeps that check:
  1. `uv sync --locked --package <name>`: only that package, its dependencies and the
     dev group.
  2. `uv build --package <name>`.
  3. Install the built wheel into a clean venv with the test tools, and run the package's
     tests and mypy (`--config-file packages/<name>/pyproject.toml`) against it.
- **Check first:** confirm that `uv sync --package <name>` installs the dev group defined in
  the root `[dependency-groups]`. If it doesn't, keep a small `dev` group (pytest,
  pytest-asyncio, mypy and the package's stubs) in each package and keep only
  `pre-commit` and `ruff` at the root.
- `publish.yml`: a `vX.Y.Z` tag builds and publishes all three wheels, all at version
  `X.Y.Z` (shared version, see Decisions). The upload uses `skip-existing: true`, so
  rerunning the workflow after a failed upload completes the release (see Decisions).
- **Required before the first release:** on PyPI, set up a trusted publisher for
  `ouestcharlie-py-toolkit`, `ouestcharlie-whitebeard` and `ouestcharlie-wally` with the
  `ouestcharlie/ouestcharlie` repo, the new workflow file and the `pypi` environment.
  Publishing fails otherwise. It is added next to the old repos' publishers, which stay
  until the end of the transition period (see Decisions).

### 7. Tooling and docs

- `Makefile`: drop the three packages from `each_repo` and the `REPOS` bitmask. `bump`
  sets the one shared version in the three `packages/*/pyproject.toml` files and the `~=`
  pins between them (Woof keeps its own entry). The workspace packages' versions are
  recorded in `uv.lock`, so `bump` then runs `uv lock` (and `uv sync --all-packages`);
  otherwise CI's `uv sync --locked` fails.
- Update `.vscode` settings and `.envrc` (one `.venv` at the root).
- Woof: updated in its own session, after the import and before the old repos are
  archived (see Decisions, Woof switch). Changes are listed in section 10, Woof repo.
- `.github/dependabot.yml`: merge the Wally and Whitebeard configs into one at the root:
  the `uv` ecosystem on `/` (Whitebeard's `pip` entry is dropped), plus `github-actions`.
  Keep the ignore on `ouestcharlie-*` packages and ignore ruff patch updates (see
  Decisions, ruff pin):

```yaml
ignore:
  - dependency-name: "ouestcharlie-*"
  - dependency-name: "ruff"
    update-types: ["version-update:semver-patch"]
```

### 8. Retire the old repos

At the move:

- Move open issues with `gh issue transfer <n> ouestcharlie/ouestcharlie`.
- Replace each README with a pointer to the new location, saying the repo is kept only
  for emergency fixes until it is archived.
- Keep the repos live, with their CI, publish workflow and PyPI trusted publisher (see
  Decisions, transition period).

At the end of the transition period:

- Remove the old repos' trusted publishers on PyPI.
- Check that the Woof switch is merged (see Decisions), then archive the three repos on
  GitHub.

### 9. Tests

- **Run pytest once per package, from the package folder:**
  `uv run --directory packages/<name> pytest`. A single pytest run from the root is not
  supported. Every package has a `tests/` package (with `__init__.py`), and py-toolkit's
  tests import `from tests.format_samples`. In one session the three `tests` packages
  have the same name and collide, even with `--import-mode=importlib`. Running per package
  also picks up each package's own `[tool.pytest.ini_options]`.
- `make test` and `.vscode` test settings follow the same per-package rule.
- No path changes are needed in the tests: fixtures (`sample-images/`) and
  `test_architecture.py` find files relative to `__file__`.

### 10. Documentation

Paths below are after the move (`packages/<name>/...`, design docs in `design/`).
Links from one repo to another use full GitHub URLs, not relative paths, so they work on
GitHub and on PyPI pages. After the merge:
- URLs to the design docs (`github.com/ouestcharlie/ouestcharlie/blob/master/design/...`)
  stay valid. No change needed.
- URLs to the three old repos must be replaced:
  - `github.com/ouestcharlie/ouestcharlie-<name>` (repo root) →
    `github.com/ouestcharlie/ouestcharlie/tree/master/packages/<name>`
  - `github.com/ouestcharlie/ouestcharlie-<name>/blob/master/<file>` →
    `github.com/ouestcharlie/ouestcharlie/blob/master/packages/<name>/<file>`
  - Here `<name>` is `py-toolkit`, `whitebeard` or `wally`.
- Inside the monorepo, links within one package stay relative.

URLs to the old repos found today (all must change):

| File | Lines |
|---|---|
| `README.md` (root) | 26–28, 54–55, 77 |
| `packages/whitebeard/README.md` | 76–78 |
| `packages/whitebeard/whitebeard_LLD.md` | 128 |
| `packages/whitebeard/pyproject.toml` | 27–28 (`[project.urls]`) |
| `packages/wally/README.md` | 67–69 |
| `packages/wally/pyproject.toml` | 30–31 (`[project.urls]`) |
| Woof `README_DEV.md` | 156–158 |

Find any new ones with:

```bash
grep -rnE "github.com/ouestcharlie/ouestcharlie-(py-toolkit|wally|whitebeard)" \
  --include="*.md" --include="*.toml" --include="*.json" --include="*.yml" .
```

**ouestcharlie repo, design and project docs**

| File | Change |
|---|---|
| `design/HLD.md` | Add a short "Code organization" section (no repo or packaging section exists today): one repo, uv workspace, three packages in `packages/`, one shared version, Woof and imageproc in their own repos (and why: see Decisions), how Woof gets the agents (PyPI wheels; `../ouestcharlie/packages/...` path sources for development). |
| `design/HLD_rationale.md` | Add the rationale for one repo + one workspace + independent packages (lockstep releases, cross-package changes in one PR, one lock file) and the alternatives (separate repos, one merged package). |
| `design/agent_LLD_rationale.md` | Check only: technology choices, no repo paths expected. |
| `README.md` (root) | "Repositories" table (lines 20–28): replace the toolkit, Whitebeard and Wally rows with one row for this repo and list the three packages. "Python toolkit" links (lines 54–55): link `packages/py-toolkit/` and its README (relative links, same repo). Low-level design table (line 77): link `packages/py-toolkit/py_toolkit_LLD.md`, add rows for `whitebeard_LLD.md` and `wally_LLD.md`. Contributing (line 119): agent and toolkit changes now come here. Add a dev setup section (`uv sync --all-packages`, tests, pre-commit). |
| `.claude/CLAUDE.md` (root) | Remove the stale `agent/py_toolkit/` paths (lines 30–34). Point to `packages/*`. Update the lint rule (line 35): one pinned ruff in the root `.venv`. Add the per-package test commands. |
| `project/Version1_vision.md` | No change: links only to the Woof repo. |

**Moved packages**

| File | Change |
|---|---|
| `packages/py-toolkit/README.md` | Install and dev instructions (`uv sync` at the root). Design-doc URL (HLD, line 162) needs no change. |
| `packages/py-toolkit/py_toolkit_LLD.md` | No link change: it links only to design docs and imageproc by URL. |
| `packages/py-toolkit/py_toolkit_LLD_rationale.md` | Check links. |
| `packages/py-toolkit/.claude/CLAUDE.md` | Title, test command run from the package folder with the root `.venv`. |
| `packages/whitebeard/README.md` | "Requires the sibling `ouestcharlie-py-toolkit` repo" (line 36) → workspace setup. Repositories table (lines 72–78; old repo URLs on lines 76–78). `mcp dev` instructions (line 61). |
| `packages/whitebeard/whitebeard_LLD.md` | `py_toolkit_LLD.md` URL (line 128) → `packages/py-toolkit/` URL. HLD and agent rationale URLs (lines 127, 129) need no change. |
| `packages/whitebeard/.claude/CLAUDE.md` | Title, test command (`.venv/bin/pytest` path, line 5). |
| `packages/wally/README.md` | "Repository Structure" (line 13), "Requires the sibling `ouestcharlie-py-toolkit` repo" (line 31), Repositories table (lines 64–72; old repo URLs on lines 67–69). |
| `packages/wally/wally_LLD.md` | "Repository Structure" section (line 12): paths relative to the package. |
| `packages/wally/.claude/CLAUDE.md` | Title, test command, LLD link (line 42). |
| `packages/*/pyproject.toml` | `[project.urls]` Homepage and Issues → `ouestcharlie/ouestcharlie`. |

**Woof repo**

| File | Change |
|---|---|
| `README_DEV.md` | "Requires sibling repositories" (lines 50–55) → `../ouestcharlie/packages/...`. Repositories table (lines 152–158; old repo URLs on lines 156–158). |
| `pyproject.toml` | `[tool.uv.sources]` paths (lines 41–44). |
| `.github/workflows/_build.yml` | Checkout of the toolkit, Whitebeard and Wally repos → one checkout of `ouestcharlie/ouestcharlie`, paths under `packages/`. |

**Website (`ouestcharlie.github.io`)**

- No change needed: it links only to the Woof repo. Optionally mention the move in a
  dev-focused post.

**Archived repos**

- The README of each archived repo gets a pointer to `ouestcharlie/ouestcharlie/packages/<name>`.

---

## Decisions

1. **One shared version.** All three packages always have the same version. One `vX.Y.Z`
   tag publishes all three, even if a package has no changes.
2. **`packages/` folder.** The three packages go under `packages/`, apart from the docs.
3. **Woof stays an independent repo**, outside the workspace, with its own `uv.lock`,
   CI and release. Reasons:
   - Woof has a separate build and release: a Node gallery build (`gallery/`), an MCPB
     bundle (`manifest.json`, `pyproject_packaging.toml`) and a Claude plugin
     (`.claude-plugin/`, `plugins/`).
   - Woof requires `==3.14.*` while the agents allow `>=3.14`. A workspace has one
     Python range for all members, so adding Woof would narrow it for all of them.
   - Woof uses the agents the way end users do: as PyPI wheels pinned with `~=`.
     For local development it uses editable path sources to
     `../ouestcharlie/packages/...`.

   The `ouestcharlie/Makefile` keeps a two-repo selector (this repo + Woof) for
   `branch`/`commit`/`push`/`pr`/`tag`. `bump` updates the agents' `~=` pins in Woof's
   `pyproject.toml`, `pyproject_packaging.toml` and `manifest.json`.
4. **Ruff rules: one rule set for all packages**, including py-toolkit's `TID` (no relative
   imports). Whitebeard and Wally have only two relative imports between them, fixed in
   this issue.
5. **Transition period: old repos and PyPI publishers kept for a while.** The new
   trusted publisher for `ouestcharlie/ouestcharlie` is added next to the old ones, not in
   their place. The three old GitHub repos stay live (not archived) with their publishers
   and workflows, so an emergency fix can still be released from them if the monorepo
   release path has a problem. The transition ends once a few releases have gone out from
   the monorepo with no issue. Then the old publishers are removed and the repos archived
   (step 8). During the transition, all new work goes to the monorepo only. The old
   repos receive nothing except an emergency fix, which is ported to the monorepo
   right away.
6. **A failed release can be completed by rerunning it.** One tag publishes three wheels,
   so an upload can fail halfway (for example a new py-toolkit on PyPI but an old Wally).
   The publish step uses `skip-existing: true`: rerunning the workflow skips the wheels
   already on PyPI and uploads the missing ones. No new tag or version bump is needed.
   Use "Re-run failed jobs" in GitHub Actions: it reuses the wheels built by the first
   run, so the completed release contains exactly the same files.

7. **Old branches: only `master` is imported.** The branch inventory of the three repos
   shows that every branch is merged into `master`, except Whitebeard's Dependabot PR #40
   (ruff 0.17.3 → 0.17.5). It is closed: ruff is updated once, in the root dev group,
   after the move.

   Merged branches are deleted locally and on GitHub before the freeze. No branch other
   than `master` is imported.

8. **Ruff pin: `~=0.17.0`, no Dependabot PRs for patch releases.** With `==` every ruff
   release produced a PR in each repo. A looser range alone does not stop them: `uv.lock`
   records the exact version and Dependabot proposes a lock bump for each release. So:
   - The root dev group allows any 0.17.x (`ruff~=0.17.0`). Minor releases (0.18) can
     change formatting and promote rules, so moving to one stays a deliberate change:
     update the range and reformat in the same PR.
   - Dependabot ignores ruff patch updates. They come in with the regular lock refresh
     (`uv lock --upgrade`). CI and pre-commit keep using the locked version, so every
     machine runs the same ruff.
9. **Woof is switched in its own session, before the old repos are archived.** Woof's
   `_build.yml` checks out `master` of the three old repos, and its `[tool.uv.sources]`
   point at `../ouestcharlie-*`. The switch is done in a dedicated session (its own
   branch and PR in the Woof repo), once the import is merged:
   - `[tool.uv.sources]` → `../ouestcharlie/packages/...`, `uv lock`.
   - `_build.yml`: one checkout of `ouestcharlie/ouestcharlie`, paths under `packages/`.
   - `README_DEV.md`: sibling repos and Repositories table.
   - Woof tests and CI pass against the moved packages.

   Until then, Woof CI keeps building the old repos' `master`, frozen at the last release.
   This is acceptable because the old repos receive nothing during the transition except
   emergency fixes (Decision 5), which are also ported to the monorepo. The old repos are
   archived (step 8) only after the Woof switch is merged.

---

## Verification

- `uv sync --all-packages --locked` succeeds from the root; only one `.venv` and one `uv.lock`.
- Tests and mypy pass for all three packages, locally and in CI.
- `uv build --package <name>` for each package gives a wheel with the same files as its
  0.17.0 wheel (only metadata such as URLs changes).
- `git log --follow packages/wally/src/wally/__main__.py` shows the history from before the move.
- Trial release to TestPyPI publishes all three wheels; installing them in a clean venv works.
- Woof still runs against the moved packages.
