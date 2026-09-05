#!/usr/bin/env bash
# lib/apply.sh — aplica los manifiestos limpios en el clúster DESTINO, en orden
# de dependencias, esperando en los puntos donde hace falta.
# shellcheck shell=bash

apply_file() {
  local f="$1"
  [[ -r "$f" ]] || return 0

  # Una List sin objetos hace fallar a 'oc apply' con "no objects passed to
  # apply". Puede quedar así legítimamente: por ejemplo, si todos los
  # ClusterRoleBindings del export resultaron ser de un operador y ninguno se
  # copia. No es un error, no hay nada que aplicar.
  if [[ "$(read_manifest "$f" 2>/dev/null \
           | jq -r 'if (.kind == "List") then (.items | length) else 1 end' 2>/dev/null)" == "0" ]]; then
    vlog "  (se omite $(basename "$f"): no contiene ningún objeto)"
    return 0
  fi

  log "  apply $(basename "$f")"
  oc_dstw apply -f "$f" >/dev/null || die "Falló 'oc apply -f $f'"
}

# Aplica un manifiesto por su nombre base, sea .yaml o .json.
apply_base() {
  local d="$1" base="$2" f
  if f="$(clean_file "$d" "$base")"; then apply_file "$f"; else vlog "  (sin $base en $d)"; fi
}

# Aplica todos los manifiestos cuyo prefijo numérico casa un patrón (p.ej. '5*').
apply_tier() {
  local d="$1" pat="$2" f found=false
  for f in "$CLEAN/$d"/${pat}-*.yaml "$CLEAN/$d"/${pat}-*.json; do
    [[ -r "$f" ]] || continue
    apply_file "$f"; found=true
  done
  [[ "$found" == true ]] || vlog "  (nada que aplicar en el tramo $pat de $d)"
}

# --- prerrequisitos globales ------------------------------------------------
apply_prereqs() {
  step "Namespaces y bindings cluster-scoped"
  local f
  for f in "$CLEAN/_cluster"/00-namespace-*.yaml "$CLEAN/_cluster"/00-namespace-*.json; do
    [[ -r "$f" ]] || continue
    apply_file "$f"
  done
  for f in "$CLEAN/_cluster"/80-clusterrolebinding.yaml "$CLEAN/_cluster"/80-clusterrolebinding.json; do
    [[ -r "$f" ]] && apply_file "$f"
  done
  ok "Namespaces creados"
}

# --- SCC --------------------------------------------------------------------
# Concede las SCC con el comando documentado por Red Hat:
#   oc -n <namespace> adm policy add-scc-to-user <scc> -z <serviceaccount>
#   (Authentication and authorization 4.18, "Managing security context constraints")
#
# Las asignaciones que en PROD venían de un RoleBinding namespaced NO se
# reconceden aquí: ese RoleBinding ya se migró como manifiesto en el tramo 14.
apply_scc_for_ns() {
  local d="$1" scc ns sa origen n=0 skipped=0
  [[ -r "$CLEAN/_cluster/scc-assignments.tsv" ]] || return 0
  while IFS=$'\t' read -r scc ns sa origen; do
    [[ "$ns" == "$d" ]] || continue
    if [[ "$origen" == "rolebinding" ]]; then
      vlog "  scc '$scc' -> sa '$sa' ya cubierta por el RoleBinding migrado"
      skipped=$((skipped+1)); continue
    fi
    log "  scc '$scc' -> sa '$sa' (origen: $origen)"
    oc_dstw -n "$d" adm policy add-scc-to-user "$scc" -z "$sa" >/dev/null \
      || warn "$d: no se pudo asignar la SCC '$scc' a '$sa' (¿faltan permisos de cluster-admin?)"
    n=$((n+1))
  done < "$CLEAN/_cluster/scc-assignments.tsv"
  [[ "$n" -gt 0 || "$skipped" -gt 0 ]] && ok "$d: $n SCC concedidas, $skipped ya cubiertas por RoleBinding"
  return 0
}

# La ServiceAccount 'default' ya existe en el destino con sus propios secrets
# autogenerados. No se aplica el objeto entero (borraría esos secrets): solo se
# le añaden los imagePullSecrets creados a mano en PROD.
reconcile_default_sa() {
  local d="$1" f="$CLEAN/$1/default-sa-pullsecrets.txt"
  [[ -s "$f" ]] || return 0
  local current merged
  current=$(oc_dst -n "$d" get sa default -o json 2>/dev/null | jq -r '[.imagePullSecrets[]?.name] | .[]' || true)
  merged=$( { printf '%s\n' "$current"; cat "$f"; } | sed '/^$/d' | sort -u \
            | jq -R . | jq -s '{imagePullSecrets: map({name: .})}' -c )
  log "  sa/default: imagePullSecrets -> $(jq -r '[.imagePullSecrets[].name] | join(",")' <<< "$merged")"
  oc_dstw -n "$d" patch sa default -p "$merged" >/dev/null \
    || warn "$d: no se pudo parchear la ServiceAccount 'default'"
}

