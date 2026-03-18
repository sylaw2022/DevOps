# Kubernetes Internals Deep Dive

This document provides a technical breakdown of how Kubernetes operates under the hood, from the core philosophy to the low-level container runtime.

---

## 1. Fundamental Question: Is DevOps just Tools?

**No.** A common misconception is that DevOps *equals* Docker + Kubernetes + AWS. In reality:
*   **DevOps is a Culture:** It is about breaking down the walls between Developers and Operations teams.
*   **The Goal:** To deliver software **Faster**, **Safer**, and more **Reliably**.

### The "K8s Stack" vs. Alternatives
While the tools documented here are industry standards, DevOps can be done with many alternatives:

| Pillar | Popular "K8s" Stack | Alternative Stack |
| :--- | :--- | :--- |
| **Infrastructure** | Public Cloud (AWS/GCP) | **On-Premise** (Your own servers) |
| **Packaging** | **Docker** (Containers) | **VMs** (Packer/Vagrant) or Bare Metal |
| **Orchestration** | **Kubernetes** | **Nomad**, **Docker Swarm**, or just Shell Scripts |
| **Git & CI/CD** | **GitHub** | **GitLab**, **Bitbucket**, or **Jenkins** |

---

## 2. Deploying Your Own Kubernetes

You absolutely can deploy your own cluster. In fact, many companies do this for security or cost reasons.

### A. Local / Development
*   **Minikube:** Runs a single-node cluster as a VM or Container.
*   **Kind (Kubernetes in Docker):** Runs the "Nodes" as Docker containers.
*   **MicroK8s:** A lightweight "Snap" package for Ubuntu/Linux.

### B. Production / Bare Metal
*   **Kubeadm:** The standard tool to bootstrap a K8s cluster manually.
*   **Kubespray:** An Ansible-based installer for multi-server deployments.
*   **K3s:** A lightweight version of K8s (ideal for Edge or IoT).

---

## 3. The Pod Architecture

### A. Pod vs. Virtual Machine
*   **Is a Pod a VM?** No. A VM has its own Kernel and OS. A Pod uses the **Host’s Kernel**.
*   **Shared Namespaces:** Containers in a Pod share the same **Network** (IP) and **IPC**. They can talk to each other using `localhost`.
*   **Analogy:** The **Server** is a City Block; the **Pod** is a House; the **Container** is a Room.

### B. The Pause (Infra) Container
Every Pod starts with a tiny, invisible container called `pause`.
- It "holds open" the Linux Namespaces.
- App containers and sidecars "join" these namespaces to share the Network and Hostname.

---

## 4. The Control Plane (The Brain)

### A. The Chain of Command
1.  **kubectl:** You send your YAML to the **API Server**.
2.  **API Server:** Stores the "Desired State" in **etcd** (the DB).
3.  **Scheduler:** Decides which Node has space and assigns the Pod.
4.  **Kubelet:** The agent on the Node "watches" the API Server and acts when an assignment is made.

### B. The "Desired State" Loop
Kubernetes constantly compares the **Desired State** (YAML) with the **Actual State**.
- If a Pod dies (Actual: 2, Desired: 3), the Controller Manager notices and triggers a new Pod creation immediately.

---

## 5. Under the Hood: K8s and containerd

### A. CRI (Container Runtime Interface)
Kubernetes doesn't speak "Docker" natively. It uses the **CRI** standard to talk to runtimes like `containerd` or `CRI-O` via **gRPC** over a local Unix socket.

### B. Execution (OCI & runc)
1.  **containerd** receives the command from the Kubelet.
2.  It calls **runc** (the OCI executor).
3.  **runc** interacts with the Linux kernel to create the isolated container environment.

---

## 6. The Update Lifecycle: RollingUpdate

### A. Standard Flow (Zero Downtime)
1.  **Create First:** New Pod (v2) is spawned.
2.  **Health Check:** Wait for `readinessProbe` to pass.
3.  **Kill Second:** Only then is the old Pod (v1) terminated.

### B. Recreate Strategy
1.  **Kill First:** All v1 pods are terminated immediately.
2.  **Create Second:** v2 pods start once the old ones are gone. (Use this for apps that can't handle version concurrency).
