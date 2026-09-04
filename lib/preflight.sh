#!/usr/bin/env bash
# lib/preflight.sh — validaciones previas. No escribe nada en ningún clúster.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Dependencias del host (RHEL 9)
#
#   oc     -> RPM de Red Hat (openshift-clients) o tarball del mirror
#   jq     -> AppStream de RHEL 9 (jq 1.6; se usan @base64d, IN, try/catch y
#             lookbehind de Oniguruma, todos disponibles en 1.6)
#   rsync  -> BaseOS, lo necesita 'oc rsync' en el lado cliente
#   yq     -> OPCIONAL, no está en los repos de RHEL 9. Sin él los manifiestos
#             se generan en JSON, que 'oc apply -f' acepta igual.
# ---------------------------------------------------------------------------
check_dependencies() {
  step "Dependencias del host (RHEL 9)"
  local missing=()
  local c
  for c in oc jq curl sed awk tar; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    cat >&2 <<MSG

  Faltan comandos obligatorios: ${missing[*]}

  En RHEL 9:
    sudo dnf install -y jq curl sed gawk tar rsync
    # cliente oc 4.18 (una de las dos vías):
    sudo subscription-manager repos --enable="rhocp-4.18-for-rhel-9-x86_64-rpms"
    sudo dnf install -y openshift-clients
    # o bien, sin suscripción de OCP:
    curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.18/openshift-client-linux.tar.gz \
      | sudo tar xz -C /usr/local/bin oc kubectl

MSG
    die "Instala las dependencias y vuelve a ejecutar el preflight."
  fi
  ok "oc, jq, curl, sed, awk y tar disponibles"

  # jq >= 1.6
  local jqv jqmaj jqmin
  jqv=$(jq --version 2>/dev/null | sed 's/^jq-//')
  jqmaj=${jqv%%.*}; jqmin=$(cut -d. -f2 <<< "$jqv")
  if (( jqmaj < 1 || (jqmaj == 1 && ${jqmin:-0} < 6) )); then
    die "Se necesita jq 1.6 o superior (encontrado: $jqv). En RHEL 9: sudo dnf install -y jq"
  fi
  ok "jq $jqv"

  if command -v rsync >/dev/null 2>&1; then
    ok "rsync disponible ('oc rsync' lo usará; si el contenedor no lo trae, oc cae a tar)"
  else
    warn "rsync no está instalado: 'oc rsync' usará la estrategia tar. Recomendado: sudo dnf install -y rsync"
  fi

  detect_manifest_format
  if [[ "$HAVE_YQ" == true ]]; then
    ok "yq presente: los manifiestos se generarán en YAML"
  else
    log "yq no está (normal en RHEL 9): los manifiestos se generarán en JSON, que 'oc apply -f' acepta igual"
  fi
}

_semver_minor() { sed -E 's/^v?([0-9]+)\.([0-9]+).*/\1 \2/' <<< "$1"; }

check_oc_version() {
  step "Versión del cliente oc vs. clústeres"
  local cli src_srv dst_srv
  cli=$(command oc version --client -o json 2>/dev/null | jq -r '.releaseClientVersion // .clientVersion.gitVersion // empty')
  [[ -n "$cli" ]] || cli=$(command oc version --client 2>/dev/null | sed -n 's/.*Client Version: *//p' | head -1)
  log "Cliente oc: ${cli:-desconocido}"

  src_srv=$(oc_src version -o json 2>/dev/null | jq -r '.openshiftVersion // empty')
  dst_srv=$(oc_dst version -o json 2>/dev/null | jq -r '.openshiftVersion // empty')
  log "Servidor ORIGEN : ${src_srv:-desconocido}"
  log "Servidor DESTINO: ${dst_srv:-desconocido}"

  local bad=false srv maj_c min_c maj_s min_s
  read -r maj_c min_c <<< "$(_semver_minor "${cli:-0.0}")"
  for srv in "$src_srv" "$dst_srv"; do
    [[ -n "$srv" ]] || continue
    read -r maj_s min_s <<< "$(_semver_minor "$srv")"
    if [[ "$maj_c" != "$maj_s" ]] || (( min_c - min_s > 1 || min_s - min_c > 1 )); then
      bad=true
    fi
  done

  if [[ "$bad" == true ]]; then
    if [[ "${SKIP_VERSION_CHECK:-false}" == true ]]; then
      warn "Skew de versión fuera de soporte, continuando por SKIP_VERSION_CHECK=true"
    else
      cat >&2 <<MSG

  El cliente oc (${cli}) está demasiado lejos de la versión del clúster.
  Solo se soporta +/- 1 versión menor. Instala el cliente 4.18:

    mkdir -p ~/bin
    curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.18/openshift-client-linux.tar.gz \\
      | tar xz -C ~/bin oc kubectl
    export PATH="\$HOME/bin:\$PATH"

  (o exporta SKIP_VERSION_CHECK=true bajo tu responsabilidad)
MSG
      die "Versión del cliente oc incompatible."
    fi
  else
    ok "Versión del cliente compatible"
  fi
}

