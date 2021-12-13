#
##
## Docker command v2 uses docker-compose if docker_compose.yaml exists
## -------
# Remember makefile *must* use tabs instead of spaces so use this vim line
# requires include.mk
#
# The makefiles are self documenting, you use two leading for make help to produce output

# YOu will want to change these depending on the image and the org
REPO ?= tongfamily
#
# https://stackoverflow.com/questions/10024279/how-to-use-shell-commands-in-makefile
# Cannot use ?= because we want the shell to evaluate at make time
ifndef NAME
# this is the short form of the longer form below
#NAME := $(shell basename $(PWD))
NAME != basename $(PWD)
endif

IMAGE ?= $(REPO)/$(NAME)

SHELL := /usr/bin/env bash
DOCKER_COMPOSE_YML ?= docker-compose.yml
DOCKER_USER ?= docker
HOST_DIR ?= /home/$(DOCKER_USER)/data
# https://stackoverflow.com/questions/18136918/how-to-get-current-relative-directory-of-your-makefile
CONTAINER_DIR ?= /var/data
# -v is deprecated
# volumes ?= -v "$$(readlink -f "./data"):$(HOST_DIR)"
VOLUMES ?= --mount "type=bind,source=$(HOST_DIR),target=$(CONTAINER_DIR)"

# no flags by default
FLAGS ?=
DOCKERFILE ?= Dockerfile

CONTAINER := $(NAME)
BUILD_PATH ?= .
MAIN ?= $(NAME).py
DOCKER_ENV ?= docker
CONDA_ENV ?= $(NAME)

# https://github.com/moby/moby/issues/7281

# pip packages that can also be installed by conda
PIP ?=
# pip packages that cannot be conda installed
PIP_ONLY ?=

# assuming one keep the input open like docker -it
STDIN_OPEN ?= true
TTY ?= true

# need the right UID for correct volume permissions
# currently breaks px4 with invalide user id
#LOCAL_USER_ID ?= $(shell echo $$UID)
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)
# get the IP container address
CONTAINER_IP=$$(docker container inspect -f '{{ $$net := index .NetworkSettings.Networks "$(NAME)_default" }}{{ $$net.IPAddress }}' $(NAME)_main_1)
HOST_IP=$(shell ipconfig getifaddr en0)
# more complex
#HOST_IP=$(shell ifconfig en0 | grep "inet " | cut -d ' ' -f 2)
EXPORTS ?= HOST_UID="$(HOST_UID)" HOST_GID="$(HOST_GID)" HOST_IP="$(HOST_IP)" IMAGE="$(IMAGE)"

## xhost: Run docker with xhost on
# https://github.com/moby/moby/issues/35886
# Cannot use single quotes in the -f filter because $(name) is itself a shell
# command so use backslashes instead
# In the IP setting not there should be no space between the two handlebars
# https://lmiller1990.github.io/electic/posts/20201119_cypress_and_x11_in_docker.html
# http://mamykin.com/posts/running-x-apps-on-mac-with-docker/
# https://stackoverflow.com/questions/38686932/how-to-forward-docker-for-mac-to-x11
# not sure which ones to add so add all of them
# Note that ifconfig and HOSTNAME point to the same DNS so you don't need both
# but do both in case that is incorrect
.PHONY: xhost
xhost:
	@echo "On MacOS install XQuartz and enable Preferences > Security > Allow connects from network clients"
	xhost "+$$HOSTNAME"
	xhost "+$(ifconfig getifaddre en0)"
	xhose "+localhost"

# You should note need the architecture since docker works with both intel and
# m1 on Apple Silicon
ARCH=$(shell uname -m)
DOCKER_ENV_FILE ?= docker-compose.env

# these are only for docker build (deprecated use docker compose and DOCKER_ENV_FILE instead)
docker_flags ?= --build-arg "DOCKER_USER=$(DOCKER_USER)" \
				--build-arg "HOST_DIR=$(HOST_DIR)" \
				--build-arg "NB_USER=$(DOCKER_USER)" \
				--build-arg "ENV=$(DOCKER_ENV)" \
				--build-arg "PYTHON=$(PYTHON)" \
				--build-arg "PIP=$(PIP)" \
				--build-arg "PIP_ONLY=$(PIP_ONLY)" \
				--build-arg "STDIN_OPEN=$(STDIN_OPEN)" \
				--build-arg "TTY=$(TTY)"

# Guess the name of the main container is called main
DOCKER_COMPOSE_MAIN ?= main

## docker-installed: make sure docker is running
.PHONY: docker-installed
docker-installed:
	if ! docker ps >/dev/null; then  open -a docker && sleep 30; fi

