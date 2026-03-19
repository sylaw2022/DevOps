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

## 6. The Pause Container — Deep Dive Q&A

### Q: What exactly is the pause container?

Every Pod starts with a tiny, invisible container called `pause` (also called the *infra container*). Its sole job is to **own and hold open the Linux kernel namespaces** (Network, IPC, UTS/hostname) that all other containers in the Pod share. If an app container crashes and restarts, the namespaces are preserved — the Pod's IP address never changes.

```
Pod
├── pause  ← owns the Network/IPC/UTS namespaces
├── app-container  ← joins those namespaces
└── sidecar        ← joins those namespaces
```

### Q: Does the pause container need a Linux kernel or OS inside it?

**No.** `FROM scratch` means no userspace OS (no `/bin`, `/lib`, no shell). But there is **always only one kernel** — the host's. Every container on the machine shares it. A container is just a regular Linux process with kernel-enforced restrictions:

| Mechanism | What it does |
|---|---|
| **Namespaces** | Makes the process *see* an isolated view (network, PIDs, hostname) |
| **Cgroups** | Limits *how much* CPU/RAM the process can use |
| **seccomp** | Restricts *which* syscalls the process can make |

```
┌──────────────────────────────────────────────────┐
│                  HOST MACHINE                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │  nginx   │  │  redis   │  │  pause   │  ← userspace processes │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘       │
│  ─────┴──────────────┴──────────────┴──────────  │
│           Linux Kernel (shared by ALL)            │
└──────────────────────────────────────────────────┘
```

### Q: Who actually creates the namespaces? I don't see it in pause.c.

**`runc`** creates them — not the pause process. Namespaces are created **before** pause even starts, via the `clone()` syscall with namespace flags. Pause merely *holds them alive* by staying as PID 1.

```
Kubelet → containerd → containerd-shim → runc
                                           │
                          ┌────────────────┴──────────────────┐
                          │ 1. clone(CLONE_NEWNET              │ ← kernel creates
                          │        | CLONE_NEWPID              │   namespaces HERE
                          │        | CLONE_NEWIPC              │
                          │        | CLONE_NEWUTS)             │
                          └────────────────┬──────────────────┘
                                           │
                          ┌────────────────┴──────────────────┐
                          │ 2. exec("/pause")                  │ ← pause starts INSIDE
                          └───────────────────────────────────┘   already-created namespaces
```

When **app containers** start, `runc` uses `setns()` to *join* the existing namespaces — it does not create new ones:

```c
// runc does this for each app container:
int fd = open("/proc/<pause-pid>/ns/net", O_RDONLY);
setns(fd, CLONE_NEWNET);   // join the existing namespace
```

### Division of Labour

| Who | Does What |
|---|---|
| **`runc`** | Creates namespaces via `clone()` syscall |
| **`pause`** | Holds namespaces open by staying alive as PID 1 |
| **`runc`** (app containers) | Joins namespaces via `setns()` syscall |
| **CNI plugin** | Configures the network inside the network namespace |
| **`pause.c`** | Reaps zombie processes + handles graceful shutdown |

---

### Q: How do I build a pause container from scratch?

**1. Write `pause.c`** (see full source below).

**2. Compile as a static binary:**
```bash
gcc -o pause pause.c -static -DVERSION=3.9
```
| Flag | Meaning |
|---|---|
| `-o pause` | Output binary named `pause` |
| `-static` | Bake all libraries into the binary (required for `FROM scratch`) |
| `-DVERSION=3.9` | Inject version string at compile time |

Verify it has no shared library dependencies:
```bash
ldd pause
# not a dynamic executable  ✓
```

**3. Write `Dockerfile`:**
```dockerfile
FROM scratch
ADD pause /pause
ENTRYPOINT ["/pause"]
```
`FROM scratch` is a completely empty base image — no OS, no shell, nothing. A static binary is the only thing that can run here.

