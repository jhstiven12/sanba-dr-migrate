#!/usr/bin/env bash
# lib/transform.sh — saneo de manifiestos, renombrado de namespace y reescritura de Routes.
# Trabaja solo sobre archivos locales: no toca ningún clúster.
# shellcheck shell=bash

# --- mapas auxiliares como JSON para jq -------------------------------------
ns_map_json() {
  local s d out='{}'
  for s in $NS_ORDER; do
    d="$(ns_dst "$s")"
    out=$(jq -c --arg k "$s" --arg v "$d" '. + {($k):$v}' <<< "$out")
  done
  printf '%s' "$out"
}

sc_map_json() {
  local pair out='{}'
  for pair in $STORAGE_CLASS_MAP; do
    out=$(jq -c --arg k "${pair%%:*}" --arg v "${pair#*:}" '. + {($k):$v}' <<< "$out")
  done
  printf '%s' "$out"
}

route_map_json() {
  local out='{}' h1 h2
  if [[ -r "$ROOT/$ROUTE_MAP_FILE" ]]; then
    while read -r h1 h2; do
      [[ -z "$h1" || "$h1" == \#* || -z "${h2:-}" ]] && continue
      out=$(jq -c --arg k "$h1" --arg v "$h2" '. + {($k):$v}' <<< "$out")
    done < "$ROOT/$ROUTE_MAP_FILE"
  fi
  printf '%s' "$out"
}

# --- programa jq principal --------------------------------------------------
build_jq_program() {
  local gsub_chain; gsub_chain="$(ns_jq_gsub)"
  cat <<JQEOF
def rewrite_text: if type == "string" then ${gsub_chain} else . end;

# Reescribe un valor base64 solo si decodifica a texto UTF-8 que round-trippea
# (así nunca corrompemos claves privadas, keystores ni binarios) y solo si
# realmente menciona alguno de los namespaces.
def rewrite_b64:
  . as \$orig
  | ((try (\$orig | @base64d) catch null)) as \$d
  | if (\$d != null) and ((\$d | @base64) == \$orig) and (\$d | test(\$nsre))
    then (\$d | rewrite_text | @base64)
    else \$orig
    end;

def sanitize:
  del(.metadata.uid, .metadata.resourceVersion, .metadata.generation,
      .metadata.creationTimestamp, .metadata.selfLink, .metadata.managedFields,
      .metadata.ownerReferences, .metadata.finalizers, .status)
  | (if .metadata.annotations then
       .metadata.annotations |= (
         del(."kubectl.kubernetes.io/last-applied-configuration",
             ."deployment.kubernetes.io/revision",
             ."openshift.io/generated-by",
             ."openshift.io/host.generated",
             ."autoscaling.alpha.kubernetes.io/conditions",
             ."autoscaling.alpha.kubernetes.io/current-metrics")
         | with_entries(select(.key | test("^(pv|volume)\\\\.(beta\\\\.)?kubernetes\\\\.io/") | not))
       )
     else . end)
  | (if (.metadata.annotations // {}) == {} then del(.metadata.annotations) else . end);

def fix_container:
    (if .env      then .env      |= map(if has("value") then .value |= rewrite_text else . end) else . end)
  | (if .args     then .args     |= map(rewrite_text) else . end)
  | (if .command  then .command  |= map(rewrite_text) else . end);

def fix_podspec:
    (if .containers     then .containers     |= map(fix_container) else . end)
  | (if .initContainers then .initContainers |= map(fix_container) else . end);

def perkind:
  if .kind == "Service" then
      del(.spec.clusterIP, .spec.clusterIPs, .spec.ipFamilies, .spec.ipFamilyPolicy,
          .spec.healthCheckNodePort, .spec.loadBalancerIP, .spec.externalIPs)
    | (if .spec.ports then .spec.ports |= map(del(.nodePort)) else . end)

  elif .kind == "PersistentVolumeClaim" then
      del(.spec.volumeName, .spec.dataSource, .spec.dataSourceRef)
    | (if (.spec.storageClassName // "") != ""
       then .spec.storageClassName = (\$scmap[.spec.storageClassName] // .spec.storageClassName)
       else . end)

  elif .kind == "ServiceAccount" then
      del(.secrets)
    | (if .imagePullSecrets then
         .imagePullSecrets |= map(select(.name | test("-dockercfg-[a-z0-9]{5}\$") | not))
         | (if (.imagePullSecrets | length) == 0 then del(.imagePullSecrets) else . end)
       else . end)

  elif .kind == "Secret" then
      (if .data       then .data       |= with_entries(.value |= rewrite_b64)  else . end)
    | (if .stringData then .stringData |= with_entries(.value |= rewrite_text) else . end)

  elif .kind == "ConfigMap" then
      (if .data then .data |= with_entries(.value |= rewrite_text) else . end)

  elif (.kind == "RoleBinding") or (.kind == "ClusterRoleBinding") then
      (if .subjects then
         .subjects |= map(
           if (.kind == "ServiceAccount") and (.namespace != null)
           then .namespace = (\$nsmap[.namespace] // .namespace) else . end)
       else . end)
    | (if .userNames  then .userNames  |= map(rewrite_text) else . end)
    | (if .groupNames then .groupNames |= map(rewrite_text) else . end)

  elif .kind == "Route" then
      del(.status)
    | ((.spec.host // "") as \$h
       | if (\$routemap[\$h] // null) != null then
             .spec.host = \$routemap[\$h]
         elif (\$h != "") and (\$h | endswith("." + \$srcdom)) then
             .spec.host = (.metadata.name + "-" + \$dstns + "." + \$dstdom)
         elif \$h == "" then .
         elif \$custom == "generate" then del(.spec.host)
         else . end)
    | (if (\$tlsmode == "default") and (.spec.tls != null)
       then .spec.tls |= del(.certificate, .key, .caCertificate, .destinationCACertificate)
       else . end)

  elif (.kind | IN("Deployment","StatefulSet","DaemonSet","DeploymentConfig","Job")) then
      del(.spec.template.metadata.creationTimestamp)
    | (if .spec.triggers then .spec.triggers |= map(del(.imageChangeParams.lastTriggeredImage)) else . end)
    | (if .spec.template.spec then .spec.template.spec |= fix_podspec else . end)

  elif .kind == "CronJob" then
      del(.spec.jobTemplate.metadata.creationTimestamp,
          .spec.jobTemplate.spec.template.metadata.creationTimestamp)
    | (if .spec.jobTemplate.spec.template.spec
       then .spec.jobTemplate.spec.template.spec |= fix_podspec else . end)

  else . end;

# Descarta lo que el clúster destino genera por su cuenta.
def keep:
  if .kind == "Secret" then
    ((.type // "") | IN("kubernetes.io/service-account-token","kubernetes.io/dockercfg") | not)
    and ((.metadata.annotations // {}) | has("service.beta.openshift.io/originating-service-name") | not)
    and ((.metadata.annotations // {}) | has("service.alpha.openshift.io/originating-service-name") | not)
  elif .kind == "ConfigMap" then
    (.metadata.name | IN("kube-root-ca.crt","openshift-service-ca.crt") | not)
  elif .kind == "ServiceAccount" then
    # 'default', 'builder' y 'deployer' ya existen en el destino con sus propios
    # secrets autogenerados: aplicarlas los destruiría. La 'default' se reconcilia
    # con un patch en apply.sh.
    (.metadata.name | IN("default","builder","deployer") | not)
  elif .kind == "RoleBinding" then
    # OpenShift crea estos RoleBindings solo en cada namespace nuevo. Copiar el
    # 'admin' de producción daría permisos de administrador sobre el namespace de
    # contingencia a los dueños del proyecto de producción.
    (\$keeprb == "true")
    or (.metadata.name | IN("admin","system:deployers","system:image-builders",
                            "system:image-pullers","system:image-puller") | not)
  else true end;

{ apiVersion: "v1", kind: "List",
  items: [ .items[]
           | select(keep)
           | sanitize
           | .metadata.namespace = \$dstns
           | perkind ] }
JQEOF
}

# --- namespaces -------------------------------------------------------------
tf_namespaces() {
  step "Namespaces"
  local s d f
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    f="$RAW/_cluster/ns-$s.json"
    [[ -r "$f" ]] || { warn "No hay export del namespace $s"; continue; }
    # Las annotations de UID/MCS range las regenera el clúster destino; copiarlas
    # deja pods que no arrancan por SELinux/UID fuera de rango.
    jq --arg d "$d" '
      { apiVersion:"v1", kind:"Namespace",
        metadata: {
          name: $d,
          labels: ((.metadata.labels // {}) | with_entries(select(.key | startswith("kubernetes.io/metadata.name") | not))),
          annotations: ((.metadata.annotations // {})
                        | del(."openshift.io/sa.scc.uid-range",
                              ."openshift.io/sa.scc.mcs",
                              ."openshift.io/sa.scc.supplemental-groups",
                              ."openshift.io/requester",
                              ."kubectl.kubernetes.io/last-applied-configuration"))
        } }' < "$f" | to_manifest > "$CLEAN/_cluster/00-namespace-$d.$MANIFEST_EXT"
    ok "$s -> $d"
  done
}

# --- recursos por namespace -------------------------------------------------
tf_namespaced() {
  local s d kind in out prog n
  prog="$(build_jq_program)"
  local nsmap scmap routemap nsre srcdom dstdom
  nsmap="$(ns_map_json)"; scmap="$(sc_map_json)"; routemap="$(route_map_json)"
  nsre="$(ns_match_regex)"
  srcdom="$(cat "$RUN/domain-src.txt")"; dstdom="$(cat "$RUN/domain-dst.txt")"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    mkdir -p "$CLEAN/$d"
    step "Transformando $s -> $d"
    for kind in $EXPORT_KINDS_APPLY; do
      in="$RAW/$s/$(kind_file "$kind").json"
      [[ -r "$in" ]] || continue
      out="$CLEAN/$d/$(kind_order "$kind")-$(kind_file "$kind").$MANIFEST_EXT"
      jq --arg dstns "$d" --arg srcns "$s" \
         --argjson nsmap "$nsmap" --argjson scmap "$scmap" --argjson routemap "$routemap" \
         --arg nsre "$nsre" --arg srcdom "$srcdom" --arg dstdom "$dstdom" \
         --arg tlsmode "$ROUTE_TLS_STRATEGY" --arg custom "$ROUTE_CUSTOM_STRATEGY" \
         --arg keeprb "${MIGRATE_DEFAULT_ROLEBINDINGS:-false}" \
         "$prog" < "$in" > "$RUN/.tmp.json" \
        || die "jq falló transformando $s/$kind"

      n=$(jq '.items | length' < "$RUN/.tmp.json")
      if [[ "$n" == "0" ]]; then
        vlog "$d/$kind: todo descartado"
        continue
      fi
      to_manifest < "$RUN/.tmp.json" > "$out"
      log "  $d/$kind: $n"
    done
  done
  rm -f "$RUN/.tmp.json"
}

# --- auditoría de reescrituras de namespace ---------------------------------
tf_report_rewrites() {
  step "Auditoría de reescrituras de namespace"
  local s d f name kind changed=0
  {
    echo "Reescrituras de nombre de namespace dentro del CONTENIDO de ConfigMaps y Secrets."
    echo "Solo se listan objeto y clave; nunca el valor."
    echo
  } > "$REPORTS/ns-rewrites.txt"

  local nsre; nsre="$(ns_match_regex)"
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    for kind in configmap secret; do
      f="$RAW/$s/$kind.json"
      [[ -r "$f" ]] || continue
      while IFS=$'\t' read -r name key; do
        [[ -z "$name" ]] && continue
        printf '%s\t%s/%s\tclave=%s\n' "$d" "$kind" "$name" "$key" >> "$REPORTS/ns-rewrites.txt"
        changed=$((changed+1))
      done < <(jq -r --arg re "$nsre" '
          .items[]
          | .metadata.name as $n
          | ( (.data // {}) | to_entries[]
              | . as $e
              | (if ($e.value | test("^[A-Za-z0-9+/]*={0,2}$")) and ((try ($e.value|@base64d) catch null) != null)
                 then (try ($e.value|@base64d) catch "") else $e.value end) as $plain
              | select($plain | test($re))
              | [$n, $e.key] | @tsv )' < "$f" 2>/dev/null)
      done
  done
  log "  $changed claves contenían un nombre de namespace y fueron reescritas"
  ok "Detalle en $REPORTS/ns-rewrites.txt"
}

# --- SCC y bindings cluster-scoped ------------------------------------------
tf_cluster_bindings() {
  step "SCC y ClusterRoleBindings"
  local nsmap; nsmap="$(ns_map_json)"

  # Asignaciones de SCC -> TSV:  scc <TAB> ns_destino <TAB> serviceaccount <TAB> origen
  # El origen importa: las que vienen de un RoleBinding namespaced ya se migran
  # como manifiesto, así que 'apply' no debe volver a concederlas.
  {
    jq -r --argjson m "$nsmap" '
      .[] | .scc as $scc | .subjects[]
      | [$scc, ($m[.namespace] // .namespace), .name, "clusterrolebinding"] | @tsv' < "$RAW/_cluster/scc-crb.json"
    jq -r --argjson m "$nsmap" '
      .[] | .scc as $scc | .subjects[]
      | [$scc, ($m[.namespace] // .namespace), .name, "rolebinding"] | @tsv' < "$RAW/_cluster/scc-rb.json"
    jq -r --argjson m "$nsmap" '
      .[] | .scc as $scc | .users[]
      | split(":") | select(length == 4)
      | [$scc, ($m[.[2]] // .[2]), .[3], "scc.users"] | @tsv' < "$RAW/_cluster/scc-users.json"
  } 2>/dev/null | sort -u > "$CLEAN/_cluster/scc-assignments.tsv"

  local n; n=$(wc -l < "$CLEAN/_cluster/scc-assignments.tsv")
  log "  Asignaciones de SCC detectadas: $n"
  [[ "$n" -gt 0 ]] && awk -F'\t' '{printf "    %-16s %-28s %-24s (via %s)\n", $1, $2, $3, $4}' \
      "$CLEAN/_cluster/scc-assignments.tsv" >&2

  # ClusterRoleBindings normales: se renombran con el sufijo de DR para no pisar
  # bindings preexistentes del clúster de pre-producción.
  if [[ -r "$RAW/_cluster/clusterrolebinding.json" ]] \
     && [[ "$(jq '.items | length' < "$RAW/_cluster/clusterrolebinding.json")" != "0" ]]; then
    jq --argjson m "$nsmap" --arg sfx "$DR_SUFFIX" '
      { apiVersion:"v1", kind:"List", items:
        [ .items[]
          | del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
                .metadata.managedFields, .metadata.selfLink, .metadata.ownerReferences, .status)
          | .metadata.name = (.metadata.name + $sfx)
          | (if .subjects then .subjects |= map(
               if .kind == "ServiceAccount" and .namespace then .namespace = ($m[.namespace] // .namespace) else . end)
             else . end)
          | (if .userNames then del(.userNames) else . end)
        ] }' < "$RAW/_cluster/clusterrolebinding.json" \
      | to_manifest > "$CLEAN/_cluster/80-clusterrolebinding.$MANIFEST_EXT"
    log "  ClusterRoleBindings renombrados con sufijo ${DR_SUFFIX} en 80-clusterrolebinding.$MANIFEST_EXT"
  fi
  ok "Bindings preparados"
}

# --- ServiceAccounts: inventario y verificación cruzada ---------------------
tf_serviceaccounts() {
  step "ServiceAccounts"
  local s d sas used missing=0
  {
    printf '%-28s %-26s %-22s %s\n' "NAMESPACE(DR)" "SERVICEACCOUNT" "SCC" "USADA POR"
    printf '%s\n' "--------------------------------------------------------------------------------------------"
  } > "$REPORTS/serviceaccounts.txt"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"

    # SAs disponibles en destino = las que migramos + la 'default' que ya existe
    sas=$( { clean_items "$d" serviceaccount | jq -r '.[].metadata.name'; echo default; } | sort -u )

    # SAs referenciadas por los workloads
    used=$(clean_items "$d" | jq -r '
      .[]
      | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // {}) as $ps
      | ($ps.serviceAccountName // $ps.serviceAccount // empty)' | sort -u)

    local sa scc who
    while read -r sa; do
      [[ -z "$sa" ]] && continue
      scc=$(awk -F'\t' -v n="$d" -v a="$sa" '$2==n && $3==a {printf "%s%s", sep, $1; sep=","}' "$CLEAN/_cluster/scc-assignments.tsv")
      who=$(clean_items "$d" | jq -r --arg sa "$sa" '
        .[]
        | (.spec.template.spec // .spec.jobTemplate.spec.template.spec) as $ps
        | select($ps != null)
        | select(($ps.serviceAccountName // $ps.serviceAccount // "default") == $sa)
        | .kind + "/" + .metadata.name' | paste -sd, -)
      printf '%-28s %-26s %-22s %s\n' "$d" "$sa" "${scc:--}" "${who:--}" >> "$REPORTS/serviceaccounts.txt"
    done <<< "$sas"

    # imagePullSecrets creados a mano en la SA 'default' de PROD: se reconcilian
    # con un patch en el destino en lugar de aplicar el objeto entero.
    jq -r '.items[]
           | select(.metadata.name == "default")
           | (.imagePullSecrets // [])[].name
           | select(test("-dockercfg-[a-z0-9]{5}$") | not)' \
       < "$RAW/$s/serviceaccount.json" 2>/dev/null | sort -u > "$CLEAN/$d/default-sa-pullsecrets.txt" || true

    # Verificación cruzada: ningún workload puede apuntar a una SA inexistente
    while read -r sa; do
      [[ -z "$sa" ]] && continue
      if ! grep -qxF "$sa" <<< "$sas"; then
        err "$d: el workload referencia la ServiceAccount '$sa', que no se exportó"
        missing=$((missing+1))
      fi
    done <<< "$used"
  done

  if (( missing > 0 )); then
    die "$missing ServiceAccounts referenciadas no existen. Un pod con SA inexistente arranca con permisos equivocados."
  fi
  ok "Inventario en $REPORTS/serviceaccounts.txt; todas las referencias resuelven"
}

# --- ConfigMaps y Secrets: inventario y referencias -------------------------
tf_config_refs() {
  step "ConfigMaps y Secrets"
  local s d have_cm have_sec kind name miss=0 refs
  {
    printf '%-26s %-10s %-34s %-7s %s\n' "NAMESPACE(DR)" "KIND" "NOMBRE" "CLAVES" "CONSUMIDO POR"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------"
  } > "$REPORTS/config.txt"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    have_cm=$(clean_items "$d" configmap | jq -r '.[].metadata.name' | sort -u)
    have_sec=$(clean_items "$d" secret    | jq -r '.[].metadata.name' | sort -u)

    # Referencias desde los workloads:  KIND <TAB> NOMBRE <TAB> WORKLOAD
    refs="$RUN/.refs-$d.tsv"
    clean_items "$d" | jq -r '
      .[]
      | (.kind + "/" + .metadata.name) as $w
      | (.spec.template.spec // .spec.jobTemplate.spec.template.spec) as $ps
      | select($ps != null)
      | ( [ ( ($ps.containers // []) + ($ps.initContainers // []) )[]
            | ( (.envFrom // [])[]
                | (if .configMapRef then ["ConfigMap", .configMapRef.name]
                   elif .secretRef  then ["Secret",    .secretRef.name]
                   else empty end) ),
              ( (.env // [])[] | (.valueFrom // {})
                | (if .configMapKeyRef then ["ConfigMap", .configMapKeyRef.name]
                   elif .secretKeyRef  then ["Secret",    .secretKeyRef.name]
                   else empty end) )
          ]
          + [ ($ps.volumes // [])[]
              | (if .configMap then ["ConfigMap", .configMap.name]
                 elif .secret then ["Secret", .secret.secretName]
                 elif .projected then ( (.projected.sources // [])[]
                        | if .configMap then ["ConfigMap", .configMap.name]
                          elif .secret  then ["Secret",    .secret.name]
                          else empty end )
                 else empty end) ]
          + [ ($ps.imagePullSecrets // [])[] | ["Secret", .name] ]
        )[]
      | . + [$w] | @tsv' | sort -u > "$refs"

    # Inventario: nombre, tipo, nº de claves y quién lo consume. Nunca valores.
    local pat consumers nkeys
    for kind in ConfigMap Secret; do
      [[ "$kind" == ConfigMap ]] && pat=configmap || pat=secret
      while IFS=$'\t' read -r name nkeys; do
        [[ -z "${name:-}" ]] && continue
        consumers=$(awk -F'\t' -v k="$kind" -v n="$name" '$1==k && $2==n {print $3}' "$refs" | sort -u | paste -sd, -)
        printf '%-26s %-10s %-34s %-7s %s\n' "$d" "$kind" "$name" "$nkeys" "${consumers:--}" >> "$REPORTS/config.txt"
      done < <(clean_items "$d" "$pat" | jq -r '.[] | [.metadata.name, ((.data // {}) | keys | length | tostring)] | @tsv')
    done

    # Toda referencia debe resolver, o el pod se queda en CreateContainerConfigError
    while IFS=$'\t' read -r kind name _w; do
      [[ -z "${name:-}" ]] && continue
      # inyectados por el propio clúster destino
      [[ "$name" == "kube-root-ca.crt" || "$name" == "openshift-service-ca.crt" ]] && continue
      if [[ "$kind" == ConfigMap ]]; then
        grep -qxF "$name" <<< "$have_cm" && continue
      else
        grep -qxF "$name" <<< "$have_sec" && continue
        # los pull secrets autogenerados los crea el clúster destino
        [[ "$name" =~ -dockercfg-[a-z0-9]{5}$ ]] && continue
      fi
      warn "$d: se referencia $kind/$name pero no se exportó (¿gestionado por Vault/ESO o creado a mano?)"
      todo "$d: crear $kind/$name antes del apply — si no, el pod queda en CreateContainerConfigError"
      miss=$((miss+1))
    done < <(cut -f1,2 "$refs" | sort -u | sed 's/$/\t-/')
  done

  if (( miss > 0 )); then
    warn "$miss referencias a ConfigMap/Secret sin resolver — ver manual-todo.txt"
  else
    ok "Todas las referencias a ConfigMap/Secret resuelven"
  fi
  ok "Inventario en $REPORTS/config.txt"
}

# --- RoleBindings autogenerados por OpenShift -------------------------------
tf_report_default_rolebindings() {
  [[ "${MIGRATE_DEFAULT_ROLEBINDINGS:-false}" == true ]] && return 0
  local s d n subs
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    [[ -r "$RAW/$s/rolebinding.json" ]] || continue
    while IFS=$'\t' read -r name subs; do
      [[ -z "${name:-}" ]] && continue
      if [[ "$name" == "admin" ]]; then
        warn "$d: NO se migra el RoleBinding 'admin' de PROD (daría admin en contingencia a: ${subs:-?})"
        todo "$d: el RoleBinding 'admin' de producción no se migra por seguridad. Si necesitas esos permisos en contingencia, concédelos a mano: oc -n $d adm policy add-role-to-user admin <usuario>"
      else
        vlog "$d: se omite el RoleBinding autogenerado '$name'"
      fi
    done < <(jq -r '
      .items[]
      | select(.metadata.name | IN("admin","system:deployers","system:image-builders","system:image-pullers","system:image-puller"))
      | [ .metadata.name,
          ([ (.subjects // [])[] | (.kind // "?") + "/" + (.name // "?") ] | join(",")) ] | @tsv' \
      < "$RAW/$s/rolebinding.json" 2>/dev/null)
  done
  return 0
}

# --- Routes -----------------------------------------------------------------
tf_routes() {
  step "Routes"
  local s d srcdom dstdom
  srcdom="$(cat "$RUN/domain-src.txt")"; dstdom="$(cat "$RUN/domain-dst.txt")"
  {
    printf '%-22s %-26s %-52s %-52s %s\n' "NAMESPACE(DR)" "ROUTE" "HOST ORIGEN" "HOST DESTINO" "TLS"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------------------------------------------------------"
  } > "$REPORTS/routes.txt"

  : > "$RUN/routes-dst.tsv"
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    [[ "$(clean_items "$d" route | jq 'length')" != "0" ]] || continue
    local old_hosts; old_hosts=$(jq -r '.items[] | [.metadata.name, (.spec.host // "-")] | @tsv' < "$RAW/$s/route.json" 2>/dev/null)

    while IFS=$'\t' read -r name newhost term; do
      [[ -z "$name" ]] && continue
      [[ "$newhost" == "<NONE>" ]] && newhost=""
      [[ "$term"    == "<NONE>" ]] && term=""
      local oldhost; oldhost=$(awk -F'\t' -v n="$name" '$1==n {print $2}' <<< "$old_hosts")
      printf '%-22s %-26s %-52s %-52s %s\n' "$d" "$name" "${oldhost:--}" "${newhost:-<generado por el router>}" "${term:--}" >> "$REPORTS/routes.txt"
      printf '%s\t%s\t%s\t%s\n' "$d" "$name" "$newhost" "$term" >> "$RUN/routes-dst.tsv"

      if [[ -z "$newhost" ]]; then
        todo "$d/$name: host custom sin mapeo; el router asignará uno. Revisa DNS/certificado."
      elif [[ ${#newhost} -gt 63 ]]; then
        warn "$d/$name: el host generado tiene ${#newhost} caracteres (>63), el router puede rechazarlo"
        todo "$d/$name: acorta el nombre de la Route o define un host en $ROUTE_MAP_FILE"
      fi
      if [[ "$term" == "reencrypt" && "$ROUTE_TLS_STRATEGY" == "default" ]]; then
        todo "$d/$name: era reencrypt; se quitó destinationCACertificate (era del service-CA de PROD). Verifica el backend TLS."
      fi
    done < <(clean_items "$d" route \
             | jq -r '.[] | [.metadata.name, (.spec.host // "<NONE>"), (.spec.tls.termination // "<NONE>")] | @tsv')
  done
  ok "Mapa de rutas en $REPORTS/routes.txt"
}

# --- ResourceQuota / LimitRange (solo informativo) --------------------------
tf_quota_report() {
  local s d n
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    for kind in resourcequota limitrange; do
      [[ -r "$RAW/$s/$kind.json" ]] || continue
      n=$(jq '.items | length' < "$RAW/$s/$kind.json")
      [[ "$n" == "0" ]] && continue
      todo "$d: en PROD hay $n $kind. No se migran; comprueba que las cuotas de pre-producción admiten la carga."
    done
  done
  if [[ -s "$RAW/_cluster/custom-resources.txt" ]]; then
    while IFS=$'\t' read -r ns res; do
      todo "$(ns_dst "$ns"): recurso de operador '$res' presente en PROD. Instala el operador en pre-producción."
    done < "$RAW/_cluster/custom-resources.txt"
  fi
}

cmd_transform() {
  require_cmd oc jq
  [[ -d "$RAW" ]] || die "No hay export en $RAW. Ejecuta primero: $0 export"
  [[ -r "$RUN/domain-src.txt" && -r "$RUN/domain-dst.txt" ]] || die "Faltan los dominios. Ejecuta primero: $0 export"

  rm -rf "$CLEAN"; mkdir -p "$CLEAN/_cluster"
  clean_cache_reset
  : > "$REPORTS/manual-todo.txt"

  tf_namespaces
  tf_namespaced
  tf_report_default_rolebindings
  tf_cluster_bindings
  tf_serviceaccounts
  tf_config_refs
  tf_report_rewrites
  tf_routes
  cmd_images
  tf_quota_report

  step "Transform terminado"
  log "Manifiestos listos en: $CLEAN"
  log "Reportes en:           $REPORTS"
  if [[ -s "$REPORTS/manual-todo.txt" ]]; then
    warn "Hay $(wc -l < "$REPORTS/manual-todo.txt") puntos pendientes en $REPORTS/manual-todo.txt"
  fi
  ok "Revisa los reportes antes de ejecutar 'apply'"
}
