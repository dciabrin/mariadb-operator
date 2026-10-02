# PVC Remediation for Stuck Galera Pods

## Background

In OpenShift/Kubernetes deployments that use local PVCs (e.g. local storage backed by
a specific worker node), a Galera pod cannot reschedule to a healthy node if its PVC
is tied via node-affinity to a node that has gone offline. The StatefulSet's pod will
remain `Pending` indefinitely, because Kubernetes will not delete or move a PVC that
has local node affinity.

The [PodRemediator](https://github.com/openstack-k8s-operators/infra-operator/pull/677)
(part of infra-operator) detects such situations and annotates the stuck PVC. The
mariadb-operator reacts to those annotations and orchestrates recovery in a safe,
serialized manner.

---

## New Data Structure: `UnavailablePods`

A new field is added to `GaleraStatus`:

```go
UnavailablePods map[string]UnavailablePodStatus `json:"unavailablePods,omitempty"`
```

Each entry is keyed by pod name and carries:

| Field | Type | Purpose |
|---|---|---|
| `Reason` | `PodUnavailabilityReason` | Why the pod is considered unavailable (e.g. `PVCStuckOnNode`) |
| `Node` | `string` | The node the stuck PVC is bound to |
| `Remediation` | `bool` | Whether the operator is **actively recovering** this pod right now |

This structure is generic and reusable — `PVCStuckOnNode` is the first reason code, but
the same map can track other unavailability conditions in the future (e.g. database
corruption, user-managed pods).

### Sequential remediation gate

At most **one pod** has `Remediation = true` at any time. If multiple PVCs are stuck,
the operator queues them and processes them one by one. A pod's entry is only removed
from `UnavailablePods` once recovery is confirmed complete (pod ready + Galera synced).

---

## Implementation: `internal/controller/remediation.go`

All remediation logic lives in a dedicated file, `internal/controller/remediation.go`,
to keep it separate from the main reconcile loop. It exposes three functions called
from `galera_controller.go`:

| Function | Role |
|---|---|
| `EnsurePVCAvailability` | Scans all PVCs of the Galera CR and populates `UnavailablePods` |
| `CheckForPendingPodRemediation` | Grants deletion consent to the PodRemediator for the active remediation |
| `CheckForResolvedPodRemediation` | Detects when a remediation is complete and clears the slot |

---

## Annotation Contract with PodRemediator

The PodRemediator and the mariadb-operator communicate through PVC annotations. All
annotation keys are imported from `infra-operator/apis/remediation/v1beta1`.

| Annotation | Set by | Meaning |
|---|---|---|
| `pvc-stuck-on-node` | PodRemediator | The PVC is bound to an unresponsive node |
| `request-id` | PodRemediator | Unique ID for this remediation request |
| `safe-to-delete` | mariadb-operator | Operator grants permission to delete the PVC |
| `consent-id` | mariadb-operator | Must echo `request-id` to complete the handshake |

The PodRemediator's `HasRemediationConsent()` check requires **both** `safe-to-delete = "true"`
and `consent-id = <request-id>` to be present. The mariadb-operator writes them
in a single patch to make the consent atomic.

---

## Flow Diagram

```
Galera Reconcile Loop
        │
        ▼
┌──────────────────────┐
│  EnsurePVCAvailability│
│  (called after STS   │
│   creation)          │
└──────────┬───────────┘
           │  For each PVC of the Galera CR (by ordinal)
           │
           ├─── PVC not found ──► skip (STS may not have created it yet)
           │
           ├─── PVC found, no stuck annotation ──► skip
           │
           └─── PVC has  pvc-stuck-on-node  annotation
                         │
                         ▼
                Add pod to UnavailablePods{Reason: PVCStuckOnNode, Node: <node>}
                         │
                         │  Is any other pod already being remediated?
                         ├─── YES ──► set Remediation=false  (queue, wait your turn)
                         └─── NO  ──► set Remediation=true   (this pod goes next)
                         │
                         ▼
              ┌──────────────────────────┐
              │ CheckForPendingPodRemediation│
              └──────────┬───────────────┘
                         │  Find pod with Remediation=true
                         │
                         ├─── PVC gone (already deleted by PodRemediator)
                         │    ──► nothing to do; pod will restart and rejoin
                         │
                         ├─── PVC exists, safe-to-delete already set
                         │    ──► nothing to do; waiting for pod restart
                         │
                         ├─── PVC exists, request-id empty
                         │    ──► defer; PodRemediator hasn't started yet
                         │
                         └─── PVC exists, request-id present
                              ──► PATCH PVC:
                                    safe-to-delete = "true"
                                    consent-id     = <request-id>
                              (single atomic patch — handshake complete)
                                    │
                                    ▼
                         PodRemediator sees consent,
                         deletes the stuck PVC.
                         StatefulSet recreates PVC on a
                         healthy node, pod restarts.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
On every subsequent reconcile (PVC annotation change triggers reconcile):

              ┌──────────────────────────────┐
              │ CheckForResolvedPodRemediation│
              └──────────┬───────────────────┘
                         │  Find pod with Remediation=true
                         │
                         ├─── Pod not found ──► not finished yet; wait
                         │
                         ├─── Pod found but not Ready ──► not finished yet; wait
                         │
                         ├─── Pod Ready but wsrep_local_state_comment ≠ "Synced"
                         │    ──► Galera still catching up; wait
                         │
                         └─── Pod Ready AND wsrep state = "Synced"
                              ──► delete(UnavailablePods, podName)
                              ──► remediation slot is now free

                              If other pods are still in UnavailablePods
                              (Remediation=false), they will be promoted
                              to Remediation=true on the next reconcile
                              by EnsurePVCAvailability.
```

---

## Trigger: PVC Annotation Watch

The reconcile loop is not only triggered by changes to the Galera CR. A dedicated
PVC watch is registered in `SetupWithManager`:

```
PersistentVolumeClaim annotation change
  → filtered to PVCs that belong to a Galera StatefulSet (IsGaleraPVC)
  → mapped to the owning Galera CR (FindGaleraForPVC)
  → enqueues a reconcile request
```

This ensures the operator reacts promptly when the PodRemediator sets the
`pvc-stuck-on-node` annotation, without waiting for any other event.

---

## Dependency Note

The annotation constants (`PVCStuckOnNodeAnnotation`, `SafeToDeleteAnnotation`,
`RequestIDAnnotation`, `ConsentIDAnnotation`) are imported directly from
`infra-operator/apis/remediation/v1beta1` to avoid duplication. A `replace`
directive in `go.mod` points to the unmerged PR #677 branch until it is merged
into `openstack-k8s-operators/infra-operator`.
