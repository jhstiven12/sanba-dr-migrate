#!/usr/bin/env bash
# lib/export.sh — extrae del clúster ORIGEN todo lo necesario.
#
# Estrictamente de solo lectura: usa oc_src, que rechaza cualquier verbo que
# modifique o borre recursos. Ni siquiera puede aplicar un manifiesto en PROD.
#
# Optimización: una sola llamada a la API por namespace (oc get acepta varios
# tipos separados por coma) en vez de una por tipo de recurso, y el resultado
# se reparte por tipo en local con jq.
# shellcheck shell=bash

# Recursos que se migran
EXPORT_KINDS_APPLY="serviceaccount secret configmap persistentvolumeclaim service route \
deployment deploymentconfig statefulset daemonset cronjob role rolebinding networkpolicy \
horizontalpodautoscaler poddisruptionbudget"

# Recursos que solo se exportan para el informe (no se aplican en DR)
EXPORT_KINDS_REPORT="resourcequota limitrange buildconfig imagestream"

# Grupos de API ya cubiertos arriba; el resto se considera "de operador"
_CORE_API_GROUPS='^(v1|apps|batch|extensions|policy|autoscaling|networking[.]k8s[.]io|rbac[.]authorization[.]k8s[.]io|events[.]k8s[.]io|discovery[.]k8s[.]io|coordination[.]k8s[.]io|metrics[.]k8s[.]io|route[.]openshift[.]io|apps[.]openshift[.]io|build[.]openshift[.]io|image[.]openshift[.]io|authorization[.]openshift[.]io|template[.]openshift[.]io|packages[.]operators[.]coreos[.]com)$'

_AVAIL_KINDS=""

# Tipos que realmente existen en este clúster (una sola consulta para todo el script)
load_available_kinds() {
  [[ -n "$_AVAIL_KINDS" ]] && return 0
  _AVAIL_KINDS=$(oc_src api-resources --namespaced --verbs=list -o name 2>/dev/null) \
    || die "No se pudo consultar 'oc api-resources' en el clúster ORIGEN"
}

kind_available() { grep -qE "^$1s(\.|$)" <<< "$_AVAIL_KINDS"; }

# Una llamada por namespace, con todos los tipos a la vez; luego se reparte por
# tipo en local. Reduce ~19 llamadas a la API por namespace a 1.
export_namespace_resources() {
  local ns="$1" kind list all n kinds_found
  list=""
  for kind in $EXPORT_KINDS_APPLY $EXPORT_KINDS_REPORT; do
    kind_available "$kind" || { vlog "$ns: el tipo '$kind' no existe en el clúster"; continue; }
    list+="${list:+,}$kind"
  done
  [[ -n "$list" ]] || die "Ningún tipo de recurso disponible; revisa la sesión con el clúster ORIGEN"

  all="$RAW/$ns/_all.json"
  oc_src -n "$ns" get "$list" -o json --ignore-not-found > "$all" \
    || die "Falló la extracción de $ns"

  n=$(jq -r '.items | length' < "$all")
  log "  $ns: $n objetos en 1 llamada a la API"

  # Reparto por tipo (local, sin más llamadas a la API)
  kinds_found=$(jq -r '[.items[].kind] | unique[]' < "$all")
  while read -r k; do
    [[ -z "$k" ]] && continue
    jq --arg k "$k" '{apiVersion:"v1", kind:"List", items:[.items[] | select(.kind==$k)]}' \
      < "$all" > "$RAW/$ns/$(kind_file "$k").json"
    vlog "    $ns/$k: $(jq '.items | length' < "$RAW/$ns/$(kind_file "$k").json")"
  done <<< "$kinds_found"
}

export_namespace_object() {
  oc_src get namespace "$1" -o json > "$RAW/_cluster/ns-$1.json"
}