## build: build images (push separately)
		# LOCAL_USER_ID=$(LOCAL_USER_ID)
.PHONY: build
build: docker-installed
	export $(EXPORTS) && \
	if [[ -r  "$(DOCKER_COMPOSE_YML)" ]]; then \
		docker compose --env-file "${DOCKER_ENV_FILE}" -f "$(DOCKER_COMPOSE_YML)" build --pull; \
	else \
		docker build --pull \
					$(FLAGS) \
					 -f "$(DOCKERFILE)" \
					 -t "$(IMAGE)" \
					 $(BUILD_PATH) && \
		docker tag $(IMAGE) $(IMAGE):$$(git rev-parse HEAD);  \
	fi

## docker-lint: run the linter against the docker file
# LOCAL_USER_ID=$(LOCAL_USER_ID)
.PHONY: docker-lint
docker-lint: $(DOCKERFILE) docker-installed
	export $(EXPORTS) && \
	if [[ -r $((DOCKER_COMPOSE_YML)) ]]; then \
		docker compose --env-file "$(DOCKER_ENV_FILE)" -f "$(DOCKER_COMPOSE_YML)" config; \
	else \
		dockerfilelint $(DOCKERFILE); \
	fi

## docker-test: run tests for pip file
.PHONY: dockertest
docker-test: docker-installed
	@echo PIP=$(PIP)
	@echo PIP_ONLY=$(PIP_ONLY)
	@echo PYTHON=$(PYTHON)

## push: after a build will push the image up
.PHONY: push
push: docker-installed
	# need to push and pull to make sure the entire cluster has the right images
	export HOST_IP=$(HOST_IP) HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) && \
	if [[ -r $(DOCKER_COMPOSE_YML) ]]; then \
		docker compose --env-file "$(DOCKER_ENV_FILE)" -f "$(DOCKER_COMPOSE_YML)" push; \
	else \
		docker push $(IMAGE); \
	fi

# for those times when we make a change in but the Dockerfile does not notice
# In the no cache case do not pull as this will give you stale layers
## no-cache: build docker image with no cache
.PHONY: no-cache
no-cache: $(DOCKERFILE) docker-installed
	export $(EXPORTS) && \
	if [[ -e $(DOCKER_COMPOSE_YML) ]]; then \
		# LOCAL_USER_ID=$(LOCAL_USER_ID) \
		docker compose --env-file "$(DOCKER_ENV_FILE)" -f "$(DOCKER_COMPOSE_YML)" build \
			--build-arg NB_USER=$(DOCKER_USER); \
	else \
		docker build --pull --no-cache \
			$(docker_flags) \
			--build-arg NB_USER=$(DOCKER_USER) -f $(Dockerfile) -t $(IMAGE) $(BUILD_PATH); \
		docker push $(IMAGE); \
	fi

# bash -c means the first argument is run and then the next are set as the $1,
# to it and not that you use awk with the \$ in double quotes
for_containers = bash -c 'for container in $$(docker ps -qa --filter name="$$0"); \
						  do \
						  	docker $$1 "$$container" $$2 $$3 $$4 $$5 $$6 $$7 $$8 $$9; \
						  done'

# we use https://stackoverflow.com/questions/12426659/how-to-extract-last-part-of-string-in-bash
# Because of quoting issues with awk
# bash -c uses $0 for the first argument
# the first $0 is assumed to be flags to docker run then come the arguments
# And that the last digit is separate by a dash to an underscore
DOCKER_RUN = bash -c ' \
	export $(EXPORTS) && \
	last=$$(docker ps --format "{{.Names}}" | rev | tr - _ | cut -d "_" -f 1 | sort -r | head -n1) && \
	docker run $$0 \
		--name $(CONTAINER)_$$((last+1)) \
		$(VOLUMES) $(FLAGS) $(IMAGE) $$@ && \
	sleep 4 && \
	docker logs $(CONTAINER)_$$((last+1))'


## stop: halts all running containers (deprecated)
.PHONY: stop
stop: docker-installed
	export $(EXPORTS) && \
	if [[ -r $(DOCKER_COMPOSE_YML) ]]; then \
		docker compose --env-file "${DOCKER_ENV_FILE}" -f "$(DOCKER_COMPOSE_YML)" down \
	; else \
		$(for_containers) $(container) stop > /dev/null && \
		$(for_containers) $(container) "rm -v" > /dev/null \
	; fi

