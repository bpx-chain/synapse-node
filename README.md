# BPX Synapse node

![Synapse](./logo.svg)

Official Nim implementation of the Synapse network node.

Synapse is a real time off-chain communication layer for BPX chain DApps.

## Installation

The Linux binary release is built for Ubuntu >=20.04 and Debian >=11. Other distributions with `glibc` version 2.31 or higher should also be supported.
Please install required dependencies before starting Synapse node:

```bash
sudo apt-get install libpq5 libpcre3
```

## Building the source

Make sure you have the standard developer tools installed, including a C compiler, GNU Make, Bash, and Git.
The first `make` invocation will update all Git submodules. You'll run `make update` after each `git pull` in the future to keep those submodules updated.

```bash
git clone https://github.com/bpx-chain/synapse-node
cd synapse-node
make synapse
```

## Usage

Run a node with default options:
```bash
./synapse
```

When a node private key is not set, the node will generate a new key every time it starts. You can generate a permanent key with the command:
```bash
openssl rand -hex 32
```
Then provide it each time you run the node:
```bash
--nodekey=6b07cb57dfa4cf2d93f5a659ab953f7f9519255adaabf9535c1256deb1b26c5d
```

You can adjust how much disk space can be used to store messages waiting for offline users (5GB by default):
```bash
--store-message-retention-policy=size:20GB
```

To allow browser-based DApps to connect to your node, enable the WebSocket server. First, assign a domain to your server and obtain a SSL certificate for it:
```bash
certbot certonly --standalone -d synapse.example.com
```
Then run Synapse with additional arguments:
```bash
--websocket-support=true --websocket-secure-support=true --websocket-secure-key-path=/etc/letsencrypt/live/synapse.example.com/privkey.pem --websocket-secure-cert-path=/etc/letsencrypt/live/synapse.example.com/fullchain.pem
```

The complete startup command for a production Synapse node might look like this:
```bash
./synapse --nodekey=6b07cb57dfa4cf2d93f5a659ab953f7f9519255adaabf9535c1256deb1b26c5d --store-message-retention-policy=size:20GB --websocket-support=true --websocket-secure-support=true --websocket-secure-key-path=/etc/letsencrypt/live/synapse.example.com/privkey.pem --websocket-secure-cert-path=/etc/letsencrypt/live/synapse.example.com/fullchain.pem
```
