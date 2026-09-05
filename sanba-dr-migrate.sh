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
WITH_DB=false
RELOAD_DB=false
ONLY_NS=""
RUN_ID=""
CMD=""

usage() {
  cat <<'USAGE'
sanba-dr-migrate.sh — migración DR de SANBA (OpenShift 4.18)

Es el motor. Para operar el drill con menú y autenticación guiada:  ./sanba-dr.sh

SUBCOMANDOS
  preflight    Valida versiones de oc, sesiones, permisos, namespaces y StorageClasses.
  export       Extrae los recursos del clúster ORIGEN a out/<run>/raw  (solo lectura).
  transform    Sanea, renombra namespaces, reescribe Routes y sustituye las URLs
               de ConfigMaps, Secrets, env, args y command -> out/<run>/clean.
  apply        Aplica los manifiestos en el clúster DESTINO en orden de dependencias.
               NO carga datos: la base de datos es una fase aparte (db-migrate).
  mirror       Copia con skopeo, POR DIGEST, las imágenes del registry interno de
               producción al de pre-producción, y verifica que el digest coincide.
  db-migrate   pg_dump en PROD -> pg_restore en DR, con comparación de filas.
               Si la base de datos de contingencia ya tiene datos, pregunta si
               recargarla (o pásale --reload-db para no preguntar).
  restart      Reinicia los workloads que arrancaron antes de cargar los datos.
               No toca el namespace de la base de datos.
  validate     Comprueba rollouts, pods, PVCs, URLs, BD, ServiceAccounts y config.
  all          Flujo completo, en este orden:
               preflight -> export -> transform -> apply -> db-migrate -> restart -> validate
  rollback     ÚNICO subcomando que borra algo. Elimina los namespaces de
               contingencia y sus ClusterRoleBindings en PRE-PRODUCCIÓN, para
               poder repetir el drill. Nunca toca producción. Exige --confirm.
  report       Muestra dónde están los informes de una corrida.

INFORMES CLAVE
  reports/manual-todo.txt   lo que hay que resolver a mano
  reports/urls.txt          qué URL tiene cada componente y cuáles quedan sin resolver
  reports/validation.txt    resultado de la validación end-to-end

OPCIONES
  --run <ID>        Reutiliza una corrida anterior (por defecto: la última).
  --only <ns>       Limita la operación a un namespace ORIGEN.
  --dry-run         No escribe en el clúster destino; solo muestra lo que haría.
  --force           Permite reutilizar namespaces -dr ya existentes.
  --no-db           Omite las fases de datos (db-migrate y restart) en 'all'.
  --with-db         'apply' encadena la carga de datos, como antes de separarlas.
  --reload-db       Autoriza a RECARGAR la base de datos de contingencia aunque
                    ya tenga datos: pg_restore --clean --if-exists. Solo afecta a
                    pre-producción; en producción nunca se escribe.
  --confirm         Requerido por 'rollback'.
  -v, --verbose     Más detalle.
  -h, --help        Esta ayuda.

EJEMPLO  (el orden importa)
  export KUBECONFIG_SRC=~/.kube/config-prod
  export KUBECONFIG_DST=~/.kube/config-preprod
  ./sanba-dr-migrate.sh preflight
  ./sanba-dr-migrate.sh export
  ./sanba-dr-migrate.sh transform
  # revisar out/<run>/reports/ antes de continuar
  ./sanba-dr-migrate.sh mirror       # si hay imágenes del registry interno
  ./sanba-dr-migrate.sh apply        # despliega, sin datos
  ./sanba-dr-migrate.sh db-migrate   # carga los datos
  ./sanba-dr-migrate.sh restart      # reinicia lo que arrancó contra la base vacía
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
    --with-db)  WITH_DB=true; shift ;;
    --reload-db) RELOAD_DB=true; shift ;;
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

# --- ayuda: nunca depende de que exista una corrida -------------------------
case "$CMD" in -h|--help|help) usage; exit 0 ;; esac

