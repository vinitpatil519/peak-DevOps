# Local setup (free path): Windows or Linux

Three ways to run CloudForge locally, from lightest to fullest:

| Level | What you get | Needs |
|---|---|---|
| A. docker compose | 3-tier app + optional Prometheus/Grafana | Docker |
| B. kind, Helm mode | Full Kubernetes platform: Istio mTLS, NGINX Ingress, canary/blue-green, monitoring, logging | Docker, kind, kubectl, helm, istioctl |
| C. kind, GitOps mode | B + Argo CD reconciling everything from your GitHub fork, Jenkins CI | B + GitHub fork, Jenkins stack |

Hardware: level B/C need ~8 GB RAM and 4 CPUs free for Docker.

---

## 1. Install tools

### Windows 11

1. **Docker Desktop** — enable *Use the WSL 2 based engine*. Settings → Resources: 8 GB RAM, 4 CPUs.
2. **WSL2 Ubuntu**: `wsl --install -d Ubuntu-24.04`. Run every command below **inside WSL** (bash), from the repo cloned into the Linux filesystem (`~/src`, not `/mnt/c`) for speed.
3. In Docker Desktop → Settings → Resources → WSL integration: enable for Ubuntu.
4. Inside WSL, install the rest with Ansible (idempotent, pinned versions):

   ```bash
   sudo apt update && sudo apt install -y ansible git make python3-pip
   git clone https://github.com/vinitpatil519/CloudForge.git ~/src/cloudforge && cd ~/src/cloudforge/infra-ansible
   ansible-galaxy collection install -r requirements.yml
   ansible-playbook playbooks/workstation.yml -K      # kubectl, kind, helm, istioctl, argocd, rollouts plugin, k9s
   ```

   The `docker` role detects Docker Desktop and skips the engine install.
5. Kernel settings for kind (many pods) and SonarQube, from PowerShell:
   `wsl -d docker-desktop sysctl -w vm.max_map_count=524288 fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512`

### Ubuntu 22.04 / 24.04

```bash
sudo apt update && sudo apt install -y ansible git make
git clone https://github.com/vinitpatil519/CloudForge.git && cd CloudForge/infra-ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/workstation.yml -K     # Docker Engine + all CLIs + sysctls
newgrp docker
```

Check: `docker version && kind version && kubectl version --client && helm version && istioctl version --remote=false`

---

## 2. Level A — docker compose

```bash
cp .env.example .env            # edit passwords
docker compose up --build -d
open http://localhost:3000      # app ;  http://localhost:8080/api/v1/info (Apache tier directly)
docker compose --profile observability up -d   # Prometheus :9090, Grafana :3001
```

The `data` network is `internal: true`: Postgres and Redis are unreachable from the host and
from the web tier — only the API can reach them.

---

## 3. Level B — kind + Helm (recommended first run)

```bash
make kind-up          # = MODE=helm scripts/bootstrap-local.sh
```

What the script does, in order:

1. Starts a local registry `localhost:5001` and creates the kind cluster from
   `scripts/kind-config.yaml` (1 control plane with host ports 80/443, 2 workers).
2. Builds `cloudforge/{api,web,apache-proxy}:local` and loads them into the nodes.
3. Installs Istio with the **CNI plugin** (`k8s-manifests/istio/istio-operator.yaml`) so app
   namespaces can enforce Pod Security *restricted*.
4. Pre-creates `frontend`, `backend`, `database`, `monitoring` namespaces and **random
   credentials** as Secrets (never written to Git).
5. Installs add-ons with pinned versions: metrics-server, cert-manager, Argo Rollouts, VPA
   (recommender), kube-prometheus-stack, Loki, Fluent Bit, ingress-nginx (in the mesh).
6. Installs the CloudForge charts in dependency order: `platform → postgres → redis → backend →
   apache-proxy → frontend`.
7. Installs Argo CD for exploration.

Then add to your hosts file (Windows: `C:\Windows\System32\drivers\etc\hosts` as admin; Linux: `/etc/hosts`):

