# Repo selector: 4-bit binary string (MSB → LSB)
#   1000 = py-toolkit
#   0100 = whitebeard
#   0010 = wally
#   0001 = woof
# Examples:
#   make branch REPOS=1111 NAME=my-feature
#   make commit REPOS=0011 MSG="fix: something"
REPOS ?= 1111

# Iterate over repos matching the REPOS bitmask and run a shell command in each.
define each_repo
	@i=1; for repo in \
		../ouestcharlie-py-toolkit \
		../ouestcharlie-whitebeard \
		../ouestcharlie-wally \
		../ouestcharlie-woof; \
	do \
		bit=$$(echo "$(REPOS)" | cut -c$$i); \
		if [ "$$bit" = "1" ]; then \
			echo "\n>>> $$repo"; \
			(cd $$repo && $(1)) || exit 1; \
		fi; \
		i=$$((i+1)); \
	done
endef

.PHONY: branch checkout pull commit push tag sync test pr bump

## Create a new branch: make branch REPOS=1111 NAME=<branch-name>
branch:
	$(call each_repo,git checkout -b $(NAME))

## Checkout an existing branch: make checkout REPOS=1111 NAME=<branch-name>
checkout:
	$(call each_repo,git checkout $(NAME))

## Checkout a branch and pull: make pull REPOS=1111 NAME=<branch-name>
pull:
	$(call each_repo,git checkout $(NAME) && git pull)

## Commit staged changes: make commit REPOS=1111 MSG="<message>" [ALL=1 to stage all changes first]
commit:
	$(call each_repo,$(if $(ALL),git add -u &&) git commit -m '$(MSG)')

## Push current branch: make push REPOS=1111
push:
	$(call each_repo,git push 2>/dev/null || git push --set-upstream origin $$(git branch --show-current))

## Create a pull request: make pr REPOS=1111 TITLE="<title>" [BASE=master]
BASE ?= master
pr:
	$(call each_repo,gh pr create --title '$(TITLE)' --base $(BASE) --fill)

## Create and push a tag: make tag REPOS=1111 NAME=<tag-name>
tag:
	$(call each_repo,git tag $(NAME) && git push origin $(NAME))

## Sync dependencies: make sync REPOS=1111
sync:
	$(call each_repo,uv sync)

## Run pytest: make test REPOS=1111 [ARGS="-v -k foo"]
test:
	$(call each_repo,.venv/bin/pytest $(ARGS))

## Bump package version(s) and update dependents: make bump REPOS=1000 VERSION=<new-version>
bump:
	@[ -n "$(VERSION)" ] || (echo "Usage: make bump REPOS=<selector> VERSION=<new-version>"; exit 1)
	@all_repos="../ouestcharlie-py-toolkit ../ouestcharlie-whitebeard ../ouestcharlie-wally ../ouestcharlie-woof"; \
	i=1; for repo in $$all_repos; do \
		bit=$$(echo "$(REPOS)" | cut -c$$i); \
		if [ "$$bit" = "1" ]; then \
			echo "\n>>> Bumping $$repo to $(VERSION)"; \
			sed -i '' 's/^version = ".*"/version = "$(VERSION)"/' $$repo/pyproject.toml; \
			pkg=$$(grep '^name = ' $$repo/pyproject.toml | sed 's/^name = "\(.*\)"/\1/'); \
			for other in $$all_repos; do \
				if [ "$$other" != "$$repo" ] && [ -f "$$other/pyproject.toml" ]; then \
					sed -i '' "s/$$pkg>=[0-9][0-9.]*/$$pkg>=$(VERSION)/g" $$other/pyproject.toml; \
				fi; \
			done; \
		fi; \
		i=$$((i+1)); \
	done
