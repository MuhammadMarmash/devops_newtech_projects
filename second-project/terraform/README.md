# Kubernetes The Hard Way — Phase 1 Infrastructure

Terraform for a from-scratch Kubernetes cluster on AWS, built without kubeadm. This is
Phase 1 of five: it provisions the machines and the boot-secret channel. PKI, control
plane bootstrap, worker TLS bootstrapping, and pod networking are Phases 2–5.

## Layout

| Path | Responsibility |
|---|---|
| `versions.tf` | Provider constraints and default tags |
| `variables.tf` | Every tunable input |
| `main.tf` | Module composition, AMI lookup, SSH key pair |
| `outputs.tf` | The machine inventory consumed by the orchestrator |
| `modules/network` | VPC, subnets, IGW, NAT gateway, route tables |
| `modules/security` | Jumpbox SSH group and intra-cluster group |
| `modules/iam` | Two roles: jumpbox writes SSM, nodes read it |
| `modules/ssm` | Boot-secret parameters |
| `modules/machine` | One EC2 instance; instantiated four or more times |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then narrow ssh_allowed_cidrs
terraform init
terraform apply
terraform output -json cluster | jq
eval "$(terraform output -raw jumpbox_ssh_command)"
terraform destroy
```

A NAT gateway bills by the hour whether or not the cluster is doing anything. Destroy
when you are finished.

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
`10.200.0.0/16` rule is what stops those packets being dropped on ingress. Inert until
Phase 5.

**`source_dest_check = false` on workers only.** Pod IPs are not the instance's own
address, so EC2 drops those packets silently unless this is off. The control plane runs
no kubelet and schedules no pods, so it does not need it. Diagnostic rule of thumb: a
refused connection means nothing is listening; a timeout means something is dropping
packets.

**Two IAM roles rather than one.** The jumpbox writes to SSM because the orchestrator
runs there and mints the CA certificate and bootstrap token. Nodes only read. This stops
a compromised worker rewriting the CA certificate that every future node will trust.

**IAM policies use a path wildcard.** `parameter/kthw/*` rather than enumerated ARNs —
required, not lazy: Phase 3 creates the bootstrap token at runtime, so no Terraform-known
ARN list could include it.

**Terraform creates the SSM parameters; Python fills two of them.** Terraform owns their
existence, the orchestrator owns their contents, and `lifecycle { ignore_changes = [value] }`
keeps the boundary. Without it, an unrelated apply would reset the cluster's CA to
`"PLACEHOLDER"`. Creating them here also means `terraform destroy` removes them, so no
live bootstrap token outlives its cluster.

**Workers keyed by name, not `count`.** With `count`, removing `node-0` renumbers and
rebuilds every later worker.

**IMDSv2 required.** Worker bootstrap reads credentials from the instance metadata
service, and IMDSv1 is the classic SSRF-to-credential-theft path.

**Local state.** One operator, no concurrency. Note that `tls_private_key` puts the SSH
private key in plaintext in state — tolerable only because state is local and gitignored.
Moving to remote state would require encryption first.

## Phase 2 — PKI bootstrap

`null_resource.cert_bootstrap` turns the four machines above into a cluster with a real
certificate authority, automatically, as part of `terraform apply`. No separate script to
run by hand.

**What it does.** Over SSH, it uploads `scripts/ca.conf.template` (rendered with the
server's real private IP and one `[node-N]` section per actual worker), the operator's
own SSH private key, and `scripts/generate-certs.sh` to the jumpbox, then runs the script
there: generate a self-signed CA, sign one leaf certificate per worker plus six
control-plane certificates — `admin`, `kube-proxy`, `kube-scheduler`,
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

**Idempotency.** Terraform provisioners fire once, at creation; the `triggers` block only
forces a re-run if the server's IP changes. `generate-certs.sh` also checks for an
existing `ca.key` before generating anything, so even a manual `terraform taint
null_resource.cert_bootstrap` can't silently replace a CA that's already signed working
certificates.

## Phase 3 — control-plane bootstrap

`null_resource.control_plane_bootstrap` brings up etcd, kube-apiserver,
kube-controller-manager, and kube-scheduler on `server`, automatically, right after
Phase 2's certs and kubeconfigs land. Binaries and configs are the exact pinned set from
upstream KTHW's `downloads-amd64.txt` (Kubernetes v1.32.3, etcd v3.6.0-rc.3 — a release
candidate, upstream's own pin).

**Addressing.** Every place upstream hardcodes `server.kubernetes.local`, this project
substitutes the real private IP — kubeconfigs' `--server`, the apiserver's
`--service-account-issuer`. No DNS exists in this project and none is planned.

**Idempotency.** Same two-layer pattern as Phase 2: Terraform's `triggers` only re-runs
the provisioner if `server`'s IP changes, and the script itself checks whether
`kube-apiserver` is already active before doing any work. The encryption key protecting
Kubernetes Secrets at rest has its own, separate persistence guard — regenerating it would
make every already-encrypted Secret permanently unreadable, a failure mode worse than a
merely-skipped step.

## Phase 4 — worker bootstrap

Two more `null_resource`s bring up `containerd`, `kubelet`, and `kube-proxy` on every
worker, right after Phase 3's control plane is running. `worker_binaries_prepared` runs
once — it extracts the worker binaries Phase 3 already downloaded but didn't need
(`kubelet`, `kube-proxy`, `containerd`, `runc`, `crictl`, the CNI plugins), and stages
every config file onto the jumpbox. `worker_bootstrap` then runs once per worker, via
Terraform's `for_each` — so a failed `node-3` retries independently of `node-0`/`node-1`.

**No pod networking yet.** Only `99-loopback.conf` is installed into `/etc/cni/net.d/` —
not the CNI bridge config upstream's tutorial hand-assigns a subnet to. This project
deliberately defers pod-subnet assignment to Phase 5's dynamic allocation (Phase 1's own
design decision), so nodes registering as `NotReady` after this phase is expected, not a
bug. Certs and kubeconfigs need no attention here — Phase 2 already delivered them to
`/var/lib/kubelet/` and `/var/lib/kube-proxy/` on every worker.

## Phase 5 — dynamic pod networking

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
that breaks when a worker is added or removed.

**Why AWS routes, not upstream's host-level `ip route add`.** Phase 1 exported
`private_route_table_id` and every worker's `primary_network_interface_id` specifically
for this moment (its own code comments say so). One route table entry per worker,
programmed once, replaces re-entering host routes on every machine for every node
change — the same underlying mechanism (a router needs to know which next-hop owns which
subnet), expressed at the layer this project's infrastructure already lives in.

**This is also where Phase 1's one unproven assumption finally gets tested.** The
cluster security group's pod-CIDR ingress rule was flagged, back in Phase 1, as reasoned
from AWS's documented behavior but never observed directly. A real pod-to-pod
connectivity test is the first time that rule's actual behavior is confirmed.

## Verifying a deployment

```bash
eval "$(terraform output -raw jumpbox_ssh_command)"          # 1  IGW, key, jumpbox SG
ssh admin@<server-private-ip>                                # 2  cluster self-rule
sudo apt-get update                                          # 3  NAT and private route
aws ssm put-parameter --name /kthw/test --value x --type String --region eu-north-1
                                                             # 4  jumpbox write
aws ssm get-parameter --name /kthw/bootstrap-token --with-decryption --region eu-north-1
                                                             # 5  node read plus KMS
aws ssm put-parameter --name /kthw/evil --value x --type String --region eu-north-1
                                                             # 6  must fail: AccessDenied
```

Test 6 is the valuable one. Tests 4 and 5 pass equally well with a single
over-permissive role; only 6 distinguishes them. A boundary never tested is an
assumption, not a control.
