#!/usr/bin/env bash

set -u
set -e
set -x

OCP_RELEASE=4.9.0-0.okd-2022-02-12-140851
LOCAL_REGISTRY="registry-1.ryax.org"
LOCAL_REPOSITORY="research/physics-openshift"
PRODUCT_REPO='openshift'
LOCAL_SECRET_JSON=$HOME/.docker/config.json
RELEASE_NAME="okd"

oc adm release mirror -a ${LOCAL_SECRET_JSON}  \
     --from=quay.io/${PRODUCT_REPO}/${RELEASE_NAME}:${OCP_RELEASE} \
     --to=${LOCAL_REGISTRY}/${LOCAL_REPOSITORY} \
     --to-release-image=${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}
