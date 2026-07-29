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
