#!/usr/bin/env bash
# clean-k8s.sh — ล้าง workload เดิมออกจาก PoC cluster ให้เหลือ Kubernetes + Calico
#
#   DRY_RUN=1 ./clean-k8s.sh   แสดงรายการที่จะลบ (ไม่ลบจริง)
#   ./clean-k8s.sh             ลบจริง
#
# ปรับจาก docs/cluster-inventory.txt:
#   CNI      = Calico ผ่าน tigera-operator (เก็บไว้)
#   Storage  = Longhorn 1.10.1 (ถอนออก จะติดตั้ง 1.12.1 ใหม่), NFS static PV บน master (ลบแค่ object)
#   ของค้าง  = webhook ของ Knative/Istio/Kubeflow/KServe/cert-manager, namespace knative-serving ค้าง Terminating,
#              Istio CNI DaemonSet ใน kube-system
set -uo pipefail
DRY_RUN=${DRY_RUN:-0}
EXPECTED_CONTEXT=kubernetes-admin@kubernetes

PROTECT_NS='^(default|kube-system|kube-public|kube-node-lease|calico-system|calico-apiserver|tigera-operator|longhorn-system)$'
PROTECT_CRD='\.(crd\.projectcalico\.org|operator\.tigera\.io|policy\.networking\.k8s\.io)$'
PROTECT_WEBHOOK='longhorn|calico|tigera'
PROTECT_RBAC='system:|kubeadm:|/cluster-admin$|/admin$|/edit$|/view$|calico|tigera|longhorn'

run() { if [[ $DRY_RUN == 1 ]]; then echo "[dry-run] $*"; else echo "+ $*"; "$@"; fi; }
unfinalize() { run kubectl "$@" --type merge -p '{"metadata":{"finalizers":null}}'; }

# รอจนคำสั่ง $2 ให้ผลว่าง (สูงสุด 5 นาที)
wait_until_empty() {
  local what=$1 cmd=$2
  [[ $DRY_RUN == 1 ]] && return
  for _ in {1..30}; do
    [[ -z $(bash -c "$cmd" 2>/dev/null) ]] && return
    sleep 10
  done
  echo "!!! ${what} ยังไม่หมดหลังรอ 5 นาที"
}

force_finalize_ns() {
  local ns=$1
  echo "--- บังคับลบ namespace ที่ค้าง: $ns"
  for r in $(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null); do
    for obj in $(kubectl -n "$ns" get "$r" -o name 2>/dev/null); do
      unfinalize -n "$ns" patch "$obj"
    done
  done
  [[ $DRY_RUN == 1 ]] && return
  kubectl get ns "$ns" -o json 2>/dev/null | jq '.spec.finalizers=[]' |
    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null
}

ctx=$(kubectl config current-context)
[[ $ctx == "$EXPECTED_CONTEXT" ]] || { echo "context คือ $ctx ไม่ใช่ $EXPECTED_CONTEXT — หยุด"; exit 1; }
if [[ $DRY_RUN == 0 ]]; then
  read -rp "จะลบทุก workload, PVC และ PV ใน $ctx — พิมพ์ YES เพื่อยืนยัน: " ok
  [[ $ok == YES ]] || exit 1
fi

echo "=== 1. ลบ admission webhook (ยกเว้น Calico/Longhorn) — หลายตัวชี้ไป service ที่ไม่มีแล้วและจะขวางการลบขั้นต่อไป"
for w in $(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -vE "$PROTECT_WEBHOOK"); do
  run kubectl delete "$w"
done

echo "=== 2. ถอน Helm release (ยกเว้น longhorn ซึ่งถอนในขั้นที่ 5)"
helm list -A -o json | jq -r '.[] | "\(.namespace) \(.name)"' | while read -r ns name; do
  [[ $name == longhorn ]] && { echo "skip longhorn"; continue; }
  run helm uninstall "$name" -n "$ns" --wait --timeout 5m
