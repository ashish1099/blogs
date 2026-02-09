---
title: "Setting Up LXD on Ubuntu 24.04 and Running OpenVox Agent with LinuxAid"
date: 2025-06-15T10:00:00+02:00
draft: false
tags: ["openvox", "linux", "cfgmgmt", "automation"]
author: "Ashish Jaiswal"
summary: "A hands-on guide to installing LXD on Ubuntu 24.04, spinning up containers, and connecting them to LinuxAid using the OpenVox agent for configuration management."
showToc: true
TocOpen: true
---

## Why LXD + OpenVox + LinuxAid?

If you manage Linux infrastructure, you know the pain of keeping configurations consistent across machines. LXD gives you lightweight system containers — full OS environments without the overhead of VMs. OpenVox is an open-source configuration management agent (a fork of Puppet), and LinuxAid is a platform that makes managing OpenVox agents straightforward.

This guide walks you through the full setup: installing LXD on Ubuntu 24.04, launching a container, installing the OpenVox agent inside it, and connecting it to LinuxAid.

## Prerequisites

- Ubuntu 24.04 LTS (Noble Numbat) host
- A user with `sudo` access
- A [LinuxAid](https://linuxaid.com) account (for the configuration management part)

## Step 1: Install and Initialize LXD

On Ubuntu 24.04, LXD is available as a snap. If you have the older `lxd` deb package installed, remove it first.

### Install LXD

```bash
sudo snap install lxd
```

If LXD is already installed via snap, make sure it's up to date:

```bash
sudo snap refresh lxd
```

### Add Your User to the LXD Group

```bash
sudo usermod -aG lxd $USER
newgrp lxd
```

### Initialize LXD

Run the interactive setup. For most use cases, the defaults work fine:

```bash
lxd init
```

You'll be asked about storage backends, networking, and clustering. For a simple single-host setup:

- **Clustering:** no
- **Storage backend:** dir (simplest) or zfs (better performance)
- **MAAS server:** no
- **Network bridge:** yes (accept default `lxdbr0`)
- **NAT:** yes
- **IPv6:** you can skip this unless you need it

A minimal non-interactive setup:

```bash
lxd init --minimal
```

Verify the installation:

```bash
lxc list
```

You should see an empty table — no containers yet.

## Step 2: Launch an LXD Container

Let's create an Ubuntu 24.04 container:

```bash
lxc launch ubuntu:24.04 openvox-node
```

This downloads the Ubuntu 24.04 image (if not cached) and starts a container named `openvox-node`.

Check it's running:

```bash
lxc list
```

```
+---------------+---------+----------------------+------+-----------+-----------+
|     NAME      |  STATE  |         IPV4         | IPV6 |   TYPE    | SNAPSHOTS |
+---------------+---------+----------------------+------+-----------+-----------+
| openvox-node  | RUNNING | 10.x.x.x (eth0)     |      | CONTAINER |     0     |
+---------------+---------+----------------------+------+-----------+-----------+
```

Get a shell inside the container:

```bash
lxc exec openvox-node -- bash
```

From here on, commands are run **inside the container** unless stated otherwise.

## Step 3: Install the OpenVox Agent

Inside the container, install the OpenVox agent. First, add the OpenVox repository.

### Add the OpenVox Repository

```bash
apt-get update
apt-get install -y curl gnupg

curl -fsSL https://apt.openvox.io/openvox-keyring.gpg \
  | gpg --dearmor -o /usr/share/keyrings/openvox-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/openvox-keyring.gpg] https://apt.openvox.io noble main" \
  | tee /etc/apt/sources.list.d/openvox.list
```

### Install the Agent

```bash
apt-get update
apt-get install -y openvox-agent
```

### Verify the Installation

```bash
/opt/openvox/bin/openvox agent --version
```

You should see the installed version printed.

## Step 4: Configure the OpenVox Agent for LinuxAid

LinuxAid acts as your OpenVox server — it manages the certificates and provides the catalog (the desired configuration) for your nodes.

### Set the LinuxAid Server

Edit the OpenVox agent configuration:

```bash
cat > /etc/openvox/openvox.conf <<EOF
[agent]
server = your-linuxaid-server.linuxaid.com
certname = openvox-node
EOF
```

Replace `your-linuxaid-server.linuxaid.com` with the server hostname provided in your LinuxAid dashboard.

### Start the Agent

Enable and start the OpenVox agent service:

```bash
systemctl enable openvox-agent
systemctl start openvox-agent
```

### Sign the Certificate

When the agent first connects to LinuxAid, it submits a certificate signing request (CSR). You need to approve this in the LinuxAid dashboard:

1. Log in to [LinuxAid](https://linuxaid.com)
2. Navigate to **Nodes** → **Unsigned Certificates**
3. Find `openvox-node` and click **Sign**

Once signed, the agent will start receiving its catalog on the next run.

### Test the Connection

Trigger a manual agent run to verify everything works:

```bash
/opt/openvox/bin/openvox agent --test
```

You should see the agent connect to LinuxAid, receive its catalog, and apply any configurations. If you see `Applied catalog in X.XX seconds`, you're all set.

## Step 5: Managing Your Node from LinuxAid

With the agent connected, you can now manage your container from the LinuxAid dashboard:

- **View facts** — hardware, OS, network info reported by the agent
- **Apply configurations** — push changes to your node
- **Monitor compliance** — see if the node's actual state matches the desired state
- **Group nodes** — organize nodes by role, environment, or any criteria you define

## Useful LXD Commands

Back on the **host**, here are some commands you'll use regularly:

```bash
# Stop the container
lxc stop openvox-node

# Start it again
lxc start openvox-node

# Delete the container (must be stopped first)
lxc delete openvox-node

# Copy a container (for testing)
lxc copy openvox-node openvox-node-test

# Take a snapshot
lxc snapshot openvox-node clean-state

# Restore from snapshot
lxc restore openvox-node clean-state

# View container resource usage
lxc info openvox-node
```

## Troubleshooting

### Agent Can't Resolve the Server Hostname

Make sure DNS works inside the container:

```bash
lxc exec openvox-node -- dig your-linuxaid-server.linuxaid.com
```

If DNS isn't resolving, check the LXD network bridge settings or add the server to `/etc/hosts` inside the container.

### Certificate Not Appearing in LinuxAid

Check the agent logs:

```bash
lxc exec openvox-node -- journalctl -u openvox-agent -f
```

Common issues:
- Wrong server hostname in `openvox.conf`
- Firewall blocking port 8140 (OpenVox uses this by default)
- Clock skew between the container and the server (certificates are time-sensitive)

### Container Networking Issues

If the container can't reach the internet:

```bash
# On the host, check the bridge
lxc network show lxdbr0

# Verify NAT is enabled
lxc network set lxdbr0 ipv4.nat true
```

## Wrapping Up

You now have a working setup: an LXD container running the OpenVox agent, connected to LinuxAid for configuration management. From here, you can:

- Launch more containers and connect them all to LinuxAid
- Write OpenVox manifests to automate your infrastructure
- Use LXD snapshots to test configuration changes before applying them to production

LXD containers are cheap to create and destroy, which makes them perfect for testing configuration management workflows. Spin up a container, test your changes, tear it down, repeat.

---

*If you spot any errors or have suggestions, hit the "Suggest Changes" link above. Find me on [GitHub](https://github.com/ashish1099) or [LinkedIn](https://linkedin.com/in/ashish1099).*
