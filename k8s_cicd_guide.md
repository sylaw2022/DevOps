# Integrating Kubernetes into CI/CD

This guide explains how to build a robust pipeline that automates the deployment of containerized applications to a Kubernetes cluster.

## 1. The High-Level Workflow

A typical Kubernetes CI/CD pipeline is split into two distinct phases:

### Phase 1: Continuous Integration (CI)
*   **Code Commit:** Developer pushes code to Git.
*   **Unit Testing:** Run automated tests to ensure code quality.
*   **Docker Build:** Build a Docker image from the current commit.
*   **Vulnerability Scan:** Scan the image for security issues (using tools like Trivy or Snyk).
*   **Image Push:** Push the tagged image to a Container Registry (Docker Hub, AWS ECR, Google GAR, etc.).

---

## 2. Multi-Cloud: Registries & Kubernetes

Different cloud providers have specific ways to authenticate and manage their registries and K8s clusters.

### A. Amazon Web Services (AWS)
*   **Registry (ECR):** Requires `aws-actions/amazon-ecr-login@v2`. Images are usually named `[account-id].dkr.ecr.[region].amazonaws.com/[repo]:[tag]`.
*   **Kubernetes (EKS):** Uses `aws eks update-kubeconfig --name [cluster-name]` to generate the credentials.

### B. Google Cloud Platform (GCP)
*   **Registry (Artifact Registry):** Uses `google-github-actions/auth@v2`. Images are named `[region]-docker.pkg.dev/[project-id]/[repo]/[image]:[tag]`.
*   **Kubernetes (GKE):** Use `google-github-actions/get-gke-credentials@v2`.

### C. Azure
*   **Registry (ACR):** Uses `azure/docker-login@v2` with a Service Principal. Images are `[registry-name].azurecr.io/[image]:[tag]`.
*   **Kubernetes (AKS):** Use `azure/aks-set-context@v3`.

---

## 3. Why the Registry? (Can we deploy directly?)

A common question is: *"Why can't I just send the image directly to K8s?"*

### Why you NEED a Registry:
1.  **Multi-Node Distribution:** If you have 100 servers (Nodes), they all need a central "library" (the Registry) to pull the image from. They can't access your laptop!
2.  **Persistence:** If a Node crashes, it needs to pull the image again. A registry ensures the image is always available.
3.  **Versioning:** Registries store every version of your app, making rollbacks instant.

### When you can "Deploy Directly" (Local Development ONLY):
If you use a local cluster (Minikube, Kind), you can "load" the image directly into the cluster's internal storage:
*   `minikube image load my-image:v1`
*   `kind load docker-image my-image:v1`

### C. The "Pull-on-Demand" Flow
This is the "magic" of how the two work together:
1.  **You Provide the Instruction:** You run `kubectl apply -f manifest.yaml`.
2.  **K8s Receives the Goal:** The cluster sees the `image: my-registry/my-app:v1` line in your YAML.
3.  **The Node Action:** The Kubelet (the "manager" on each server) asks: *"Do I have this image locally?"*
4.  **The Registry Fetch:** If "No," it goes to the registry, pulls the bits, and then starts the pod.

> [!NOTE]
> This is why your CI/CD pipeline **must** push the image *before* it applies the YAML. If the YAML points to an image that hasn't been pushed yet, K8s will return an `ErrImagePull` or `ImagePullBackOff` error.

---

## 3. Phase 2: Continuous Deployment (CD)
*   **Manifest Update:** Update the Kubernetes YAML files (or Helm charts) with the new image tag.
*   **Deploy to K8s:** Apply the updated manifests to the cluster.
*   **Health Check & Verification:** Kubernetes performs a rolling update, and the pipeline waits for the new pods to be "Ready."
*   **Rollback (if needed):** If the health checks fail, the pipeline or K8s automatically reverts to the previous version.

---

## 2. Push-based vs. Pull-based (GitOps)

There are two primary ways to handle the **Deployment (CD)** phase:

