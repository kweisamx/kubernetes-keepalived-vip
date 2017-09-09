# keepalived-vip

Kubernetes 使用[keepalived](http://www.keepalived.org)來產生虛擬IP address

我們將探討如何利用[IPVS - The Linux Virtual Server Project](http://www.linuxvirtualserver.org/software/ipvs.html)"來kubernetes配置VIP


## 前言

kubernetes v1.6版提供了三種方式去暴露Service：

1. **L4的LoadBalacncer** :只能再[cloud providers](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/)上被使用 像是GCE或AWS
2. **NodePort** : [NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport)允許再每個節點上開啟一個port口,借由這個port口會再將請求導向到隨機的pod上
3. **L7 Ingress** :[Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) 為一個LoadBalancer(例:nginx, HAProxy, traefik, vulcand)會將HTTP/HTTPS的各個請求導向到相對應的service endpoint

有了這些方式,為何我們還需要 _keepalived_ ?

```
                                                  ___________________
                                                 |                   |
                                           |-----| Host IP: 10.4.0.3 |
                                           |     |___________________|
                                           |
                                           |      ___________________
                                           |     |                   |
Public ----(example.com = 10.4.0.3/4/5)----|-----| Host IP: 10.4.0.4 |
                                           |     |___________________|
                                           |
                                           |      ___________________
                                           |     |                   |
                                           |-----| Host IP: 10.4.0.5 |
                                                 |___________________|
```

我們假設Ingress運行再3個kubernetes 節點上,並對外暴露`10.4.0.x`的IP去做loadbalance

DNS Round Robin (RR) 將對應到`example.com`的請求輪循給這3個節點,如果`10.4.0.3`掛了,仍有三分之一的流量會導向`10.4.0.3`,這樣就會有一段downtime,直到DNS發現`10.4.0.3`掛了並修正導向

嚴格來說,這並沒有真正的做到High Availability (HA)

這邊IPVS可以幫助我們解決這件事,這個想法是虛擬IP(VIP)對應到每個service上,並將VIP暴露到kubernetes群集之外

### 與 [service-loadbalancer](https://github.com/kubernetes/contrib/tree/master/service-loadbalancer)或[nginx](https://github.com/kubernetes/ingress/tree/master/controllers/nginx) 的區別

我們看到以下的圖


```
                                               ___________________
                                              |                   |
                                              | VIP: 10.4.0.50    |
                                        |-----| Host IP: 10.4.0.3 |
                                        |     | Role: Master      |
                                        |     |___________________|
                                        |
                                        |      ___________________
                                        |     |                   |
                                        |     | VIP: Unassigned   |
Public ----(example.com = 10.4.0.50)----|-----| Host IP: 10.4.0.3 |
                                        |     | Role: Slave       |
                                        |     |___________________|
                                        |
                                        |      ___________________
                                        |     |                   |
                                        |     | VIP: Unassigned   |
                                        |-----| Host IP: 10.4.0.3 |
                                              | Role: Slave       |
                                              |___________________|
```

我們可以看到只有一個node被選為Master(透過VRRP選擇的),而我們的VIP是`10.4.0.50`,如果`10.4.0.3`掛掉了,那會從剩余的節點中選一個成為Master並接手VIP,這樣我們就可以確保落實真正的HA

## 環境需求

只需要確認要運行keepalived-vip的kubernetes群集[DaemonSets](https://github.com/kubernetes/kubernetes/blob/master/docs/design/daemon.md)功能是正常的就行了

### RBAC

由於kubernetes在1.6後引進了RBAC的概念,所以我們要先去設定rule,至於有關RBAC的詳情請至[說明](https://feisky.gitbooks.io/kubernetes/plugins/auth.html)


vip-rbac.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  name: kube-keepalived-vip
rules:
- apiGroups: [""]
  resources:
  - pods
  - nodes
  - endpoints
  - services
  - configmaps
  verbs: ["get", "list", "watch"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-keepalived-vip 
  namespace: default 
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: kube-keepalived-vip
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-keepalived-vip
subjects:
- kind: ServiceAccount
  name: kube-keepalived-vip
  namespace: default
```

clusterrolebinding.yaml


```yaml
apiVersion: rbac.authorization.k8s.io/v1alpha1
kind: ClusterRoleBinding
metadata:
  name: kube-keepalived-vip
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-keepalived-vip
subjects:
  - kind: ServiceAccount
    name: kube-keepalived-vip
    namespace: default
```

```sh
$ kubectl create -f vip-rbac.yaml
$ kubectl create -f clusterrolebinding.yaml
```

## 示例



先建立一個簡單的service


nginx-deployment.yaml
```yaml
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  type: NodePort
  ports:
  - port: 80
    nodePort: 30302
    targetPort: 80
    protocol: TCP
    name: http
  selector:
    app: nginx
```

主要功能就是pod去監聽聽80 port,再開啟service NodePort監聽30320


```sh
$ kubecrl create -f nginx-deployment.yaml
```
接下來我們要做的是config map


```sh
$ echo "apiVersion: v1
kind: ConfigMap
metadata:
  name: vip-configmap
data:
  10.87.2.50: default/nginx" | kubectl create -f -
```


註意,這邊的```10.87.2.50``` 必須換成你自己同網段下無使用的IP e.g. 10.87.2.X
後面```nginx```為service的name,這邊可以自行更換

接著確認一下
```sh
$kubectl get configmap 
NAME            DATA      AGE
vip-configmap   1         23h

```

再來就是設置keepalived-vip

```yaml

apiVersion: extensions/v1beta1
kind: DaemonSet
metadata:
  name: kube-keepalived-vip
spec:
  template:
    metadata:
      labels:
        name: kube-keepalived-vip
    spec:
      hostNetwork: true
      containers:
        - image: gcr.io/google_containers/kube-keepalived-vip:0.9
          name: kube-keepalived-vip
          imagePullPolicy: Always
          securityContext:
            privileged: true
          volumeMounts:
            - mountPath: /lib/modules
              name: modules
              readOnly: true
            - mountPath: /dev
              name: dev
          # use downward API
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          # to use unicast
          args:
          - --services-configmap=default/vip-configmap
          # unicast uses the ip of the nodes instead of multicast
          # this is useful if running in cloud providers (like AWS)
          #- --use-unicast=true
      volumes:
        - name: modules
          hostPath:
            path: /lib/modules
        - name: dev
          hostPath:
            path: /dev
```


建立daemonset

```sh
$ kubectl get daemonset kube-keepalived-vip 
NAME                  DESIRED   CURRENT   READY     UP-TO-DATE   AVAILABLE   NODE-SELECTOR   AGE
kube-keepalived-vip   5         5         5         5            5           
```

檢查一下配置狀態

```sh
kubectl get pod -o wide |grep keepalive
kube-keepalived-vip-c4sxw         1/1       Running            0          23h       10.87.2.6    10.87.2.6
kube-keepalived-vip-c9p7n         1/1       Running            0          23h       10.87.2.8    10.87.2.8
kube-keepalived-vip-psdp9         1/1       Running            0          23h       10.87.2.10   10.87.2.10
kube-keepalived-vip-xfmxg         1/1       Running            0          23h       10.87.2.12   10.87.2.12
kube-keepalived-vip-zjts7         1/1       Running            3          23h       10.87.2.4    10.87.2.4
```
可以隨機挑一個pod,去看裏面的配置

```sh
 $ kubectl exec kube-keepalived-vip-c4sxw cat /etc/keepalived/keepalived.conf
 
 
global_defs {
  vrrp_version 3
  vrrp_iptables KUBE-KEEPALIVED-VIP
}
 
vrrp_instance vips {
  state BACKUP
  interface eno1
  virtual_router_id 50
  priority 103
  nopreempt
  advert_int 1
 
  track_interface {
    eno1
  }
 
 
 
  virtual_ipaddress { 
    10.87.2.50
  }
}
 
 
# Service: default/nginx
virtual_server 10.87.2.50 80 { //此為service開的口
  delay_loop 5
  lvs_sched wlc
  lvs_method NAT
  persistence_timeout 1800
  protocol TCP
 
 
  real_server 10.2.49.30 8080 { //這裏說明 pod的真實狀況
    weight 1
    TCP_CHECK {
      connect_port 80
      connect_timeout 3
    }
  }
 
}
 
```

最後我們去測試這功能

```sh
$ curl  10.87.2.50
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body {
        width: 35em;
        margin: 0 auto;
        font-family: Tahoma, Verdana, Arial, sans-serif;
    }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>

```

10.87.2.50:80(我們假設的VIP,實際上其實沒有node是用這IP)即可幫我們導向這個service


以上的程式代碼都在[github](https://github.com/kubernetes/contrib/tree/master/keepalived-vip)上可以找到。

## 參考文檔

- [kweisamx/kubernetes-keepalived-vip](https://github.com/kweisamx/kubernetes-keepalived-vip)
- [kubernetes/keepalived-vip](https://github.com/kubernetes/contrib/tree/master/keepalived-vip)
