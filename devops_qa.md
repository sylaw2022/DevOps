# DevOps & Kubernetes: Q&A Session

This document captures the recent Q&A session regarding Kubernetes internals, architecture, and its role in the industry.

---

### Q: Who gives commands to the Kubelet?
**A:** The **Kube-API-Server**. It is the central "Headquarters." The Kubelet (the worker) "watches" the API Server for assignments.

### Q: How does Kubernetes know when to spawn a new Pod?
**A:** It uses a **Control Loop**. It constantly compares the **Desired State** (your YAML) with the **Actual State** (what is running). If there is a mismatch (e.g., a Pod crashed), it spawns a new one to bridge the gap.

### Q: Does the Kubelet pull the Docker image and start the container?
**A:** Parallel effort. The **Kubelet** is the Foreman who gives the order. The **Container Runtime** (containerd/Docker) is the Worker that actually pulls the bits from the registry and tells the Linux Kernel to start the process.

### Q: Is a Pod just a Virtual Machine?
**A:** **No.** A VM has its own Kernel and OS (heavy). A Pod is a **logical grouping** of containers that share the host's Kernel. They share a "Network Namespace," which is why they share an IP and can talk via `localhost`.

### Q: How do Linux Namespaces achieve the "Pod" concept?
**A:** Kubernetes starts a hidden **Pause Container** first. This container holds the namespaces (Network, IPC, UTS) open. All your application containers then **join** those same namespaces so they "see" the same network and hostname.

### Q: What triggers Kubernetes to create a new Pod from a YAML update?
**A:** Any change to the **`spec.template`** section. This includes changing the Image tag, Environment Variables, or Resource Limits. Changes to labels outside the template usually do NOT trigger new Pods.

### Q: Is Kubernetes the industry standard?
**A:** **Yes.** It is considered the "OS of the Cloud." Every major cloud provider offers it, and it has the largest ecosystem of supporting tools in the world.

### Q: What is OpenStack and how does it compare?
**A:** 
*   **OpenStack:** Manages Physical Hardware and Virtual Machines (IaaS). It is like building your own private AWS.
*   **Kubernetes:** Manages Containers (PaaS). It usually runs **on top** of a cloud like AWS or a system like OpenStack.
*   **Similarity:** Both use a similar "API -> Scheduler -> Worker Agent" model, but for different levels of the infrastructure.

### Q: Does Google Cloud use OpenStack to start my VMs?
**A:** **No.** Google, AWS, and Azure use their own proprietary, heavily-guarded systems. OpenStack is primarily used by companies (like NASA) that want to build a "Cloud-like" experience on their own private servers.
