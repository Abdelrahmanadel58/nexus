1- NFS share the DATA:
mkdir /etcd-k8s
vi /etc/exports
/etcd-k8s  192.168.0.0/16(sync,rw,root_squash,no_all_squash)
exportfs -arv


2- Ha-proxy
hostnamectl set-hostname lb-k8s
yum install -y haproxy
systemctl disable --now firewalld.service
setenforce 0
vi /etc/haproxy/haproxy.cfg

#---------------------------------------------------------------------
# Example configuration for a possible web application.  See the
# full configuration options online.
#
#   https://www.haproxy.org/download/1.8/doc/configuration.txt
#
#---------------------------------------------------------------------

#---------------------------------------------------------------------
# Global settings
#---------------------------------------------------------------------
global
    # to have these messages end up in /var/log/haproxy.log you will
    # need to:
    #
    # 1) configure syslog to accept network log events.  This is done
    #    by adding the '-r' option to the SYSLOGD_OPTIONS in
    #    /etc/sysconfig/syslog
    #
    # 2) configure local2 events to go to the /var/log/haproxy.log
    #   file. A line like the following can be added to
    #   /etc/sysconfig/syslog
    #
    #    local2.*                       /var/log/haproxy.log
    #
    log         127.0.0.1 local2

    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon

    # turn on stats unix socket
    stats socket /var/lib/haproxy/stats

    # utilize system-wide crypto-policies
    ssl-default-bind-ciphers PROFILE=SYSTEM
    ssl-default-server-ciphers PROFILE=SYSTEM

#---------------------------------------------------------------------
# common defaults that all the 'listen' and 'backend' sections will
# use if not designated in their block
#---------------------------------------------------------------------
defaults
    mode                    http
    log                     global
    option                  httplog
    option                  dontlognull
    option http-server-close
    option forwardfor       except 127.0.0.0/8
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 3000

#---------------------------------------------------------------------
# main frontend which proxys to the backends
#---------------------------------------------------------------------
# frontend main
#     bind *:5000
#     acl url_static       path_beg       -i /static /images /javascript /stylesheets
#     acl url_static       path_end       -i .jpg .gif .png .css .js

#     use_backend static          if url_static
#     default_backend             app

frontend kubernetes
    bind *:6443
    option tcplog
    mode tcp
    default_backend kubernetes-master-nodes

# frontend http_front
#     mode http
#     bind *:80
#     default_backend http_back

# frontend https_front
#     mode http
#     bind *:443
#     default_backend https_back

#---------------------------------------------------------------------
# static backend for serving up images, stylesheets and such
#---------------------------------------------------------------------
# backend static
#     balance     roundrobin
#     server      static 127.0.0.1:4331 check

#---------------------------------------------------------------------
# round robin balancing between the various backends
#---------------------------------------------------------------------
# backend app
#     balance     roundrobin
#     server  app1 127.0.0.1:5001 check
#     server  app2 127.0.0.1:5002 check
#     server  app3 127.0.0.1:5003 check
#     server  app4 127.0.0.1:5004 check

backend kubernetes-master-nodes
    mode tcp
    balance roundrobin
    option tcp-check
    server k8s-master-0 k8s-master-0:6443 check fall 3 rise 2
#    server k8s-master-1 <kube-master1-ip>:6443 check fall 3 rise 2

# backend http_back
#     mode http
#     server k8s-master-0 k8s-master-0:32059 check fall 3 rise 2
#    server k8s-master-0 <kube-master0-ip>:32059 check fall 3 rise 2

# backend https_back
#     mode http
#     server k8s-master-0 k8s-master-0:32423 check fall 3 rise 2
#    server k8s-master-0 <kube-master0-ip>:32423 check fall 3 rise 2

systemctl enable --now haproxy.service

4- master
hostnamectl set-hostname k8s-master

yum install -y nfs-utils

mount -t nfs 192.168.150.128:/etcd-k8s /etcd-k8s

echo '############################################
      Remove the old version of Docker
      ############################################'
echo

yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc -y

echo
echo '############################################
      Disable SELinux enforcement
      ############################################'
echo

setenforce 0

sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux


echo
echo '###############################################
      Set bridged packets to traverse iptables rules
      ###############################################'
echo

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

echo 1 > /proc/sys/net/ipv4/ip_forward

sysctl --system

echo
echo '#################################################
      Disable all memory swaps to increase performance
      #################################################'
