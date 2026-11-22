# Repo selector: 3-bit binary string (MSB → LSB)
#   100 = ouestcharlie (this repo: docs + the py-toolkit, whitebeard and wally packages)
#   010 = woof
#   001 = imageproc
# Examples:
#   make branch REPOS=110 NAME=my-feature
#   make commit REPOS=010 MSG="fix: something"
# Default: this repo and Woof (imageproc changes less often, select it explicitly).
REPOS ?= 110

# Pull request base branch (default: each repo's default branch, e.g. master or main)
PR_BASE ?=

WOOF := ../ouestcharlie-woof
IMAGEPROC := ../ouestcharlie-imageproc

# Workspace packages (one shared version, see `bump`)
PACKAGES := py-toolkit whitebeard wally

# Iterate over repos matching the REPOS bitmask and run a shell command in each.
define each_repo
	@i=1; for repo in . $(WOOF) $(IMAGEPROC); \
	do \
		bit=$$(echo "$(REPOS)" | cut -c$$i); \
		if [ "$$bit" = "1" ]; then \
			echo "\n>>> $$repo"; \
			(cd $$repo && $(1)) || exit 1; \
		fi; \
		i=$$((i+1)); \
	done
endef

# True if bit N (1-based) of REPOS is set.
bit_set = [ "$$(echo "$(REPOS)" | cut -c$(1))" = "1" ]

# True in this repo (the uv workspace), false in Woof and imageproc.
IS_WORKSPACE := [ -d packages ]

