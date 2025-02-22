#!/bin/bash
# Author: Jrohy
# Github: https://github.com/Jrohy/k8s-install

# cancel centos alias
[[ -f /etc/redhat-release ]] && unalias -a

# 判断cpu架构
[[ `uname -m` == "x86_64" ]] && ARCHITECTURE="amd64" || ARCHITECTURE="arm64"

#######color code########
RED="31m"      
GREEN="32m"  
YELLOW="33m" 
BLUE="36m"
FUCHSIA="35m"

GOOGLE_URLS=(
    packages.cloud.google.com
    k8s.gcr.io
    gcr.io
)

DOCKER_IMAGE_SOURCE=(
    mirrorgooglecontainers
    googlecontainer
)

CAN_GOOGLE=1

IS_MASTER=0

HELM=0

NETWORK=""

K8S_VERSION=""

colorEcho(){
    COLOR=$1
    echo -e "\033[${COLOR}${@:2}\033[0m"
}

ipIsConnect(){
    ping -c2 -i0.3 -W1 $1 &>/dev/null
    if [ $? -eq 0 ];then
        return 0
    else
        return 1
    fi
}

runCommand(){
    echo ""
    COMMAND=$1
    colorEcho $GREEN $1
    eval $1
}

setHostname(){
    local HOSTNAME=$1
    if [[ $HOSTNAME =~ '_' ]];then
        colorEcho $YELLOW "hostname can't contain '_' character, auto change to '-'.."
        HOSTNAME=`echo $HOSTNAME|sed 's/_/-/g'`
    fi
    echo "set hostname: `colorEcho $BLUE $HOSTNAME`"
    echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
    runCommand "hostnamectl --static set-hostname $HOSTNAME"
}

#######get params#########
while [[ $# > 0 ]];do
    KEY="$1"
    case $KEY in
        --hostname)
        setHostname $2
        shift
        ;;
        --flannel)
        echo "use flannel network, and set this node as master"
        NETWORK="flannel"
        IS_MASTER=1
        ;;
        --calico)
        echo "use calico network, and set this node as master"
        NETWORK="calico"
        IS_MASTER=1
        ;;
        --helm)
        echo "install Helm, only use in master node"
        HELM=1
        ;;
        -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "   --flannel                    use flannel network, and set this node as master"
        echo "   --calico                     use calico network, and set this node as master"
        echo "   --helm                       install helm, only use in master node"
        echo "   --hostname [HOSTNAME]        set hostname"
        echo "   -h, --help:                  find help"
        echo ""
        exit 0
        shift # past argument
        ;; 
        *)
                # unknown option
        ;;
    esac
    shift # past argument or value
done
#############################

