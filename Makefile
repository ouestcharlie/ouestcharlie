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

.PHONY: branch commit

## Create a new branch: make branch REPOS=1111 NAME=<branch-name>
branch:
	$(call each_repo,git checkout -b $(NAME))

## Commit staged changes: make commit REPOS=1111 MSG="<message>"
commit:
	$(call each_repo,git commit -m '$(MSG)')
