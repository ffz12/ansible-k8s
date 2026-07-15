#!/bin/bash


docker run --privileged --rm tonistiigi/binfmt --install all


docker buildx create \
  --name mybuilder \
  --use \
  --bootstrap \
  --driver docker-container \
  --driver-opt image=moby/buildkit:latest \
  --driver-opt network=host \
  --buildkitd-flags '--allow-insecure-entitlement network.host'\
  --config ./buildkitd.toml 
  
