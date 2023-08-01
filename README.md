# docker-machine-poc

## Export Credential
```bash
export GOOGLE_APPLICATION_CREDENTIALS=/home/shaad/go/src/github.com/Shaad7/capi-basics/gcp/gcp-cred.json
```

## Run the docker-machine command
```bash
docker-machine create --driver google \
--google-project appscode-testing \
--google-zone us-central1-a \
--google-machine-type n1-standard-2 \
--google-machine-image ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20230714 \
--google-userdata capg_gke_cluster_create.sh\
rancher-vm
```

## When run this from ubuntu pod

- Copy the script, credential and `docker-machine` binary in the pod
- Run the command `apt-get update && apt-get install ca-certificates -y` to install ca-certificates
- Run the docker machine command