##
## Base Commands
## -------------
#
TAG ?= v1
# https://www.gnu.org/software/make/manual/make.html#Flavors
# Use simple expansion for most and not ?= since default is /bin/bash
# which is bash v3 for MacOS
SHELL := /usr/bin/env bash
GIT_ORG ?= richtong
# the URL of the org like tne.ai
ORG ?=
LIB_DIR ?= $(WS_DIR)/git/src/lib

SUBMODULE_HOME ?= $(WS_DIR)
NEW_REPO ?=
name ?= $$(basename "$(PWD)")
# if you have include.python installed then it uses the environment but by
# default we assume we are using the raw environment
RUN ?=
# python modules that should go into pdoc
PYTHON_FILES ?=
FORCE ?= false

# The base installation packages needed
BASE_PREREQ ?= coreutils markdownlint-cli shellcheck shfmt hadolint git-lfs
BASE_PREREQ_PIP ?= pynvim mkdocs mkdocs-material pymdown-extensions fontawesone-markdown

.DEFAULT_GOAL := help
.PHONY: help
# https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html does not
# work because we use an include file
# https://swcarpentry.github.io/make-novice/08-self-doc/ is simpler just need
# and it dumpes them out relies on the variable MAKEFILE_LIST which is a list of
# all files note we do not just use $< because this is an include.mk file
## help: available commands (the default)
help: $(MAKEFILE_LIST)
	@sed -n 's/^##//p' $(MAKEFILE_LIST)

# https://stackoverflow.com/questions/4728810/how-to-ensure-makefile-variable-is-set-as-a-prerequisite/7367903#7367903
# Clever trick using replacement where the % means match all targets that look
# like this and ${*} means provide me with the targets
# So a dependency on guard-PIPENV_ACTIVE would make sure you are in pipenv
.PHONY: unset-%
unset-%:
	@if [[ -n "${${*}}" ]]; then \
		echo "Environment variable $* must not be set for this Make rule to run"; \
		exit 1; \
	fi

.PHONY: set-%
set-%:
	@if [[ -z "${${*}}" ]]; then \
		echo "Environment variable $* must set for this Make rule to run"; \
		exit 1; \
	fi

## auth: Authenticate against aws, netlify, doctl, gcp, auth0, huggingface
.PHONY: auth
auth:
	command -v aws > /dev/null &&  aws sts get-caller-identity &> /dev/null || aws sso login
	command -v netlify > /dev/null && ! netlify status | grep -q "Not logged in" || netlify login
	command -v doctl > /dev/null && doctl projects list &>/dev/null || op plugin run -- doctl auth init
	command -v gcloud > /dev/null && gcloud projects list >/dev/null || gcloud auth login
	command -v auth0 > /dev/null && auth0 tenants list | grep -v "auth0 login" || auth0 login
	command -v huggingface-cli >/dev/null && huggingface-cli whoami >/dev/null || huggingface-cli login

# These are required tags from checkmate stubs are here you should overwrite
#.PHONY: test
#test:
#    @echo "test stub"

## tag: pushes a new tag up while delete old to force the action
.PHONY: tag
tag:
	git tag -d "$(TAG)"; \
	git push origin :"$(TAG)" ; \
	git tag -a "$(TAG)" -m "$(COMMENT)" && \
	git push origin "$(TAG)"

## docs: Generate a documentation runing pdoc and mkdocs
.PHONY: docs
docs: pdoc mkdocs

## docs-serve: start mkdocs server in background and start safari pkill mkdocs to end
.PHONY: docs-serve
docs-serve: docs-stop
	mkdocs serve
	sleep 5
	open http://localhost:8000

## docs-stop: Kill the mkdocs server at http://localhost:8000
# do not care if it it doesn't exist so ignore return code
# and need -f since mkdocs is not the executable name if it
# is run with poetry
.PHONY: docs-stop
docs-stop:
	-pkill -f mkdocs

## mkdocs: Generate mkdocs ./site from ./docs
.PHONY: mkdocs
mkdocs:
	mkdocs build

## mkdocs-gh: deploy doc to github pages only works for public repos
.PHONY: mkdocs-gh
mkdocs-gh:
	mkdocs gh-deploy

