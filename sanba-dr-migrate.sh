#!/usr/bin/env bash
# =============================================================================
#  sanba-dr-migrate.sh — Migración de SANBA a un clúster de contingencia (DR)
#
#  Migra los namespaces de OpenShift 4.18
#      location-resources  sanba-data-persistence  sanba-core  sanba-gui
#  hacia sus equivalentes con sufijo -dr en otro clúster, incluyendo
#  ServiceAccounts, SCC, ConfigMaps, Secrets, PVCs, Routes y los datos de
#  PostgreSQL, y valida que la aplicación responde.
#
#  Sobre el clúster ORIGEN (producción) solo se LEE y se extraen datos: el
#  wrapper oc_src rechaza cualquier verbo que modifique o borre recursos.
#  El único subcomando que borra algo es 'rollback', y solo en pre-producción.
#
#  Uso:  ./sanba-dr-migrate.sh <subcomando> [opciones]
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- valores por defecto de las opciones ------------------------------------
DRY_RUN=false
VERBOSE=false
FORCE=false
CONFIRM=false
SKIP_DB=false
ONLY_NS=""
RUN_ID=""
CMD=""

usage() {
  cat <<'USAGE'
sanba-dr-migrate.sh — migración DR de SANBA (OpenShift 4.18)

SUBCOMANDOS
  preflight    Valida versiones de oc, sesiones, permisos, namespaces y StorageClasses.
  export       Extrae los recursos del clúster ORIGEN a out/<run>/raw  (solo lectura).
  transform    Sanea, renombra namespaces y reescribe Routes -> out/<run>/clean.
  apply        Aplica los manifiestos en el clúster DESTINO en orden de dependencias.
               Encadena db-migrate justo después de levantar la base de datos.
  db-migrate   pg_dump en PROD -> pg_restore en DR, con comparación de filas.
  validate     Comprueba rollouts, pods, PVCs, URLs, BD, ServiceAccounts y config.
  all          preflight -> export -> transform -> apply -> validate.
  rollback     ÚNICO subcomando que borra algo. Elimina los namespaces de
               contingencia y sus ClusterRoleBindings en PRE-PRODUCCIÓN, para
               poder repetir el drill. Nunca toca producción. Exige --confirm.
  report       Muestra dónde están los informes de una corrida.

OPCIONES
  --run <ID>        Reutiliza una corrida anterior (por defecto: la última).
  --only <ns>       Limita la operación a un namespace ORIGEN.
  --dry-run         No escribe en el clúster destino; solo muestra lo que haría.
  --force           Permite reutilizar namespaces -dr ya existentes.
  --no-db           No encadena la migración de datos durante 'apply'.
  --confirm         Requerido por 'rollback'.
  -v, --verbose     Más detalle.
  -h, --help        Esta ayuda.

EJEMPLO
  export KUBECONFIG_SRC=~/.kube/config-prod
  export KUBECONFIG_DST=~/.kube/config-preprod
  ./sanba-dr-migrate.sh preflight
  ./sanba-dr-migrate.sh export && ./sanba-dr-migrate.sh transform
  # revisar out/<run>/reports/ antes de continuar
  ./sanba-dr-migrate.sh apply
  ./sanba-dr-migrate.sh validate
USAGE
}

# --- parseo de argumentos ---------------------------------------------------
[[ $# -gt 0 ]] || { usage; exit 1; }
CMD="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)      RUN_ID="${2:-}"; shift 2 ;;
    --only)     ONLY_NS="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --force)    FORCE=true; shift ;;
    --no-db)    SKIP_DB=true; shift ;;
    --confirm)  CONFIRM=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
  esac
done

# --- configuración ----------------------------------------------------------
[[ -r "$ROOT/sanba-dr.env" ]] || { echo "Falta $ROOT/sanba-dr.env" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ROOT/sanba-dr.env"

# --- directorio de la corrida ----------------------------------------------
latest_run() { ls -1 "$ROOT/out" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -1; }

case "$CMD" in
  preflight|export|all)
    RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}" ;;
  *)
    RUN_ID="${RUN_ID:-$(latest_run)}"
    [[ -n "$RUN_ID" ]] || { echo "No hay ninguna corrida en $ROOT/out. Ejecuta 'export' primero." >&2; exit 1; } ;;
esac

RUN="$ROOT/out/$RUN_ID"
RAW="$RUN/raw"
CLEAN="$RUN/clean"
REPORTS="$RUN/reports"
mkdir -p "$RUN" "$RAW" "$CLEAN" "$REPORTS"
touch "$REPORTS/manual-todo.txt"

# Todo el log (que va a stderr) queda también en el archivo de la corrida.
exec 2> >(tee -a "$RUN/migrate.log" >&2)

# --- librerías --------------------------------------------------------------
# shellcheck source=lib/common.sh
for f in common preflight export transform images apply database validate; do
  source "$ROOT/lib/$f.sh"
done