```
127.0.0.1 cloudforge.local preview.cloudforge.local mesh.cloudforge.local
```

Verify:

```bash
kubectl get pods -A                      # everything Running/Completed
make smoke                               # end-to-end checks through all tiers
open http://cloudforge.local             # storefront
open http://cloudforge.local/grafana     # dashboards (folder "CloudForge")
kubectl get peerauthentication -A        # STRICT mTLS
istioctl x describe pod -n backend $(kubectl get pod -n backend -l app.kubernetes.io/name=backend-api -o name | head -1 | cut -d/ -f2)
```

### Try the deployment strategies

```bash
make canary                                            # builds a new tag, starts canary + blue/green
kubectl argo rollouts get rollout backend-api -n backend --watch
kubectl get vs backend-api -n backend -o jsonpath='{.spec.http[0].route[*].weight}{"\n"}'
open http://preview.cloudforge.local                   # green version before promotion
kubectl argo rollouts promote frontend -n frontend     # cut over
```

### Drive load and watch autoscaling

```bash
docker run --rm -i --network host -e BASE_URL=http://cloudforge.local grafana/k6 run - < scripts/load-test.js
kubectl get hpa -A -w
```

---

## 4. Level C — GitOps + Jenkins

1. **Repo URL.** Argo CD, Jenkins and alert runbook links point at
   `https://github.com/vinitpatil519/CloudForge.git`. If you fork, replace it everywhere:

   ```bash
   grep -rl 'vinitpatil519/CloudForge' . | xargs sed -i 's#vinitpatil519/CloudForge#<you>/<repo>#g'
   git commit -am "chore: point GitOps at my fork" && git push
   ```

2. **Cluster with Argo CD in control**: `make kind-down && make kind-gitops`. The root app
   (`gitops/root-app.yaml`) creates the AppProjects and two ApplicationSets which render
   one Argo CD Application per add-on and per chart. Watch: `kubectl -n argocd get applications -w`.
3. **CI stack** (Jenkins + SonarQube):

   ```bash
   cp jenkins/.env.example jenkins/.env      # set passwords, GitHub PAT, NVD key
   ansible-playbook infra-ansible/playbooks/jenkins.yml -K
   ```

   - SonarQube http://localhost:9000 → change admin password → create a token → put it in
     `jenkins/.env` as `SONAR_TOKEN` and re-run the playbook. Add a webhook
     *Administration → Configuration → Webhooks* → `http://jenkins:8080/sonarqube-webhook/`.
   - Jenkins http://localhost:8081 (admin / `JENKINS_ADMIN_PASSWORD`). The JCasC seed job
     creates the `cloudforge-platform` multibranch pipeline.
4. Push a change to `app-backend/`. Jenkins tests, scans, builds, pushes to `localhost:5001`,
   commits the new tag to `gitops/environments/local/*.yaml`; Argo CD syncs and Argo Rollouts
   runs the canary.

---

## 5. Minikube instead of kind

```bash
minikube start -p cloudforge --cpus 4 --memory 8g --kubernetes-version=stable --cni=calico
minikube -p cloudforge addons enable registry
eval $(minikube -p cloudforge docker-env)       # build images straight into the node
for i in api:app-backend web:app-frontend apache-proxy:apache-proxy; do docker build -t cloudforge/${i%%:*}:local ${i#*:}; done
istioctl install -y -f k8s-manifests/istio/istio-operator.yaml
source scripts/lib.sh && ensure_app_namespaces && ensure_app_secrets && install_addons local && install_apps local
echo "$(minikube -p cloudforge ip) cloudforge.local preview.cloudforge.local" | sudo tee -a /etc/hosts
```

Calico is used because minikube's default CNI does not enforce NetworkPolicy.
In `gitops/addons/ingress-nginx/values-local.yaml`, hostPort + NodePort also works on minikube.

## 6. Clean up

```bash
make kind-down                                         # cluster + registry
docker compose --profile observability down -v         # compose stack + volumes
docker compose -f jenkins/docker-compose.yml down -v   # CI stack
```