# The current repo's default branch (master here and in Woof, main in imageproc).
DEFAULT_BRANCH := b=$$(git symbolic-ref --short -q refs/remotes/origin/HEAD); b=$${b\#origin/}; \
	if [ -z "$$b" ]; then git rev-parse -q --verify origin/main >/dev/null && b=main || b=master; fi

.PHONY: branch checkout co-master pull commit push tag sync sync-upgrade test pr bump

## Create a new branch: make branch REPOS=110 NAME=<branch-name>
branch:
	$(call each_repo,git checkout -b $(NAME))

## Checkout an existing branch: make checkout REPOS=110 NAME=<branch-name>
checkout:
	$(call each_repo,git checkout $(NAME))

## Checkout the default branch (master or main) and pull: make co-master REPOS=110
co-master:
	$(call each_repo,$(DEFAULT_BRANCH); git checkout $$b && git pull)

## Checkout a branch and pull: make pull REPOS=110 NAME=<branch-name>
pull:
	$(call each_repo,git checkout $(NAME) && git pull)

## Commit staged changes: make commit REPOS=110 MSG="<message>" [ALL=1 to stage all changes first]
commit:
	$(call each_repo,$(if $(ALL),git add -u &&) git commit -m '$(MSG)')

## Push current branch: make push REPOS=110
push:
	$(call each_repo,git push 2>/dev/null || git push --set-upstream origin $$(git branch --show-current))

## Create a pull request: make pr REPOS=110 TITLE="<title>" [PR_BASE=<branch>]
pr:
	$(call each_repo,$(DEFAULT_BRANCH); gh pr create --title '$(TITLE)' --base $${PR_BASE:-$$b} --fill)

## Create and push a tag: make tag REPOS=110 NAME=<tag-name>
## In this repo a vX.Y.Z tag publishes the three packages to PyPI.
tag:
	$(call each_repo,git tag $(NAME) && git push origin $(NAME))

## Sync dependencies: make sync REPOS=110
sync:
	$(call each_repo,if $(IS_WORKSPACE); then uv sync --all-packages; else uv sync; fi)

## Upgrade dependencies
sync-upgrade:
	$(call each_repo,if $(IS_WORKSPACE); then uv sync --all-packages --upgrade; else uv sync --upgrade; fi)

## Run pytest: make test REPOS=110 [ARGS="-v -k foo"]
## Workspace packages are tested one at a time, from their own folder: their tests/
## packages share a name and can't be collected in one pytest session.
test:
	$(call each_repo,if $(IS_WORKSPACE); then \
		for p in $(PACKAGES); do echo "\n--- $$p"; (cd packages/$$p && ../../.venv/bin/pytest $(ARGS)) || exit 1; done; \
	else .venv/bin/pytest $(ARGS); fi)

## Bump versions and update dependents:
##   make bump REPOS=110 VERSION=<new-version> [IMAGEPROC_VERSION=<new-version>]
##   100: the three workspace packages, all to VERSION (one shared version), and the
##        `~=` pins on them in the packages and in Woof. Then `uv lock`: the lock file
##        records the workspace packages' versions, and CI syncs with --locked.
##   010: Woof's own version (pyproject.toml, pyproject_packaging.toml, manifest.json).
##   001: imageproc to IMAGEPROC_VERSION (its own version line): pyproject.toml and
##        image-proc/Cargo.toml (+ Cargo.lock), then `uv lock`. py-toolkit's
##        `ouestcharlie-imageproc~=` pin is not changed: raise it once the new imageproc
##        is published on PyPI.
bump:
	@if $(call bit_set,1) || $(call bit_set,2); then \
		[ -n "$(VERSION)" ] || { echo "Usage: make bump REPOS=<selector> VERSION=<new-version>"; exit 1; }; \
	fi; \
	if $(call bit_set,3); then \
		[ -n "$(IMAGEPROC_VERSION)" ] || { echo "Usage: make bump REPOS=xx1 IMAGEPROC_VERSION=<new-version>"; exit 1; }; \
	fi
	@compat=$$(echo "$(VERSION)" | cut -d. -f1,2); \
	dependents="$(foreach p,$(PACKAGES),packages/$(p)/pyproject.toml) $(WOOF)/pyproject.toml $(WOOF)/pyproject_packaging.toml"; \
	if $(call bit_set,1); then \
		echo "\n>>> Bumping $(PACKAGES) to $(VERSION)"; \
		for p in $(PACKAGES); do \
			f=packages/$$p/pyproject.toml; \
			sed -i '' 's/^version = ".*"/version = "$(VERSION)"/' $$f; \
			pkg=$$(grep '^name = ' $$f | sed 's/^name = "\(.*\)"/\1/'); \
			for other in $$dependents; do \
				[ -f "$$other" ] && sed -i '' -E "s/$$pkg(>=|~=)[0-9][0-9.]*/$$pkg~=$$compat/g" $$other; \
			done; \
		done; \
		uv lock && uv sync --all-packages || exit 1; \
	fi; \
	if $(call bit_set,2); then \
		echo "\n>>> Bumping $(WOOF) to $(VERSION)"; \
		sed -i '' 's/^version = ".*"/version = "$(VERSION)"/' $(WOOF)/pyproject.toml; \
		if [ -f "$(WOOF)/pyproject_packaging.toml" ]; then \
			sed -i '' 's/^version = ".*"/version = "$(VERSION)"/' $(WOOF)/pyproject_packaging.toml; \
		fi; \
		pkg=$$(grep '^name = ' $(WOOF)/pyproject.toml | sed 's/^name = "\(.*\)"/\1/'); \
		if [ -f "$(WOOF)/manifest.json" ]; then \
			sed -i '' 's/"version": "[0-9][0-9.]*"/"version": "$(VERSION)"/' $(WOOF)/manifest.json; \
			sed -i '' "s/$$pkg==[0-9][0-9.]*/$$pkg==$(VERSION)/" $(WOOF)/manifest.json; \
		fi; \
	fi; \
	if ($(call bit_set,1) || $(call bit_set,2)) && [ -f "$(WOOF)/pyproject.toml" ]; then \
		(cd $(WOOF) && uv sync) || exit 1; \
	fi; \
	if $(call bit_set,3); then \
		echo "\n>>> Bumping $(IMAGEPROC) to $(IMAGEPROC_VERSION)"; \
		sed -i '' 's/^version = ".*"/version = "$(IMAGEPROC_VERSION)"/' $(IMAGEPROC)/pyproject.toml; \
		sed -i '' '/^\[package\]/,/^\[/ s/^version = ".*"/version = "$(IMAGEPROC_VERSION)"/' $(IMAGEPROC)/image-proc/Cargo.toml; \
		if command -v cargo >/dev/null; then \
			(cd $(IMAGEPROC)/image-proc && cargo update --workspace --offline -q) || exit 1; \
		else echo "cargo not found: run 'cargo update --workspace' in image-proc to refresh Cargo.lock"; fi; \
		(cd $(IMAGEPROC) && uv lock) || exit 1; \
	fi
