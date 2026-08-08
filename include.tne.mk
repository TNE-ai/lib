##
## TNE.ai shared Makefile targets — included by all tne-ai repos via Makefile.template
## Edit this file (in src/lib/) to update targets across all repos at once.
## Repo-specific targets go in include.local.mk, not here.
##
## Governed by r-cio-install91-plugin-sync

ORG          ?= tne
WS_DIR       ?= $(HOME)/ws
GITHUB_ORG   ?= $(ORG)-ai
PLUGIN_REPO  ?= $(WS_DIR)/git/src/sys/tne-plugins

# ── Plugin sync targets ───────────────────────────────────────────────────────
# src/lib/ and src/bin/ are sources of truth; plugins/tne/lib/ and
# plugins/tne/bin/ are compiled outputs. (r-cio-install91-plugin-sync)

## sync-plugin-lib: distill src/lib/ functions into plugins/tne/lib/
.PHONY: sync-plugin-lib
sync-plugin-lib:
	$(PLUGIN_REPO)/plugins/tne/scripts/sync-lib.sh $(PLUGIN_REPO)

## sync-plugin-bin: distill src/bin/ launchers into plugins/tne/bin/
.PHONY: sync-plugin-bin
sync-plugin-bin:
	$(PLUGIN_REPO)/plugins/tne/scripts/sync-bin.sh $(PLUGIN_REPO)

## sync-plugin: sync lib/ and bin/, then commit to tne-plugins
.PHONY: sync-plugin
sync-plugin: sync-plugin-lib sync-plugin-bin
	cd $(PLUGIN_REPO) && \
	  git add plugins/tne/lib/ plugins/tne/bin/ && \
	  git diff --cached --quiet || \
	  git commit -m "chore(sync): distill from src/ $$(git -C $(CURDIR) rev-parse --short HEAD)"

# ── Studio / user repo targets ────────────────────────────────────────────────

PLUGIN_REPO ?= $(WS_DIR)/git/src/sys/tne-plugins
PLUGIN_SCRIPTS ?= $(PLUGIN_REPO)/plugins/tne/scripts

## sync-plugin-lib: distill src/lib/ into plugins/tne/lib/
.PHONY: sync-plugin-lib
sync-plugin-lib:
	$(PLUGIN_SCRIPTS)/sync-lib.sh $(PLUGIN_REPO)

## sync-plugin-bin: distill src/bin/ launchers into plugins/tne/bin/
.PHONY: sync-plugin-bin
sync-plugin-bin:
	$(PLUGIN_SCRIPTS)/sync-bin.sh $(PLUGIN_REPO)

## sync-plugin: run both lib and bin sync
.PHONY: sync-plugin
sync-plugin: sync-plugin-lib sync-plugin-bin

STUDIO_SUBMODULE_DIR ?= $(WS_DIR)/git/src/user
STUDIO_AWS_S3        ?= s3://bp-authoring-files/d
STUDIO_PREFIX        ?= studio
STUDIO_USER          ?= demo
STUDIO_EMAIL_ORG     ?= $(ORG).ai
STUDIO_EMAIL         ?= $(STUDIO_USER)@$(STUDIO_EMAIL_ORG)
STUDIO_REPO          ?= $(STUDIO_PREFIX)-$(STUDIO_USER)
STUDIO_REPO_URL      ?= git@github.com:$(ORG)/$(STUDIO_REPO)

## studio: create a studio repo — usage: STUDIO_USER=trang make studio
.PHONY: studio
studio:
	gh repo view "$(GITHUB_ORG)/$(STUDIO_REPO)" &> /dev/null || \
		gh repo create -d \
			"$$(echo $(STUDIO_USER)\'s Studio | sed 's/\b\w/\u&/g')" \
			--add-readme --private "$(GITHUB_ORG)/$(STUDIO_REPO)" && \
	cd $(WS_DIR)/git/src/user && \
		git submodule | grep -q "$(STUDIO_REPO)" || \
		git submodule add git@github.com:$(GITHUB_ORG)/$(STUDIO_REPO).git

## app: create an app repo — usage: APP_NAME=maria make app
APP_PREFIX ?= app
APP_NAME   ?= maria
APP_REPO   ?= $(APP_PREFIX)-$(APP_NAME)
.PHONY: app
app:
	gh repo view "$(GITHUB_ORG)/$(APP_REPO)" &> /dev/null || \
		gh repo create -d \
			"$$(echo $(APP_NAME)\'s App | sed 's/\b\w/\u&/g')" \
			--add-readme --private "$(GITHUB_ORG)/$(APP_REPO)"
	cd $(WS_DIR)/git/src/app && \
		git submodule | grep -q "$(APP_REPO)" || \
		git submodule add git@github.com:$(GITHUB_ORG)/$(APP_REPO).git
