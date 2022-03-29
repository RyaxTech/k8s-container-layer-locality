for n in $(kind get nodes --name crio); do
  docker cp  $HOME/Projects/kubernetes/_output/local/bin/linux/amd64/kubelet $n:/usr/bin/kubelet
  docker exec $n systemctl restart kubelet
  sleep 1
  docker exec $n systemctl status kubelet
done