checkSys() {
    #检查是否为Root
    [ $(id -u) != "0" ] && { colorEcho ${RED} "Error: You must be root to run this script"; exit 1; }

    #检查CPU核数
    [[ `cat /proc/cpuinfo |grep "processor"|wc -l` == 1 && $IS_MASTER == 1 ]] && { colorEcho ${RED} "master node cpu number should be >= 2!"; exit 1;}

    #检查系统信息
    if [[ -e /etc/redhat-release ]];then
        if [[ $(cat /etc/redhat-release | grep Fedora) ]];then
            OS='Fedora'
            PACKAGE_MANAGER='dnf'
        else
            OS='CentOS'
            PACKAGE_MANAGER='yum'
        fi
    elif [[ $(cat /etc/issue | grep Debian) ]];then
        OS='Debian'
        PACKAGE_MANAGER='apt-get'
    elif [[ $(cat /etc/issue | grep Ubuntu) ]];then
        OS='Ubuntu'
        PACKAGE_MANAGER='apt-get'
    else
        colorEcho ${RED} "Not support OS, Please reinstall OS and retry!"
        exit 1
    fi

    [[ `cat /etc/hostname` =~ '_' ]] && setHostname `cat /etc/hostname`

    echo "Checking machine network(access google)..."
    for ((i=0;i<${#GOOGLE_URLS[*]};i++))
    do
        ipIsConnect ${GOOGLE_URLS[$i]}
        if [[ ! $? -eq 0 ]]; then
            colorEcho ${YELLOW} "server can't access google source, switch to chinese source(aliyun).."
            CAN_GOOGLE=0
            break	
        fi
    done

}

#安装依赖
installDependent(){
    if [[ ${OS} == 'CentOS' || ${OS} == 'Fedora' ]];then
        ${PACKAGE_MANAGER} install bash-completion -y
    else
        ${PACKAGE_MANAGER} update
        ${PACKAGE_MANAGER} install dirmngr -y
        ${PACKAGE_MANAGER} install bash-completion apt-transport-https gpg gpg-agent -y
    fi
}

prepareWork() {
    ## Centos设置
    if [[ ${OS} == 'CentOS' || ${OS} == 'Fedora' ]];then
        if [[ `systemctl list-units --type=service|grep firewalld` ]];then
            systemctl disable firewalld.service
            systemctl stop firewalld.service
        fi
        cat <<EOF >  /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
        sysctl --system
    fi
    ## 禁用SELinux
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
    ## 关闭swap
    swapoff -a
    sed -i 's/.*swap.*/#&/' /etc/fstab

    ## 安装最新版docker
    if [[ ! $(type docker 2>/dev/null) ]];then
        colorEcho ${YELLOW} "docker no install, auto install latest docker..."
        while :
        do
            if [[ $CAN_GOOGLE == 1 ]];then
                sh <(curl -sL https://get.docker.com)
            else
                sh <(curl -sL https://get.docker.com) --mirror Aliyun
            fi
            if [[ $(type docker 2>/dev/null) ]];then
                break
            else
                export CHANNEL=test
                colorEcho ${YELLOW} "stable channel docker can't install, auto install test channel docker..."
            fi
        done
        systemctl enable docker
        systemctl start docker
    fi

    ## 修改cgroupdriver
    if [[ ! -e /etc/docker/daemon.json || -z `cat /etc/docker/daemon.json|grep systemd` ]];then
        ## see https://kubernetes.io/docs/setup/production-environment/container-runtimes/
        mkdir -p /etc/docker
        if [[ ${OS} == 'CentOS' || ${OS} == 'Fedora' ]];then
            if [[ $CAN_GOOGLE == 1 ]];then
                cat > /etc/docker/daemon.json <<EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2",
    "storage-opts": [
        "overlay2.override_kernel_check=true"
    ]
}
EOF
            else
                cat > /etc/docker/daemon.json <<EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2",
    "storage-opts": [
        "overlay2.override_kernel_check=true"
    ],
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://docker.mirrors.ustc.edu.cn",
        "https://registry.docker-cn.com"
    ]
}
EOF
            fi
        else
            if [[ $CAN_GOOGLE == 1 ]];then
                cat > /etc/docker/daemon.json <<EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2"
}
EOF
            else
                cat > /etc/docker/daemon.json <<EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2",
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://docker.mirrors.ustc.edu.cn",
        "https://registry.docker-cn.com"
    ]
}
EOF
            fi
        fi
        systemctl restart docker
        if [ $? -ne 0 ];then
            rm -f /etc/docker/daemon.json
            if [[ $CAN_GOOGLE == 0 ]];then
                cat > /etc/docker/daemon.json <<EOF
{
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://docker.mirrors.ustc.edu.cn",
        "https://registry.docker-cn.com"
    ]
}
EOF
            fi
            systemctl restart docker
        fi
    fi
}

installK8sBase() {
    if [[ $CAN_GOOGLE == 1 ]];then
        if [[ $OS == 'Fedora' || $OS == 'CentOS' ]];then
            cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
            yum install -y kubelet kubeadm kubectl
        else
            curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
            echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | tee -a /etc/apt/sources.list.d/kubernetes.list
            apt-get update
            apt-get install -y kubelet kubeadm kubectl
        fi
    else
        if [[ $OS == 'Fedora' || $OS == 'CentOS' ]];then
            cat>>/etc/yum.repos.d/kubrenetes.repo<<EOF
[kubernetes]
name=Kubernetes Repo
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
gpgcheck=0
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
EOF
            yum install -y kubelet kubeadm kubectl
        else
            cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb https://mirrors.aliyun.com/kubernetes/apt kubernetes-xenial main
EOF
            gpg --keyserver keyserver.ubuntu.com --recv-keys BA07F4FB
            gpg --export --armor BA07F4FB | apt-key add -
            apt-get update
            apt-get install -y kubelet kubeadm kubectl
        fi
    fi
    systemctl enable kubelet && systemctl start kubelet

    #命令行补全
    [[ -z $(grep kubectl ~/.bashrc) ]] && echo "source <(kubectl completion bash)" >> ~/.bashrc
    [[ -z $(grep kubeadm ~/.bashrc) ]] && echo "source <(kubeadm completion bash)" >> ~/.bashrc
    source ~/.bashrc
    K8S_VERSION=$(kubectl version --short=true|awk 'NR==1{print $3}')
    echo "k8s version: $(colorEcho $GREEN $K8S_VERSION)"
}

