#Author sam
#Create in 2017/7/19

#!/bin/bash


kubectl delete deployment nginx-deployment
kubectl delete svc nginx
kubectl delete daemonset kube-keepalived-vip
kubectl delete configmap vip-configmap
