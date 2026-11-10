# OEC-73: Merge py-toolkit, Whitebeard and Wally into the ouestcharlie repo as a uv workspace

#status:draft

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
`~=3.0`). Woof is discussed in Open decisions.

---

## Changes

### 1. Target layout

```
ouestcharlie/
  pyproject.toml          # workspace root only: no [project], just workspace + shared settings
  uv.lock                 # single lock file
  .pre-commit-config.yaml
  .github/workflows/      # one CI, one publish
  packages/
    py-toolkit/   pyproject.toml, src/ouestcharlie_toolkit, tests/, README, LICENSE, LLD docs
    whitebeard/   pyproject.toml, src/whitebeard, tests/, profiling/, README, LICENSE, LLD
    wally/        pyproject.toml, src/wally, tests/, README, LICENSE, LLD
  HLD.md, docs/, project/, ...   # existing content unchanged
```

### 2. Freeze the source repos

- Merge or close open branches and PRs in the three repos.
- Tag the last release in each.
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
- Tags must be renamed: all three repos have a `v0.17.0` tag.

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
    "ruff==0.17.3",
    # plus the per-package extras today: mcp[cli], httpx, types-python-dateutil, python-dotenv
]

[tool.ruff]
target-version = "py314"
line-length = 100
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

- Remove the per-package `[dependency-groups] dev` (moved to root) and duplicated ruff settings.
- Pick one ruff rule set. py-toolkit also enables `TID` (no relative imports) and
  Wally/Whitebeard don't. Suggest applying `TID` to all.
- Update `[project.urls]` for Wally and Whitebeard (they point at their own repos today).
- Delete the per-package `uv.lock` files. Run `uv sync --all-packages`.

### 5. Pre-commit

**File:** `.pre-commit-config.yaml` (repo root; the three package copies are deleted)

- `ruff check` and `ruff format`: one hook each, whole repo.
- `mypy`: one hook per package, because strict mode checks each package against its own
  dependencies:

```yaml
- id: mypy-wally
  name: mypy (wally)
  entry: uv run --no-sync mypy packages/wally/src
  language: system
  files: ^packages/wally/src/.*\.py$
  pass_filenames: false
```

### 6. CI and publishing

**Files:** `.github/workflows/ci.yml`, `.github/workflows/publish.yml` (replace the three
sets of `_build.yml`, `build.yml`, `publish.yml`)

- `ci.yml`: one job per package, with path filters. Steps: `uv sync --locked`,
  `uv build --package <name>`, tests and mypy for that package. The second checkout of the
  py-toolkit repo goes away.
- `publish.yml`: a `vX.Y.Z` tag builds and publishes all three wheels, all at version
  `X.Y.Z` (shared version, see Decisions).
- **Required before the first release:** on PyPI, update the trusted publisher for
  `ouestcharlie-py-toolkit`, `ouestcharlie-whitebeard` and `ouestcharlie-wally` to the
  `ouestcharlie/ouestcharlie` repo, the new workflow file and the `pypi` environment.
  Publishing fails otherwise.

### 7. Tooling and docs

- `Makefile`: drop the three packages from `each_repo` and the `REPOS` bitmask. `bump`
  sets the one shared version in the three `packages/*/pyproject.toml` files and the `~=`
  pins between them (Woof keeps its own entry).
- Update `.vscode` settings and `.envrc` (one `.venv` at the root).
- Woof: change its `[tool.uv.sources]` paths to `../ouestcharlie/packages/...` (unless it joins
  the workspace, see Open decisions).
- `.github/dependabot.yml`: merge the Wally and Whitebeard configs into one at the root
  (`pip`/`uv` ecosystem on `/`, plus `github-actions`).

### 8. Retire the old repos

- Move open issues with `gh issue transfer <n> ouestcharlie/ouestcharlie`.
- Replace each README with a pointer to the new location.
- Archive the three repos on GitHub.

### 9. Tests

- Every package has a `tests/__init__.py`, so a single pytest run from the root fails with
  "import file mismatch". Either run pytest per package or set
  `addopts = "--import-mode=importlib"` in the root pytest config.
- Check `packages/py-toolkit/tests/test_architecture.py` for repo-relative path assumptions.

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
| `design/HLD.md` | Add a short "Code organization" section (no repo or packaging section exists today): one repo, uv workspace, three packages in `packages/`, one shared version, Woof and imageproc in their own repos, how Woof gets the agents (PyPI wheels). |
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

## Open decisions

1. **Woof.** It is also Python and depends on all three packages through `../` paths.
   Leaving it out keeps the multi-repo Makefile for it. Suggestion: add it as a fourth member
   in a follow-up issue.
2. **Ruff rules.** Apply py-toolkit's `TID` rule to all packages, or keep per-package rules.

---

## Verification

- `uv sync --all-packages --locked` succeeds from the root; only one `.venv` and one `uv.lock`.
- Tests and mypy pass for all three packages, locally and in CI.
- `uv build --package <name>` for each package gives a wheel with the same files as its
  0.17.0 wheel (only metadata such as URLs changes).
- `git log --follow packages/wally/src/wally/__main__.py` shows the history from before the move.
- Trial release to TestPyPI publishes all three wheels; installing them in a clean venv works.
- Woof still runs against the moved packages.
