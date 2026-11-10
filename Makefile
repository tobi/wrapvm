CONTAINER_ENGINE ?= podman
IMAGE ?= localhost/wrapvm:test
# BASE_IMAGE overrides the Containerfile's base. On arm64 it is tobi/wrap's
# Containerfile.arm64 build, since ghcr.io/tobi/wrap:latest is amd64-only:
#   make test CONTAINER_ENGINE=docker BASE_IMAGE=wrap-arm64:local
# --pull is dropped in that case: a locally built base is in no registry.
BASE_IMAGE ?=

.PHONY: image test image.tar check-engine

# The Containerfile writes its scripts with RUN heredocs. Docker's legacy
# builder (no buildx/BuildKit) accepts them but writes empty files.
check-engine:
	@if [ "$$(basename "$(CONTAINER_ENGINE)")" = docker ] && ! $(CONTAINER_ENGINE) buildx version >/dev/null 2>&1; then \
	  echo "docker has no buildx, so it would use the legacy builder, which drops RUN heredocs." >&2; \
	  echo "Install docker-buildx, or run: make CONTAINER_ENGINE=podman" >&2; \
	  exit 1; \
	fi

image: check-engine
	$(CONTAINER_ENGINE) build $(if $(BASE_IMAGE),--build-arg BASE_IMAGE=$(BASE_IMAGE),--pull) \
	  -t $(IMAGE) -f Containerfile .

# wrap's desktop tests (tests/container_{mise,viewer,a11y,desktop}*, from
# tobi/wrap), then what wrapvm adds. Needs egress; every container is disposable.
test: image
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/tests:/tests:ro" $(IMAGE) bash /tests/container_mise.sh desktop
	$(CONTAINER_ENGINE) run --rm --network none -e MISE_OFFLINE=1 -v "$(CURDIR)/tests:/tests:ro" $(IMAGE) bash /tests/container_viewer.sh
	$(CONTAINER_ENGINE) run --rm --network none $(IMAGE) sh -lc 'd=$$(mktemp -d); HOME=$$d agent-browser --version >/dev/null && HOME=$$d agent-desktop version >/dev/null'
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" bash tests/container_a11y_run.sh $(IMAGE)
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" bash tests/container_desktop_run.sh $(IMAGE)
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/tests:/tests:ro" $(IMAGE) bash -l /tests/container_wrapvm.sh

# A local build for smolvm before CI has published it:
#   make image.tar && WRAPVM_IMAGE=$PWD/wrapvm.tar ./wrapvm
image.tar: image
	$(CONTAINER_ENGINE) save --format docker-archive -o wrapvm.tar $(IMAGE)
