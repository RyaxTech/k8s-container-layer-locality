for n in $(kind get nodes --name crio); do
  docker cp /nix/store/2x16d8wlcrkvxxyp5d4lmnh5kk105h91-cri-o/bin/crio $n:/usr/bin/crio
  docker exec $n systemctl restart crio
  sleep 1
  docker exec $n systemctl status crio
done
