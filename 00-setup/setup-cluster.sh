return

sudo apt-get install -y nfs-common cifs-utils

sudo snap install microk8s --classic --channel=1.19

sudo iptables -P FORWARD ACCEPT
sudo apt-get install iptables-persistent

sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube


# first node
microk8s status --wait-ready

microk8s enable dns dashboard
microk8s enable metallb:192.168.8.1-192.168.15.255

#get command to join other nodes
microk8s add-node

# other nodes
microk8s join ***************************************************