## pdoc: Make python documentation using pdoc3
.PHONY: pdoc
pdoc: $(PYTHON_FILES)
	if [[ -n "$(PYTHON_FILES)" ]]; then \
		$(RUN) pdoc --force -o docs/code $(PYTHON_FILES); \
	fi

## install-netlify: Generate a netlify configuration
.PHONY: install-netlify
install-netlify: requirements.txt runtime.txt netlify.toml .node-version
	@echo netlify needs requirements.txt, runtime.txt and netlify.toml and .node-version
	@echo use netlify switch if the right link does not appear
	netlify link
	netlify env:set GIT_LFS_ENABLED true

## doctoc: generate toc for markdowns at the top level (deprecated)
.PHONY: doctoc
doctoc:
	doctoc *.md

# https://joshtronic.com/2020/08/09/how-to-get-the-default-git-branch/
# this is how to figure out the default branch main or master
# git symbolic-ref refs/remotes/origin/HEAD | cut -d '/' -f 4
# note that the --remote only works if the --branch is specified on the git
# clone
## install-src: creates mono repo and submodules in $(BASE_REPO)
BASE_REPO ?= bin lib
.PHONY: install-src
install-src: git-lfs install-repo
	for repo in $(BASE_REPO); do \
		$(RUN) git submodule add \
			--branch "$$(git symbolic-ref refs/remotes/origin/HEAD | cut -d '/' -f 4)" \
			git@github.com:$(GIT_ORG)/$$repo;\
	done
	$(RUN) git submodule update --init --recursive --remote

## update-repo: update repo and submodules
.PHONY: update-repo
update-repo:
	@echo "make sure git submodules set-branch --branch main set for all repos"
	$(RUN) git submodule update --init --recursive --remote

# use install instead to create sub-directories
# https://stackoverflow.com/questions/1529946/linux-copy-and-create-destination-dir-if-it-does-not-exist
#				cp "$(WS_DIR)/git/src/lib/$${TEMPLATE[i]}" $${FILE[i]};
# set these to the destination FILE and the source TEMPLATE if the file does
# not exist are you are using FORCE to overwrite
# do nore use envrc.base except at the very top of ./src
# no longer make git lfs the default as this
# needs tools to understand git lfs
			# gitattributes.base \
			# .gitattributes \
# the envrc should only go at the top of your ./ws for each project
# requirements.txt needed for netlify
# no longer have specific tool-versions for asdf, set globally
# if you need venv use the programming language specific ones
#
# set PYTHON_INSTALL to force installation python install-repo
PYTHON_TEMPLATE ?= \
			tool-versions.base \
			envrc.base \
			python_version.base \
			pyproject.base.toml

PYTHON_FILE ?= \
			.tool-versions  \
			.envrc  \
			.python_version \
			pyproject.toml

# netlify disabled: uncomment TEMPLATE and FILE pairs to re-enable
#			runtime.base.txt        -> runtime.txt
#			netlify.base.toml       -> netlify.toml
#			mkdocs.base.yml         -> mkdocs.yml
#			requirements.netlify.txt -> requirements.txt
TEMPLATE ?= \
			gitignore.base \
			pre-commit-config.full.yaml \
			prettierignore.base \
			markdownlint-cli2.base.yaml \
			docs.base \
			workflow.base
# node-version disabled: use mise (.mise.toml) for node version management instead
#			node-version.base \

FILE ?= \
			.gitignore \
			.pre-commit-config.yaml \
			.prettierignore \
			.markdownlint-cli2.yaml \
			docs \
			.github/workflows
# node-version disabled: use mise (.mise.toml) for node version management instead
#			.node-version \