# --- ServiceAccounts y SCC --------------------------------------------------
# En OCP 4 la SCC se concede de dos formas: por RoleBinding/ClusterRoleBinding al
# ClusterRole system:openshift:scc:<nombre>, y por el campo legacy .users[] de la
# propia SCC. Se contemplan ambas.
#   Ref: Authentication and authorization 4.18, cap. "Managing security context
#   constraints", secciones "Role-based access to SCCs" y "SCC reference commands".
export_scc_bindings() {
  step "SCC y bindings cluster-scoped"
  local ns_json crb_all
  ns_json=$(printf '%s\n' $NS_ORDER | jq -R . | jq -s .)

  # Una sola lectura de los ClusterRoleBindings, reutilizada para los dos filtros
  crb_all="$RAW/_cluster/_crb-all.json"
  oc_src get clusterrolebinding -o json > "$crb_all" \
    || die "No se pudieron leer los ClusterRoleBindings del clúster ORIGEN"

  jq --argjson ns "$ns_json" '
      [ .items[]
        | select(.roleRef.name | startswith("system:openshift:scc:"))
        | select([.subjects[]? | select(.kind=="ServiceAccount" and (.namespace as $n | $ns | index($n)))] | length > 0)
        | { name: .metadata.name,
            scc: (.roleRef.name | sub("^system:openshift:scc:";"")),
            subjects: [ .subjects[]? | select(.kind=="ServiceAccount" and (.namespace as $n | $ns | index($n))) ] }
      ]' < "$crb_all" > "$RAW/_cluster/scc-crb.json"

  jq --argjson ns "$ns_json" '
      { apiVersion:"v1", kind:"List", items:
        [ .items[]
          | select(.roleRef.name | startswith("system:openshift:scc:") | not)
          | select([.subjects[]? | select(.kind=="ServiceAccount" and (.namespace as $n | $ns | index($n)))] | length > 0)
        ] }' < "$crb_all" > "$RAW/_cluster/clusterrolebinding.json"

  # RoleBindings namespaced que conceden SCC (forma recomendada en OCP 4.18)
  local ns f
  for ns in $(src_namespaces); do
    f="$RAW/$ns/rolebinding.json"
    [[ -r "$f" ]] || continue
    jq --arg ns "$ns" '
      [ .items[]
        | select(.roleRef.name | startswith("system:openshift:scc:"))
        | { name: .metadata.name,
            scc: (.roleRef.name | sub("^system:openshift:scc:";"")),
            subjects: [ .subjects[]? | select(.kind=="ServiceAccount") | {name, namespace: (.namespace // $ns)} ] } ]' \
      < "$f"
  done | jq -s 'add // []' > "$RAW/_cluster/scc-rb.json"

  oc_src get scc -o json 2>/dev/null \
    | jq --argjson ns "$ns_json" '
        [ .items[] as $s
          | ($ns | map("system:serviceaccount:" + . + ":")) as $pfx
          | ($s.users // []) | map(. as $u | select($pfx | map(. as $p | $u | startswith($p)) | any)) as $matched
          | select($matched | length > 0)
          | { scc: $s.metadata.name, users: $matched }
        ]' > "$RAW/_cluster/scc-users.json"

  log "  ClusterRoleBindings de SCC : $(jq 'length'       < "$RAW/_cluster/scc-crb.json")"
  log "  RoleBindings de SCC        : $(jq 'length'       < "$RAW/_cluster/scc-rb.json")"
  log "  SCC con .users[] directo   : $(jq 'length'       < "$RAW/_cluster/scc-users.json")"
  log "  Otros ClusterRoleBindings  : $(jq '.items|length' < "$RAW/_cluster/clusterrolebinding.json")"
  ok "Bindings cluster-scoped exportados"
}

# --- Recursos de operadores -------------------------------------------------
detect_custom_resources() {
  step "Recursos personalizados (CRs de operadores)"
  local kinds list ns found r
  # '-o name' da 'recurso.grupo' ya cualificado: evita el desalineado de columnas
  # de '-o wide' cuando un recurso no tiene shortnames.
  kinds=$(awk -v re="$_CORE_API_GROUPS" '
            { i = index($0, ".");
              if (i == 0) next;                 # grupo core: ya cubierto arriba
              grp = substr($0, i + 1);
              if (grp !~ re) print $0 }' <<< "$_AVAIL_KINDS" | sort -u | head -200)
  if [[ -z "$kinds" ]]; then
    log "No se detectaron CRDs adicionales"
    return 0
  fi
  list=$(tr '\n' ',' <<< "$kinds" | sed 's/,$//')
  : > "$RAW/_cluster/custom-resources.txt"
  for ns in $(src_namespaces); do
    found=$(oc_src -n "$ns" get "$list" -o name --ignore-not-found 2>/dev/null | sort -u)
    [[ -z "$found" ]] && continue
    while read -r r; do
      [[ -z "$r" ]] && continue
      printf '%s\t%s\n' "$ns" "$r" >> "$RAW/_cluster/custom-resources.txt"
    done <<< "$found"
  done
  if [[ -s "$RAW/_cluster/custom-resources.txt" ]]; then
    warn "Hay $(wc -l < "$RAW/_cluster/custom-resources.txt") recursos de operadores en estos namespaces"
    log  "Detalle en $RAW/_cluster/custom-resources.txt — el operador debe existir en pre-producción"
  else
    ok "Sin recursos de operadores en los namespaces"
  fi
}

# --- Dominios de ingress ----------------------------------------------------
export_domains() {
  step "Dominios de aplicaciones (apps domain)"
  local s d
  s=$(oc_src get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
  d=$(oc_dst get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
  [[ -n "$s" ]] || die "No se pudo leer el apps-domain del clúster ORIGEN"
  [[ -n "$d" ]] || die "No se pudo leer el apps-domain del clúster DESTINO"
  printf '%s\n' "$s" > "$RUN/domain-src.txt"
  printf '%s\n' "$d" > "$RUN/domain-dst.txt"
  log "  ORIGEN : $s"
  log "  DESTINO: $d"
  ok "Dominios detectados"
}

cmd_export() {
  require_cmd oc jq
  step "Exportando desde el clúster ORIGEN (solo lectura)"
  mkdir -p "$RAW/_cluster"
  load_available_kinds

  local ns
  for ns in $(src_namespaces); do
    mkdir -p "$RAW/$ns"
    export_namespace_object "$ns"
    export_namespace_resources "$ns"
  done

  export_scc_bindings
  detect_custom_resources
  export_domains

  step "Export terminado"
  log "Artefactos crudos en: $RAW"
  ok "No se escribió ni se borró nada en producción"
}
