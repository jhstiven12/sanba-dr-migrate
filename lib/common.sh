#!/usr/bin/env bash
# lib/common.sh — logging, wrappers de oc y helpers compartidos.
# Probado en RHEL 9 (bash 5.1, jq 1.6, coreutils/gawk/sed de los repos base).
# shellcheck shell=bash

[[ -n "${_SANBA_COMMON_LOADED:-}" ]] && return 0
_SANBA_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Colores y logging
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  C_RST=$'\e[0m'; C_RED=$'\e[1;31m'; C_YEL=$'\e[1;33m'
  C_GRN=$'\e[1;32m'; C_BLU=$'\e[1;34m'; C_DIM=$'\e[2m'
else
  C_RST=''; C_RED=''; C_YEL=''; C_GRN=''; C_BLU=''; C_DIM=''
fi

WARN_COUNT=0
FAIL_COUNT=0

_ts()  { date +'%H:%M:%S'; }
log()  { printf '%s %s\n'    "${C_DIM}[$(_ts)]${C_RST}" "$*" >&2; }
vlog() { [[ "${VERBOSE:-false}" == true ]] && printf '%s %s\n' "${C_DIM}[$(_ts)]   ·${C_RST}" "$*" >&2; return 0; }
step() { printf '\n%s %s\n'  "${C_BLU}==>${C_RST}"      "$*" >&2; }
ok()   { printf '  %s %s\n'  "${C_GRN}OK${C_RST}"       "$*" >&2; }
warn() { printf '  %s %s\n'  "${C_YEL}WARN${C_RST}"     "$*" >&2; WARN_COUNT=$((WARN_COUNT+1)); }
err()  { printf '  %s %s\n'  "${C_RED}FAIL${C_RST}"     "$*" >&2; FAIL_COUNT=$((FAIL_COUNT+1)); }
# Aborta con un mensaje propio. Marca _SANBA_DIED para que el trap de ERR no
# añada encima una traza de "comando fallido": el motivo ya se ha explicado.
die()  { _SANBA_DIED=1; printf '\n%s %s\n\n' "${C_RED}ABORTA:${C_RST}" "$*" >&2; exit 1; }

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
_OC_SRC_VERBS=" get describe exec rsh rsync cp logs version whoami auth api-resources api-versions explain project projects status "

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

# Cadena de gsub (jq / Oniguruma) que reescribe los nombres de namespace dentro
# de textos: ConfigMaps, Secrets, env vars y URLs internas.
#
# El patrón exige que el nombre sea una etiqueta DNS completa:
#   sanba-core.svc          -> sanba-core-dr.svc        (se reescribe)
#   sanba-core-legacy-app   -> sanba-core-legacy-app    (NO se toca)
#   sanba-core-dr           -> sanba-core-dr            (idempotente)
ns_jq_gsub() {
  local s d suf prog='.'
  for s in $NS_ORDER; do
    d="$(ns_dst "$s")"
    if [[ "$d" == "$s"* ]]; then
      suf="${d#"$s"}"
      prog+=" | gsub(\"(?<![\\\\w-])${s}(${suf})?(?![\\\\w-])\"; \"${d}\")"
    else
      prog+=" | gsub(\"(?<![\\\\w-])${s}(?![\\\\w-])\"; \"${d}\")"
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
  local d="$1" cache="$RUN/.cache-clean-$d.json" f
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