echo

swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab


echo
echo '####################################################################################################################
      Enable transparent masquerading and facilitate Virtual Extensible LAN (VxLAN) traffic for communication between Kubernetes pods across the cluster
      ####################################################################################################################'
echo

modprobe br_netfilter

echo
echo '#######################################################
      Add the repository for the docker installation package
      #######################################################'
echo

yum install -y yum-utils dnf
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y https://download.docker.com/linux/centos/7/x86_64/stable/Packages/containerd.io-1.2.6-3.3.el7.x86_64.rpm
dnf install -y docker-ce

echo
echo '########################################################
      Start the docker service
      ########################################################'
echo

systemctl start docker
systemctl enable docker

echo
echo '#######################################################
      Change docker to use systemd cgrouyp driver
      #######################################################'
echo

echo '{
  "exec-opts": ["native.cgroupdriver=systemd"]
}' > /etc/docker/daemon.json

systemctl restart docker

echo
echo '#######################################################################################
      Add the Kubernetes repository and  Install all the necessary components for Kubernetes
      #######################################################################################'
echo

touch /etc/yum.repos.d/kubernetes.repo
echo '[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-$basearch
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl' > /etc/yum.repos.d/kubernetes.repo

yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

echo
echo '#######################################################################################
      Start the Kubernetes services and enable them
      #######################################################################################'
echo

systemctl enable kubelet
systemctl start kubelet


echo
echo '#######################################################################################
      ensur that "iproute-tc" installed corructrlly
      #######################################################################################'
echo

yum install -y iproute-tc

echo
echo '#######################################################################################
      Configure kubeadm and creating cluster
      #######################################################################################'
echo

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl restart containerd


echo 'apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
etcd:
  # one of local or external
  local:
    dataDir: "/etcd-k8s"
kubernetesVersion: "v1.28.4"
controlPlaneEndpoint: "lb-k8s:6443"
apiServer:
  certSANs:
    - "lb-k8s"' > k8s-config.yml

kubeadm init --config=k8s-config.yml

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

echo
echo '#######################################################################################
      Setup Pod Network
      #######################################################################################'
echo

kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

3- worker
hostnamectl set-hostname worker

echo '############################################
      Remove the old version of Docker
      ############################################'
echo

yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc -y

echo
echo '#############################################
      Disable SELinux enforcement
      #############################################'
echo

setenforce 0

sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux


echo
echo '###############################################
      Set bridged packets to traverse iptables rules
      ###############################################'
echo

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

echo 1 > /proc/sys/net/ipv4/ip_forward

sysctl --system

echo
echo '#################################################
      Disable all memory swaps to increase performance
      #################################################'
echo

swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab


echo
echo '####################################################################################################################
      Enable transparent masquerading and facilitate Virtual Extensible LAN (VxLAN) traffic for communication between Kubernetes pods across the cluster
      ####################################################################################################################'
echo

modprobe br_netfilter

echo
echo '#######################################################
      Add the repository for the docker installation package
      #######################################################'
echo

yum install -y yum-utils dnf
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y https://download.docker.com/linux/centos/7/x86_64/stable/Packages/containerd.io-1.2.6-3.3.el7.x86_64.rpm
dnf install -y docker-ce

echo
echo '#######################################################
      Start the docker service
      #######################################################'
echo

systemctl start docker
systemctl enable docker

echo
echo '#######################################################
      Change docker to use systemd cgrouyp driver
      #######################################################'
echo

echo '{
  "exec-opts": ["native.cgroupdriver=systemd"]
}' > /etc/docker/daemon.json

systemctl restart docker

echo
echo '#######################################################################################
      Add the Kubernetes repository and  Install all the necessary components for Kubernetes
      #######################################################################################'
echo

touch /etc/yum.repos.d/kubernetes.repo
echo '[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-$basearch
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl' > /etc/yum.repos.d/kubernetes.repo

yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

echo
echo '#######################################################################################
      Start the Kubernetes services and enable them
      #######################################################################################'
echo

systemctl enable kubelet
systemctl start kubelet

echo
echo '#######################################################################################
      ensur that "iproute-tc" installed corructrlly
      #######################################################################################'
echo

yum install -y iproute-tc

echo
echo '#######################################################################################
      PREREQUISITES FOR WORKER NODES
      #######################################################################################'
echo

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl restart containerd