# --- PVCs -------------------------------------------------------------------
wait_pvcs_bound() {
  local d="$1" waited=0 pending
  clean_file "$d" 30-persistentvolumeclaim >/dev/null || return 0
  [[ "${DRY_RUN:-false}" == true ]] && return 0

  log "  esperando a que los PVC queden Bound (máx ${PVC_BOUND_TIMEOUT}s)"
  while (( waited < PVC_BOUND_TIMEOUT )); do
    pending=$(oc_dst -n "$d" get pvc -o json 2>/dev/null \
      | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.name' | paste -sd, -)
    [[ -z "$pending" ]] && { ok "$d: todos los PVC están Bound"; return 0; }

    # WaitForFirstConsumer no se enlaza hasta que hay un pod: no es un error.
    local wffc=true name sc mode
    for name in ${pending//,/ }; do
      sc=$(oc_dst -n "$d" get pvc "$name" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
      mode=$(oc_dst get storageclass "$sc" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)
      [[ "$mode" == "WaitForFirstConsumer" ]] || wffc=false
    done
    if [[ "$wffc" == true ]]; then
      log "  PVC pendientes con WaitForFirstConsumer ($pending): se enlazarán al arrancar los pods"
      return 0
    fi
    sleep 5; waited=$((waited+5))
  done
  warn "$d: PVC sin enlazar tras ${PVC_BOUND_TIMEOUT}s: $pending"
  todo "$d: revisa los PVC pendientes ($pending) — StorageClass o capacidad en pre-producción"
}

# --- Workloads --------------------------------------------------------------
wait_rollouts() {
  local d="$1" kind name
  [[ "${DRY_RUN:-false}" == true ]] && return 0
  while IFS=$'\t' read -r kind name; do
    [[ -z "${name:-}" ]] && continue
    log "  rollout $kind/$name"
    if ! oc_dst -n "$d" rollout status "$kind/$name" --timeout="$ROLLOUT_TIMEOUT" >/dev/null 2>&1; then
      err "$d: $kind/$name no completó el rollout en $ROLLOUT_TIMEOUT"
      oc_dst -n "$d" get pods -l "$(oc_dst -n "$d" get "$kind" "$name" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | jq -r 'to_entries|map(.key+"="+.value)|join(",")' 2>/dev/null || echo '')" 2>/dev/null | sed 's/^/      /' >&2 || true
      todo "$d: $kind/$name no arrancó. Revisa 'oc -n $d describe $kind/$name' y los logs."
    fi
  done < <(clean_items "$d" | jq -r '
      .[]
      | select(.kind | IN("Deployment","StatefulSet","DaemonSet","DeploymentConfig"))
      | [(.kind | ascii_downcase), .metadata.name] | @tsv')
}

# --- un namespace completo --------------------------------------------------
apply_namespace() {
  local s="$1" d; d="$(ns_dst "$s")"
  step "Aplicando $d"
  [[ -d "$CLEAN/$d" ]] || { warn "No hay manifiestos para $d"; return 0; }

  apply_base "$d" 10-serviceaccount
  reconcile_default_sa "$d"
  apply_scc_for_ns "$d"

  apply_base "$d" 12-role
  apply_base "$d" 14-rolebinding
  apply_base "$d" 20-secret
  apply_base "$d" 25-configmap

  apply_base "$d" 30-persistentvolumeclaim
  wait_pvcs_bound "$d"

  apply_base "$d" 40-service

  apply_tier "$d" '5*'
  wait_rollouts "$d"

  apply_base "$d" 60-route
  apply_tier "$d" '7*' 

  ok "$d aplicado"
}

cmd_apply() {
  require_cmd oc jq
  # namespaces + prerrequisitos + cierre
  phase_steps $(( $(src_namespaces | wc -l) + 2 ))
  [[ -d "$CLEAN" ]] || die "No hay manifiestos limpios en $CLEAN. Ejecuta primero: $0 transform"

  # Guardas: nunca aplicar sobre el clúster origen.
  local dst_api src_api
  dst_api=$(oc_dst whoami --show-server 2>/dev/null) || die "Sesión de DESTINO inválida"
  src_api=$(oc_src whoami --show-server 2>/dev/null) || die "Sesión de ORIGEN inválida"
  [[ "$dst_api" != "$src_api" ]] || die "ORIGEN y DESTINO son el mismo clúster. Abortando."
  log "Destino: $dst_api"

  apply_prereqs

  local s
  for s in $(src_namespaces); do
    [[ -n "${ONLY_NS:-}" && "$ONLY_NS" != "$s" ]] && continue
    apply_namespace "$s"

    # La carga de datos es una fase aparte, con su propio subcomando. Solo se
    # encadena aquí si se pide expresamente con --with-db, para quien prefiera
    # el comportamiento antiguo (restaurar entre la BD y el backend).
    #
    # Se ejecuta en una subshell a propósito: si algo falla dentro, un 'die'
    # terminaría el script entero y dejaría el resto de namespaces sin
    # desplegar. Aquí se avisa y se sigue: es preferible un drill completo con
    # la base de datos pendiente que medio entorno sin crear.
    if [[ "$s" == "$DB_NS" && "${WITH_DB:-false}" == true && "$DB_MIGRATE" == true \
          && "${SKIP_DB:-false}" != true && -z "${ONLY_NS:-}" ]]; then
      if ( run_phase DB-MIGRATE "Carga de datos PostgreSQL de PROD a contingencia" cmd_db_migrate ); then
        DB_STEP_OK=true
      else
        DB_STEP_OK=false
        warn "La carga de datos no se completó. Se continúa desplegando el resto."
        todo "Repite la carga:  $0 db-migrate --run $RUN_ID"
        todo "Y después reinicia el backend, que habrá arrancado contra una base vacía."
      fi
    fi
  done

  step "Apply terminado"
  if [[ "${DB_STEP_OK:-true}" != true ]]; then
    warn "Los namespaces están desplegados, pero la base de datos NO se cargó"
    log  "  1) $0 db-migrate --run $RUN_ID"
    log  "  2) $0 restart    --run $RUN_ID"
    log  "  3) $0 validate   --run $RUN_ID"
  elif [[ "${WITH_DB:-false}" == true ]]; then
    ok "Ejecuta ahora: $0 validate --run $RUN_ID"
  else
    log "Los workloads están desplegados. La base de datos aún NO se ha cargado:"
    log "  1) $0 db-migrate --run $RUN_ID   (pg_dump en PROD -> pg_restore en DR)"
    log "  2) $0 restart    --run $RUN_ID   (reinicia lo que arrancó contra la base vacía)"
    log "  3) $0 validate   --run $RUN_ID"
    ok "Apply completado"
  fi
}

# =============================================================================
#  restart — reinicia los workloads que arrancaron antes de que hubiera datos
#
#  Al separar la carga de datos del despliegue, el backend arranca contra una
#  base vacía: cachés frías, pools de conexión creados contra un esquema que aún
#  no existía y, según la aplicación, un arranque fallido. Este paso los reinicia
#  una vez cargados los datos. No toca el namespace de la base de datos.
# =============================================================================
cmd_restart() {
  require_cmd oc jq
  phase_steps "$(src_namespaces | wc -l)"

  local dst_api src_api
  dst_api=$(oc_dst whoami --show-server 2>/dev/null) || die "Sesión de DESTINO inválida"
  src_api=$(oc_src whoami --show-server 2>/dev/null) || die "Sesión de ORIGEN inválida"
  [[ "$dst_api" != "$src_api" ]] || die "ORIGEN y DESTINO son el mismo clúster. Abortando."

  local s d kind name n
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    [[ -n "${ONLY_NS:-}" && "$ONLY_NS" != "$s" ]] && continue

    if [[ "$s" == "$DB_NS" ]]; then
      step "$d: no se reinicia (es la base de datos que acaba de cargarse)"
      continue
    fi

    step "Reiniciando los workloads de $d"
    [[ "$d" == *"$DR_SUFFIX" ]] || die "El namespace '$d' no termina en '$DR_SUFFIX'. Abortando por seguridad."

    n=0
    while IFS=$'\t' read -r kind name; do
      [[ -z "${name:-}" ]] && continue
      n=$((n+1))
      if [[ "$kind" == "deploymentconfig" ]]; then
        # Un DeploymentConfig no admite 'rollout restart'; su equivalente es
        # lanzar un despliegue nuevo.
        log "  rollout latest $kind/$name"
        oc_dstw -n "$d" rollout latest "dc/$name" >/dev/null 2>&1 \
          || warn "$d: no se pudo relanzar dc/$name (¿hay un despliegue en curso?)"
      else
        log "  rollout restart $kind/$name"
        oc_dstw -n "$d" rollout restart "$kind/$name" >/dev/null \
          || warn "$d: no se pudo reiniciar $kind/$name"
      fi
    done < <(oc_dst -n "$d" get deployment,deploymentconfig,statefulset -o json 2>/dev/null \
             | jq -r '.items[] | [(.kind | ascii_downcase), .metadata.name] | @tsv')

    if (( n == 0 )); then
      warn "$d: no hay workloads que reiniciar"
    else
      wait_rollouts "$d"
      ok "$d: $n workloads reiniciados"
    fi
  done
}
