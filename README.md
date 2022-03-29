# Kubernetes Scheduler with container layer locality

We want to develop a container layer aware scheduler for Kubernetes. There is already an image locality plugin in the Kubernetes scheduler but it does not take into account layers in the image.

This plugin is located in `pkg/scheduler/framework/plugins/imagelocality` it the current Kubernetes codebase (02/2022).

The idea here is to modify the `imagelocality` plugin to:
- Get the layers available with there size (if possible) on each nodes at statup
- For each new pod compute a score regarding the cumulative size of already present layers

## Implementation

### The CRI config lead (CANCELED)
We have explore the code of the CRI interface and we find out that the CIO-O implmentation of the `ImageStatusRequest` with the `verbose` option give us a lot of information including layers id
https://github.com/cri-o/cri-o/blob/main/server/image_status.go#L77

This is return in a map in the `ImageStatusResponse` message:
https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto#L1284

> NOT WORKING:  We do not have layer size in the CRI Config object only some unrelated diff ids 

### CRI manifest

The CRI manifests do contains the layers and there size and are available at pull time.
See the OCI reference about manifest: https://github.com/opencontainers/image-spec/blob/main/manifest.md 

> Get a manifest example with:
> `docker manifest inspect python:3-alpine -v | jq .`

The idea is to get the layers info from the manifest and put in the `ImageSpec.annotations` field in the CRI API.
See: https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto#L673

To do so, we have to implemented a change of the internal Kubernetes interfaces to add the Layers information into Kubernetes core.v1 protocol. To propagate the layer information from the CRI interface to the internal `NodeStatus.Images` interface that is already accessible by the scheduler.

It is prototyped in this branch of our Kubernetes fork:
https://github.com/RyaxTech/kubernetes/tree/image-layer-locallity-scheduler

> To update protobuf based generated code in Kubernetes run:
> `hack/update-generated-protobuf.sh`

Then, we have to modify the CRI. We choose CRI-O as the CRI of reference because it is the one use by our testbed base on OpenShift which use CRI-O by default.

The layer information must come from the image pulled to the CRI interface. It is not possible by now, we need to find a way to get information from the manifest which contains layers digest and size to put it in CRI v1 protocol ImageSpec Annotation map with a prefix (See kubernetes implementation).

We have created a branch to do this work here:
https://github.com/RyaxTech/cri-o/tree/image-layer-locality-scheduler

CRI-O is now giving layers size in the CRI protocol Image annotations.

## Testing
### Use the Kubernetes scheduler simulator (discarded)

Kubernetes comunity is using a scheduler simulator for testing scheduling:
https://github.com/kubernetes-sigs/kube-scheduler-simulator

