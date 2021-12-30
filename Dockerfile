ARG UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:latest
ARG GO_IMAGE=rancher/hardened-build-base:v1.17.5b7

FROM ${UBI_IMAGE} as ubi
FROM ${GO_IMAGE} as build
RUN set -x \
    && apk --no-cache add \
    bash \
    curl \
    file \
    git \
    libseccomp-dev \
    rsync \
    tar \
    make \
    gcc \
    py-pip

FROM build AS build-k8s-codegen
ARG TAG

COPY ./scripts/semver-parse.sh /semver-parse.sh
RUN chmod +x /semver-parse.sh

RUN git clone -b $(/semver-parse.sh ${TAG} all) --depth=1 https://github.com/kubernetes/kubernetes.git ${GOPATH}/src/kubernetes
WORKDIR ${GOPATH}/src/kubernetes

# force code generation
RUN make WHAT=cmd/kube-apiserver
# build statically linked executables
RUN echo "export MAJOR=$(/semver-parse.sh ${TAG} major)" \
    >> /usr/local/go/bin/go-build-static-k8s.sh
RUN echo "export MINOR=$(/semver-parse.sh ${TAG} minor)" \
    >> /usr/local/go/bin/go-build-static-k8s.sh
RUN echo "export GIT_COMMIT=$(git rev-parse HEAD)" \
    >> /usr/local/go/bin/go-build-static-k8s.sh
RUN echo "export KUBERNETES_VERSION=$(/semver-parse.sh ${TAG} k8s)" \
    >> /usr/local/go/bin/go-build-static-k8s.sh
RUN echo "export BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> /usr/local/go/bin/go-build-static-k8s.sh
RUN echo "export GO_LDFLAGS=\"-linkmode=external \
    -X k8s.io/component-base/version.gitVersion=\${KUBERNETES_VERSION} \
    -X k8s.io/component-base/version.gitMajor=\${MAJOR} \
    -X k8s.io/component-base/version.gitMinor=\${MINOR} \
    -X k8s.io/component-base/version.gitCommit=\${GIT_COMMIT} \
    -X k8s.io/component-base/version.gitTreeState=clean \
    -X k8s.io/component-base/version.buildDate=\${BUILD_DATE} \
    -X k8s.io/client-go/pkg/version.gitVersion=\${KUBERNETES_VERSION} \
    -X k8s.io/client-go/pkg/version.gitMajor=\${MAJOR} \
    -X k8s.io/client-go/pkg/version.gitMinor=\${MINOR} \
    -X k8s.io/client-go/pkg/version.gitCommit=\${GIT_COMMIT} \
    -X k8s.io/client-go/pkg/version.gitTreeState=clean \
    -X k8s.io/client-go/pkg/version.buildDate=\${BUILD_DATE} \
    \"" >> /usr/local/go/bin/go-build-static-k8s.sh
RUN echo 'go-build-static.sh -gcflags=-trimpath=${GOPATH}/src/kubernetes -mod=vendor -tags=selinux,osusergo,netgo ${@}' \
    >> /usr/local/go/bin/go-build-static-k8s.sh
RUN chmod -v +x /usr/local/go/bin/go-*.sh

FROM build-k8s-codegen AS build-k8s
ARG ARCH="amd64"
ARG K3S_ROOT_VERSION="v0.9.1"
ARG CALICO_VERSION="v3.20.1" 
ADD https://github.com/k3s-io/k3s-root/releases/download/${K3S_ROOT_VERSION}/k3s-root-${ARCH}.tar /opt/k3s-root/k3s-root.tar
RUN tar xvf /opt/k3s-root/k3s-root.tar -C /opt/k3s-root --wildcards --strip-components=2 './bin/aux/*tables*'
RUN tar xvf /opt/k3s-root/k3s-root.tar -C /opt/k3s-root './bin/ipset'

RUN go-build-static-k8s.sh -o bin/kube-apiserver           ./cmd/kube-apiserver
RUN go-build-static-k8s.sh -o bin/kube-controller-manager  ./cmd/kube-controller-manager
RUN go-build-static-k8s.sh -o bin/kube-scheduler           ./cmd/kube-scheduler
RUN go-build-static-k8s.sh -o bin/kube-proxy               ./cmd/kube-proxy
RUN go-build-static-k8s.sh -o bin/kubeadm                  ./cmd/kubeadm
RUN go-build-static-k8s.sh -o bin/kubectl                  ./cmd/kubectl
RUN go-build-static-k8s.sh -o bin/kubelet                  ./cmd/kubelet
RUN go-assert-static.sh bin/*
RUN if [ "${ARCH}" != "s390x" ]; then \
      go-assert-boring.sh bin/* ; \
    fi
RUN install -s bin/* /usr/local/bin/
RUN kube-proxy --version

FROM ubi AS ubi-updated
RUN microdnf update -y

FROM ubi-updated AS kubernetes
ARG ARCH="amd64"
# As ubi8 does not have conntrack-tools, install from centos8 (method used by Calico-node).
ADD https://raw.githubusercontent.com/projectcalico/calico/master/node/centos.repo /etc/yum.repos.d/
RUN rm /etc/yum.repos.d/ubi.repo                                                                   && \
    if [ "${ARCH}" == "arm64" ]; then sed -i 's/x86_64/aarch64/' /etc/yum.repos.d/centos.repo; fi  && \
    microdnf update -y                                                                             && \
    microdnf install which                                                                            \
    conntrack-tools                                                                                && \
    rm -rf /var/cache/yum

COPY --from=build-k8s /opt/k3s-root/aux/ /usr/sbin/
COPY --from=build-k8s /opt/k3s-root/bin/ /bin/
COPY --from=build-k8s /usr/local/bin/ /usr/local/bin/
