CONTAINER_ENGINE ?= podman
IMAGE ?= localhost/wrapvm:test
BUILD_FLAGS ?= --pull

.PHONY: check image base-image test test-base image.tar check-engine

check:
	bash tests/source_standalone.sh

# The Containerfile writes its scripts with RUN heredocs. Docker's legacy
# builder (no buildx/BuildKit) accepts them but writes empty files.
check-engine:
	@if [ "$$(basename "$(CONTAINER_ENGINE)")" = docker ] && ! $(CONTAINER_ENGINE) buildx version >/dev/null 2>&1; then \
	  echo "docker has no buildx, so it would use the legacy builder, which drops RUN heredocs." >&2; \
	  echo "Install docker-buildx, or run: make CONTAINER_ENGINE=podman" >&2; \
	  exit 1; \
	fi

image: check check-engine
	$(CONTAINER_ENGINE) build $(BUILD_FLAGS) -t $(IMAGE) -f Containerfile .

base-image: check check-engine
	$(CONTAINER_ENGINE) build $(BUILD_FLAGS) --target base -t $(IMAGE)-base -f Containerfile .

test-base: base-image
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/tests:/tests:ro" $(IMAGE)-base bash /tests/container_mise.sh base

# Desktop, viewer, accessibility and integration tests. Needs egress;
# every container is disposable.
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