done

echo "=== 3. ลบ namespace (PVC ถูกลบไปด้วย)"
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  [[ $ns =~ $PROTECT_NS ]] || run kubectl delete ns "$ns" --wait=false
done
run kubectl -n default delete deploy,sts,ds,job,cronjob,pod,ingress,pvc --all --ignore-not-found
wait_until_empty "namespace ที่กำลังลบ" "kubectl get ns --no-headers | awk '\$2==\"Terminating\"'"
for ns in $(kubectl get ns --no-headers | awk '$2=="Terminating"{print $1}'); do
  force_finalize_ns "$ns"
done

echo "=== 4. ลบ PV และ Longhorn volume ที่เหลือ (ข้อมูลบน NFS ของ master ไม่ถูกลบ)"
for pv in $(kubectl get pv -o name); do run kubectl delete "$pv" --wait=false; done
wait_until_empty "PV" "kubectl get pv -o name"
for pv in $(kubectl get pv -o name); do unfinalize patch "$pv"; done
wait_until_empty "Longhorn volume" "kubectl -n longhorn-system get volumes.longhorn.io -o name"
for v in $(kubectl -n longhorn-system get volumes.longhorn.io -o name 2>/dev/null); do
  run kubectl -n longhorn-system delete "$v"
done

echo "=== 5. ถอน Longhorn 1.10.1"
if kubectl get ns longhorn-system &>/dev/null; then
  run kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag --type merge -p '{"value":"true"}'
  run helm uninstall longhorn -n longhorn-system --wait --timeout 10m
  run kubectl delete ns longhorn-system --wait=false
  wait_until_empty "namespace longhorn-system" "kubectl get ns longhorn-system -o name"
  kubectl get ns longhorn-system &>/dev/null && force_finalize_ns longhorn-system
fi

echo "=== 6. ถอด Istio CNI ออกจาก kube-system แล้วให้ Calico เขียน CNI config ใหม่"
for o in $(kubectl -n kube-system get ds,cm,sa -o name | grep -i istio); do
  run kubectl -n kube-system delete "$o"
done
wait_until_empty "istio-cni pod" "kubectl -n kube-system get pods -o name | grep -i istio"
run kubectl -n calico-system delete pod -l k8s-app=calico-node
[[ $DRY_RUN == 1 ]] || { sleep 15; kubectl -n calico-system rollout status ds calico-node --timeout=5m; }

echo "=== 7. ลบ CRD (ยกเว้นของ Calico)"
for crd in $(kubectl get crd -o name | grep -vE "$PROTECT_CRD"); do
  run kubectl delete "$crd" --wait=false
done
wait_until_empty "CRD" "kubectl get crd -o name | grep -vE '$PROTECT_CRD'"
for crd in $(kubectl get crd -o name | grep -vE "$PROTECT_CRD"); do unfinalize patch "$crd"; done

echo "=== 8. ลบ webhook และ APIService ที่ยังค้าง"
for w in $(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -vE 'calico|tigera'); do
  run kubectl delete "$w"
done
for a in $(kubectl get apiservices --no-headers | awk '$3 ~ /^False/ {print $1}'); do
  run kubectl delete apiservice "$a"
done

echo "=== 9. ลบ ClusterRole/Binding, StorageClass, IngressClass, PriorityClass"
for o in $(kubectl get clusterrole,clusterrolebinding -o name | grep -vE "$PROTECT_RBAC"); do
  run kubectl delete "$o"
done
for o in $(kubectl get storageclass,ingressclass -o name); do run kubectl delete "$o"; done
for o in $(kubectl get priorityclass -o name | grep -v '/system-'); do run kubectl delete "$o"; done

echo "=== เสร็จ — ตรวจผล"
kubectl get ns
kubectl -n kube-system get ds,deploy,sts
kubectl get pv,pvc -A
kubectl get crd
kubectl get sc,ingressclass,priorityclass
helm list -A