check_logins() {
  step "Sesiones en ambos clústeres"
  local src_api dst_api src_user dst_user

  [[ -r "$KUBECONFIG_SRC" ]] || die "No se puede leer KUBECONFIG_SRC: $KUBECONFIG_SRC"
  [[ -r "$KUBECONFIG_DST" ]] || die "No se puede leer KUBECONFIG_DST: $KUBECONFIG_DST"

  src_user=$(oc_src whoami 2>/dev/null) || die "Token de ORIGEN inválido o expirado ($KUBECONFIG_SRC)"
  dst_user=$(oc_dst whoami 2>/dev/null) || die "Token de DESTINO inválido o expirado ($KUBECONFIG_DST)"
  src_api=$(oc_src whoami --show-server 2>/dev/null)
  dst_api=$(oc_dst whoami --show-server 2>/dev/null)

  log "ORIGEN  $src_api  (usuario: $src_user)"
  log "DESTINO $dst_api  (usuario: $dst_user)"

  [[ "$src_api" != "$dst_api" ]] \
    || die "Los dos kubeconfig apuntan al MISMO clúster ($src_api). Revisa KUBECONFIG_SRC/KUBECONFIG_DST."

  printf '%s\n' "$src_api" > "$RUN/src-api.txt"
  printf '%s\n' "$dst_api" > "$RUN/dst-api.txt"
  ok "Dos clústeres distintos, ambos alcanzables"
}

check_permissions() {
  step "Permisos en el clúster destino"
  local v missing=false
  while read -r verb res; do
    [[ -z "$verb" ]] && continue
    if [[ "$(oc_dst auth can-i "$verb" "$res" 2>/dev/null)" == "yes" ]]; then
      vlog "can-i $verb $res: yes"
    else
      err "Sin permiso para '$verb $res' en el destino"
      missing=true
    fi
  done <<'PERMS'
create namespaces
create serviceaccounts
create rolebindings
create clusterrolebindings
create secrets
create persistentvolumeclaims
create deployments
create routes
PERMS

  # Los bindings de SCC requieren poder tocar securitycontextconstraints o
  # crear clusterrolebindings hacia system:openshift:scc:*
  if [[ "$(oc_dst auth can-i use securitycontextconstraints 2>/dev/null)" != "yes" ]]; then
    vlog "No se puede 'use scc' directamente (normal si no eres cluster-admin)"
  fi

  if [[ "$missing" == true ]]; then
    die "Faltan permisos en el destino. Se necesita cluster-admin o equivalente para SCC y ClusterRoleBindings."
  fi
  ok "Permisos suficientes en el destino"
}

check_namespaces() {
  step "Namespaces origen y destino"
  local s d
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    if oc_src get namespace "$s" >/dev/null 2>&1; then
      ok "ORIGEN  $s existe"
    else
      err "ORIGEN  $s NO existe"
    fi
    if oc_dst get namespace "$d" >/dev/null 2>&1; then
      if [[ "${FORCE:-false}" == true ]]; then
        warn "DESTINO $d ya existe (se reutilizará por --force)"
      else
        err "DESTINO $d ya existe. Usa --force para reutilizarlo, o 'rollback --confirm' para borrarlo."
      fi
    else
      ok "DESTINO $d libre"
    fi
  done
  (( FAIL_COUNT == 0 )) || die "Revisa los namespaces antes de continuar."
}

