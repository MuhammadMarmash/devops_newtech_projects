# Kubernetes The Hard Way — Automated on AWS

A from-scratch Kubernetes cluster on AWS, built without `kubeadm`, brought up entirely by
`terraform apply`. All five phases of the build exist in this codebase: infrastructure,
PKI, control plane, worker bootstrap, and dynamic pod networking. Nothing has ever been
applied to real AWS — this is the first live run.

This follows [Kelsey Hightower's Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
faithfully where upstream's method survives automation, and departs from it deliberately
(with the reasoning recorded below) where it doesn't. The two departures that matter most:
no kubelet TLS bootstrapping (certs are generated centrally and copied out, matching
upstream's own simpler method, rather than the harder self-service CSR flow) and pod
routing via real AWS VPC routes instead of upstream's hand-typed `ip route add`.

## Before you apply

**Capacity.** `t3.micro` is capacity-starved in `eu-north-1`. If `jumpbox` fails to launch
with `InsufficientInstanceCapacity`, it's not a bug — override in `terraform.tfvars`:

```hcl
availability_zone     = "eu-north-1b"
jumpbox_instance_type = "t3.small"
```

Terraform retries silently for a long time before surfacing this error, which looks like a
hang. If `apply` seems stuck on the jumpbox for more than a couple of minutes, that's
usually what's happening — check `Ctrl+C` and rerun `terraform plan` rather than waiting.

**vCPU quota.** Default is 8 (`L-1216C47A`). Four `t3.small` machines already use all 8.
Anything else running in the same region/account blocks the apply with a quota error, not
a capacity error — check `EC2 → Limits` if `server`/workers fail the same way `jumpbox`
might.

**Network.** Some networks (university/corporate) block outbound port 22. If SSH from your
machine to the jumpbox hangs while `https://github.com` works fine, that's the network, not
AWS — a hotspot usually resolves it. Diagnose with `nc -zv <jumpbox-ip> 22` before assuming
anything is broken on the AWS side.

**Credentials.** The AWS CLI must already be configured (`aws sts get-caller-identity`
should work) before `terraform apply` — Terraform itself, and every jumpbox-side script,
relies on it.

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars   # then narrow ssh_allowed_cidrs, adjust AZ/type if needed
terraform init
terraform apply
```

One `apply` brings up all five phases in order — infrastructure, then PKI, then control
plane, then workers, then pod networking — each gated behind the last via `depends_on`.
Expect it to take a while: NAT gateway provisioning, ~700MB of Kubernetes/etcd/containerd
binaries downloaded once on the jumpbox, and multiple SSH hops doing real work. This is not
a fast `apply`.

When it's done:

```bash
terraform output -json cluster | jq
eval "$(terraform output -raw jumpbox_ssh_command)"
```

A NAT gateway bills by the hour whether or not the cluster is doing anything:

```bash
terraform destroy
```

## Topology

```
                        Internet
                            │
                    ┌───── IGW ─────┐
                    │               │
   public  10.240.0.0/24            │
     jumpbox (public IP)  ──►  NAT gateway
                                    │
   private 10.240.1.0/24            │
     server, node-0 … node-N  ──────┘  (egress only)
```

Pod network `10.200.0.0/16`, service network `10.32.0.0/24`, apiserver ClusterIP
`10.32.0.1`. None of the four ranges overlap.

## What `terraform apply` actually does

| Stage | Resource | Runs where | Depends on |
|---|---|---|---|
| 1. Infrastructure | `module.network`/`security`/`iam`/`ssm`/`machine` | Terraform itself | — |
| 2. PKI | `null_resource.cert_bootstrap` | jumpbox → hops to each worker | Stage 1 |
| 3. Control plane | `null_resource.control_plane_bootstrap` | jumpbox → hops to `server` | Stage 2 |
| 4. Worker binaries | `null_resource.worker_binaries_prepared` | jumpbox only | Stage 3 |
| 4. Worker bootstrap | `null_resource.worker_bootstrap` (×N, one per worker) | jumpbox → hops to each worker | Worker binaries |
| 5. Pod networking | `null_resource.pod_networking` | jumpbox → hops to each worker + AWS API | All `worker_bootstrap` |

Everything past Stage 1 runs as shell scripts over SSH from the jumpbox — there is no
separate orchestrator process, no Python, nothing running after `apply` finishes. The full
"why" for each stage is under **Design decisions** below.

## Verifying a deployment

Run these in order after `terraform apply` completes. Each proves the stage above it
actually worked, not just that Terraform didn't error.

**1. Infrastructure.**

```bash
eval "$(terraform output -raw jumpbox_ssh_command)"          # IGW, key, jumpbox SG
ssh admin@<server-private-ip>                                # cluster self-rule (from the jumpbox)
sudo apt-get update                                          # NAT and private route
aws ssm put-parameter --name /kthw/test --value x --type String --region eu-north-1
                                                               # jumpbox write
aws ssm get-parameter --name /kthw/bootstrap-token --with-decryption --region eu-north-1
                                                               # node read plus KMS
aws ssm put-parameter --name /kthw/evil --value x --type String --region eu-north-1
                                                               # must fail: AccessDenied
```

The last one is the check that matters — a working read/write pair passes even with a
single over-permissive role; only a confirmed *denial* proves the boundary is real.

**2. PKI.** From the jumpbox:

```bash
ls certs/*.crt certs/*.kubeconfig
openssl verify -CAfile certs/ca.crt certs/kube-api-server.crt
aws ssm get-parameter --name /kthw/ca.crt --region eu-north-1 --query Parameter.Value --output text | head -1
```

Expect a cert for every control-plane role plus one per worker, all verifying against
`ca.crt`, and the SSM parameter starting with `-----BEGIN CERTIFICATE-----`.

**3. Control plane.** From the jumpbox:

```bash
kubectl cluster-info --kubeconfig certs/admin.kubeconfig
kubectl get componentstatuses --kubeconfig certs/admin.kubeconfig
ssh -i ~/kthw.pem admin@<server-private-ip> \
  'systemctl is-active etcd kube-apiserver kube-controller-manager kube-scheduler'
```

Expect `Kubernetes control plane is running at https://<server-ip>:6443` and `active`
printed four times. `componentstatuses` may print deprecation warnings — normal for this
Kubernetes version, not a failure.

**4. Worker bootstrap.**

```bash
kubectl get nodes --kubeconfig certs/admin.kubeconfig
```

**Check the `NAME` column specifically** — it must read `node-0`, `node-1`, etc., not an
AWS-assigned hostname like `ip-10-240-1-45`. If it shows the wrong name, or the list is
empty, kubelet is failing to register — check `journalctl -u kubelet` on the worker for
`is not allowed to modify node`, and confirm `--hostname-override` actually made it into
`/etc/systemd/system/kubelet.service` on the worker (see Troubleshooting below).

`STATUS` will read `NotReady` at this point — **expected**, not a failure. No pod network
exists yet; that's Stage 5's job. Also expect:

```bash
for w in $(terraform output -json cluster | jq -r '.workers | keys[]'); do
  ip=$(terraform output -json cluster | jq -r ".workers[\"$w\"].private_ip")
  ssh -i ~/kthw.pem admin@"$ip" 'systemctl is-active containerd kubelet kube-proxy'
done
```

(run from the jumpbox, or prefix with the jumpbox hop if running from your own machine).

**5. Pod networking — the actual, final proof.**

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.podCIDR}{"\n"}{end}' --kubeconfig certs/admin.kubeconfig
```

Every node should now have a `10.200.x.0/24`-shaped CIDR, and `kubectl get nodes` should
show `Ready` (a brief `NotReady` right after `apply` completes, while kubelet picks up the
new CNI config, is not a failure — recheck after a minute).

Then the real test — two pods, two different nodes, one talks to the other:

```bash
kubectl run pod-a --image=busybox --restart=Never \
  --overrides='{"spec":{"nodeName":"node-0"}}' --kubeconfig certs/admin.kubeconfig -- sleep 3600
kubectl run pod-b --image=busybox --restart=Never \
  --overrides='{"spec":{"nodeName":"node-1"}}' --kubeconfig certs/admin.kubeconfig -- sleep 3600
# wait for both to reach Running, then:
POD_B_IP=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}' --kubeconfig certs/admin.kubeconfig)
kubectl exec pod-a --kubeconfig certs/admin.kubeconfig -- ping -c 3 "${POD_B_IP}"
kubectl delete pod pod-a pod-b --kubeconfig certs/admin.kubeconfig
```

`0% packet loss` here is the project's actual, original success criterion — packets
crossing node boundaries, on infrastructure this apply built from nothing.

```bash
aws ec2 describe-route-tables --region eu-north-1 \
  --route-table-ids "$(terraform output -raw private_route_table_id)" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,ENI:NetworkInterfaceId}' --output table
```

One row per worker, each with a real `eni-...` target, confirms the routing layer
independently of the ping.

## Troubleshooting

**`kubectl get nodes` is empty, or shows the wrong name, after Stage 4.** kubelet
registers under `--hostname-override`, which is rendered per-worker from
`kubelet.service.template` into `/home/admin/kubelet.service` on the jumpbox before being
shipped to that worker. If this is wrong, `journalctl -u kubelet` on the worker will show
`NodeRestriction`-style authorization errors (`is not allowed to modify node "..."`), not
a networking error — the fix is in `bootstrap-worker.sh`, not in AWS.

**`kubectl exec`/`kubectl logs` time out or fail TLS verification, even though
`kubectl get nodes` looks fine.** The apiserver dials the kubelet directly for these
(`--kubelet-preferred-address-types=InternalIP`), and that connection is
certificate-verified against the worker's own IP SAN (`ca.conf.template`'s per-worker
section). If Phase 2 ever runs against a `ca.conf.template` that's missing this, the
symptom is `x509: certificate is valid for ..., not <worker-ip>` — regenerating certs
(taint `null_resource.cert_bootstrap`) is the fix, not a control-plane restart.

**A `terraform apply` retry seems to do nothing after you've fixed a script.**
`worker_binaries_prepared` and `pod_networking` key their re-run `triggers` off a content
hash of every file they stage — editing a script *should* force a re-run automatically.
If it doesn't, confirm you edited a file that's actually in the hash (check the
`staged_files` trigger in `main.tf`) rather than, say, `bootstrap-control-plane.sh`, which
belongs to a different, independently-triggered resource.

**Phase 5 stalls for ~3 minutes per worker printing "Waiting for `<node>`'s pod CIDR", then
fails.** `configure-pod-networking.sh` polls `kubectl get node <name> -o jsonpath=...` and
prints the last real `kubectl` error on final failure — read that message first; it's
usually more specific than "never received a podCIDR" (an unreachable apiserver, an
expired/mismatched kubeconfig, or the node genuinely never having registered — see the
first item above).

**A worker gets replaced (new instance) and pod-to-pod networking breaks for that node
specifically.** `kube-controller-manager` can reassign a freed pod CIDR to the new
instance while the route table still points that CIDR at the old, now-deleted ENI.
`configure-pod-networking.sh` calls `aws ec2 replace-route` in exactly this case (not just
`create-route`), so a plain `terraform apply` should self-heal it — if it doesn't, check
`aws ec2 describe-route-tables` directly against the table's actual current routes.

**`terraform apply` looks stuck for 2+ minutes with no output on the jumpbox.** Almost
always the capacity issue under **Before you apply** — check the AWS Console's EC2 launch
events, or `Ctrl+C` and `terraform plan` to see what's still pending, before assuming
something is hung.

## Design decisions

**Dedicated VPC, not the default one.** In the default VPC, subnet and AZ assignment is
AWS's choice, so no two applies produce the same network shape. It also gives us a route
table we own — Phase 5 programs pod routes into it, and mutating a table shared with the
whole account is fine until it isn't.

**Single AZ.** The control plane is one instance. Spreading workers across AZs while the
apiserver and etcd sit on one box buys no availability and doubles the NAT bill. The AZ
and every CIDR are variables, so this is reversible.

**Private nodes behind a NAT.** Only the jumpbox has a public IP. Nodes reach the
internet for package and image pulls through the NAT and are reachable only from inside
the VPC.

**Self-referencing security group rule.** AWS denies intra-VPC traffic by default, which
Kubernetes The Hard Way never mentions because it assumes a flat network. The `cluster`
group allows all traffic from itself, covering etcd, the apiserver, and kubelet.

**An explicit pod-CIDR ingress rule as well.** A rule whose source is a security group is
resolved by mapping the packet's source IP to an ENI carrying that group. A pod packet's
source address belongs to no ENI, so the self-rule cannot match it. The separate
`10.200.0.0/16` rule was added for this — though the CNI bridge's own `ipMasq` behavior
means cross-node pod traffic actually leaves each node already source-NATed to that node's
own IP, so in practice the `cluster_self` rule is very likely what's really carrying that
traffic; the pod-CIDR rule remains a belt-and-suspenders rule whose necessity has not been
cleanly isolated by testing. It costs nothing to leave in place.

**`source_dest_check = false` on workers only.** Pod IPs are not the instance's own
address, so EC2 drops those packets silently unless this is off. The control plane runs
no kubelet and schedules no pods, so it does not need it. Diagnostic rule of thumb: a
refused connection means nothing is listening; a timeout means something is dropping
packets.

**Two IAM roles rather than one.** The jumpbox writes to SSM because the orchestrator
runs there and mints the CA certificate and bootstrap token. Nodes only read. This stops
a compromised worker rewriting the CA certificate that every future node will trust.

**IAM policies use a path wildcard.** `parameter/kthw/*` rather than enumerated ARNs —
required, not lazy: later phases create parameters at runtime, so no Terraform-known ARN
list could include them.

**Terraform creates the SSM parameters; the jumpbox scripts fill them.** Terraform owns
their existence, the jumpbox's scripts own their contents, and
`lifecycle { ignore_changes = [value] }` keeps the boundary. Without it, an unrelated
apply would reset the cluster's CA to `"PLACEHOLDER"`. Creating them here also means
`terraform destroy` removes them, so no live secret outlives its cluster.

**Workers keyed by name, not `count`.** With `count`, removing `node-0` renumbers and
rebuilds every later worker.

**IMDSv2 required.** Worker bootstrap reads credentials from the instance metadata
service, and IMDSv1 is the classic SSRF-to-credential-theft path.

**Local state.** One operator, no concurrency. Note that `tls_private_key` puts the SSH
private key in plaintext in state — tolerable only because state is local and gitignored.
Moving to remote state would require encryption first.

### Phase 2 — PKI bootstrap

`null_resource.cert_bootstrap` turns the four machines above into a cluster with a real
certificate authority, automatically, as part of `terraform apply`. No separate script to
run by hand.

**What it does.** Over SSH, it uploads `scripts/ca.conf.template` (rendered with the
server's real private IP and one `[node-N]` section per actual worker, each carrying that
worker's own private IP as a certificate SAN — see "Why every worker cert carries an IP
SAN" below), the operator's own SSH private key, and `scripts/generate-certs.sh` to the
jumpbox, then runs the script there: generate a self-signed CA, sign one leaf certificate
per worker plus six control-plane certificates — `admin`, `kube-proxy`, `kube-scheduler`,
`kube-controller-manager`, `kube-api-server`, `service-accounts` — verify every signature
and every CN/O/SAN field, publish `ca.crt` to `/kthw/ca.crt` in SSM using the jumpbox's
own IAM role, then hop from the jumpbox to each worker over SSH and `scp` its cert/key
pair plus `ca.crt` into `/var/lib/kubelet/`. This matches upstream KTHW's own method
(`docs/04-certificate-authority.md`'s "Distribute the Client and Server Certificates")
rather than kubelet TLS bootstrapping — this project is for learning the manual mechanism,
not production-grade automation.

**Why the jumpbox, not your laptop.** Running the script locally would put the CA private
key on the operator's machine first; running it over `remote-exec` means it is born on the
jumpbox and never leaves. The operator's SSH private key does get copied to the jumpbox
(`/home/admin/kthw.pem`) so it can reach the workers in turn — that key isn't as sensitive
as the CA key, and copying it matches what this project's own testing steps already do by
hand.

**Where the CA private key lives.** Born on the jumpbox, and — starting in Phase 3 —
also copied to `server`, because `kube-controller-manager`'s built-in CSR-signing
controller needs it locally. Never copied anywhere else, and never leaves AWS.

**Why `openssl`, not a Python library.** This project's goal is understanding what
Kubernetes The Hard Way does, not building the most testable toolchain. `ca.conf.template`
reproduces upstream's `ca.conf`, with one deliberate edit: the apiserver certificate's SAN
list is templated, because its IP is only known after `terraform apply`. The `[node-N]`
sections are generated once per worker via Terraform's own `%{ for }` template syntax,
since `var.worker_count` is a variable in this project, unlike upstream's fixed two nodes.

**Why every worker cert carries an IP SAN, not just a `DNS:node-N` name.** This project
never sets up any name resolution (no `/etc/hosts`, no private DNS zone) — every other
address in this codebase is already the real private IP, not a hostname (see Phase 3's
"Addressing" below). The apiserver reaches back to each kubelet directly by IP for
`kubectl exec`/`logs`/metrics, and that connection is TLS-verified; without the IP SAN,
that verification fails even though the node itself registers and looks healthy in
`kubectl get nodes`.

**Idempotency.** Terraform provisioners fire once, at creation; the `triggers` block only
forces a re-run if the server's IP changes. `generate-certs.sh` also checks for an
existing `ca.key` before generating anything, so even a manual `terraform taint
null_resource.cert_bootstrap` can't silently replace a CA that's already signed working
certificates.

### Phase 3 — control-plane bootstrap

`null_resource.control_plane_bootstrap` brings up etcd, kube-apiserver,
kube-controller-manager, and kube-scheduler on `server`, automatically, right after
Phase 2's certs and kubeconfigs land. Binaries and configs are the exact pinned set from
upstream KTHW's `downloads-amd64.txt` (Kubernetes v1.32.3, etcd v3.6.0-rc.3 — a release
candidate, upstream's own pin).

**Addressing.** Every place upstream hardcodes `server.kubernetes.local`, this project
substitutes the real private IP — kubeconfigs' `--server`, the apiserver's
`--service-account-issuer`. No DNS exists in this project and none is planned. The
apiserver also reaches kubelets by `InternalIP` rather than the default preferred order
(`Hostname`, which would need working name resolution this project deliberately doesn't
have) — see Phase 2's IP-SAN note above, which this flag depends on.

**Idempotency.** Same two-layer pattern as Phase 2: Terraform's `triggers` only re-runs
the provisioner if `server`'s IP changes, and the script itself checks whether
`kube-apiserver` is already active before doing any work. The encryption key protecting
Kubernetes Secrets at rest has its own, separate persistence guard, stored in SSM rather
than only on the (ephemeral) jumpbox — regenerating it would make every already-encrypted
Secret permanently unreadable, a failure mode worse than a merely-skipped step.

### Phase 4 — worker bootstrap

Two more `null_resource`s bring up `containerd`, `kubelet`, and `kube-proxy` on every
worker, right after Phase 3's control plane is running. `worker_binaries_prepared` runs
once — it extracts the worker binaries Phase 3 already downloaded but didn't need
(`kubelet`, `kube-proxy`, `containerd`, `runc`, `crictl`, the CNI plugins), and stages
every config file onto the jumpbox. `worker_bootstrap` then runs once per worker, via
Terraform's `for_each` — so a failed `node-3` retries independently of `node-0`/`node-1`.

**Why kubelet needs `--hostname-override`.** By default kubelet registers itself under
the machine's own hostname, which on a fresh EC2 instance is AWS's auto-assigned name —
not `node-0`. But this worker's certificate identity (from Phase 2) is
`CN=system:node:node-0`, and the apiserver's `NodeRestriction` admission plugin refuses
any node object whose name doesn't match that identity. So `kubelet.service.template`
gets `--hostname-override=NODENAME`, rendered per-worker (via `sed`, the same technique
Phase 5 uses for `10-bridge.conf`) inside `bootstrap-worker.sh`, right before it's shipped
to that specific worker.

**No pod networking yet.** Only `99-loopback.conf` is installed into `/etc/cni/net.d/` —
not the CNI bridge config upstream's tutorial hand-assigns a subnet to. This project
deliberately defers pod-subnet assignment to Phase 5's dynamic allocation (Phase 1's own
design decision), so nodes registering as `NotReady` after this phase is expected, not a
bug. Certs and kubeconfigs need no attention here — Phase 2 already delivered them to
`/var/lib/kubelet/` and `/var/lib/kube-proxy/` on every worker.

### Phase 5 — dynamic pod networking

The last phase. `null_resource.pod_networking` makes pods on different workers reach
each other, with no hand-assigned subnet — the one piece of upstream KTHW's tutorial
this project's own charter singled out as not surviving automation (upstream hand-enters
a static `ip route add` per node pair from a hand-assigned `SUBNET` column).

**How it actually works.** `kube-controller-manager` (Phase 3) now runs with
`--allocate-node-cidrs=true --node-cidr-mask-size=24`, so each node gets a `/24` out of
`var.pod_cidr` automatically once it registers — no `machines.txt`-style hand-assignment.
A script polls each node's `.spec.podCIDR` until it's populated, renders that node's
`10-bridge.conf` (upstream's own file, one `sed` substitution — the CNI config Phase 4
deliberately didn't install), and creates one AWS VPC route per worker: that worker's pod
subnet, routed to that worker's own network interface. Every private-subnet instance
already shares this route table, so pod-to-pod traffic between any two workers flows
through AWS's own VPC routing — no per-host route table to maintain, and no manual step
that breaks when a worker is added or removed. If a worker is later replaced, the script
detects the pre-existing route for its (possibly reassigned) pod CIDR and `replace-route`s
it to the new ENI, rather than leaving a blackhole route behind.

**Why AWS routes, not upstream's host-level `ip route add`.** Phase 1 exported
`private_route_table_id` and every worker's `primary_network_interface_id` specifically
for this moment (its own code comments say so). One route table entry per worker,
programmed once, replaces re-entering host routes on every machine for every node
change — the same underlying mechanism (a router needs to know which next-hop owns which
subnet), expressed at the layer this project's infrastructure already lives in.
