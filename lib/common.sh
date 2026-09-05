#!/usr/bin/env bash
# lib/common.sh — logging, wrappers de oc y helpers compartidos.
# Probado en RHEL 9 (bash 5.1, jq 1.6, coreutils/gawk/sed de los repos base).
# shellcheck shell=bash

[[ -n "${_SANBA_COMMON_LOADED:-}" ]] && return 0
_SANBA_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Salida: bitácora de operación
#
#   HH:MM:SS  NIVEL  mensaje
#
# Tres planos de información, para que la corrida se lea igual en la consola
# que en migrate.log:
#   FASE  — un pase completo del plan de DR (preflight, export, apply...).
#   PASO  — una tarea dentro de la fase; se numera y se cierra con su estado.
#   línea — el detalle (INFO/OK/WARN/FAIL) que produce cada paso.
#
# El color se decide con SANBA_TTY, no con [[ -t 2 ]]: el script redirige
# stderr a un 'tee' antes de cargar esta librería, así que en ese punto stderr
# ya no es un terminal. migrate.log se escribe sin secuencias ANSI.
# ---------------------------------------------------------------------------
if [[ "${SANBA_TTY:-$( [[ -t 2 ]] && echo true || echo false )}" == true ]]; then
  C_RST=$'\e[0m';    C_RED=$'\e[1;31m'; C_YEL=$'\e[1;33m'
  C_GRN=$'\e[1;32m'; C_BLU=$'\e[1;34m'; C_DIM=$'\e[2m'
  C_CYA=$'\e[1;36m'; C_BLD=$'\e[1m'
else
  C_RST=''; C_RED=''; C_YEL=''; C_GRN=''; C_BLU=''; C_DIM=''; C_CYA=''; C_BLD=''
fi

WARN_COUNT=0
FAIL_COUNT=0

# --- estado de la fase y del paso en curso ---------------------------------
PHASE_TOTAL="${PHASE_TOTAL:-0}"   # fases planificadas en esta ejecución
PHASE_INDEX=0                     # fase en curso
PHASE_ID=""                       # etiqueta corta (EXPORT, APPLY...)
PHASE_START=0
PHASE_STEPS=0                     # pasos previstos en la fase (0 = desconocido)
PHASE_OK=0; PHASE_WARN=0; PHASE_FAIL=0
STEP_INDEX=0
STEP_NAME=""
STEP_START=0
STEP_OK=0; STEP_WARN=0; STEP_FAIL=0
PHASE_SUMMARY=()                  # "id|estado|pasos|ok|warn|fail|segundos"