downloadImages() {
    colorEcho $YELLOW "auto download $K8S_VERSION all k8s.gcr.io images..."
    K8S_IMAGES=(`kubeadm config images list 2>/dev/null|grep 'k8s.gcr.io'|xargs -r`)
    for IMAGE in ${K8S_IMAGES[@]}
    do
        if [[ $CAN_GOOGLE == 0 ]];then
            TEMP_NAME=${IMAGE#*/}
            IMAGE_INFO=(`echo $TEMP_NAME | tr ':' ' '`)
            if [[ $TEMP_NAME =~ "coredns" ]];then
                MIRROR_NAME="coredns/"$TEMP_NAME
                docker pull $MIRROR_NAME
            else
                for SOURCE in ${DOCKER_IMAGE_SOURCE[@]}
                do
                    if [[ $TEMP_NAME =~ "kube" ]];then
                        TEMP_NAME="${IMAGE_INFO[0]}-$ARCHITECTURE:${IMAGE_INFO[1]}"
                    fi  
                    MIRROR_NAME="$SOURCE/$TEMP_NAME"
                    docker pull $MIRROR_NAME
                    if [ $? -eq 0 ];then
                        break
                    else
                        colorEcho $YELLOW "try other image source .."
                    fi
                done
            fi
            docker tag $MIRROR_NAME $IMAGE
            docker rmi $MIRROR_NAME
        else
            docker pull $IMAGE
        fi

        if [ $? -eq 0 ];then
            echo "Downloaded image: $(colorEcho $BLUE $IMAGE)"
        else
            echo "Failed download image: $(colorEcho $RED $IMAGE)"
        fi
        echo ""
    done
}

runK8s(){
    if [[ $IS_MASTER == 1 ]];then
        if [[ $NETWORK == "flannel" ]];then
            runCommand "kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=`echo $K8S_VERSION|sed "s/v//g"`"
            runCommand "mkdir -p $HOME/.kube"
            runCommand "cp -i /etc/kubernetes/admin.conf $HOME/.kube/config"
            runCommand "chown $(id -u):$(id -g) $HOME/.kube/config"
            runCommand "kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
        elif [[ $NETWORK == "calico" ]];then
            runCommand "kubeadm init --pod-network-cidr=192.168.0.0/16 --kubernetes-version=`echo $K8S_VERSION|sed "s/v//g"`"
            runCommand "mkdir -p $HOME/.kube"
            runCommand "cp -i /etc/kubernetes/admin.conf $HOME/.kube/config"
            runCommand "chown $(id -u):$(id -g) $HOME/.kube/config"
            CALIO_VERSION=$(curl -s https://docs.projectcalico.org/latest/getting-started/|grep Click|egrep 'v[0-9].[0-9]' -o)
            runCommand "kubectl apply -f https://docs.projectcalico.org/$CALIO_VERSION/manifests/calico.yaml"
        fi
    else
        echo "this node is slave, please manual run 'kubeadm join' command. if forget join command, please run `colorEcho $GREEN "kubeadm token create --print-join-command"` in master node"
    fi
    colorEcho $YELLOW "kubectl and kubeadm command completion must reopen ssh to affect!"
}

installHelm(){
    if [[ $IS_MASTER == 1 && $HELM == 1 ]];then
        # install helm client
        curl -L https://git.io/get_helm.sh | bash
        
        HELM_VERSION=`helm version -c | grep '^Client' | cut -d'"' -f2`

        # install helm tiller(server)
        cat > rbac-config.yaml  << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tiller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tiller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tiller
    namespace: kube-system
EOF
        # download tiller image if can't access gcr.io
        if [[ $CAN_GOOGLE == 0 ]];then
            docker pull googlecontainer/tiller:$HELM_VERSION
            docker tag googlecontainer/tiller:$HELM_VERSION gcr.io/kubernetes-helm/tiller:$HELM_VERSION
            docker rmi googlecontainer/tiller:$HELM_VERSION
        else
            docker pull gcr.io/kubernetes-helm/tiller:$HELM_VERSION
        fi

        kubectl taint nodes --all node-role.kubernetes.io/master-

        runCommand "kubectl create -f rbac-config.yaml"
        runCommand "helm init --service-account tiller --history-max 200"

        rm -f rbac-config.yaml
        #命令行补全
        [[ -z $(grep helm ~/.bashrc) ]] && { echo "source <(helm completion bash)" >> ~/.bashrc; source ~/.bashrc; }
    fi
}

main() {
    checkSys
    prepareWork
    installDependent
    installK8sBase
    downloadImages
    runK8s
    installHelm
}

main