### Push-based (Traditional)
*   **Tools:** Jenkins, GitHub Actions, GitLab CI.
*   **How it works:** The CI server has credentials for the K8s cluster and "pushes" the changes using `kubectl apply` or `helm upgrade`.
*   **Pros:** Simple to set up, familiar workflow.
*   **Cons:** Security risk (CI server needs cluster-admin access), hard to track who changed what in the cluster without looking at CI logs.

### Pull-based (GitOps)
*   **Tools:** ArgoCD, Flux.
*   **How it works:** A controller runs *inside* the K8s cluster. It watches a Git repository containing your manifests. When Git changes, the controller "pulls" the changes into the cluster.
*   **Pros:** Highly secure (no outside access needed), Git becomes the "Single Source of Truth."
*   **Cons:** Requires more setup and a separate repository for manifests.

---

## 3. Best Practices for Kubernetes CI/CD

1.  **Never use the `:latest` tag:** Always tag images with the Git commit SHA or a version number. This ensures you know exactly what code is running and allows for easy rollbacks.
2.  **Use Infrastructure as Code (IaC):** Store your Kubernetes manifests (YAMLs) or Helm charts in Git alongside your code.
3.  **Separate Config from Code:** Use **ConfigMaps** and **Secrets** to manage environment-specific settings so you can use the same Docker image in Dev, Staging, and Production.
4.  **Implement Readiness/Liveness Probes:** Ensure your K8s manifests include health checks. This prevents the CI/CD pipeline from considering a deployment "successful" if the app is crashing.
5.  **Automated Rollbacks:** Configure your CD tool to automatically roll back if the new deployment fails its health checks.

---

## 4. How the Pipeline Detects Pod Health

A pipeline knows if a deployment succeeded or failed through a combination of **Kubernetes Probes** and the **Rollout Status** command.

### A. The "Brains": Readiness and Liveness Probes
In your `deployment.yaml`, you must define how Kubernetes should check your app's health.

*   **Readiness Probe:** Tells K8s when the pod is ready to accept traffic. If this fails, K8s stops the rollout and won't send traffic to that pod.
*   **Liveness Probe:** Tells K8s if the pod is still alive. If this fails (e.g., the app has deadlocked), K8s kills and restarts the container.

```yaml
# Example snippet in deployment.yaml
spec:
  containers:
  - name: my-app
    readinessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
```

### B. Alternative Probe Types (If you don't use HTTP)
You are **not limited to HTTP GET**. Kubernetes supports three other ways to check health:

1.  **TCP Socket Probe:** K8s simply tries to open a TCP connection to a specific port. If the port is open, the probe succeeds. 
    *   *Best for:* Databases, mail servers, or internal services that don't have an HTTP interface.
    ```yaml
    tcpSocket:
      port: 3306
    ```

2.  **gRPC Probe:** If your application uses gRPC, K8s can perform native health checks using the standard gRPC health checking protocol.
    ```yaml
    grpc:
      port: 9000
    ```

3.  **Exec (Command) Probe:** K8s runs a specific command *inside* your container. If the command exits with code 0, it's "Healthy."
    *   *Best for:* Checking file existence, script results, or legacy apps.
    ```yaml
    exec:
      command:
      - cat
      - /tmp/healthy
    ```

### C. Handling Legacy Applications

Legacy applications often cannot be modified to add an `/healthz` endpoint. In these cases, DevOps engineers use two main patterns:

1.  **The "Exec" Probe (Most Common):** Instead of an HTTP call, K8s runs a script or command already bundled in the container.
    *   **Process Check:** `command: ["kill", "-0", "1"]`
        *   **Why PID 1?** In Linux containers, the application started by `ENTRYPOINT` or `CMD` always has Process ID 1. If this process dies, the container should stop, but sometimes it "hangs" in a zombie state.
        *   **What does `kill -0` do?** It sends **no signal**. Instead, it just checks if the process exists and if the caller has permission to signal it.
        *   **Exit Logic:** If the process is alive, the command returns **0** (Success). If the process is gone, it returns **1** (Failure), triggering the K8s probe failure.
    *   **File Check:** `command: ["ls", "/var/run/app.pid"]`.
    *   **Legacy CLI:** Use the app's own CLI for status: `command: ["/opt/myapp/bin/status-check.sh"]`.