_ts()   { date +'%H:%M:%S'; }
_now()  { date +'%Y-%m-%d %H:%M:%S'; }
_dur()  { printf '%02d:%02d' $(( ${1:-0} / 60 )) $(( ${1:-0} % 60 )); }
# tr no es multibyte: la regla se construye concatenando.
_rule() { local ch="${1:--}" n="${2:-78}" s=''; while (( ${#s} < n )); do s+="$ch"; done; printf '%s' "$s"; }

# _emit <color> <nivel> <mensaje...>
_emit() {
  local color="$1" level="$2"; shift 2
  printf '%s%s%s  %s%-4s%s  %s\n' \
    "$C_DIM" "$(_ts)" "$C_RST" "$color" "$level" "$C_RST" "$*" >&2
}

log()  { _emit "$C_BLU" "INFO" "$*"; }
vlog() { [[ "${VERBOSE:-false}" == true ]] && _emit "$C_DIM" "DBG" "$*"; return 0; }
ok()   { _emit "$C_GRN" "OK"   "$*"; STEP_OK=$((STEP_OK+1));     PHASE_OK=$((PHASE_OK+1)); }
warn() { _emit "$C_YEL" "WARN" "$*"; STEP_WARN=$((STEP_WARN+1)); PHASE_WARN=$((PHASE_WARN+1)); WARN_COUNT=$((WARN_COUNT+1)); }
err()  { _emit "$C_RED" "FAIL" "$*"; STEP_FAIL=$((STEP_FAIL+1)); PHASE_FAIL=$((PHASE_FAIL+1)); FAIL_COUNT=$((FAIL_COUNT+1)); }

# Aborta con un mensaje propio. Marca _SANBA_DIED para que el trap de ERR no
# añada encima una traza de "comando fallido": el motivo ya se ha explicado.
die() {
  _SANBA_DIED=1
  STEP_FAIL=$((STEP_FAIL+1)); PHASE_FAIL=$((PHASE_FAIL+1)); FAIL_COUNT=$((FAIL_COUNT+1))
  _step_close ABORTADO
  printf '\n%s%s ABORTADA%s  %s\n\n' "$C_RED" "${PHASE_ID:-EJECUCIÓN}" "$C_RST" "$*" >&2
  exit 1
}

# --- pasos ------------------------------------------------------------------
_step_label() {
  if (( PHASE_STEPS > 0 )); then printf '%d/%d' "$STEP_INDEX" "$PHASE_STEPS"
  else printf '%d' "$STEP_INDEX"; fi
}

# Cierra el paso en curso imprimiendo su estado y cuánto tardó.
_step_close() {
  [[ -z "$STEP_NAME" ]] && return 0
  local forced="${1:-}" estado color d=$(( SECONDS - STEP_START ))
  if   [[ -n "$forced"       ]]; then estado="$forced";   color="$C_RED"
  elif (( STEP_FAIL > 0 ));     then estado="CON FALLOS"; color="$C_RED"
  elif (( STEP_WARN > 0 ));     then estado="CON AVISOS"; color="$C_YEL"
  else                               estado="OK";         color="$C_GRN"
  fi
  printf '%s          · paso %s%s %s%s%s  %s(%s OK · %s avisos · %s fallos · %ss)%s\n' \
    "$C_DIM" "$(_step_label)" "$C_RST" "$color" "$estado" "$C_RST" \
    "$C_DIM" "$STEP_OK" "$STEP_WARN" "$STEP_FAIL" "$d" "$C_RST" >&2
  STEP_NAME=""
}

# step <descripción> — abre una tarea nueva y cierra la anterior.
step() {
  _step_close
  STEP_INDEX=$((STEP_INDEX+1)); STEP_NAME="$*"; STEP_START=$SECONDS
  STEP_OK=0; STEP_WARN=0; STEP_FAIL=0
  printf '\n%s%s%s  %sPASO%s  %s%-7s %s%s\n' \
    "$C_DIM" "$(_ts)" "$C_RST" "$C_CYA" "$C_RST" \
    "$C_BLD" "$(_step_label)" "$*" "$C_RST" >&2
}

# Número de pasos previstos en la fase; permite mostrar "paso 3/9".
phase_steps() { PHASE_STEPS="${1:-0}"; }

# --- fases ------------------------------------------------------------------
# phase_begin <ID> <título> [pasos]
phase_begin() {
  PHASE_INDEX=$((PHASE_INDEX+1))
  PHASE_ID="$1"; PHASE_START=$SECONDS
  PHASE_STEPS="${3:-0}"; STEP_INDEX=0; STEP_NAME=""
  PHASE_OK=0; PHASE_WARN=0; PHASE_FAIL=0
  local prog="" modo="escritura en el clúster destino"
  (( PHASE_TOTAL > 0 && PHASE_INDEX <= PHASE_TOTAL )) && prog=" ${PHASE_INDEX}/${PHASE_TOTAL}"
  [[ "${DRY_RUN:-false}" == true ]] && modo="simulación (--dry-run): no se escribe nada"
  {
    printf '\n%s%s%s\n' "$C_CYA" "$(_rule '=')" "$C_RST"
    printf ' %sFASE%s  %s%s%s — %s\n' "$C_CYA$C_BLD" "$prog" "$C_BLD" "$1" "$C_RST" "$2"
    printf ' %sinicio %s · corrida %s · modo %s%s\n' \
      "$C_DIM" "$(_now)" "${RUN_ID:-?}" "$modo" "$C_RST"
    printf '%s%s%s\n' "$C_CYA" "$(_rule '=')" "$C_RST"
  } >&2
}

# phase_end [rc] — cierra el paso en curso y resume la fase.
phase_end() {
  local rc="${1:-0}" estado color d=$(( SECONDS - PHASE_START ))
  _step_close
  if   (( rc != 0 ));        then estado="FALLIDA";    color="$C_RED"
  elif (( PHASE_FAIL > 0 )); then estado="CON FALLOS"; color="$C_RED"
  elif (( PHASE_WARN > 0 )); then estado="CON AVISOS"; color="$C_YEL"
  else                            estado="COMPLETADA"; color="$C_GRN"
  fi
  PHASE_SUMMARY+=("${PHASE_ID}|${estado}|${STEP_INDEX}|${PHASE_OK}|${PHASE_WARN}|${PHASE_FAIL}|${d}")
  [[ -n "${PHASE_FILE:-}" ]] \
    && printf '%s|%s|%s|%s|%s|%s|%s\n' "$PHASE_ID" "$estado" "$STEP_INDEX" \
         "$PHASE_OK" "$PHASE_WARN" "$PHASE_FAIL" "$d" >> "$PHASE_FILE"
  {
    printf '%s%s%s\n' "$C_DIM" "$(_rule '-')" "$C_RST"
    printf ' %sFASE %s%s  %s%s%s  ·  %s pasos · %s OK · %s avisos · %s fallos · %s\n' \
      "$C_BLD" "$PHASE_ID" "$C_RST" "$color" "$estado" "$C_RST" \
      "$STEP_INDEX" "$PHASE_OK" "$PHASE_WARN" "$PHASE_FAIL" "$(_dur "$d")"
    printf '%s%s%s\n' "$C_DIM" "$(_rule '-')" "$C_RST"
  } >&2
  return 0
}

# run_phase <ID> <título> <función> — envoltorio de un pase completo.
# La propia función declara cuántos pasos tiene con phase_steps.
run_phase() {
  local id="$1" title="$2" fn="$3" rc=0
  phase_begin "$id" "$title"
  "$fn" || rc=$?
  phase_end "$rc"
  return "$rc"
}

# Recuadro informativo que no es una fase: hitos, puntos de control, avisos
# que el operador debe leer antes de seguir.
banner() {
  {
    printf '\n%s%s%s\n' "$C_YEL" "$(_rule '=')" "$C_RST"
    printf ' %s%s%s\n' "$C_BLD" "$1" "$C_RST"
    [[ -n "${2:-}" ]] && printf ' %s%s%s\n' "$C_DIM" "$2" "$C_RST"
    printf '%s%s%s\n' "$C_YEL" "$(_rule '=')" "$C_RST"
  } >&2
}

# Cuadro final con el estado de cada fase de la ejecución.
run_summary() {
  local -a filas=()
  if [[ -n "${PHASE_FILE:-}" && -s "${PHASE_FILE:-/nonexistent}" ]]; then
    mapfile -t filas < "$PHASE_FILE"
  else
    filas=("${PHASE_SUMMARY[@]:-}")
  fi
  [[ ${#filas[@]} -eq 0 || -z "${filas[0]}" ]] && return 0
  local e id st n o w f d
  {
    printf '\n%s%s%s\n' "$C_CYA" "$(_rule '=')" "$C_RST"
    printf ' %sRESUMEN DE LA EJECUCIÓN · corrida %s%s\n' "$C_BLD" "${RUN_ID:-?}" "$C_RST"
    printf '%s%s%s\n' "$C_CYA" "$(_rule '=')" "$C_RST"
    printf ' %-12s %-12s %6s %5s %7s %7s %8s\n' FASE ESTADO PASOS OK AVISOS FALLOS TIEMPO
    for e in "${filas[@]}"; do
      IFS='|' read -r id st n o w f d <<< "$e"
      printf ' %-12s %-12s %6s %5s %7s %7s %8s\n' "$id" "$st" "$n" "$o" "$w" "$f" "$(_dur "$d")"
    done
    printf '%s%s%s\n' "$C_DIM" "$(_rule '-')" "$C_RST"
    printf ' Bitácora: %s\n' "${RUN:-.}/migrate.log"
    printf ' Informes: %s\n' "${REPORTS:-.}"
    printf '%s%s%s\n\n' "$C_CYA" "$(_rule '=')" "$C_RST"
  } >&2
}

# Enmascara credenciales en cualquier texto que vaya al log.
mask() {
  sed -E 's/((PASSWORD|PASSWD|TOKEN|SECRET|PGPASSWORD)[^ ]{0,12}[=:[:space:]]+)[^[:space:]"'"'"']+/\1********/Ig'
}

# ===========================================================================
#  Wrappers de oc — la protección más importante del script
#
#  Sobre el clúster ORIGEN (producción) solo se permiten verbos de lectura y
#  la extracción de datos. Cualquier verbo que modifique o borre recursos
#  aborta la ejecución antes de llamar a oc.
#
#  Verbos permitidos, todos documentados por Red Hat en
#  "OpenShift CLI (oc)" (CLI tools, OCP 4.18):
#    get, describe, logs, version, whoami, auth, api-resources, explain,
#    project(s), status, exec, rsh, rsync, cp
# ===========================================================================
_OC_SRC_VERBS=" get describe exec rsh rsync cp logs version whoami auth api-resources api-versions explain project projects status registry "

# Devuelve los argumentos posicionales de una línea de oc (verbo y operandos),
# saltando las opciones globales y sus valores. Hace falta porque el verbo no
# siempre es $1: 'oc -n ns get pvc' es tan válido como 'oc get pvc -n ns'.
_oc_positional() {
  local a skip=false
  for a in "$@"; do
    if [[ "$skip" == true ]]; then skip=false; continue; fi
    case "$a" in
      -n|--namespace|--context|--kubeconfig|--as|--as-group|--token|--server|--user|\
      --cluster|--request-timeout|--cache-dir|--certificate-authority|--client-key|\
      --client-certificate|-v|--v|--log-flush-frequency|-c|--container|--strategy)
        skip=true ;;
      -*) ;;                       # opción booleana o --clave=valor
      *) printf '%s\n' "$a" ;;
    esac
  done
}

oc_src() {
  local positional verb
  mapfile -t positional < <(_oc_positional "$@")
  verb="${positional[0]:-}"
  [[ -n "$verb" ]] || die "oc_src llamado sin verbo: oc $*"
  [[ "$_OC_SRC_VERBS" == *" $verb "* ]] \
    || die "BLOQUEADO: 'oc $verb' no está permitido sobre el clúster ORIGEN (producción)."

  # 'oc cp' y 'oc rsync' solo se admiten en dirección pod -> local (descargar).
  if [[ "$verb" == cp || "$verb" == rsync ]]; then
    local from="${positional[1]:-}" to="${positional[2]:-}"
    [[ "$from" == *:* && "$to" != *:* ]] \
      || die "BLOQUEADO: 'oc $verb' escribiría en el clúster ORIGEN. Solo se permite descargar (pod:ruta -> local)."
  fi

  KUBECONFIG="$KUBECONFIG_SRC" command oc "$@"
}

# Destino (pre-producción): lectura y escritura sin restricción.
oc_dst() { KUBECONFIG="$KUBECONFIG_DST" command oc "$@"; }

# Escritura en destino respetando --dry-run.
oc_dstw() {
  if [[ "${DRY_RUN:-false}" == true ]]; then
    log "${C_DIM}(dry-run) oc $*${C_RST}"
    return 0
  fi
  oc_dst "$@"
}

# ===========================================================================
#  Namespaces — todo se deriva de NS_ORDER + DR_SUFFIX, o de NS_MAP si se
#  define explícitamente. Nada de nombres incrustados en el código.
# ===========================================================================
ns_dst() {
  local src="$1" line
  if [[ -n "${NS_MAP:-}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line// }" ]] && continue
      if [[ "${line%%:*}" == "$src" ]]; then printf '%s\n' "${line#*:}"; return 0; fi
    done <<< "$NS_MAP"
  fi
  printf '%s\n' "${src}${DR_SUFFIX}"
}

src_namespaces() { printf '%s\n' $NS_ORDER; }

# ¿'$1' es uno de los namespaces que se están migrando (nombre de PRODUCCIÓN)?
is_src_ns() { local n="$1" s; for s in $NS_ORDER; do [[ "$s" == "$n" ]] && return 0; done; return 1; }

# ¿'$1' es el namespace de contingencia de alguno de ellos?
is_dst_ns() { local n="$1" s; for s in $NS_ORDER; do [[ "$(ns_dst "$s")" == "$n" ]] && return 0; done; return 1; }

# Cadena de gsub (jq / Oniguruma) que reescribe los nombres de namespace dentro
# de textos: ConfigMaps, Secrets, env vars y URLs internas.
#
# El patrón exige que el nombre sea una etiqueta DNS completa:
#   sanba-core.svc          -> sanba-core-dr.svc        (se reescribe)
#   sanba-core-legacy-app   -> sanba-core-legacy-app    (NO se toca)
#   sanba-core-dr           -> sanba-core-dr            (idempotente)
#
# Y NUNCA toca la etiqueta de SERVICIO de un FQDN de Kubernetes. En
# <servicio>.<namespace>.svc el namespace es la etiqueta que precede a .svc; el
# servicio conserva su nombre porque este script no renombra objetos:
#
#   postgresql.sanba-data-persistence.svc -> postgresql.sanba-data-persistence-dr.svc
#   sanba-core.sanba-core.svc             -> sanba-core.sanba-core-dr.svc
#                                            ^^^^^^^^^^ el Service se sigue
#                                            llamando 'sanba-core' en el
#                                            namespace de contingencia
#
# Sin esa exclusión, un Service cuyo nombre coincide con el de su namespace
# (lo habitual) acababa como sanba-core-dr.sanba-core-dr.svc: un nombre DNS que
# no resuelve, y el componente se queda sin backend en el drill.
_NS_SVC_GUARD='(?!\\.[\\w-]+\\.svc)'

ns_jq_gsub() {
  local s d suf prog='.' g="$_NS_SVC_GUARD"
  for s in $NS_ORDER; do
    d="$(ns_dst "$s")"
    if [[ "$d" == "$s"* ]]; then
      suf="${d#"$s"}"
      prog+=" | gsub(\"(?<![\\\\w-])${s}(${suf})?(?![\\\\w-])${g}\"; \"${d}\")"
    else
      prog+=" | gsub(\"(?<![\\\\w-])${s}(?![\\\\w-])${g}\"; \"${d}\")"
    fi
  done
  printf '%s' "$prog"
}

# Regex (ERE) que detecta si un texto menciona alguno de los namespaces.
ns_match_regex() {
  local s out=''
  for s in $NS_ORDER; do out+="${out:+|}${s}"; done
  printf '%s' "($out)"
}

# ---------------------------------------------------------------------------
# StorageClass
# ---------------------------------------------------------------------------
sc_dst() {
  local src="$1" pair
  for pair in ${STORAGE_CLASS_MAP:-}; do
    [[ "${pair%%:*}" == "$src" ]] && { printf '%s\n' "${pair#*:}"; return 0; }
  done
  printf '%s\n' "$src"
}

# ===========================================================================
#  Formato de los manifiestos
#
#  yq NO está en los repositorios base de RHEL 9. Si está instalado se generan
#  manifiestos YAML (más cómodos de revisar); si no, JSON, que 'oc apply -f'
#  acepta igual. La decisión se toma UNA vez, no por archivo.
# ===========================================================================
detect_manifest_format() {
  if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q 'mikefarah'; then
    MANIFEST_EXT="yaml"; HAVE_YQ=true
  else
    MANIFEST_EXT="json"; HAVE_YQ=false
  fi
  export MANIFEST_EXT HAVE_YQ
}

# Convierte JSON de stdin al formato elegido.
to_manifest() {
  if [[ "${HAVE_YQ:-false}" == true ]]; then yq -P -o=yaml '.'; else jq '.'; fi
}

# Lee un manifiesto ya generado y lo devuelve como JSON. Decide por extensión,
# no por la presencia de yq, para que una corrida antigua siga siendo legible.
read_manifest() {
  case "$1" in
    *.json) cat "$1" ;;
    *)      yq -o=json '.' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Caché de manifiestos limpios por namespace
#
# clean_items se llamaba dentro de bucles por ServiceAccount y por ConfigMap,
# reparseando todos los YAML del namespace en cada vuelta. Ahora se construye
# un único JSON por namespace y las consultas leen de ahí.
# ---------------------------------------------------------------------------
clean_cache() {
  local d="$1"
  local cache="$RUN/.cache-clean-$d.json"
  local f
  if [[ ! -s "$cache" ]]; then
    for f in "$CLEAN/$d"/[0-9]*-*.yaml "$CLEAN/$d"/[0-9]*-*.json; do
      [[ -r "$f" ]] || continue
      read_manifest "$f"
    done | jq -s '[.[].items[]?]' > "$cache"
  fi
  printf '%s' "$cache"
}

clean_items() {
  local d="$1" kind="${2:-}"
  if [[ -z "$kind" ]]; then
    cat "$(clean_cache "$d")"
  else
    jq --arg k "$kind" '[.[] | select((.kind | ascii_downcase) == ($k | ascii_downcase))]' "$(clean_cache "$d")"
  fi
}

clean_cache_reset() { rm -f "$RUN"/.cache-clean-*.json; }

# Ruta de un manifiesto limpio, sea .yaml o .json
clean_file() {
  local d="$1" base="$2" f
  for f in "$CLEAN/$d/$base".yaml "$CLEAN/$d/$base".json; do
    [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# Utilidades varias
# ---------------------------------------------------------------------------
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Falta el comando requerido: $c"
  done
}

kind_file() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

# Prefijo numérico que fija el orden de aplicación dentro de un namespace.
kind_order() {
  case "$(tr '[:upper:]' '[:lower:]' <<< "$1")" in
    serviceaccount)             echo 10 ;;
    role)                       echo 12 ;;
    rolebinding)                echo 14 ;;
    secret)                     echo 20 ;;
    configmap)                  echo 25 ;;
    persistentvolumeclaim)      echo 30 ;;
    service)                    echo 40 ;;
    deployment|deploymentconfig|statefulset) echo 50 ;;
    daemonset)                  echo 52 ;;
    cronjob)                    echo 55 ;;
    route)                      echo 60 ;;
    networkpolicy)              echo 70 ;;
    horizontalpodautoscaler)    echo 72 ;;
    poddisruptionbudget)        echo 74 ;;
    *)                          echo 90 ;;
  esac
}

# report <nombre-reporte> <texto...>
report() { local f="$1"; shift; printf '%s\n' "$*" >> "$REPORTS/${f}.txt"; }

# Añade una entrada a manual-todo.txt
todo() { printf '  - %s\n' "$*" >> "$REPORTS/manual-todo.txt"; }
