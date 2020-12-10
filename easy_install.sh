#!/bin/bash

## function definitions
function yes_or_no() {
    while true; do
        read -p "$* [y/n]: " yn
        case $yn in
            [Yy]*) return 0  ;;
            [Nn]*) echo "Aborted" ; return  1 ;;
        esac
    done
}

function install_req() {
  echo "Installing requirements"

  # checking for docker
  if docker ps 2>&1 > /dev/null; then
    echo "Docker OK!"

    # checking for 'eth2' docker network
    result=$(docker network ls -q -f name=eth2 )
    if [[ -n "$result" ]]; then
      echo "Network exists. Next step: install services!"
      ## pulling images we will need later in the background
      docker pull lidofinance/deposit-cli 2>&1 > /dev/null &
      docker pull sigp/lighthouse:v1.0.3 2>&1 > /dev/null &
      docker pull ethereum/client-go:stable 2>&1 > /dev/null &
    else
      echo "Creating Docker network"
      docker network create eth2
    fi


  else
    echo "Installing Docker"
    sudo apt update; sudo apt install docker;
    user=$(whoami)
    sudo usermod -a -G docker $user
    echo "Installed Docker. Log out and back in to proceed"
    exit
  fi

}

function install_svc() {
  echo "Installing services "
  # install geth
  echo "$geth_service" > /tmp/geth-goerli.service; sudo cp /tmp/geth-goerli.service /etc/systemd/system/
  # install lh-beacon
  echo "$beacon_service" > /tmp/lh-pyrmont-beacon.service; sudo cp /tmp/lh-pyrmont-beacon.service /etc/systemd/system/
  # install lh-validator
  echo "$validator_service" > /tmp/lh-pyrmont-validator.service; sudo cp /tmp/lh-pyrmont-validator.service /etc/systemd/system/

  rm /tmp/*.service
  sudo systemctl daemon-reload
  echo "Services installed! "
}

function gen_keys() {
  echo "Generating validator keys..."
  echo "!! Make SURE to backup the mnemonic, without it you cannot withdraw your ETH !"
  docker run --rm -ti --name eth2keys \
  -v eth2-keys:/mount \
  lidofinance/deposit-cli \
  new-mnemonic --folder /mount --mnemonic_language english --num_validators 1 --chain pyrmont

  docker run --rm -ti \
  -v eth2-keys:/mount \
  -v lh-pyrmont-keys:/keys \
  sigp/lighthouse:v1.0.3 \
  lighthouse account_manager validator import \
  --directory /mount/validator_keys --datadir /keys --network pyrmont

  deposit_data=$(docker run --rm -ti \
  -v eth2-keys:/mount \
  --entrypoint sh lidofinance/deposit-cli \
  -c 'cat /mount/validator_keys/deposit_data-*.json')
  echo $deposit_data > ~/.deposit_data.json
  echo "This is your deposit_data file. It has been saved to ~/.deposit_data.json"
  cat ~/.deposit_data.json

  docker volume rm eth2-keys
  # restart validator
  sudo systemctl restart lh-pyrmont-validator
}

function start_svc() {
  echo "Enabling and starting services"
  sudo systemctl enable --now geth-goerli lh-pyrmont-beacon lh-pyrmont-validator
}

function update() {
  echo "Updating your installation"
  # sed s/ver/ver2/g /etc/systemd/system
}

function stop_svc() {
  echo "Stopping and disabling services"
  sudo systemctl stop geth-goerli lh-pyrmont-beacon lh-pyrmont-validator
  sudo systemctl disable geth-goerli lh-pyrmont-beacon lh-pyrmont-validator
  docker rm geth-goerli lh-pyrmont-beacon lh-pyrmont-validator
}

function cleanup() {
  echo "Cleanup requested."
  yes_or_no "Remove systemd unit files?" && sudo rm /etc/systemd/system/geth-goerli.service && sudo rm /etc/systemd/system/lh-pyrmont-beacon.service && sudo rm /etc/systemd/system/lh-pyrmont-validator.service
  yes_or_no "Remove ETH1 chaindata?" && docker volume rm geth-goerli-data
  yes_or_no "Remove ETH2 chaindata?" && docker volume rm lh-pyrmont-beacon
  yes_or_no "Remove ETH2 keys?" && yes_or_no "Are you sure?" && docker volume rm lh-pyrmont-keys
  yes_or_no "Remove Docker network eth2?" && docker network rm eth2
}

## systemd unit files

geth_service="[Unit]
Description=Geth (Goerli testnet)
After=docker.service

[Service]
TimeoutStartSec=0
Restart=always
ExecStartPre=-/usr/bin/docker kill geth-goerli
ExecStartPre=-/usr/bin/docker rm geth-goerli
ExecStart=/usr/bin/docker run --name geth-goerli -m 4g \\
  -p 30305:30305/tcp \\
  -p 30305:30305/udp \\
  -v geth-goerli-data:/root/.ethereum \\
  --net=eth2 \\
  ethereum/client-go:stable \\
  --goerli \\
  --syncmode=fast --maxpeers=10 --cache=1024 \\
  --nousb \\
  --http --http.addr "0.0.0.0" --http.port=8545 --http.vhosts=* \\
  --port 30305
ExecStop=/usr/bin/docker stop geth-goerli

[Install]
WantedBy=multi-user.target
"

beacon_service="[Unit]
Description=Lighthouse beacon node (Pyrmont testnet)
After=geth-goerli.service

[Service]
TimeoutStartSec=0
Restart=always
ExecStartPre=-/usr/bin/docker kill lh-pyrmont-beacon
ExecStartPre=-/usr/bin/docker rm lh-pyrmont-beacon
ExecStart=/usr/bin/docker run --name lh-pyrmont-beacon -m 4g \\
  -p 19000:19000/tcp \\
  -p 19000:19000/udp \\
  -v lh-pyrmont-beacon:/root/.lighthouse/pyrmont \\
  --net=eth2 \\
 sigp/lighthouse:v1.0.3 lighthouse \\
  --debug-level info \\
  --network pyrmont \\
  beacon_node \\
  --eth1-endpoint "http://geth-goerli:8545" \\
  --target-peers 20 \\
  --port 19000 \\
  --enr-udp-port 19000 \\
  --http --http-address 0.0.0.0
ExecStop=/usr/bin/docker stop lh-pyrmont-beacon

[Install]
WantedBy=multi-user.target
"

validator_service="[Unit]
Description=Lighthouse validator (Pyrmont testnet)
After=lh-pyrmont-beacon.service

[Service]
TimeoutStartSec=0
Restart=always
ExecStartPre=-/usr/bin/docker kill lh-pyrmont-validator
ExecStartPre=-/usr/bin/docker rm lh-pyrmont-validator
ExecStart=/usr/bin/docker run --name lh-pyrmont-validator -m 2g \\
  -v lh-pyrmont-keys:/keys \\
  --net=eth2 \\
 sigp/lighthouse:v1.0.3 lighthouse \\
  validator \\
  --network pyrmont \\
  --datadir /keys \\
  --init-slashing-protection \\
  --beacon-node "http://lh-pyrmont-beacon:5052"
ExecStop=/usr/bin/docker stop lh-pyrmont-validator

[Install]
WantedBy=multi-user.target
"



PS3='What do you want to do? '
actions=("Install requirements" "Install Services" "Generate Keys" "Start Services" "Update" "Stop Services" "Clean up" "Quit")
select action in "${actions[@]}"; do
  case $action in
   "Install requirements")
     install_req;
     ;;
   "Install Services")
     install_svc;
     ;;
   "Generate Keys")
     gen_keys;
     ;;
   "Start Services")
     start_svc;
     ;;
   "Update")
     update;
     ;;
   "Stop Services")
     stop_svc;
     ;;
   "Clean up")
     cleanup;
     ;;
  "Quit")
    echo "Hope to see you soon!
Donations welcome at 0x9069524F2cB40C97E6529FE1080cea32826D73BD"
    exit
    ;;
    *) echo "invalid option $REPLY";;
  esac
done
