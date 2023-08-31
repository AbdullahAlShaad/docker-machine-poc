#!/bin/bash

sudo su

export GCP_B64ENCODED_CREDENTIALS="{{ .EncodedCredential}}"
export GCP_REGION="{{ .Region }}"
export GCP_PROJECT="{{ .ProjectID }}"
export CLUSTER_NAME="{{ .ClusterName }}"
export GITHUB_TOKEN="{{ .GithubToken }}"
export GCP_NETWORK_NAME="{{ .NetworkName }}"
export SUBNET_CIDR="{{ .SubnetCIDR }}"

export EXP_CAPG_GKE=true
export EXP_MACHINE_POOL=true

export KUBERNETES_VERSION=1.23.6
export GCP_CONTROL_PLANE_MACHINE_TYPE=n1-standard-2
export GCP_NODE_MACHINE_TYPE=n1-standard-2
export WORKER_MACHINE_COUNT=3


HOME="/root"
cd ${HOME}

set -eou pipefail



#curl -fsSLO https://github.com/bytebuilders/nats-logger/releases/latest/download/nats-logger-linux-amd64.tar.gz
#tar -xzf nats-logger-linux-amd64.tar.gz
#chmod +x nats-logger-linux-amd64
#mv nats-logger-linux-amd64 nats-logger

exec >/root/script.log 2>&1
#SHIPPER_FILE=/root/stackscript.log ./nats-logger &

kind_version=v0.19.0
clusterctl_version=v1.3.5
cluster_namespace=kubedb-managed

# http://redsymbol.net/articles/bash-exit-traps/
# https://unix.stackexchange.com/a/308209
rollback() {
    kubectl delete cluster $CLUSTER_NAME -n $cluster_namespace || true
}

function finish {
    result=$?
    if [ $result -ne 0 ]; then
        rollback || true
    fi

    if [ $result -ne 0 ]; then
        echo "Cluster provision: Task failed !"
    else
        echo "Cluster provision: Task completed successfully !"
    fi

    sleep 5s

    [ ! -f /tmp/result.txt ] && echo $result >/tmp/result.txt
}
trap finish EXIT

#architecture
case $(uname -m) in
    x86_64)
        sys_arch=amd64
        ;;
    arm64 | aarch64)
        sys_arch=arm64
        ;;
    ppc64le)
        sys_arch=ppc64le
        ;;
    s390x)
        sys_arch=s390x
        ;;
    *)
        sys_arch=amd64
        ;;
esac

#opearating system
opsys=windows
if [[ "$OSTYPE" == linux* ]]; then
    opsys=linux
elif [[ "$OSTYPE" == darwin* ]]; then
    opsys=darwin
fi

timestamp() {
    date +"%Y/%m/%d %T"
}

