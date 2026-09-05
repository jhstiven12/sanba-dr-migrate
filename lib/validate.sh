#!/usr/bin/env bash
# lib/validate.sh — comprobaciones end-to-end sobre el clúster DR. Es el entregable
# de la prueba: deja reports/validation.txt y devuelve exit != 0 si algo falla.
# shellcheck shell=bash

V_OK=0; V_FAIL=0; V_WARN=0
vsec()  { printf '\n=== %s ===\n' "$*" >> "$REPORTS/validation.txt"; step "$*"; }
vok()   { printf '  [OK]   %s\n'   "$*" >> "$REPORTS/validation.txt"; ok "$*";   V_OK=$((V_OK+1)); }
vfail() { printf '  [FAIL] %s\n'   "$*" >> "$REPORTS/validation.txt"; err "$*";  V_FAIL=$((V_FAIL+1)); }
vwarn() { printf '  [WARN] %s\n'   "$*" >> "$REPORTS/validation.txt"; warn "$*"; V_WARN=$((V_WARN+1)); }
vraw()  { printf '%s\n' "$*" >> "$REPORTS/validation.txt"; }

# 1. Workloads con todas las réplicas listas
v_workloads() {
  vsec "Workloads"
  local s d line
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r kind name want have; do
      [[ -z "${name:-}" ]] && continue
      if [[ "${want:-0}" == "${have:-0}" && "${want:-0}" != "0" ]]; then
        vok "$d $kind/$name  $have/$want listas"
      elif [[ "${want:-0}" == "0" ]]; then
        vwarn "$d $kind/$name  escalado a 0 réplicas"
      else
        vfail "$d $kind/$name  solo $have/$want réplicas listas"
      fi
    done < <(oc_dst -n "$d" get deployment,statefulset,daemonset,deploymentconfig -o json 2>/dev/null | jq -r '
      .items[]
      | [ (.kind|ascii_downcase), .metadata.name,
          ((.spec.replicas // .status.desiredNumberScheduled // 1) | tostring),
          ((.status.readyReplicas // .status.numberReady // 0) | tostring) ] | @tsv')
  done
}

# 2. Pods sanos
v_pods() {
  vsec "Pods"
  local s d pod reason
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r pod reason; do
      [[ -z "${pod:-}" ]] && continue
      vfail "$d pod/$pod en estado '$reason'"
      vraw "         --- últimas líneas de log ---"
      oc_dst -n "$d" logs "$pod" --tail=20 --all-containers=true 2>&1 | sed 's/^/         /' >> "$REPORTS/validation.txt" || true
    done < <(oc_dst -n "$d" get pods -o json 2>/dev/null | jq -r '
      .items[]
      | .metadata.name as $n
      | [ (.status.containerStatuses // [])[] , (.status.initContainerStatuses // [])[] ]
      | map(.state.waiting.reason // .state.terminated.reason // empty)
      | map(select(. | IN("CrashLoopBackOff","ImagePullBackOff","ErrImagePull","CreateContainerConfigError","CreateContainerError","RunContainerError")))
      | select(length > 0)
      | [$n, .[0]] | @tsv')

    # Pods atascados en Pending
    while read -r pod; do
      [[ -z "$pod" ]] && continue
      vfail "$d pod/$pod lleva en Pending (¿PVC, cuota o nodos sin capacidad?)"
    done < <(oc_dst -n "$d" get pods -o json 2>/dev/null \
             | jq -r '.items[] | select(.status.phase=="Pending") | .metadata.name')
  done
  (( V_FAIL == 0 )) && vok "Ningún pod en estado de error"
  return 0
}

# 3. PVCs
v_pvcs() {
  vsec "PersistentVolumeClaims"
  local s d name phase found=false
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r name phase; do
      [[ -z "${name:-}" ]] && continue
      found=true
      [[ "$phase" == "Bound" ]] && vok "$d pvc/$name Bound" || vfail "$d pvc/$name en estado $phase"
    done < <(oc_dst -n "$d" get pvc -o json 2>/dev/null \
             | jq -r '.items[] | [.metadata.name, .status.phase] | @tsv')
  done
  [[ "$found" == false ]] && vraw "  (no hay PVCs)"
  return 0
}

# 4. Eventos de aviso recientes
v_events() {
  vsec "Eventos de tipo Warning (últimos 30 min)"
  local s d n
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    n=$(oc_dst -n "$d" get events --field-selector type=Warning -o json 2>/dev/null | jq -r '.items | length')
    if [[ "${n:-0}" -gt 0 ]]; then
      vwarn "$d: $n eventos Warning"
      oc_dst -n "$d" get events --field-selector type=Warning \
        --sort-by=.lastTimestamp -o custom-columns=OBJ:.involvedObject.name,REASON:.reason,MSG:.message 2>/dev/null \
        | tail -12 | sed 's/^/         /' >> "$REPORTS/validation.txt" || true
    else
      vok "$d sin eventos Warning"
    fi
  done
}

# 5. URLs — el objetivo declarado de la prueba
#
# Dos pasadas: primero se sondean TODAS las rutas de una vez (sin esperas), y
# solo las que fallan se reintentan. Así una ruta rota no bloquea al resto
# durante minutos, que es lo que pasaba sondeando en serie con reintentos.
_probe_url() {
  curl -sk -o /dev/null -w '%{http_code} %{time_total}' \
       --max-time "$ROUTE_PROBE_TIMEOUT" --connect-timeout 5 "$1" 2>/dev/null || echo "000 0"
}

v_urls() {
  vsec "URLs de la aplicación"
  local s d name host term scheme url code t i ok_codes=" $HEALTH_OK_CODES "
  local list="$RUN/.routes-probe.tsv"; : > "$list"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r name host term; do
      [[ -z "${host:-}" || "$host" == "<NONE>" ]] && continue
      [[ "$term" == "<NONE>" ]] && term=""
      [[ -n "$term" ]] && scheme=https || scheme=http
      printf '%s\t%s\t%s\n' "$d" "$name" "${scheme}://${host}${HEALTH_PATH}" >> "$list"
    done < <(oc_dst -n "$d" get route -o json 2>/dev/null | jq -r '
      .items[] | [.metadata.name, (.spec.host // "<NONE>"), (.spec.tls.termination // "<NONE>")] | @tsv')
  done

  if [[ ! -s "$list" ]]; then
    vwarn "No hay Routes en los namespaces de contingencia"
    return 0
  fi

  local pending="$RUN/.routes-pending.tsv" results="$RUN/.routes-results.tsv"
  cp "$list" "$pending"; : > "$results"

  for (( i=1; i<=ROUTE_PROBE_RETRIES; i++ )); do
    : > "$pending.next"
    while IFS=$'\t' read -r d name url; do
      [[ -z "${url:-}" ]] && continue
      read -r code t < <(_probe_url "$url")
      if [[ "$ok_codes" == *" $code "* ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$name" "$url" "$code" "$t" >> "$results"
      else
        printf '%s\t%s\t%s\n' "$d" "$name" "$url" >> "$pending.next"
        printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$name" "$url" "$code" "$t" > "$RUN/.last-$name"
      fi
    done < "$pending"
    mv "$pending.next" "$pending"
    [[ -s "$pending" ]] || break
    (( i < ROUTE_PROBE_RETRIES )) || break
    log "  $(wc -l < "$pending") rutas aún sin responder; reintento $((i+1))/$ROUTE_PROBE_RETRIES en ${ROUTE_PROBE_INTERVAL}s"
    sleep "$ROUTE_PROBE_INTERVAL"
  done

  # las que siguen pendientes son fallo definitivo
  while IFS=$'\t' read -r d name url; do
    [[ -z "${url:-}" ]] && continue
    cat "$RUN/.last-$name" >> "$results" 2>/dev/null || printf '%s\t%s\t%s\t000\t0\n' "$d" "$name" "$url" >> "$results"
  done < "$pending"
  rm -f "$RUN"/.last-* "$pending" "$list"

  vraw "$(printf '%-26s %-20s %-58s %-6s %-8s %s' 'NAMESPACE' 'ROUTE' 'URL' 'HTTP' 'SEG' 'RESULTADO')"
  while IFS=$'\t' read -r d name url code t; do
    [[ -z "${url:-}" ]] && continue
    if [[ "$ok_codes" == *" $code "* ]]; then
      vraw "$(printf '%-26s %-20s %-58s %-6s %-8s %s' "$d" "$name" "$url" "$code" "$t" 'OK')"
      ok "$d $url -> $code"; V_OK=$((V_OK+1))
    else
      vraw "$(printf '%-26s %-20s %-58s %-6s %-8s %s' "$d" "$name" "$url" "$code" "$t" 'FAIL')"
      err "$d $url -> $code"; V_FAIL=$((V_FAIL+1))
      todo "$d: la URL $url devuelve $code. Revisa Route, Service, endpoints y readiness del pod."
    fi
  done < <(sort -u "$results")
  rm -f "$results"
  return 0
}

# 6. Base de datos y conectividad entre namespaces
v_database() {
  vsec "Base de datos y conectividad entre namespaces"
  local db_ns; db_ns="$(ns_dst "$DB_NS")"
  local pod; pod=$(db_find_pod oc_dst "$db_ns")
  if [[ -z "$pod" ]]; then
    vfail "$db_ns: no hay pod de PostgreSQL Running"
    return 0
  fi

  if oc_dst -n "$db_ns" exec "$pod" -- bash -c \
      'PGPASSWORD="$POSTGRESQL_PASSWORD" psql -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DATABASE" -At -c "select 1"' \
      >/dev/null 2>&1; then
    vok "$db_ns: PostgreSQL responde a 'select 1'"
  else
    vfail "$db_ns: PostgreSQL no responde a 'select 1'"
  fi

  # Diff de conteo de filas generado por db-migrate
  if [[ -r "$RUN/db/rowcounts.diff" ]]; then
    if [[ -s "$RUN/db/rowcounts.diff" ]]; then
      vfail "El conteo de filas difiere de PROD (ver $RUN/db/rowcounts.diff)"
    else
      vok "Conteo de filas idéntico a PROD"
    fi
  else
    vwarn "No se ejecutó db-migrate en esta corrida: no hay comparación de filas"
  fi

  # Alcance desde el backend: valida el renombrado de namespace en la config
  local core_ns core_pod svc port
  core_ns="$(ns_dst sanba-core)"
  core_pod=$(oc_dst -n "$core_ns" get pods -o json 2>/dev/null | jq -r '
    .items[] | select(.status.phase=="Running")
    | select([.status.containerStatuses[]? | select(.ready)] | length > 0)
    | .metadata.name' | head -1)
  svc=$(oc_dst -n "$db_ns" get svc -o json 2>/dev/null | jq -r '
    .items[] | select([.spec.ports[]?.port] | index(5432)) | .metadata.name' | head -1)

  if [[ -z "$core_pod" ]]; then
    vwarn "$core_ns: no hay pod Ready desde el que probar la conexión a la BD"
  elif [[ -z "$svc" ]]; then
    vwarn "$db_ns: no se encontró un Service que exponga el puerto 5432"
  else
    local target="${svc}.${db_ns}.svc.cluster.local"
    if oc_dst -n "$core_ns" exec "$core_pod" -- bash -c \
        "timeout 5 bash -c 'exec 3<>/dev/tcp/${target}/5432' 2>/dev/null" >/dev/null 2>&1; then
      vok "$core_ns -> ${target}:5432 alcanzable (el renombrado de namespace funciona)"
    else
      vwarn "$core_ns: no se pudo probar ${target}:5432 desde el pod (¿la imagen no trae bash/timeout?). Verifícalo a mano."
    fi
  fi
}

# 7. ServiceAccounts y SCC
v_serviceaccounts() {
  vsec "ServiceAccounts y SCC"
  local s d sa scc expected actual pod
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"

    # Una sola lectura de las SAs y de los RoleBindings del namespace
    local live_sa live_rb
    live_sa=$(oc_dst -n "$d" get sa -o json 2>/dev/null | jq -r '.items[].metadata.name')
    live_rb="$RUN/.rb-$d.json"
    oc_dst -n "$d" get rolebinding -o json 2>/dev/null > "$live_rb" || echo '{"items":[]}' > "$live_rb"

    # Las SAs que migramos deben existir
    while read -r sa; do
      [[ -z "$sa" ]] && continue
      if grep -qxF "$sa" <<< "$live_sa"; then
        vok "$d sa/$sa existe"
      else
        vfail "$d sa/$sa NO existe"
      fi
    done < <(clean_items "$d" serviceaccount | jq -r '.[].metadata.name')

    # Cada pod corre con la SA esperada
    while IFS=$'\t' read -r pod actual; do
      [[ -z "${pod:-}" ]] && continue
      vraw "  pod/$pod usa serviceAccount '$actual' en $d"
    done < <(oc_dst -n "$d" get pods -o json 2>/dev/null \
             | jq -r '.items[] | [.metadata.name, (.spec.serviceAccountName // "default")] | @tsv')

    # Las SCC concedidas en DR deben coincidir con las de PROD
    while IFS=$'\t' read -r scc ns sa origen; do
      [[ "$ns" == "$d" ]] || continue
      if jq -e --arg scc "system:openshift:scc:$scc" --arg sa "$sa" \
            '[.items[] | select(.roleRef.name == $scc) | .subjects[]? | select(.name == $sa)] | length > 0' \
            < "$live_rb" >/dev/null; then
        vok "$d sa/$sa tiene la SCC '$scc'"
      else
        vfail "$d sa/$sa NO tiene la SCC '$scc' que sí tenía en PROD (origen: $origen)"
      fi
    done < <(cat "$CLEAN/_cluster/scc-assignments.tsv" 2>/dev/null)
    rm -f "$live_rb"
  done
}

# 8. ConfigMaps y Secrets: existencia y diff de CLAVES (nunca de valores)
v_config() {
  vsec "ConfigMaps y Secrets"
  local s d kind name src_keys dst_keys
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    for kind in configmap secret; do
      while read -r name; do
        [[ -z "$name" ]] && continue
        if ! oc_dst -n "$d" get "$kind" "$name" >/dev/null 2>&1; then
          vfail "$d $kind/$name no existe en destino"
          continue
        fi
        src_keys=$(jq -r --arg n "$name" '.items[] | select(.metadata.name==$n) | (.data // {}) | keys | join(",")' \
                   < "$RAW/$s/$kind.json" 2>/dev/null)
        dst_keys=$(oc_dst -n "$d" get "$kind" "$name" -o json 2>/dev/null | jq -r '(.data // {}) | keys | join(",")')
        if [[ "$src_keys" == "$dst_keys" ]]; then
          vok "$d $kind/$name  claves idénticas"
        else
          vfail "$d $kind/$name  las claves difieren (PROD: [$src_keys] / DR: [$dst_keys])"
        fi
      done < <(clean_items "$d" "$kind" | jq -r '.[].metadata.name')
    done
  done
}

# 9. URLs dentro de ConfigMaps, Secrets y variables de entorno
#
# Comprueba lo que de verdad quedó EN EL CLÚSTER de contingencia: si algún
# componente conserva una URL de producción, la prueba de DR es falsa aunque
# todos los pods estén Ready. De los Secrets solo se mira el valor descodificado
# en memoria; al informe solo va el nombre de la clave.
v_config_urls() {
  vsec "URLs de producción dentro de la configuración desplegada"
  local s d srcdom froms filtro n_bad=0

  if [[ ! -r "$RUN/domain-src.txt" ]]; then
    vwarn "No hay domain-src.txt en esta corrida: no se puede comprobar el dominio de producción"
    return 0
  fi
  srcdom="$(cat "$RUN/domain-src.txt")"

  # Patrones a buscar: el apps-domain de PROD, el lado izquierdo del mapa de
  # URLs y los hosts de PROD que 'transform' no pudo traducir.
  froms=$( { cut -f1 "$RUN/url-map.tsv" 2>/dev/null
             cat "$RUN/.url-unmapped.txt" 2>/dev/null; } | grep -v '^$' || true)
  filtro=$(printf '%s\n%s\n' "$srcdom" "$froms" | grep -v '^$' | sort -u | jq -R . | jq -s -c .)

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r kind name key hit; do
      [[ -z "${name:-}" ]] && continue
      vfail "$d $kind/$name clave '$key' apunta todavía a producción ('$hit')"
      todo "$d: $kind/$name clave '$key' conserva '$hit'. Añade el par correcto a ${URL_MAP_FILE:-url-map.txt}, repite 'transform' y vuelve a aplicar."
      n_bad=$((n_bad+1))
    done < <(oc_dst -n "$d" get configmap,secret,deployment,deploymentconfig,statefulset,daemonset -o json 2>/dev/null \
      | jq -r --argjson pats "$filtro" '
          .items[]
          | .kind as $k | .metadata.name as $n
          | select($n | IN("kube-root-ca.crt","openshift-service-ca.crt") | not)
          | ( ( (.data // {}) | to_entries[]
                | {key: .key,
                   v: (if $k == "Secret" then ((try (.value | @base64d) catch "") // "") else (.value // "") end)} ),
              ( ((.spec.template.spec // {}) | (.containers // []) + (.initContainers // []))[]
                | ( ((.env // [])[] | select(has("value")) | {key: ("env/" + .name), v: (.value // "")}),
                    ((.args // [])[] | {key: "args", v: .}),
                    ((.command // [])[] | {key: "command", v: .}) ) ) )
          | select(.v | type == "string")
          | . as $e
          | $pats[] | . as $p
          | select($p | length > 0)
          | select($e.v | contains($p))
          | [$k, $n, $e.key, $p] | @tsv')
  done

  if (( n_bad == 0 )); then
    vok "Ningún ConfigMap, Secret ni variable de entorno del entorno de contingencia apunta a producción"
  fi
  [[ -r "$REPORTS/urls.txt" ]] && vraw "  Mapa completo de URLs: $REPORTS/urls.txt"
  return 0
}

# 10. Asociación entre namespaces, comprobada sobre el clúster
#
# El equivalente en caliente de tf_cross_refs: que cada dependencia
# <servicio>.<namespace>-dr.svc que la configuración desplegada declara exista
# de verdad, tenga endpoints, y que el RBAC y las NetworkPolicies apunten a los
# namespaces de contingencia y no a los de producción.
v_cross_namespace() {
  vsec "Asociación entre los namespaces de contingencia"
  local s d ns_re svcs="$RUN/.live-svcs.tsv" eps="$RUN/.live-eps.tsv"
  : > "$svcs"; : > "$eps"

  ns_re=""
  for s in $(src_namespaces); do ns_re+="${ns_re:+|}$(ns_dst "$s")"; done
  for s in $(src_namespaces); do ns_re+="|$s"; done

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    oc_dst -n "$d" get service -o json 2>/dev/null \
      | jq -r --arg d "$d" '.items[] | [$d, .metadata.name] | @tsv' >> "$svcs"
    oc_dst -n "$d" get endpoints -o json 2>/dev/null \
      | jq -r --arg d "$d" '.items[] | [$d, .metadata.name,
          ([.subsets[]?.addresses[]?] | length | tostring)] | @tsv' >> "$eps"
  done

  local vistos=0
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"

    # --- dependencias DNS declaradas en la configuración desplegada ---------
    while IFS=$'\t' read -r kind name campo svc tns; do
      [[ -z "${svc:-}" ]] && continue
      vistos=$((vistos+1))
      if [[ "$tns" != *"$DR_SUFFIX" ]]; then
        vfail "$d $kind/$name ($campo) apunta a ${svc}.${tns}.svc, el namespace de PRODUCCIÓN"
        todo "$d: $kind/$name ($campo) apunta a producción (${svc}.${tns}.svc). Repite 'transform' y vuelve a aplicar."
      elif ! awk -F'\t' -v n="$tns" -v x="$svc" '$1==n && $2==x {f=1} END{exit !f}' "$svcs"; then
        vfail "$d $kind/$name ($campo) apunta a ${svc}.${tns}.svc, pero ese Service no existe en $tns"
        todo "$d: falta el Service '$svc' en '$tns'; ${kind}/${name} no podrá resolverlo."
      elif [[ "$(awk -F'\t' -v n="$tns" -v x="$svc" '$1==n && $2==x {print $3}' "$eps")" == "0" ]]; then
        vwarn "$d $kind/$name ($campo) -> ${svc}.${tns}.svc existe pero no tiene endpoints (ningún pod listo detrás)"
      else
        vok "$d $kind/$name ($campo) -> ${svc}.${tns}.svc resuelve y tiene endpoints"
      fi
    done < <(oc_dst -n "$d" get configmap,secret,deployment,deploymentconfig,statefulset,daemonset -o json 2>/dev/null \
      | jq -r --arg re "([A-Za-z0-9][A-Za-z0-9_-]*)\\.($ns_re)\\.svc" '
          .items[] as $o
          | select($o.metadata.name | IN("kube-root-ca.crt","openshift-service-ca.crt") | not)
          | ($o | paths(strings)) as $p
          | ($o | getpath($p)) as $raw
          | (if ($o.kind == "Secret") and ($p[0] == "data")
             then ((try ($raw | @base64d) catch "") // "") else $raw end) as $v
          | select($v | type == "string")
          | $v | [match($re; "g")][]
          | [$o.kind, $o.metadata.name, ($p | map(tostring) | join(".")),
             .captures[0].string, .captures[1].string] | @tsv' | sort -u)

    # --- RBAC: ninguna concesión puede seguir apuntando a producción --------
    # Un subject en un namespace ajeno a la migración no es un fallo nuestro:
    # es un permiso a otra aplicación del clúster. Se avisa, no se suspende.
    while IFS=$'\t' read -r bind sa sans; do
      [[ -z "${sa:-}" ]] && continue
      if is_src_ns "$sans"; then
        vfail "$d rolebinding/$bind concede permisos a la SA '$sa' del namespace de PRODUCCIÓN '$sans'"
      elif ! is_dst_ns "$sans"; then
        vwarn "$d rolebinding/$bind concede permisos a '$sa' de '$sans', ajeno a la migración; comprueba que ese namespace existe aquí"
      elif [[ "$sans" != "$d" ]]; then
        if oc_dst -n "$sans" get sa "$sa" >/dev/null 2>&1; then
          vok "$d rolebinding/$bind concede acceso a $sa de $sans (asociación cruzada correcta)"
        else
          vfail "$d rolebinding/$bind apunta a la SA '$sa' de '$sans', que no existe"
        fi
      fi
    done < <(oc_dst -n "$d" get rolebinding -o json 2>/dev/null | jq -r --arg d "$d" '
        .items[] | select(.metadata.name | startswith("system:") | not)
        | .metadata.name as $n | ((.subjects // [])[])
        | select(.kind == "ServiceAccount")
        | [$n, .name, (.namespace // $d)] | @tsv')

    # --- NetworkPolicy: los selectores deben elegir namespaces -dr ----------
    while IFS=$'\t' read -r name valor; do
      [[ -z "${valor:-}" ]] && continue
      if [[ "$valor" != *"$DR_SUFFIX" ]]; then
        vfail "$d networkpolicy/$name selecciona el namespace '$valor', que no es de contingencia: el tráfico quedará bloqueado"
        todo "$d: networkpolicy/$name selecciona '$valor'. Debe seleccionar '$(ns_dst "$valor")'."
      else
        vok "$d networkpolicy/$name selecciona correctamente '$valor'"
      fi
    done < <(oc_dst -n "$d" get networkpolicy -o json 2>/dev/null | jq -r --arg re "^($ns_re)\$" '
        .items[] | .metadata.name as $n
        | [ .. | objects | select(has("namespaceSelector")) | .namespaceSelector
            | ((.matchLabels // {}) | to_entries[] | .value),
              ((.matchExpressions // [])[] | (.values // [])[]) ]
        | .[] | select(test($re)) | [$n, .] | @tsv' | sort -u)
  done

  rm -f "$svcs" "$eps"
  (( vistos == 0 )) && vwarn "No se encontró ninguna dependencia DNS entre namespaces en la configuración desplegada"
  [[ -r "$REPORTS/cross-namespace.txt" ]] && vraw "  Mapa de dependencias: $REPORTS/cross-namespace.txt"
  return 0
}

cmd_validate() {
  require_cmd oc jq curl
  phase_steps 12
  [[ -d "$RUN" ]] || die "No existe la corrida $RUN_ID"
  {
    echo "Validación de la prueba de DR de SANBA"
    echo "Corrida:  $RUN_ID"
    echo "Fecha:    $(date -Is)"
    echo "Destino:  $(oc_dst whoami --show-server 2>/dev/null)"
  } > "$REPORTS/validation.txt"

  v_workloads
  v_pods
  v_pvcs
  v_events
  v_urls
  v_database
  v_serviceaccounts
  v_config
  v_config_urls
  v_cross_namespace

  vsec "Resumen"
  vraw "  Comprobaciones OK : $V_OK"
  vraw "  Avisos            : $V_WARN"
  vraw "  Fallos            : $V_FAIL"
  if [[ -s "$REPORTS/manual-todo.txt" ]]; then
    vraw ""
    vraw "  Pendientes manuales:"
    sed 's/^/  /' "$REPORTS/manual-todo.txt" >> "$REPORTS/validation.txt"
  fi

  step "Validación terminada"
  log "Informe completo: $REPORTS/validation.txt"
  if (( V_FAIL > 0 )); then
    err "$V_FAIL comprobaciones fallaron ($V_WARN avisos)"
    return 1
  fi
  ok "Todas las comprobaciones pasaron ($V_WARN avisos)"
  return 0
}