# --- directorio de la corrida ----------------------------------------------
# El 'grep' no encuentra nada cuando out/ está vacío y, con 'pipefail', ese 1
# hacía fallar la asignación y morir al script sin imprimir una sola línea: el
# trap de ERR todavía no está instalado a esta altura. Por eso el '|| true'.
latest_run() {
  ls -1 "$ROOT/out" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -1 || true
}

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

# Resumen de fases: en fichero, porque 'apply' encadena 'db-migrate' dentro de
# una subshell y un array de bash no sobreviviría a eso.
PHASE_FILE="$RUN/.phases"
: > "$PHASE_FILE"

# Si stderr es un terminal se decide AQUÍ, antes de redirigirlo: a partir de la
# línea siguiente stderr es una tubería y [[ -t 2 ]] siempre diría que no.
if [[ -t 2 ]]; then SANBA_TTY=true; else SANBA_TTY=false; fi
export SANBA_TTY

# Todo el log (que va a stderr) queda también en el archivo de la corrida, sin
# secuencias de color: migrate.log se lee y se grepea en limpio.
exec 2> >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$RUN/migrate.log") >&2)

# --- librerías --------------------------------------------------------------
# shellcheck source=lib/common.sh
for f in common preflight export transform images apply database validate; do
  source "$ROOT/lib/$f.sh"
done

# Decide una sola vez si los manifiestos se generan en YAML (yq presente) o en
# JSON (RHEL 9 sin yq). Todo el resto del script respeta $MANIFEST_EXT.
detect_manifest_format

trap 'rc=$?; if [[ $rc -ne 0 && -z "${_SANBA_DIED:-}" ]]; then
        printf "\n%s comando fallido (rc=%s) en %s:%s\n" \
          "${C_RED:-}ERROR${C_RST:-}" "$rc" "${BASH_SOURCE[0]}" "$LINENO" >&2
      fi; exit $rc' ERR

# =============================================================================
#  rollback
# =============================================================================
cmd_rollback() {
  require_cmd oc jq
  phase_steps 3
  step "Comprobando que ORIGEN y DESTINO son clústeres distintos"

  local src_api dst_api
  src_api=$(oc_src whoami --show-server 2>/dev/null) || die "Sesión de ORIGEN inválida"
  dst_api=$(oc_dst whoami --show-server 2>/dev/null) || die "Sesión de DESTINO inválida"
  [[ "$src_api" != "$dst_api" ]] || die "ORIGEN y DESTINO son el mismo clúster. Abortando."

  step "Inventario de namespaces de contingencia a borrar"
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

  step "Borrado de namespaces y ClusterRoleBindings de contingencia"
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
  phase_steps 1
  step "Informes de la corrida $RUN_ID"
  local f
  for f in validation routes urls images serviceaccounts config ns-rewrites manual-todo; do
    [[ -r "$REPORTS/$f.txt" ]] && log "  $REPORTS/$f.txt"
  done
  [[ -r "$RUN/url-map.tsv" ]] && log "  $RUN/url-map.tsv"
  [[ -r "$RUN/mirror-commands.sh" ]] && log "  $RUN/mirror-commands.sh"
  [[ -r "$RUN/db/rowcounts.diff" ]] && log "  $RUN/db/rowcounts.diff"
  [[ -r "$RUN/migrate.log" ]] && log "  $RUN/migrate.log"
  return 0
}