2.  **The "Sidecar" Pattern (The Architecture):** 
    In Kubernetes, all containers in a **Pod** share the same logical "host." This is what makes a sidecar possible:
    *   **Shared Network (Localhost):** The sidecar and the legacy app share the same network namespace. This means the sidecar can "talk" to the legacy app using `127.0.0.1:[legacy-port]`.
    *   **The Translator Role:** The sidecar acts as a health proxy. It exposes a modern HTTP `/healthz` endpoint. When the Kubelet calls this endpoint, the sidecar runs a check against the legacy app (e.g., a complex script or binary check) and translates it into a simple `200 OK`.
    *   **Shared Volumes:** If the legacy app writes logs or status files, you can use an `emptyDir` volume shared between both containers, allowing the sidecar to "watch" the app's internal files.

---

## 6. Best Practice for Fullstack Apps: "Deep" vs "Shallow"

For a fullstack application (e.g., React + Node + DB), **HTTP GET is the best method**, but you must use it strategically.

### Why HTTP is Best:
Unlike a TCP check (which only knows if the server is "on"), an HTTP endpoint can run logic. You should implement a "Deep Health Check" that validates:
*   **Database Connectivity:** Can the app still talk to the DB?
*   **Cache Status:** Is Redis reachable?
*   **Dependencies:** Are critical external APIs responding?

### The "Pro" Strategy:
1.  **Liveness Probe (Shallow):** Should only check if the process is alive (e.g., returns `200 OK` immediately). If you put deep logic here and the DB is slightly slow, K8s might kill your app unnecessarily.
2.  **Readiness Probe (Deep):** This is where you check your Database/Redis. If the DB goes down, K8s will stop sending user traffic to that Pod until the DB is back, but it **won't kill the Pod**.

---

## 7. The "Monitor": `kubectl rollout status`
After the CI/CD pipeline runs `kubectl apply`, it doesn't just stop. It runs:
`kubectl rollout status deployment/my-app`

*   **How it works:** This command waits for all pods in the new version to pass their **Readiness Probes**.
*   **Handling Crashes:** If a pod enters a `CrashLoopBackOff` or fails its probes, this command returns a **non-zero exit code** after a timeout.
*   **Pipeline Failure:** The CI/CD pipeline (GitHub Actions, Jenkins, etc.) marks the step as **FAILED** due to the error code.

---

## 6. GitOps (ArgoCD/Flux)
If using GitOps, the controller inside the cluster constantly compares the "Desired State" (Git) with the "Live State" (Cluster).
*   If the new pods are crashing, the ArgoCD dashboard will show a **"Degraded"** status.
*   The pipeline only updates Git; the controller manages the health and alerts within the cluster.

---

## 9. CI/CD Observability & Notifications

In a mature DevOps culture, knowing *when* a pipeline fails is just as important as the deployment itself.

### A. The Evolution of Notifications
1.  **Email (Traditional):** Good for formal records, but often gets ignored in a busy inbox. Usually used for "Audit" logs.
2.  **ChatOps (Modern):** Sending alerts directly to **Slack**, **Microsoft Teams**, or even **WhatsApp/Telegram**. This allows the whole team to see the failure instantly and discuss the fix in the same thread.
3.  **On-Call (Critical):** For production failures, tools like **PagerDuty** or **Opsgenie** are used to "page" the engineer on duty.

### B. Best Practices
*   **Don't Spam:** Only notify on "State Changes" (e.g., when a build goes from Success to Failure, or when a Failure is Fixed).
*   **Include Context:** A good notification should include the **Commit Message**, the **Developer Name**, and a **Link to the Logs**.

### C. Group vs. Individual Messaging
To message an entire team at once, you use different methods depending on the tool:

1.  **Slack & MS Teams (The Channel Way):** 
    You create an **Incoming Webhook** for a specific channel. GitHub Actions sends the message to that one URL, and *everyone* in the channel sees it instantly. This is the gold standard for groups.