check_storage_classes() {
  step "StorageClasses"
  local s used sc mapped
  used=$(for s in $(src_namespaces); do
           oc_src -n "$s" get pvc -o json 2>/dev/null \
             | jq -r '.items[]?.spec.storageClassName // empty'
         done | sort -u)

  if [[ -z "$used" ]]; then
    log "Ningún PVC declara storageClassName (se usará la clase por defecto del destino)"
  fi

  local default_dst
  default_dst=$(oc_dst get storageclass -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name' | head -1)
  log "StorageClass por defecto en destino: ${default_dst:-<ninguna>}"

  while read -r sc; do
    [[ -z "$sc" ]] && continue
    mapped="$(sc_dst "$sc")"
    if oc_dst get storageclass "$mapped" >/dev/null 2>&1; then
      ok "StorageClass '$sc' -> '$mapped' disponible en destino"
    else
      err "StorageClass '$mapped' (origen '$sc') NO existe en destino. Añádela a STORAGE_CLASS_MAP en sanba-dr.env."
    fi
  done <<< "$used"
  (( FAIL_COUNT == 0 )) || die "Resuelve el mapeo de StorageClasses antes de continuar."
}

check_quotas() {
  step "Cuotas del clúster destino"
  local s d q
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    oc_dst get namespace "$d" >/dev/null 2>&1 || continue
    q=$(oc_dst -n "$d" get resourcequota -o json 2>/dev/null | jq -r '.items | length')
    [[ "${q:-0}" -gt 0 ]] && warn "$d ya tiene $q ResourceQuota; verifica que la app quepa"
  done
  ok "Revisión de cuotas terminada"
}


# ---------------------------------------------------------------------------
# Descubrimiento: todo lo que el script necesita se lee del clúster de
# PRODUCCIÓN en vez de estar incrustado en el código. El resultado queda en
# out/<run>/discovered.env para que puedas revisarlo o reutilizarlo.
# ---------------------------------------------------------------------------
discover_parameters() {
  step "Parámetros descubiertos en el clúster de PRODUCCIÓN"
  local out="$RUN/discovered.env"
  : > "$out"
  {
    echo "# Generado por preflight el $(date -Is). Solo informativo."
    echo "SRC_API=\"$(cat "$RUN/src-api.txt" 2>/dev/null)\""
    echo "DST_API=\"$(cat "$RUN/dst-api.txt" 2>/dev/null)\""
  } >> "$out"

  # Pod y credenciales de PostgreSQL
  local db_pod db_img db_sel
  db_pod=$(db_find_pod oc_src "$DB_NS")
  if [[ -n "$db_pod" ]]; then
    db_img=$(oc_src -n "$DB_NS" get pod "$db_pod" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
    db_sel=$(oc_src -n "$DB_NS" get pod "$db_pod" -o json 2>/dev/null \
             | jq -r '(.metadata.labels // {}) | to_entries
                      | map(select(.key | test("^(name|app|deployment|deploymentconfig)$")))
                      | map(.key + "=" + .value) | first // ""')
    log "  PostgreSQL  pod=$db_pod"
    log "              imagen=$db_img"
    log "              selector sugerido=${db_sel:-<ninguno, se autodescubre por imagen>}"
    {
      echo "DB_POD_DETECTED=\"$db_pod\""
      echo "DB_IMAGE_DETECTED=\"$db_img\""
      echo "DB_SELECTOR_SUGGESTED=\"$db_sel\""
    } >> "$out"
    [[ -z "${DB_SELECTOR:-}" && -n "$db_sel" ]] \
      && log "              (DB_SELECTOR está vacío; el script usará la autodetección por imagen)"
  else
    warn "No se encontró un pod de PostgreSQL Running en $DB_NS"
    todo "Revisa DB_NS/DB_SELECTOR: no se localizó el pod de PostgreSQL en producción."
  fi

  # Registries en uso
  local regs
  regs=$(for ns in $(src_namespaces); do
           oc_src -n "$ns" get deployment,deploymentconfig,statefulset,daemonset -o json 2>/dev/null \
             | jq -r '.items[]?.spec.template.spec.containers[]?.image // empty'
         done | awk -F/ '{print (NF>1 && $1 ~ /[.:]/) ? $1 : "docker.io"}' | sort -u)
  if [[ -n "$regs" ]]; then
    log "  Registries en uso:"
    printf '                %s\n' $regs >&2
    printf 'REGISTRIES_DETECTED="%s"\n' "$(tr '\n' ' ' <<< "$regs")" >> "$out"
  fi

  # Dominios
  [[ -r "$RUN/domain-src.txt" ]] && echo "APPS_DOMAIN_SRC=\"$(cat "$RUN/domain-src.txt")\"" >> "$out"
  [[ -r "$RUN/domain-dst.txt" ]] && echo "APPS_DOMAIN_DST=\"$(cat "$RUN/domain-dst.txt")\"" >> "$out"

  ok "Parámetros en $out"
}

cmd_preflight() {
  phase_steps 10
  check_dependencies
  check_oc_version
  check_logins
  check_permissions
  check_namespaces
  check_storage_classes
  check_quotas
  export_domains
  discover_parameters

  step "Resumen del preflight"
  if (( FAIL_COUNT > 0 )); then
    die "$FAIL_COUNT comprobaciones fallaron."
  fi
  ok "Preflight superado ($WARN_COUNT avisos)"
}