cmd_all() {
  PHASE_TOTAL=7
  [[ "$DB_MIGRATE" != true || "${SKIP_DB:-false}" == true ]] && PHASE_TOTAL=5
  run_phase PREFLIGHT "$T_PREFLIGHT" cmd_preflight
  run_phase EXPORT    "$T_EXPORT"    cmd_export
  run_phase TRANSFORM "$T_TRANSFORM" cmd_transform

  # Punto de control: es la última oportunidad de parar antes de escribir en
  # pre-producción. No es una fase, es una puerta.
  if [[ -s "$REPORTS/manual-todo.txt" ]]; then
    banner "PUNTO DE CONTROL — $(wc -l < "$REPORTS/manual-todo.txt") pendientes antes de tocar pre-producción" \
           "$REPORTS/manual-todo.txt"
    cat "$REPORTS/manual-todo.txt" >&2
    if [[ "$FORCE" != true ]]; then
      die "Resuelve los puntos anteriores (o repite con --force para continuar de todos modos)."
    fi
    warn "Continuando pese a los pendientes por --force"
  fi

  run_phase APPLY "$T_APPLY" cmd_apply

  # La base de datos va DESPUÉS del despliegue y ANTES de la validación, con el
  # reinicio en medio: los workloads arrancaron contra una base vacía.
  if [[ "$DB_MIGRATE" == true && "${SKIP_DB:-false}" != true ]]; then
    run_phase DB-MIGRATE "$T_DBMIGRATE" cmd_db_migrate
    run_phase RESTART    "$T_RESTART"   cmd_restart
  else
    banner "FASES DE DATOS OMITIDAS" \
           "DB_MIGRATE=$DB_MIGRATE, --no-db=${SKIP_DB:-false}: la base de datos de contingencia queda como esté."
  fi

  run_phase VALIDATE "$T_VALIDATE" cmd_validate || return $?
}

# =============================================================================
# 'validate' y 'all' devuelven != 0 cuando alguna comprobación falla: eso no es
# un error del script, así que se propaga el código sin disparar el trap de ERR.
# Título de cada fase, compartido entre 'all' y la ejecución suelta.
T_PREFLIGHT="Validación previa: host, sesiones, permisos y almacenamiento"
T_EXPORT="Extracción del clúster ORIGEN (solo lectura)"
T_TRANSFORM="Saneo, renombrado de namespaces y reescritura de URLs"
T_APPLY="Despliegue en el clúster de contingencia"
T_MIRROR="Mirror de imágenes por digest"
T_DBMIGRATE="Carga de datos PostgreSQL de PROD a contingencia"
T_RESTART="Reinicio de los workloads que arrancaron sin datos"
T_VALIDATE="Validación end-to-end del entorno de contingencia"
T_ROLLBACK="Borrado del entorno de contingencia (solo pre-producción)"
T_REPORT="Informes de la corrida"

EXIT_RC=0
case "$CMD" in
  preflight)  PHASE_TOTAL=1; run_phase PREFLIGHT  "$T_PREFLIGHT"  cmd_preflight ;;
  export)     PHASE_TOTAL=1; run_phase EXPORT     "$T_EXPORT"     cmd_export ;;
  transform)  PHASE_TOTAL=1; run_phase TRANSFORM  "$T_TRANSFORM"  cmd_transform ;;
  apply)      PHASE_TOTAL=1; run_phase APPLY      "$T_APPLY"      cmd_apply ;;
  mirror)     PHASE_TOTAL=1; run_phase MIRROR     "$T_MIRROR"     cmd_mirror     || EXIT_RC=$? ;;
  db-migrate) PHASE_TOTAL=1; run_phase DB-MIGRATE "$T_DBMIGRATE"  cmd_db_migrate ;;
  restart)    PHASE_TOTAL=1; run_phase RESTART    "$T_RESTART"    cmd_restart ;;
  validate)   PHASE_TOTAL=1; run_phase VALIDATE   "$T_VALIDATE"   cmd_validate   || EXIT_RC=$? ;;
  all)        cmd_all || EXIT_RC=$? ;;
  rollback)   PHASE_TOTAL=1; run_phase ROLLBACK   "$T_ROLLBACK"   cmd_rollback ;;
  report)     PHASE_TOTAL=1; run_phase REPORT     "$T_REPORT"     cmd_report ;;
  *) echo "Subcomando desconocido: $CMD" >&2; usage; exit 1 ;;
esac

run_summary
exit "$EXIT_RC"
