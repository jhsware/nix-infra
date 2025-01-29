appendWithLineBreak() {
  if [ -z "$1" ]; then
    printf "$2"
  else
    printf "$1\n$2"
  fi
}

cmd () {
  echo "You need to add a command similar to the following after you import this file:"
  echo '$NIX_INFRA cmd -d $WORK_DIR --target="$1" "$2"'
}

checkNixos() {
  echo "Checking NixOS"
  local NODES="$1"
  local node
  local _nixos_fail=""

  for node in $NODES; do
    if [[ $(cmd "$node" "uname -a" &) == *"NixOS"* ]]; then
      echo "- nixos    : ok ($node)"
    else
      echo "- nixos    : fail ($node)"
      _nixos_fail="true";
    fi
  done
  wait

  if [ -n "$_nixos_fail" ]; then
    return 1
  fi
}

checkEtcd() {
  echo "Checking etcd"
  local NODES="$1" # ETCD nodes
  local node
  local _failed

  for node in $NODES; do
    if [[ $(cmd "$node" "systemctl is-active etcd" &) == *"active"* ]]; then
      echo "- etcd     : ok ($node)"
    else
      echo "- etcd     : down ($node)"
      _failed="yes"
    fi
  done
  wait

  if [ -n "$_failed" ]; then
    return 1
  fi
}

checkWireguard() {
  echo "Checking wireguard"
  local NODES="$1"
  local node
  local _failed

  for node in $NODES; do
    if [[ $(cmd "$node" "wg show" &) == *"peer: "* ]]; then
      echo "- wireguard: ok ($node)"
    else
      echo "- wireguard: down ($node)"
      _failed="yes"
    fi
  done
  wait

  if [ -n "$_failed" ]; then
    return 1
  fi
}

checkConfd() {
  echo "Checking confd"
  local NODES="$1"
  local node
  local _failed

  for node in $NODES; do
    if [[ $(cmd "$node" "grep -q \"$node\" /root/test.txt && echo true" &) == *"true"* ]]; then
      echo "- confd: ok ($node)"
    else
      echo "- confd: down ($node)"
      _failed="yes"
    fi
  done
  wait
  
  if [ -n "$_failed" ]; then
    return 1
  fi
}
