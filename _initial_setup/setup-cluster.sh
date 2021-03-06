return

sudo apt-get install -y nfs-common cifs-utils

sudo snap install microk8s --classic --channel=1.20

sudo iptables -P FORWARD ACCEPT
sudo apt-get install iptables-persistent

sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube

# change k8s version
sudo snap refresh microk8s --classic --channel=1.20

# reset snap
snap list
sudo snap remove core18
sudo snap remove snapd

sudo apt autoremove --purge snapd gnome-software-plugin-snap

rm -rf ~/snap
sudo rm -rf /snap
sudo rm -rf /var/snap
sudo rm -rf /var/lib/snapd
sudo umount /var/snap

sudo mount -a
sudo apt install snapd

# first node
microk8s status --wait-ready

microk8s enable dns dashboard
microk8s enable metallb:192.168.8.1-192.168.15.255

#get command to join other nodes
microk8s add-node

# other nodes
microk8s join ***************************************************

# get the .kube/config file
microk8s config

# apply all the manifests
kubectl apply -f . --recursive
