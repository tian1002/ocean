#!/usr/bin/env bash

validate_hex() {
  if [[ ! "$1" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "The private key seems invalid, exiting ..."
    exit 1
  fi
}

validate_port() {
  if [[ ! "$1" =~ ^[0-9]+$ ]] || [ "$1" -le 1024 ] || [ "$1" -ge 65535 ]; then
    echo "Invalid port number, it must be between 1024 and 65535."
    exit 1
  fi
}

validate_ip_or_fqdn() {
  local input=$1
  if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$input" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    return 0
  else
    echo "Invalid input, must be a valid IPv4 address or FQDN."
    return 1
  fi
}

generate_address_from_private_key() {
  local private_key=$1
  private_key=${private_key#0x}  # 去掉 '0x' 前缀
  echo -n "$private_key" > /tmp/private_key_file

  docker_output=$(docker run --rm -v /tmp/private_key_file:/tmp/private_key_file ethereum/client-go:latest account import --password /dev/null /tmp/private_key_file 2>&1)

  rm /tmp/private_key_file

  address=$(echo "$docker_output" | grep -oP '(?<=Address: \{)[a-fA-F0-9]+(?=\})')

  if [ -z "$address" ]; then
    echo "Failed to generate address from private key."
    return 1
  fi

  echo "$address"
}

get_public_ip() {
  curl -s https://api.ipify.org
}

install_nodes() {
  read -p "Enter the start index for the nodes: " START_INDEX
  read -p "Enter the end index for the nodes: " END_INDEX
  read -p "Enter the base directory for node data: " BASE_DIR
  BASE_DIR="${BASE_DIR/#\~/$HOME}"

  if ! mkdir -p "$BASE_DIR"; then
    echo "Failed to create base directory: $BASE_DIR"
    exit 1
  fi

  P2P_ANNOUNCE_ADDRESS=$(get_public_ip)
  echo "Detected public IP address: $P2P_ANNOUNCE_ADDRESS"
  read -p "Use this IP as P2P_ANNOUNCE_ADDRESS? (y/n): " use_detected_ip
  if [[ $use_detected_ip != "y" ]]; then
    read -p "Provide the public IPv4 address or FQDN where nodes will be accessible: " P2P_ANNOUNCE_ADDRESS
  fi
  validate_ip_or_fqdn "$P2P_ANNOUNCE_ADDRESS"

  # 通过安装批次自动调整 BASE_HTTP_PORT
  BASE_HTTP_PORT=$((10000 + (START_INDEX - 1) * 6))
  PORT_INCREMENT=6

  install_single_node() {
    local i=$1
    local NODE_DIR="${BASE_DIR}/node${i}"
    mkdir -p "$NODE_DIR"
    echo "Setting up node $i in $NODE_DIR"

    PRIVATE_KEY_FILE="${NODE_DIR}/private_key"
    if [ -f "$PRIVATE_KEY_FILE" ]; then
      PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE")
    else
      PRIVATE_KEY=$(openssl rand -hex 32)
      PRIVATE_KEY="0x$PRIVATE_KEY"
      echo "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"
    fi

    validate_hex "$PRIVATE_KEY"

    ADMIN_ADDRESS=$(generate_address_from_private_key "$PRIVATE_KEY")
    echo "Admin address generated for node $i: 0x$ADMIN_ADDRESS"

    HTTP_PORT=$((BASE_HTTP_PORT + (i-START_INDEX)*PORT_INCREMENT))
    P2P_TCP_PORT=$((HTTP_PORT + 1))
    P2P_WS_PORT=$((HTTP_PORT + 2))
    P2P_IPV6_TCP_PORT=$((HTTP_PORT + 3))
    P2P_IPV6_WS_PORT=$((HTTP_PORT + 4))
    TYPESENSE_PORT=$((HTTP_PORT + 5))

    validate_port "$HTTP_PORT"
    validate_port "$P2P_TCP_PORT"
    validate_port "$P2P_WS_PORT"
    validate_port "$P2P_IPV6_TCP_PORT"
    validate_port "$P2P_IPV6_WS_PORT"
    validate_port "$TYPESENSE_PORT"

    if [[ "$P2P_ANNOUNCE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      P2P_ANNOUNCE_ADDRESSES='["/ip4/'$P2P_ANNOUNCE_ADDRESS'/tcp/'$P2P_TCP_PORT'", "/ip4/'$P2P_ANNOUNCE_ADDRESS'/ws/tcp/'$P2P_WS_PORT'"]'
    elif [[ "$P2P_ANNOUNCE_ADDRESS" =~ ^[a-zA-Z0-9.-]+$ ]]; then
      P2P_ANNOUNCE_ADDRESSES='["/dns4/'$P2P_ANNOUNCE_ADDRESS'/tcp/'$P2P_TCP_PORT'", "/dns4/'$P2P_ANNOUNCE_ADDRESS'/ws/tcp/'$P2P_WS_PORT'"]'
    else
      P2P_ANNOUNCE_ADDRESSES=''
      echo "No input provided, the Ocean Node might not be accessible from other nodes."
    fi

    # Generate docker-compose.yml
    cat <<EOF > "${NODE_DIR}/docker-compose.yml"
services:
  ocean-node:
    image: oceanprotocol/ocean-node:latest
    container_name: ocean-node-${i}
    restart: on-failure
    ports:
      - "${HTTP_PORT}:8000"
      - "${P2P_TCP_PORT}:9000"
      - "${P2P_WS_PORT}:9001"
      - "${P2P_IPV6_TCP_PORT}:9002"
      - "${P2P_IPV6_WS_PORT}:9003"
    environment:
      PRIVATE_KEY: '${PRIVATE_KEY}'
      RPCS: |
        {
          "1": {
            "rpc": "https://ethereum-rpc.publicnode.com",
            "fallbackRPCs": [
              "https://rpc.ankr.com/eth",
              "https://1rpc.io/eth",
              "https://eth.api.onfinality.io/public"
            ],
            "chainId": 1,
            "network": "mainnet",
            "chunkSize": 100
          },
          "10": {
            "rpc": "https://mainnet.optimism.io",
            "fallbackRPCs": [
              "https://optimism-mainnet.public.blastapi.io",
              "https://rpc.ankr.com/optimism",
              "https://optimism-rpc.publicnode.com"
            ],
            "chainId": 10,
            "network": "optimism",
            "chunkSize": 100
          },
          "137": {
            "rpc": "https://polygon-rpc.com/",
            "fallbackRPCs": [
              "https://polygon-mainnet.public.blastapi.io",
              "https://1rpc.io/matic",
              "https://rpc.ankr.com/polygon"
            ],
            "chainId": 137,
            "network": "polygon",
            "chunkSize": 100
          },
          "23294": {
            "rpc": "https://sapphire.oasis.io",
            "fallbackRPCs": [
              "https://1rpc.io/oasis/sapphire"
            ],
            "chainId": 23294,
            "network": "sapphire",
            "chunkSize": 100
          },
          "23295": {
            "rpc": "https://testnet.sapphire.oasis.io",
            "chainId": 23295,
            "network": "sapphire-testnet",
            "chunkSize": 100
          },
          "11155111": {
            "rpc": "https://eth-sepolia.public.blastapi.io",
            "fallbackRPCs": [
              "https://1rpc.io/sepolia",
              "https://eth-sepolia.g.alchemy.com/v2/demo"
            ],
            "chainId": 11155111,
            "network": "sepolia",
            "chunkSize": 100
          },
          "11155420": {
            "rpc": "https://sepolia.optimism.io",
            "fallbackRPCs": [
              "https://endpoints.omniatech.io/v1/op/sepolia/public",
              "https://optimism-sepolia.blockpi.network/v1/rpc/public"
            ],
            "chainId": 11155420,
            "network": "optimism-sepolia",
            "chunkSize": 100
          }
        }
      DB_URL: 'http://typesense:8108/?apiKey=xyz'
      IPFS_GATEWAY: 'https://ipfs.io/'
      ARWEAVE_GATEWAY: 'https://arweave.net/'
      INTERFACES: '["HTTP","P2P"]'
      ALLOWED_ADMINS: '["0x${ADMIN_ADDRESS}"]'
      DASHBOARD: 'true'
      HTTP_API_PORT: '8000'
      P2P_ENABLE_IPV4: 'true'
      P2P_ENABLE_IPV6: 'true'
      P2P_ipV4BindAddress: '0.0.0.0'
      P2P_ipV4BindTcpPort: '9000'
      P2P_ipV4BindWsPort: '9001'
      P2P_ipV6BindAddress: '::'
      P2P_ipV6BindTcpPort: '9002'
      P2P_ipV6BindWsPort: '9003'
      P2P_ANNOUNCE_ADDRESSES: '${P2P_ANNOUNCE_ADDRESSES}'
    networks:
      - ocean_network
    volumes:
      - ${NODE_DIR}:/app/data
    depends_on:
      - typesense
      mem_limit: 512m
  typesense:
    image: typesense/typesense:26.0
    container_name: typesense-${i}
    ports:
      - "${TYPESENSE_PORT}:8108"
    networks:
      - ocean_network
    volumes:
      - ${NODE_DIR}/typesense-data:/data
    command: '--data-dir /data --api-key=xyz'
networks:
  ocean_network:
    driver: bridge
EOF

    if [ ! -f "${NODE_DIR}/docker-compose.yml" ]; then
      echo "Failed to generate docker-compose.yml for Node $i"
      return 1
    fi

    echo "Docker Compose file for Node $i has been generated at ${NODE_DIR}/docker-compose.yml"

    # Start Docker containers
    echo "Starting Node $i..."
    (cd "$NODE_DIR" && docker-compose up -d)

    if [ $? -eq 0 ]; then
      echo "Node $i started successfully."
    else
      echo "Failed to start Node $i."
      return 1
    fi
  }

  # 顺序安装节点
  for ((i=START_INDEX; i<=END_INDEX; i++)); do
    install_single_node $i
  done
}

uninstall_nodes() {
  read -p "Enter the start index for the nodes: " START_INDEX
  read -p "Enter the end index for the nodes: " END_INDEX
  read -p "Enter the base directory for node data: " BASE_DIR
  BASE_DIR="${BASE_DIR/#\~/$HOME}"

  uninstall_single_node() {
    local i=$1
    local NODE_DIR="${BASE_DIR}/node${i}"
    if [ -d "$NODE_DIR" ]; then
      echo "Stopping and removing containers for Node $i..."
      (cd "$NODE_DIR" && docker-compose down -v)
      echo "Removing node directory..."
      rm -rf "$NODE_DIR"
      echo "Node $i uninstalled."
    else
      echo "Directory for Node $i not found. Skipping..."
    fi
  }

  for ((i=START_INDEX; i<=END_INDEX; i++)); do
    uninstall_single_node $i
  done

  echo "Uninstallation complete."
}

# Main script
echo "Ocean Node Management Script"
echo "1. Install Ocean Nodes"
echo "2. Uninstall Ocean Nodes"
read -p "Enter your choice (1 or 2): " choice

case $choice in
  1)
    install_nodes
    ;;
  2)
    uninstall_nodes
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac
