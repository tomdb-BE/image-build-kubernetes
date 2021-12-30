SEVERITIES = HIGH,CRITICAL
SHELL := /bin/bash -x

ifeq ($(ARCH),)
ARCH=$(shell go env GOARCH)
endif

BUILD_META ?= -multiarch-build$(shell date +%Y%m%d)

ORG ?= rancher
PKG ?= github.com/kubernetes/kubernetes
SRC ?= github.com/kubernetes/kubernetes
TAG ?= v1.23.1-rke2r1$(BUILD_META)
K3S_ROOT_VERSION ?= v0.10.1
UBI_IMAGE ?= registry.access.redhat.com/ubi8/ubi-minimal:latest

GOLANG_VERSION := v1.17.5b7

.PHONY: image-build
image-build:
	docker build \
		--build-arg ARCH=$(ARCH) \
		--build-arg PKG=$(PKG) \
		--build-arg SRC=$(SRC) \
		--build-arg TAG=$(TAG) \
                --build-arg K3S_ROOT_VERSION=$(K3S_ROOT_VERSION) \
		--build-arg GO_IMAGE=$(ORG)/hardened-build-base:$(GOLANG_VERSION)-multiarch \
                --build-arg UBI_IMAGE=$(UBI_IMAGE) \
                --build-arg CALICO_VERSION=$(CALICO_VERSION) \
		--tag $(ORG)/hardened-kubernetes:$(TAG)-linux-$(ARCH) \
		.

.PHONY: all
all:
	docker build \
	--build-arg K8S_TAG=$(shell echo $(TAG) | grep -oP "^v(([0-9]+)\.([0-9]+)\.([0-9]+))") \
	--build-arg TAG=$(TAG) -t $(ORG)/hardened-kubernetes:$(shell echo $(TAG) | sed -e 's/+/-/g') .

.PHONY: image-push
image-push:
	docker push $(ORG)/hardened-kubernetes:$(TAG)-linux-$(ARCH) >> /dev/null

.PHONY: scan
image-scan:
	trivy --severity $(SEVERITIES) --no-progress --skip-update --ignore-unfixed $(ORG)/hardened-kubernetes:$(TAG)-linux-$(ARCH)

.PHONY: image-manifest
image-manifest:
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create --amend \
		$(ORG)/hardened-kubernetes:$(TAG) \
		$(ORG)/hardened-kubernetes:$(TAG)-linux-$(ARCH)
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest push \
		$(ORG)/hardened-kubernetes:$(TAG)