# Decide una sola vez si los manifiestos se generan en YAML (yq presente) o en
# JSON (RHEL 9 sin yq). Todo el resto del script respeta $MANIFEST_EXT.
detect_manifest_format

trap 'rc=$?; [[ $rc -ne 0 ]] && printf "\n%s comando fallido (rc=%s) en %s:%s\n" \
      "${C_RED:-}ERROR${C_RST:-}" "$rc" "${BASH_SOURCE[0]}" "$LINENO" >&2; exit $rc' ERR

# =============================================================================
#  rollback
# =============================================================================
cmd_rollback() {
  require_cmd oc jq
  step "Rollback del entorno de DR"

  local src_api dst_api
  src_api=$(oc_src whoami --show-server 2>/dev/null) || die "Sesión de ORIGEN inválida"
  dst_api=$(oc_dst whoami --show-server 2>/dev/null) || die "Sesión de DESTINO inválida"
  [[ "$src_api" != "$dst_api" ]] || die "ORIGEN y DESTINO son el mismo clúster. Abortando."

  local s d targets=()
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    # Guarda: solo se borran namespaces cuyo nombre termina con el sufijo de DR
    [[ "$d" == *"$DR_SUFFIX" ]] \
      || die "El namespace '$d' no termina en '$DR_SUFFIX'. Abortando por seguridad."
    oc_dst get namespace "$d" >/dev/null 2>&1 && targets+=("$d")
  done

  if [[ ${#targets[@]} -eq 0 ]]; then
    ok "No hay namespaces -dr que borrar en $dst_api"
    return 0
  fi

  log "Clúster destino (PRE-PRODUCCIÓN): $dst_api"
  log "Clúster de producción ($src_api): NO se toca."
  log "Se BORRARÁN estos namespaces de PRE-PRODUCCIÓN y todo su contenido:"
  printf '    %s\n' "${targets[@]}" >&2

  if [[ "$CONFIRM" != true ]]; then
    die "Añade --confirm para ejecutar el borrado."
  fi

  for d in "${targets[@]}"; do
    log "  borrando namespace $d"
    oc_dstw delete namespace "$d" --wait=false >/dev/null || warn "No se pudo borrar $d"
  done

  # ClusterRoleBindings que creó este script (siempre con el sufijo de DR)
  local crb
  for crb in "$CLEAN/_cluster/80-clusterrolebinding.yaml" "$CLEAN/_cluster/80-clusterrolebinding.json"; do
    [[ -r "$crb" ]] || continue
    while read -r name; do
      [[ -z "$name" ]] && continue
      [[ "$name" == *"$DR_SUFFIX" ]] || continue
      log "  borrando clusterrolebinding $name"
      oc_dstw delete clusterrolebinding "$name" --ignore-not-found >/dev/null || true
    done < <(read_manifest "$crb" | jq -r '.items[].metadata.name')
  done

  ok "Borrado lanzado. El terminado de los namespaces puede tardar unos minutos."
}

cmd_report() {
  step "Informes de la corrida $RUN_ID"
  local f
  for f in validation routes images serviceaccounts config ns-rewrites manual-todo; do
    [[ -r "$REPORTS/$f.txt" ]] && log "  $REPORTS/$f.txt"
  done
  [[ -r "$RUN/mirror-commands.sh" ]] && log "  $RUN/mirror-commands.sh"
  [[ -r "$RUN/db/rowcounts.diff" ]] && log "  $RUN/db/rowcounts.diff"
  [[ -r "$RUN/migrate.log" ]] && log "  $RUN/migrate.log"
  return 0
}

cmd_all() {
  cmd_preflight
  cmd_export
  cmd_transform

  if [[ -s "$REPORTS/manual-todo.txt" ]]; then
    step "Pendientes detectados antes de aplicar"
    cat "$REPORTS/manual-todo.txt" >&2
    if [[ "$FORCE" != true ]]; then
      die "Resuelve los puntos anteriores (o repite con --force para continuar de todos modos)."
    fi
    warn "Continuando pese a los pendientes por --force"
  fi

  cmd_apply
  cmd_validate || return $?
}

# =============================================================================
# 'validate' y 'all' devuelven != 0 cuando alguna comprobación falla: eso no es
# un error del script, así que se propaga el código sin disparar el trap de ERR.
EXIT_RC=0
case "$CMD" in
  preflight)  cmd_preflight ;;
  export)     cmd_export ;;
  transform)  cmd_transform ;;
  apply)      cmd_apply ;;
  db-migrate) cmd_db_migrate ;;
  validate)   cmd_validate  || EXIT_RC=$? ;;
  all)        cmd_all       || EXIT_RC=$? ;;
  rollback)   cmd_rollback ;;
  report)     cmd_report ;;
  -h|--help|help) usage ;;
  *) echo "Subcomando desconocido: $CMD" >&2; usage; exit 1 ;;
esac
exit "$EXIT_RC"