log() {
    local type="$1"
    local msg="$2"
    local script_name=${0##*/}
    echo "$(timestamp) [$script_name] [$type] $msg"
}

retry() {
    local retries="$1"
    shift

    local count=0
    local wait=5
    until "$@"; do
        exit="$?"
        if [ $count -lt $retries ]; then
            log "INFO" "Attempt $count/$retries. Command exited with exit_code: $exit. Retrying after $wait seconds..."
            sleep $wait
        else
            log "INFO" "Command failed in all $retries attempts with exit_code: $exit. Stopping trying any further...."
            return $exit
        fi
        count=$(($count + 1))
    done
    return 0
}

#download docker from: https://docs.docker.com/engine/install/ubuntu/
install_docker() {
    echo "--------------updating apt--------------"
    apt-get -y update

    local cmnd="apt-get -y install ca-certificates curl gnupg lsb-release"
    retry 5 ${cmnd}

    echo "--------------installing docker--------------"
    mkdir -p /etc/apt/keyrings

    rm -rf /etc/apt/keyrings/docker.gpg

    cmnd="curl -fsSL https://download.docker.com/linux/ubuntu/gpg"
    retry 5 ${cmnd} | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    echo "repositories seted up:"

    apt-get -y update

    cmnd="apt-get -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin"
    retry 5 ${cmnd}
}

wait_for_docker() {

    while [[ -z "$(! docker stats --no-stream 2> /dev/null)" ]]; do
        echo "Waiting for docker to start"
        sleep 30s
    done
}

install_yq() {
    snap install yq
}

#install docker from: https://kind.sigs.k8s.io/docs/user/quick-start/#installing-from-source
install_kind() {
    echo "--------------creating kind--------------"

    local cmnd="curl -Lo ./kind https://kind.sigs.k8s.io/dl/${kind_version}/kind-linux-${sys_arch}"
    retry 5 ${cmnd}

    chmod +x ./kind

    cmnd="mv ./kind /usr/local/bin/kind"
    retry 5 ${cmnd}
}

create_kind_cluster() {
    #create cluster
    echo $(whoami)
    cmnd="kind delete cluster"
    retry 5 ${cmnd}

    sleep 5s

    kind create cluster
    kubectl wait --for=condition=ready pods --all -A --timeout=5m
}

#download kubectl from: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
install_kubectl() {
    echo "--------------installing kubectl--------------"
    ltral="https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl"
    local cmnd="curl -LO"
    retry 5 ${cmnd} ${ltral}

    ltral="https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl.sha256"
    cmnd="curl -LO"
    retry 5 ${cmnd} ${ltral}

    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

    cmnd="install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
    retry 5 ${cmnd}
}

#download clusterctl from: https://cluster-api.sigs.k8s.io/user/quick-start.html
install_clusterctl() {
    local cmnd="curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/${clusterctl_version}/clusterctl-${opsys}-${sys_arch} -o clusterctl"
    retry 5 ${cmnd}

    cmnd="install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl"
    retry 5 ${cmnd}

    clusterctl version
}

#download helm from apt (debian/ubuntu) https://helm.sh/docs/intro/install/
install_helm() {
    echo "--------------installing helm------------------"
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg >/dev/null
    apt-get install apt-transport-https --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | tee /etc/apt/sources.list.d/helm-stable-debian.list
    apt-get update
    apt-get install helm
}

# initialize the cluster with gcp infrastructure
init_gcp_infrastructure() {

    local cmnd="clusterctl init --infrastructure gcp"
    retry 5 ${cmnd}

    echo "waiting for pods to be ready"
    kubectl wait --for=condition=Ready pods -A --all --timeout=10m
}

# add subnet cidr to cluster template
configure_yaml() {
    curl -fsSLO https://github.com/bytebuilders/capi-config/releases/download/v0.0.1/capi-config-linux-amd64.tar.gz
    tar -xzf capi-config-linux-amd64.tar.gz
    cp capi-config-linux-amd64 /bin
    capi-config-linux-amd64 capg --subnet-cidr="${SUBNET_CIDR}" </root/cluster.yaml >/root/configured-cluster.yaml
}

create_gke_cluster() {
    echo "Creating gke Cluster"

    cmnd="clusterctl generate cluster"

    kubectl create ns $cluster_namespace

    retry 5 ${cmnd} ${CLUSTER_NAME} --flavor gke -n $cluster_namespace >/root/cluster.yaml

    configure_yaml

    kubectl apply -f /root/configured-cluster.yaml

    echo "creating cluster..."
    kubectl wait --for=condition=ready cluster --all -A --timeout=30m
    clusterctl get kubeconfig ${CLUSTER_NAME} -n $cluster_namespace >${HOME}/kubeconfig
}

add_appscode_helm_chart() {
    local cmnd="helm repo add appscode https://charts.appscode.com/stable/"
    retry 5 ${cmnd}

    local cmnd="helm repo update"
    retry 5 ${cmnd}
}

install_license_proxy_server() {
    echo "------------------installing proxyserver license-----------------------"
    local cmnd="helm upgrade --install license-proxyserver appscode/license-proxyserver --namespace kubeops --create-namespace --set platform.baseURL=https://api.byte.builders/ --set platform.token=427123d4a04bfe1c95e71a5f81384f7d6bf697ee --kubeconfig=${HOME}/kubeconfig"
    retry 5 ${cmnd}
}

install_external_dns_operator() {
    echo "------------------installing external dns operator-----------------------"
    local cmnd="helm upgrade -i external-dns-operator appscode/external-dns-operator -n kubeops --create-namespace --version=v2022.06.14 --kubeconfig=${HOME}/kubeconfig"
    retry 5 $cmnd
}

install_kubedb() {
    echo "------------------installing kubedb-----------------------"
    local cmnd="helm upgrade -i kubedb appscode/kubedb --version v2023.04.10 --namespace kubedb --create-namespace --set kubedb-provisioner.enabled=true --set kubedb-ops-manager.enabled=true --kubeconfig=${HOME}/kubeconfig"
    retry 5 ${cmnd}

    kubectl wait --for=condition=ready pods --all --namespace kubedb --timeout=10m --kubeconfig=${HOME}/kubeconfig
}

pivot_cluster() {
    local cmnd="clusterctl init --infrastructure gcp --kubeconfig=${HOME}/kubeconfig"
    retry 5 ${cmnd}
    kubectl wait --kubeconfig=${HOME}/kubeconfig --for=condition=ready pods --all --namespace capg-system --timeout=10m

    clusterctl move --to-kubeconfig=${HOME}/kubeconfig -n $cluster_namespace
}

# Temporary until capg release
update_capg_image() {
    local kubeconfig="$1"

    kubectl apply -f https://raw.githubusercontent.com/Shaad7/cluster-api-provider-gcp/main/config/crd/bases/infrastructure.cluster.x-k8s.io_gcpmanagedcontrolplanes.yaml --kubeconfig=${kubeconfig}

    local cmnd="kubectl set image -n capg-system deployment/capg-controller-manager manager=shaad7/cluster-api-gcp-controller-amd64:gcp --kubeconfig=${kubeconfig}"
    retry 5 ${cmnd}

    kubectl wait --for=condition=ready pods --all --namespace capg-system --timeout=10m --kubeconfig=${kubeconfig}

}

create_secret() {
    echo "Creating secret for crossplane"
    echo "$GCP_B64ENCODED_CREDENTIALS" | base64 --decode >/root/gcp-credentials.json
    local cmnd="kubectl create namespace crossplane-system --kubeconfig=${HOME}/kubeconfig"
    retry 5 ${cmnd}
    cmnd="kubectl create secret generic gcp-credential -n crossplane-system --from-file=crossplane-creds=/root/gcp-credentials.json --kubeconfig=${HOME}/kubeconfig"
    retry 5 ${cmnd}
}

init() {
    wait_for_docker
    install_yq
    install_kind
    install_kubectl
    sleep 60s
    create_kind_cluster
    install_clusterctl
    install_helm
    init_gcp_infrastructure
    update_capg_image "${HOME}/.kube/config"
    create_gke_cluster
    #    add_appscode_helm_chart
    #    install_license_proxy_server
    #    install_external_dns_operator
    #    install_kubedb

    pivot_cluster
    update_capg_image "${HOME}/kubeconfig"
    create_secret

}
init