It is based on custom a apiserver, controller and pv controller. Thus this simulator is only usable if you create plugins that are not changing scheduler API (see comment [here](https://github.com/kubernetes-sigs/kube-scheduler-simulator/issues/8#issuecomment-941914456)).

Finnaly, it does not allows us to test our implementation inside kubernetes without modifing the simulator itself to reflect the internal changes we've made.

### CRI-O alone

Pull the our cri-o fork with:
```
git pull https://github.com/RyaxTech/cri-o
git checkout image-layer-locality-scheduler
cd cri-o
```
Build cri-o with Nix:
```sh
nix build -f nix
```
Start Cri-o:
```sh
sudo --preserve-env=PATH ./result/bin/crio --log-dir /tmp/cri-o/logs --root /tmp/cri-o/root --log-level debug --signature-policy test/policy.json
```


Pull an image and query CRI-O through the CRI API: 
```sh
sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock pull docker.io/library/debian:latest
sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock pull docker.io/library/python:latest
sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock images -o json
```

You should see that the annotation map contains one common key because the python image is based on debian. The common layer is:
```
"imageLayer.sha256:0c6b8ff8c37e92eb1ca65ed8917e818927d5bf318b6f18896049b5d9afc28343": "54917164",
```

#### (Optional) Create container images for custom K8s services


> Only do this step if you have modified the Kubernetes code. Mind to update the version...
{.is-info}

Pull the our Kubernetes fork with:
```
git pull https://github.com/RyaxTech/kubernetes
git checkout image-layer-locality-scheduler
cd kubernetes
```

Build kubernetes binaries with embeded libc to avoid portability issues:
```sh
CGO_ENABLED=0 make all
```

Create a docker file for the kubernetes api server
```
cat > _output/Dockerfile.kube-apiserver <<EOF
FROM busybox
ADD ./local/bin/linux/amd64/kube-apiserver /usr/local/bin/kube-apiserver
EOF
```
```
docker build -t ryaxtech/kube-apiserver:latest --file _output/Dockerfile.kube-apiserver  ./_output
docker push ryaxtech/kube-apiserver:latest
docker tag ryaxtech/kube-apiserver:latest ryaxtech/kube-apiserver:v1.22.6
docker push ryaxtech/kube-apiserver:v1.22.6
```
Create a docker file for the kubernetes controller
```
cat > _output/Dockerfile.kube-controller-manager <<EOF
FROM busybox
ADD ./local/bin/linux/amd64/kube-controller-manager /usr/local/bin/kube-controller-manager
EOF
```
```
docker build -t ryaxtech/kube-controller-manager:latest --file _output/Dockerfile.kube-controller-manager  ./_output
docker push ryaxtech/kube-controller-manager:latest
docker tag ryaxtech/kube-controller-manager:latest ryaxtech/kube-controller-manager:v1.22.6
docker push ryaxtech/kube-controller-manager:v1.22.6
```

Create a dockerfile for the scheduler
```
cat > _output/Dockerfile.kube-scheduler <<EOF
FROM busybox
ADD ./local/bin/linux/amd64/kube-scheduler /usr/local/bin/kube-scheduler
EOF
```
```
docker build -t ryaxtech/kube-scheduler-llocality:latest --file _output/Dockerfile.kube-scheduler  ./_output
docker push ryaxtech/kube-scheduler-llocality:latest
docker tag ryaxtech/kube-scheduler-llocality:latest ryaxtech/kube-scheduler-llocality:v1.22.6
docker push ryaxtech/kube-scheduler-llocality:v1.22.6
```

### Test in a Kind cluster

> The previous step should have bin done first because it requires `./result/bin/crio` to be already created.
{.is-warning}

Create a config for the kind cluster to use Cri-o and our custom images:
```
cat > kind-crio.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: quay.io/aojea/kindnode:crio1639620432
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      criSocket: unix:///var/run/crio/crio.sock
  - |
    kind: JoinConfiguration
    nodeRegistration:
      criSocket: unix:///var/run/crio/crio.sock
  - |
    kind: ClusterConfiguration
    kubernetesVersion: 1.22.6
    imageRepository: docker.io/ryaxtech
- role: worker
  image: quay.io/aojea/kindnode:crio1639620432
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      criSocket: unix:///var/run/crio/crio.sock
- role: worker
  image: quay.io/aojea/kindnode:crio1639620432
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      criSocket: unix:///var/run/crio/crio.sock
EOF
```

> Only tested with kind version `0.11.1`
{.is-info}

Create the cluster:
```
kind create cluster --name crio --config kind-crio.yaml
```

Inside the cri-o repository, replace the Cri-o executable by ours with:
``` 
for n in $(kind get nodes --name crio); do
  docker cp ./result/bin/crio $n:/usr/bin/crio
  docker exec $n systemctl restart crio
  sleep 1
  docker exec $n systemctl status crio
done
```

Check if this work with:
```
docker exec -ti crio-control-plane crictl --runtime-endpoint unix:///var/run/crio/crio.sock images -o json
```
You should see this kind of annotations:
```
        "annotations": {
          "imageLayer.sha256:b0e18b6da7595b49270553e8094411bdf070f95866b3f33de252d02c157a1bc7": "15879307",
          "imageLayer.sha256:d256164d794efdde4db53b59b83dd6c13cabf639c7cac7b747903f8e921e32c9": "23796084"
        }
```

Inside the kubernetes repository, push the kubelet in all nodes:
```
for n in $(kind get nodes --name crio); do
  docker cp  _output/local/bin/linux/amd64/kubelet $n:/usr/bin/kubelet
  docker exec $n systemctl restart kubelet
  sleep 1
  docker exec $n systemctl status kubelet
done
```

Fix the coredns image name (use a hardcoded subpath `coredns/coredns` unsupported by dockerhub):
```
kubectl set image -n kube-system deployment/coredns coredns=docker.io/ryaxtech/coredns:v1.8.0
```

### Test in OpenShift

To be able to install our custom Kubernetes and Cri-O versions into OpenShift
we have to tweak some Openshift elements:
- the Fedora CoreOS (FCOS) image used by OKD to add our modified cri-o and kubelet.
- the containers of the Kubernetes control plane (api-server and
  controller-manager)
- the installer configuration to use our custom container images. Doc reference on customization:
  https://github.com/openshift/installer/blob/master/docs/user/customization.md#image-content-sources

#### Mirroring the images

To be able to customize the OKD (OpenShift Kubernetes Distribution) we have to
use custom images with our modified Kubernetes version instead of the official
ones.

> Selete the OKD version by setting the VERSION with one of the image tag of the repository:
> https://quay.io/repository/openshift/okd?tab=tags

To do so, first we copy **all** the official images from the RedHat OKD
repository to our own custom repository with the script (10GB
of disk space is required):
```sh
./mirror-images.sh
```

#### Create custom image for Kubernetes

First, create a backup of the Hyperkube image that contains all the Kubernetes
binaries.
```sh
docker pull registry-1.ryax.org/research/physics-openshift:hyperkube
docker tag registry-1.ryax.org/research/physics-openshift:hyperkube registry-1.ryax.org/research/physics-openshift:hyperkube-old
docker push registry-1.ryax.org/research/physics-openshift:hyperkube-old
```

**Put all the modified binaries in the local `./bin` directory.**

Now create the custom image with this Dockerfile:
```sh
FROM registry-1.ryax.org/research/physics-openshift:hyperkube-old

ADD ./bin/kube-apiserver /usr/bin/kube-apiserver
ADD ./bin/kube-controller-manager /usr/bin/kube-controller-manager
ADD ./bin/kubelet /usr/bin/kubelet
```
Build it with
```sh
docker build . -t registry-1.ryax.org/research/physics-openshift:hyperkube
docker push registry-1.ryax.org/research/physics-openshift:hyperkube
```

#### Create custom image for FCOS (Cri-o)

To add our own Cri-O to the FCOS image we need to create an RPM repository with
our packages inside.

The full process is:
1. [X] create a RPM package for Cri-o
2. [ ] create a RPM package for kubelet
3. [-] include this package in fork of OKD FCOS image
4. [ ] build the new image and make it accessible
5. [ ] configure the openshift installer to use our custom FCOS

##### Create Crio RPM with Nix (ABANDONED)

Build the RPM package for Cri-O with:
```
nix bundle -f ./nix --bundler github:NixOS/bundlers#toRPM
```

But with the nix approach the RPM generated package was not compatible with
rpm-ostree:
```
(rpm-ostree compose tree:242): GLib-WARNING **: 08:12:45.147: GError set over the top of a previous GError or uninitialized memory.                                                                                                                                                       
This indicates a bug in someone's code. You must ensure an error is NULL before it's set.                                                                                                                                                                                                 
The overwriting error message was: Analyzing /nix/store/xwlbvhhaqvccakfvvf5y4jbk5a5y8vqd-cyrus-sasl-2.1.27/lib/sasl2/libplain.la: Unsupported path; see https://github.com/projectatomic/rpm-ostree/issues/233
```

##### Create Cri-o RPM from the source RPM

Create a tarball of the Cri-o source on the right format:
```sh
mkdir rpms-source
pushd $CRIO_SOURCE_DIR
tar --exclude-vcs --exclude-vcs-ignores --exclude="_output" --exclude="build" -cvzf cri-o.tar.gz ./cri-o-1.23.2
popd
cp $CRIO_SOURCE_DIR/cri-o.tar.gz ./rpms-source
```
Get the source RPM and unpack the it with:
```sh
cd rpms-source
wget https://fr2.rpmfind.net/linux/fedora/linux/development/rawhide/Everything/source/tree/Packages/c/cri-o-1.23.2-1.fc37.src.rpm
rpm2cpio cri-o-1.23.2-1.fc37.src.rpm | cpio -idmv --no-absolute-filenames
```
Run a container with fedora to have the RPM tools:
```sh
podman run -ti -v $PWD:/tmp/host -v fedora
```
Inside that container install dependencies:
```sh
yum install -y btrfs-progs-devel device-mapper-devel git-core glib2-devel glibc-static go-md2man go-rpm-macros gpgme-devel libassuan-devel libseccomp-devel make systemd-rpm-macros
```
Change the spec file so it uses our tarball (line 45-46):
```
URL:            https://github.com/RyaxTech/cri-o
Source0:        %{name}.tar.gz
```

Now run the build:
```sh
cd /tmp/host
rpmbuild -ba -r $PWD/build cri-o.spec
```

Copy it the final rpm repo:
```sh
mkdir -m 777 rpms
cp RPMS/* ./rpms
```
##### Create Kubelet RPM from the source RPM

> TODO


#### Build the FCOS image

Reference:
https://blog.cubieserver.de/2021/building-a-custom-okd-machine-os-image/

Get our version of the okd machine repo and put the rpms in it:
```
git pull https://github.com/RyaxTech/okd-machine-os
cd okd-machine-os
cp -r ../rpms .
```

Do the build of FCOS (change the user/registry/repo if
needed):
```sh
podman build -f Dockerfile.cosa -t fcos-builder
export REGISTRY_PASSWORD=$(cat $HOME/.docker/config.json | jq '.auths["registry-1.ryax.org"].auth' -r | base64 -d | cut -f2 -d':')
podman run -e REGISTRY_PASSWORD -e USERNAME=michael.mercier -e REGISTRY=registry-1.ryax.org -e REPOSITORY=research -e VERSION=411.35.test -v /dev/kvm:/dev/kvm --privileged -ti --entrypoint /bin/sh localhost/fcos-builder -i
```
In the container run:
```sh
# Patch the coreos assembler to avoid this error:
# tar: ./tmp/build/coreos-assembler-config.tar.gz: file changed as we read it
RUN sed -i 's#--exclude-vcs#--exclude-vcs --exclude=./tmp/build/coreos-assembler-config.tar.gz#' /usr/lib/coreos-assembler/cmdlib.sh
./entrypoint.sh
```

> This is failing with 

#### On Azure

Not possible using the openshift-installer due to this bug:
https://github.com/openshift/installer/issues/4986

#### On AWS

TODO


#### Testing scenario

- We consider two images:
- Img1: Layers: L1, L2, L3
- Img2: Layers: L1, L2, L4
- Three homogeneous nodes: N1, N2 and N3
- Two pods: P1 using Img1 and P2 using Img2 both requesting all the node resources
- Considering an empty cluster with no layers of Img1 and Img2 in cache.

1. At time `t0` we submit P1
	 => e.g. It goes to node N1
2. At time `t1` we submit P2
   => e.g. It goes to node N2
3. At time `t2` we remove P2
4. At time `t3` we submit P1 again
   => **goes to the N2 node P2 was scheduled because layers are already present**

## TODO list
- [X] Make a verbose ImageStatusRequest to get all the informations about the layers and see if we have all we need
  => We do not have layer size in he CRIConfig so we have to modify CRI-O to send these information (layers id and size)
- [X] Modify Kubernetes to expose layer information to the scheduler: Done in the ContainerImage structure
- [X] Modify CRI-O to get layer info from the manifest and put it in the imageList CRI call return
- [X] Modify the scheduler to use layers information of already scheduled image to compute the new score based on layers
- [X] Setup a testing Kubernetes environment (with documented process)
- [X] Find a way to query all nodes with an ImageStatusRequest at scheduler startup and keep a map of image/layers association and another of node/layers association (which can be computed from the first one and the image/node association given by the scheduler framework objects).
- [ ] Find a way to demonstrate and evaluate the scheduling impact
- [ ] Check on performance impact of the scheduler and reduce it as much as possible