.PHONY: install-repo
## install-repo: copy the skeleton files a new repo set PYTHON_INSTALL for python template
install-repo:
	# Makefile: only copy if missing (--ignore-existing) to preserve custom targets
	rsync -vL --chmod=F664 --ignore-existing \
		"$(WS_DIR)/git/src/lib/Makefile.base" Makefile
	# rsync -u skips files newer on the destination (use FORCE=true to override)
	FILE=( $(FILE) $(if $(PYTHON_INSTALL),$(PYTHON_FILE)) ) && \
	TEMPLATE=( $(TEMPLATE) $(if $(PYTHON_INSTALL),$(PYTHON_TEMPLATE)) ) && \
	LIB_DIR="$(WS_DIR)/git/src/lib" && \
	RSYNC_OPTS="-vL --chmod=F664" && \
	if ! $(FORCE); then RSYNC_OPTS="$$RSYNC_OPTS -u"; fi && \
	for (( i=0; i<$${#FILE[@]}; i++ )); do \
		DEST_FILE="$${FILE[i]}" && \
		SRC_FILE="$$LIB_DIR/$${TEMPLATE[i]}" && \
		if [[ ! -e $$SRC_FILE ]]; then \
			echo "skipped $$i $$SRC_FILE (not found)"; \
		elif [[ -f $$SRC_FILE ]]; then \
			mkdir -p "$$(dirname "$$DEST_FILE")" && \
			rsync $$RSYNC_OPTS "$$SRC_FILE" "$$DEST_FILE"; \
		else \
			mkdir -p "$$DEST_FILE" && \
			rsync -r $$RSYNC_OPTS "$$SRC_FILE/" "$$DEST_FILE/"; \
		fi; \
	done

# install-repo-old: deprecated Install repo
# replaced by a set of variables instead of hard coded
.PHONY: install-repo-old
install-repo-old:
	for PREREQ in $(BASE_PREREQ); do \
		if ! command -v "$$PREREQ" >/dev/null; then brew install "$$PREREQ"; fi ;\
	done && \
	for PREREQ_PIP in $(BASE_PREREQ_PIP); do \
	    pip install "$$PREREQ_PIP"; \
	done && \
	if $(FORCE) || [[ -e $(WS_DIR)/git/src/lib/gitattributes.base && \
		! -e .gitattributes ]]; then \
			cp "$(WS_DIR)/git/src/lib/gitattributes.base" .gitattributes; \
	fi && \
	if $(FORCE) || [[ -e $(WS_DIR)/git/src/lib/gitignore.base && \
		! -e .gitignore ]]; then \
			cp "$(WS_DIR)/git/src/lib/gitignore.base" .gitignore; \
	fi && \
	if $(FORCE) || [[ -e $(WS_DIR)/git/src/lib/pre-commit-config.full.yaml && \
		! -e .pre-commit-config.yaml ]]; then \
			cp "$(WS_DIR)/git/src/lib/pre-commit-config.full.yaml" .pre-commit-config.yaml; \
	fi && \
	if $(FORCE) || [[ -e $(WS_DIR)/git/src/lib/workflow.full.gha.yaml && \
		! -e .github/workflows/workflow.full.gha.yaml ]]; then \
			mkdir -p .github/workflows; \
			cp "$(WS_DIR)/git/src/lib/workflow.full.gha.yaml" .github/workflows; \
	fi && \
	if $(FORCE) || [[ -e $(WS_DIR)/git/src/lib/tool-versions.full && \
		! -e .tool-versions ]]; then \
			cp "$(WS_DIR)/git/src/lib/tool-versions.full" .tool-versions; \
	fi && \
	if $(FORCE) || [[ -e $(WS_DIR)/git/src/lib/envrc.full && \
		! -e .envrc ]]; then \
			cp "$(WS_DIR)/git/src/lib/envrc.full" .envrc; \
	fi &&
	if $(FORCE) || [[ -e $(WS_DIR)/git/src/lib/pyproject.full.toml && \
		! -e pyproject.toml ]]; then \
			cp "$(WS_DIR)/git/src/lib/pyproject.full.toml" pyproject.toml; \
	fi

## pre-commit: Run pre-commit hooks and install if not there with update
.PHONY: pre-commit
pre-commit: install-pre-commit
	@echo this does not work on WSL so you need to run pre-commit install manually
	if [[ ! -e .pre-commit-config.yaml ]]; then \
		echo "no .pre-commit-config.yaml found copy from ./lib"; \
	else \
		$(RUN) pre-commit run --all-files || true \
	; fi

## install-pre-commit: Install precommit (get prebuilt .pre-commit-config.yaml from @richtong/lib)
## Handles repos that set core.hooksPath (e.g. to .githooks): pre-commit install always
## writes to .git/hooks/ but git looks in core.hooksPath instead. We copy installed hooks
## across so both locations are in sync and git actually fires them on commit/push.
.PHONY: install-pre-commit
install-pre-commit: install-repo
	if [[ -e .pre-commit-config.yaml ]]; then \
		$(RUN) pre-commit install || true && \
		pre-commit install --hook-type commit-msg || true && \
		pre-commit install --hook-type pre-push || true && \
		if HOOKS_PATH=$$(git config core.hooksPath 2>/dev/null); then \
			mkdir -p "$$HOOKS_PATH" && \
			for hook in pre-commit commit-msg pre-push; do \
				if [[ -e ".git/hooks/$$hook" && ! -e "$$HOOKS_PATH/$$hook" ]]; then \
					cp ".git/hooks/$$hook" "$$HOOKS_PATH/$$hook" && \
					echo "Copied .git/hooks/$$hook → $$HOOKS_PATH/$$hook (core.hooksPath override)"; \
				fi; \
			done; \
		fi \
	; fi

## pre-commit-update: Bump all pre-commit versions
.PHONY: pre-commit-update
pre-commit-update:
		$(RUN) pre-commit autoupdate || true

## act: Run Github actions as docker job on local machine only works as amd64
# https://github.com/nektos/act/issues/285
# --reuse make the cache work locally
.PHONY: act
act:
	act --reuse --container-architecture linux/amd64

## runner-label: Set Blacksmith RUNNER_LABEL org variable for faster CI
# https://www.blacksmith.sh — 2x faster, 3000 free min/mo for private repos
# Workflows using ${{ vars.RUNNER_LABEL }} pick this up automatically.
# Requires org admin rights on GitHub.
BLACKSMITH_RUNNER ?= blacksmith-4vcpu-ubuntu-2404
.PHONY: runner-label
runner-label:
	gh variable set RUNNER_LABEL --org $(ORG) --body "$(BLACKSMITH_RUNNER)"
	@echo "RUNNER_LABEL=$(BLACKSMITH_RUNNER) set for org $(ORG)"

## install-submodule: installs a new submodule $(GIT_ORG)/$(NEW_REPO)
.PHONY: install-submodule
install-submodule:
ifeq ($(NEW_REPO),)
	@echo "create with make git NEW_REPO=_name_"
else
	gh repo create git@github.com:$(GIT_ORG)/$(NEW_REPO)
	cd $(SUBMODULE_HOME)
	git submodule add git@github.com:$(GIT_ORG)/$(NEW_REPO)
	cd $(NEW_REPO)
	git init
	cat "## $(ORG) $(name) repo" >> README.md
	git commit -m "README.md first commit"
	git branch -M main
	git push -u origin main
endif

## direnv: creates a new environemnt with direnv and asdf
.PHONY: direnv
direnv:
	touch .envrc
	direnv allow .envrc

## install-brew: install brew packages
# quote needed in case BREW is not set
.PHONY: install-brew
install-brew:
	if [[ -n "$(BREW)" ]]; then \
		brew install $(BREW) \
	; fi

LIB_SOURCE ?= ../../lib
LIB_FILES ?= include.python.mk include.mk
## lib-sync: sync from $(LIB_FILES) from $(LIB) for independent PIP packages
.PHONY: lib-sync
lib-sync:
	for f in $(LIB_FILES); do \
		if [[ -e $(LIB_SOURCE)/$$f ]]; then \
			rsync -av "$(LIB_SOURCE)/$$f" "$$f" \
		; fi \
	; done


## git-lfs: installs git lfs
.PHONY: git-lfs
git-lfs:
	$(RUN) brew install git-lfs
	$(RUN) git lfs install
	$(RUN) git add --all
	$(RUN) git commit -av
	# this will fail if you are not already committed
	$(RUN) git lfs pull
## lfs-uninstall: to remove git and get rid of lfs files
# https://gist.github.com/everttrollip/198ed9a09bba45d2663ccac99e662201
# https://stackoverflow.com/questions/40365154/git-migrate-from-lfs-to-normal-repo
.PHONY: lfs-uninstall
lfs-uninstall:
	if [[ -n "$(git lfs track)" ]]; then git lfs uninstall; fi
	if [[ -e .gitattributes ]]; then git mv .gitattributes .gitattributes.disabled; fi
	git add --renormalize .
	git lfs migrate export --everything --include "*"
	@echo you cannot remove git lfs files without recreating the repo