**4. Build the image:**
```bash
docker build -t my-pause:v1 .
```
| Part | Meaning |
|---|---|
| `-t my-pause:v1` | Tag: name `my-pause`, version `v1` |
| `.` | Build context (current directory, where `pause` binary lives) |

Result: a ~700 KB image containing **exactly one file**.

**5. (Optional) Use musl for a smaller binary:**
```bash
musl-gcc -o pause pause.c -static
# ~20 KB vs ~900 KB with glibc
```

**6. (Optional) Use a custom pause image in containerd:**

Edit `/etc/containerd/config.toml`:
```toml
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "my-pause:v1"
```

---

### Full C Source (`pause.c`) — Official Kubernetes

```c
/*
Copyright 2016 The Kubernetes Authors.
Licensed under the Apache License, Version 2.0
*/

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define STRINGIFY(x) #x
#define VERSION_STRING(x) STRINGIFY(x)

#ifndef VERSION
#define VERSION HEAD
#endif

/* Called on SIGINT / SIGTERM — print signal name and exit cleanly */
static void sigdown(int signo) {
  psignal(signo, "Shutting down, got signal");
  exit(0);
}

/*
 * Called on SIGCHLD — reap all zombie children.
 * pause is PID 1 inside the Pod's PID namespace, so orphaned
 * child processes are re-parented to it. Without this reaper,
 * dead children accumulate as zombies in the kernel process table.
 * WNOHANG = don't block if no child is ready to be reaped.
 */
static void sigreap(int signo) {
  while (waitpid(-1, NULL, WNOHANG) > 0)
    ;
}

int main(int argc, char **argv) {
  int i;

  /* Support a -v flag to print version and exit */
  for (i = 1; i < argc; ++i) {
    if (!strcasecmp(argv[i], "-v")) {
      printf("pause.c %s\n", VERSION_STRING(VERSION));
      return 0;
    }
  }

  /* Warn if not running as PID 1 (e.g. run manually on host) */
  if (getpid() != 1)
    fprintf(stderr, "Warning: pause should be the first process\n");

  /* Register signal handlers */
  if (sigaction(SIGINT,  &(struct sigaction){.sa_handler = sigdown}, NULL) < 0) return 1;
  if (sigaction(SIGTERM, &(struct sigaction){.sa_handler = sigdown}, NULL) < 0) return 2;
  if (sigaction(SIGCHLD, &(struct sigaction){.sa_handler = sigreap,
                                             .sa_flags = SA_NOCLDSTOP},
                NULL) < 0) return 3;

  /*
   * The entire purpose of this process: sleep forever.
   * pause() syscall suspends until any signal is delivered.
   * The signal handler runs, then we loop back and sleep again.
   * CPU usage: effectively 0.
   */
  for (;;)
    pause();

  fprintf(stderr, "Error: infinite loop terminated\n");
  return 42;
}
```

#### Key Points

| Element | Purpose |
|---|---|
| `sigdown` | Graceful exit on `SIGTERM`/`SIGINT` (how K8s stops a Pod) |
| `sigreap` | Zombie reaper — critical because pause is PID 1 |
| `SA_NOCLDSTOP` | Only trigger `SIGCHLD` on child *death*, not on stop/continue |
| `pause()` syscall | Sleeps with zero CPU until a signal arrives |
| **No `clone()`/`unshare()`** | Namespaces are created by `runc`, not by this code |

---

## 7. The Update Lifecycle: RollingUpdate

### A. Standard Flow (Zero Downtime)
1.  **Create First:** New Pod (v2) is spawned.
2.  **Health Check:** Wait for `readinessProbe` to pass.
3.  **Kill Second:** Only then is the old Pod (v1) terminated.

### B. Recreate Strategy
1.  **Kill First:** All v1 pods are terminated immediately.
2.  **Create Second:** v2 pods start once the old ones are gone. (Use this for apps that can't handle version concurrency).