2.  **Telegram (The Group Chat Way):** 
    You create a Group Chat, add your Bot to it, and get the **Group ID**. When the Bot sends a message to that ID, the whole group receives it.
3.  **WhatsApp Sandbox (The Limitation):** 
    The sandbox **does not support groups** easily. Each person must manually "join" the sandbox, and your GitHub Action must send a separate message to each phone number. This is why it's mostly used for solo developers or critical "emergency" alerts for one person.

### D. Step-by-Step: How to Create a Group Webhook

#### 1. Slack (Incoming Webhooks)
1.  Go to the **[Slack App Directory](https://api.slack.com/apps)** and click **"Create New App"**.
2.  Select **"From scratch"**, give it a name (e.g., `K8s-Deploy-Bot`), and select your workspace.
3.  On the left menu, click **"Incoming Webhooks"** and toggle the switch to **"On"**.
4.  Click **"Add New Webhook to Workspace"** at the bottom.
5.  Select the **Channel** (e.g., `#devops-alerts`) you want the bot to post to.
6.  **Copy the Webhook URL.** It will look like `https://hooks.slack.com/services/T000/B000/XXXX`.

#### 2. Microsoft Teams (Incoming Webhooks)
1.  Open the **Teams Channel** where you want to receive alerts.
2.  Click the **"..." (More options)** next to the channel name and select **"Connectors"**.
3.  Search for **"Incoming Webhook"** and click **"Add"** or **"Configure"**.
4.  Give the webhook a name (e.g., `Github-Alerts`) and click **"Create"**.
5.  **Copy the Webhook URL.** It will be a very long link ending in `...[long-ID]`.

#### 3. How to use in GitHub
Once you have the URL from Slack or Teams:
1.  Go to your **GitHub Repository** -> **Settings**.
2.  Click **Secrets and variables** -> **Actions**.
3.  Click **"New repository secret"**.
4.  Name it `SLACK_WEBHOOK` or `TEAMS_WEBHOOK` and paste the URL as the value.
5.  The GitHub Action will now automatically "Broadcast" to the entire channel when a build fails.

---

## 11. Deep Dive: GitHub Actions Steps

Here is a detailed breakdown of what happens in each step of the [github_actions_k8s.yaml](file:///home/sylaw/.gemini/antigravity/brain/35140846-7200-4214-ae23-1d92b772b8f1/github_actions_k8s.yaml) example:

### 1. Checkout Code
*   **Action:** `actions/checkout@v4`
*   **What it does:** Downloads your repository's source code onto the GitHub runner (the temporary virtual machine).

### 2. Log in to Docker Registry
*   **Action:** `docker/login-action@v3`
*   **What it does:** Authenticates the runner with your container registry (Docker Hub, AWS ECR, etc.) using `secrets` you've stored in GitHub. This is required so you can "Push" your image in the next step.

### 3. Build and Push Docker Image
*   **The Script:**
    1.  `IMAGE_TAG=$(git rev-parse --short HEAD)`: Gets the first 7 characters of the current Git commit hash. This makes every build unique.
    2.  `docker build`: Creates the container image from your `Dockerfile`.
    3.  `docker push`: Sends the image to your registry.
    4.  `echo ... >> $GITHUB_ENV`: Saves the `IMAGE_TAG` so later steps in the same job can use it.

### 4. Set up Kubeconfig
*   **Action:** `azure/k8s-set-context@v3`
*   **What it does:** This is the most important "connection" step. It takes your cluster's credentials (the `KUBECONFIG` secret) and configures the `kubectl` tool on the runner so it has permission to talk to your Kubernetes cluster.

### 5. Deploy to Kubernetes
*   **The Script:**
    1.  `sed -i ...`: This is a "Search and Replace" command. It finds the placeholder image in your `k8s/deployment.yaml` and replaces it with the exact `IMAGE_TAG` you just built.
    2.  `kubectl apply -f ...`: Sends the updated YAML to the cluster.
    3.  `kubectl rollout status ...`: This is the **Safety Check**. The pipeline will sit and wait for Kubernetes to confirm that the new pods are "Ready." If they crash, this step fails, and your pipeline stops.