## pull: pulls the latest image
.PHONY: pull
pull: docker-installed
	export $(EXPORTS) && \
	if [[ -r $(DOCKER_COMPOSE_YML) ]]; then \
		docker compose --env-file "$(DOCKER_ENV_FILE)" -f "$(DOCKER_COMPOSE_YML)" pull; \
	else \
		docker pull $(IMAGE); \
	fi

## run [args]: stops all the containers and then runs in the background
##             if there are flags than to a make -- run --flags [args]
# https://stackoverflow.com/questions/2214575/passing-arguments-to-make-run
# Hack to allow parameters after run only works with GNU make
# Note no indents allowed for ifeq
# This commented out does not work if MAKECMDGOALS
# include real targets like 'run'
#ifeq (exec,$(firstword $(MAKECMDGOALS)))
## use the rest of the goals as arguments
#RUN_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)), $(MAKECMDGOALS))
## and create phantom targets for all those args
#$(eval $(RUN_ARGS):;@:)
#endif

# https://stackoverflow.com/questions/30137135/confused-about-docker-t-option-to-allocate-a-pseudo-tty
# docker run flags
# -i interactive connects the docker stdin to the terminal stdin
#    to exit the container send a CTRL-D to the stdin. This is used to run
#    and then exit like a shell command
# -t terminal means that the input is a terminal (and is useless without -i)
# -it this is almost always used together. commands like ls treat things
#     differently if they are not readl terminals so this works like a shell
# -dt runs but connects the stdin and stdout so logging works
#
# https://www.tecmint.com/run-docker-container-in-background-detached-mode/
# -d run in detached mode so it runs in the background and output goes
#    to the terminal if -t is set or it goes to the log otherwise
#  docker attach will reconnect it to the foreground.
# -rm remove the container when it exits


## docker: Run the docker container in the background (for web apps like Jupyter)
# we show the log after 5 second so you can see things like the security token
# needs. the Host IP has to be passed in as it changes dynamically
# and the .env file is static
.PHONY: docker
docker: stop  docker-installed
	export $(EXPORTS) && \
	if [[ -r $(DOCKER_COMPOSE_YML) ]]; then \
		docker compose --env-file "$(DOCKER_ENV_FILE)" -f "$(DOCKER_COMPOSE_YML)" up -d  && \
		sleep 5 && \
		docker compose --env-file "$(DOCKER_ENV_FILE)" logs \
	; else \
		$(DOCKER_RUN) $(FLAGS) -dt $(CMD) \
	; fi

## exec: Run docker in foreground and then exit (treat like any Unix command)
##       if you need to pass arguments down then use the form
# note no --re needed we automaticaly do this and need for logs
#
.PHONY: exec
exec: stop docker-installed
	export $(EXPORTS) && \
	if [[ -r $(DOCKER_COMPOSE_YML) ]]; then \
		LOCAL_USER_ID=$(LOCAL_USER_ID) \
		docker compose --env-file "$(DOCKER_ENV_FILE)" -f "$(DOCKER_COMPOSE_YML)" up \
	; else \
		$(DOCKER_RUN) -t $(CMD) \
	; fi

# https://gist.github.com/mitchwongho/11266726
# Need entrypoint to make sure we get something interactive
# LOCAL_USER_ID=$(LOCAL_USER_ID) \
# The need for the host IP is to allow X-Windows support
# which allows openGL acceleration to the outer system
# For security there is a cookie stored in .Xauthority and the hostname has to
# resolve to the HOST IP. The cookie is opaque, but you can see the hostname
# on a Mac this is usually the HOSTNAME
	#export HOST_IP=$(HOST_IP) HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) && \
## shell: start and new container and run the interactive shell
.PHONY: shell
shell: docker-installed
	export $(EXPORTS) && \
	if [[ -r $(DOCKER_COMPOSE_YML) ]]; then \
		docker compose --env-file "$(DOCKER_ENV_FILE)" -f "$(DOCKER_COMPOSE_YML)" run "$(DOCKER_COMPOSE_MAIN)" /bin/bash; \
	else \
		docker pull $(IMAGE); \
		docker run -it \
			--entrypoint /bin/bash \
			--rm $(volumes) $(flags) $(IMAGE); \
	fi

## resume: keep running an existing container
.PHONY: resume
resume: docker-installed
	export $(EXPORTS) && \
	if [[ -r $(DOCKER_COMPOSE_YML) ]]; then \
		docker compose --env-file "$(DOCKER_ENV_FILE)" start; \
	else \
		docker start -ai $(container); \
	fi

# Note we say only the type file because otherwise it tries to delete $(docker_data) itself
## prune: Save some space on docker
.PHONY: prune
prune: docker-installed
	docker system prune --volumes
