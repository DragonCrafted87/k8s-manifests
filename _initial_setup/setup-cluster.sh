return

sudo apt-get install --assume-yes nfs-common cifs-utils

sudo snap install microk8s --classic --channel=1.27/stable

sudo apt-get install iptables-persistent
sudo iptables -P FORWARD ACCEPT
sudo iptables-save
sudo iptables-legacy-save

sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube

# change k8s version
sudo snap refresh microk8s --classic --channel=1.27/stable

# reset snap
snap list
sudo snap remove microk8s
sudo snap remove snapd

sudo apt autoremove --assume-yes --purge snapd gnome-software-plugin-snap

rm -rf ~/snap
sudo rm -rf /root/snap
sudo rm -rf /snap
sudo rm -rf /var/snap
sudo rm -rf /var/lib/snapd
sudo umount /var/snap

sudo mount -a
sudo apt install snapd --assume-yes

# first node
microk8s status --wait-ready

microk8s enable dns
microk8s enable dashboard
microk8s enable metallb:192.168.8.1-192.168.15.255

#get command to join other nodes
microk8s add-node

# other nodes
microk8s join ***************************************************

# get the .kube/config file
microk8s config

# apply all the manifests
kubectl apply -f . --recursive




https://discuss.kubernetes.io/t/microk8s-ipv6-dualstack-how-to/14507

kubectl apply -f https://docs.projectcalico.org/archive/v3.13/manifests/calicoctl.yaml
