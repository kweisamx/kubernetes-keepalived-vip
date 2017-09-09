# Author :Sam Zheng
# Create in 2017/7/20
# it is used for create keepalived vip
#!/bin/bash



kubectl create -f nginx-deployment.yaml
kubectl create -f vip-configmap.yaml
kubectl create -f vip-ds.yaml




