#!/usr/bin/env bash
# =============================================================================
#  sanba-dr.sh — Consola de operación de la prueba de DR de SANBA
#
#  Es la puerta de entrada al drill: pide las credenciales de los dos clústeres
#  y ofrece un menú con las tareas del plan de contingencia. Cada opción invoca
#  a sanba-dr-migrate.sh, que es quien hace el trabajo y deja la bitácora.
#
#  Sobre PRODUCCIÓN solo se lee. La sesión de producción se guarda en su propio
#  kubeconfig y el motor la usa a través de un wrapper que rechaza cualquier
#  verbo de escritura.
#
#  Los tokens se piden por teclado, no se muestran, no se guardan en el
#  historial ni en la bitácora: acaban únicamente en el kubeconfig
#  correspondiente, con permisos 600.
#
#  Uso:  ./sanba-dr.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MOTOR="$ROOT/sanba-dr-migrate.sh"

[[ -x "$MOTOR" ]] || { echo "No encuentro $MOTOR" >&2; exit 1; }
[[ -r "$ROOT/sanba-dr.env" ]] || { echo "Falta $ROOT/sanba-dr.env" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ROOT/sanba-dr.env"

if [[ -t 1 ]]; then SANBA_TTY=true; else SANBA_TTY=false; fi
export SANBA_TTY
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

[[ -t 0 ]] || die "sanba-dr.sh es interactivo: ejecútalo en un terminal. Para automatizar usa $MOTOR directamente."

# --- estado de la sesión de trabajo -----------------------------------------
OPT_DRY_RUN=false
OPT_VERBOSE=false
OPT_FORCE=false
OPT_NO_DB=false
OPT_ONLY=""
OPT_RUN=""              # vacío = el motor elige (nueva corrida o la última)

SRC_USER=""; SRC_SERVER=""
DST_USER=""; DST_SERVER=""

# =============================================================================
#  Sesiones en los clústeres
# =============================================================================
_login_flags() {
  [[ "${LOGIN_INSECURE:-true}" == true ]] && printf '%s' "--insecure-skip-tls-verify=true"
}

# Estado actual de un kubeconfig: imprime "usuario<TAB>servidor" si la sesión
# sirve, y no imprime nada si no hay sesión o el token caducó.
session_info() {
  local kube="$1" u s
  [[ -r "$kube" ]] || return 1
  u=$(KUBECONFIG="$kube" oc whoami 2>/dev/null) || return 1
  s=$(KUBECONFIG="$kube" oc whoami --show-server 2>/dev/null) || return 1
  printf '%s\t%s\n' "$u" "$s"
}

# El operador puede pegar la línea completa que ofrece la consola web de
# OpenShift ("oc login --token=sha256~... --server=https://api...:6443"), o
# solo el token. Se acepta cualquiera de las dos formas.
_extract_token() {
  local raw="$1"
  if [[ "$raw" == *"--token="* ]]; then
    raw="${raw#*--token=}"; raw="${raw%% *}"
  fi
  printf '%s' "$raw"
}
_extract_server() {
  local raw="$1"
  if [[ "$raw" == *"--server="* ]]; then
    raw="${raw#*--server=}"; raw="${raw%% *}"
    printf '%s' "$raw"
  fi
}

# login_cluster <SRC|DST>
login_cluster() {
  local rol="$1" kube etiqueta api_def api token server_pegado

  if [[ "$rol" == SRC ]]; then
    kube="$KUBECONFIG_SRC"; etiqueta="PRODUCCIÓN (solo lectura)"; api_def="${SRC_API:-}"
  else
    kube="$KUBECONFIG_DST"; etiqueta="PRE-PRODUCCIÓN / contingencia"; api_def="${DST_API:-}"
  fi

  printf '\n%s%s%s\n' "$C_BLD" "Sesión en $etiqueta" "$C_RST"
  printf '  kubeconfig: %s\n' "$kube"

  local actual
  if actual="$(session_info "$kube")"; then
    printf '  sesión válida: %s en %s\n' "$(cut -f1 <<< "$actual")" "$(cut -f2 <<< "$actual")"
    local r
    read -rp "  ¿Reutilizarla? [S/n]: " r
    if [[ -z "$r" || "$r" =~ ^[SsYy]$ ]]; then
      [[ "$rol" == SRC ]] && { SRC_USER="$(cut -f1 <<< "$actual")"; SRC_SERVER="$(cut -f2 <<< "$actual")"; } \
                          || { DST_USER="$(cut -f1 <<< "$actual")"; DST_SERVER="$(cut -f2 <<< "$actual")"; }
      return 0
    fi
  fi

  printf '  Pega el token de la consola web (Copy login command). No se mostrará.\n'
  read -rsp "  Token o comando 'oc login' completo: " token; echo
  [[ -n "$token" ]] || { err "No se introdujo ningún token"; return 1; }

  server_pegado="$(_extract_server "$token")"
  token="$(_extract_token "$token")"

  api="${server_pegado:-$api_def}"
  if [[ -z "$api" ]]; then
    read -rp "  URL de la API (https://api.<clúster>:6443): " api
  else
    local r
    read -rp "  API [$api]: " r
    [[ -n "$r" ]] && api="$r"
  fi
  [[ -n "$api" ]] || { err "No se indicó la URL de la API"; return 1; }

  mkdir -p "$(dirname "$kube")"
  local salida rc
  # El token va como argumento de oc, nunca al log ni al historial.
  salida=$(KUBECONFIG="$kube" oc login "$api" --token="$token" $(_login_flags) 2>&1); rc=$?
  unset token
  chmod 600 "$kube" 2>/dev/null || true

  if (( rc != 0 )); then
    err "No se pudo iniciar sesión en $etiqueta"
    printf '%s\n' "$salida" | mask | sed 's/^/      /' >&2
    return 1
  fi

  local info
  info="$(session_info "$kube")" || { err "El login pareció correcto pero la sesión no responde"; return 1; }
  if [[ "$rol" == SRC ]]; then
    SRC_USER="$(cut -f1 <<< "$info")"; SRC_SERVER="$(cut -f2 <<< "$info")"
  else
    DST_USER="$(cut -f1 <<< "$info")"; DST_SERVER="$(cut -f2 <<< "$info")"
  fi
  ok "$etiqueta: $(cut -f1 <<< "$info") en $(cut -f2 <<< "$info")"
  return 0
}

# Las dos sesiones, con la comprobación que evita el peor error posible:
# apuntar el "destino" al clúster de producción.
establecer_sesiones() {
  banner "AUTENTICACIÓN EN LOS DOS CLÚSTERES" \
         "Producción se usa en modo solo lectura; contingencia es el único clúster donde se escribe."
  login_cluster SRC || return 1
  login_cluster DST || return 1

  if [[ "$SRC_SERVER" == "$DST_SERVER" ]]; then
    err "Las dos sesiones apuntan al MISMO clúster ($SRC_SERVER)"
    log "  Repite el paso indicando la API de pre-producción como destino."
    SRC_SERVER=""; DST_SERVER=""
    return 1
  fi
  ok "Dos clústeres distintos: la migración puede continuar"
  return 0
}

sesiones_listas() { [[ -n "$SRC_SERVER" && -n "$DST_SERVER" && "$SRC_SERVER" != "$DST_SERVER" ]]; }

# =============================================================================
#  Ejecución de tareas
# =============================================================================
flags_actuales() {
  local f=()
  [[ -n "$OPT_RUN"        ]] && f+=(--run "$OPT_RUN")
  [[ -n "$OPT_ONLY"       ]] && f+=(--only "$OPT_ONLY")
  [[ "$OPT_DRY_RUN" == true ]] && f+=(--dry-run)
  [[ "$OPT_VERBOSE" == true ]] && f+=(--verbose)
  [[ "$OPT_FORCE"   == true ]] && f+=(--force)
  [[ "$OPT_NO_DB"   == true ]] && f+=(--no-db)
  printf '%s\n' "${f[@]:-}"
}

# ejecutar <subcomando> [flags extra...]
ejecutar() {
  local cmd="$1"; shift
  local -a flags=()
  mapfile -t flags < <(flags_actuales)
  # 'db-migrate' y 'rollback' no admiten --only ni --no-db
  case "$cmd" in
    db-migrate|rollback|report)
      local -a limpias=(); local i skip=false
      for i in "${flags[@]}"; do
        [[ -z "$i" ]] && continue
        if [[ "$skip" == true ]]; then skip=false; continue; fi
        case "$i" in
          --only) skip=true ;;
          --no-db|--force) ;;
          *) limpias+=("$i") ;;
        esac
      done
      flags=("${limpias[@]:-}") ;;
  esac

  local -a argv=()
  local a
  for a in "${flags[@]}" "$@"; do [[ -n "$a" ]] && argv+=("$a"); done

  printf '\n%s$ %s %s %s%s\n' "$C_DIM" "$(basename "$MOTOR")" "$cmd" "${argv[*]:-}" "$C_RST"
  "$MOTOR" "$cmd" "${argv[@]}"
  local rc=$?

  # La corrida que acaba de crearse pasa a ser la corrida de trabajo, para que
  # las siguientes tareas del menú operen sobre la misma.
  [[ -z "$OPT_RUN" ]] && OPT_RUN="$(ultima_corrida)"

  if (( rc == 0 )); then
    ok "'$cmd' terminó correctamente (corrida ${OPT_RUN:-?})"
  else
    err "'$cmd' terminó con código $rc — revisa la bitácora de la corrida"
  fi
  pausa
  return $rc
}

ultima_corrida() { ls -1 "$ROOT/out" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -1; }

pausa() { local _x; printf '\n'; read -rp "  [Enter] para volver al menú " _x; }

confirmar() {
  local pregunta="$1" palabra="$2" r
  printf '\n%s%s%s\n' "$C_YEL" "$pregunta" "$C_RST"
  read -rp "  Escribe '$palabra' para continuar: " r
  [[ "$r" == "$palabra" ]]
}

# =============================================================================
#  Pantallas auxiliares
# =============================================================================
ver_fichero() {
  local f="$1"
  if [[ -r "$f" ]]; then
    printf '\n%s--- %s ---%s\n' "$C_DIM" "$f" "$C_RST"
    if command -v less >/dev/null 2>&1; then less -R "$f"; else cat "$f"; fi
  else
    warn "Todavía no existe $f"
  fi
}

menu_urls() {
  local run="${OPT_RUN:-$(ultima_corrida)}"
  while true; do
    printf '\n%sURLs de los componentes%s\n' "$C_BLD" "$C_RST"
    printf '  1) Ver el mapa de sustituciones de la corrida %s\n' "${run:-<ninguna>}"
    printf '  2) Ver el informe por objeto (reports/urls.txt)\n'
    printf '  3) Editar %s (pares <URL en PROD> <URL en DR>)\n' "${URL_MAP_FILE:-url-map.txt}"
    printf '  4) Editar %s (hosts custom de Routes)\n' "${ROUTE_MAP_FILE:-route-map.txt}"
    printf '  0) Volver\n'
    local o; read -rp "  Opción: " o
    case "$o" in
      1) ver_fichero "$ROOT/out/$run/url-map.tsv" ;;
      2) ver_fichero "$ROOT/out/$run/reports/urls.txt" ;;
      3) "${EDITOR:-vi}" "$ROOT/${URL_MAP_FILE:-url-map.txt}"
         log "Recuerda repetir 'transform' para que los cambios lleguen a los manifiestos" ;;
      4) "${EDITOR:-vi}" "$ROOT/${ROUTE_MAP_FILE:-route-map.txt}"
         log "Recuerda repetir 'transform' para que los cambios lleguen a los manifiestos" ;;
      0|q) return 0 ;;
      *) warn "Opción no válida" ;;
    esac
  done
}

menu_informes() {
  local run="${OPT_RUN:-$(ultima_corrida)}"
  [[ -n "$run" ]] || { warn "Todavía no hay ninguna corrida"; pausa; return 0; }
  local rep="$ROOT/out/$run/reports"
  while true; do
    printf '\n%sInformes de la corrida %s%s\n' "$C_BLD" "$run" "$C_RST"
    printf '  1) Pendientes manuales (manual-todo.txt)\n'
    printf '  2) Validación (validation.txt)\n'
    printf '  3) URLs (urls.txt)\n'
    printf '  4) Routes (routes.txt)\n'
    printf '  5) ConfigMaps y Secrets (config.txt)\n'
    printf '  6) ServiceAccounts y SCC (serviceaccounts.txt)\n'
    printf '  7) Imágenes (images.txt)\n'
    printf '  8) Bitácora completa (migrate.log)\n'
    printf '  0) Volver\n'
    local o; read -rp "  Opción: " o
    case "$o" in
      1) ver_fichero "$rep/manual-todo.txt" ;;
      2) ver_fichero "$rep/validation.txt" ;;
      3) ver_fichero "$rep/urls.txt" ;;
      4) ver_fichero "$rep/routes.txt" ;;
      5) ver_fichero "$rep/config.txt" ;;
      6) ver_fichero "$rep/serviceaccounts.txt" ;;
      7) ver_fichero "$rep/images.txt" ;;
      8) ver_fichero "$ROOT/out/$run/migrate.log" ;;
      0|q) return 0 ;;
      *) warn "Opción no válida" ;;
    esac
  done
}

menu_opciones() {
  while true; do
    printf '\n%sOpciones de ejecución%s\n' "$C_BLD" "$C_RST"
    printf '  1) Simulación (--dry-run) ....... %s\n' "$OPT_DRY_RUN"
    printf '  2) Detalle (--verbose) .......... %s\n' "$OPT_VERBOSE"
    printf '  3) Reutilizar namespaces (--force) %s\n' "$OPT_FORCE"
    printf '  4) No encadenar la BD (--no-db) . %s\n' "$OPT_NO_DB"
    printf '  5) Limitar a un namespace ....... %s\n' "${OPT_ONLY:-<todos>}"
    printf '  6) Corrida de trabajo ........... %s\n' "${OPT_RUN:-<nueva / la última>}"
    printf '  0) Volver\n'
    local o r; read -rp "  Opción: " o
    case "$o" in
      1) [[ "$OPT_DRY_RUN" == true ]] && OPT_DRY_RUN=false || OPT_DRY_RUN=true ;;
      2) [[ "$OPT_VERBOSE" == true ]] && OPT_VERBOSE=false || OPT_VERBOSE=true ;;
      3) [[ "$OPT_FORCE"   == true ]] && OPT_FORCE=false   || OPT_FORCE=true ;;
      4) [[ "$OPT_NO_DB"   == true ]] && OPT_NO_DB=false   || OPT_NO_DB=true ;;
      5) printf '     Namespaces de origen: %s\n' "$NS_ORDER"
         read -rp "     Namespace (vacío = todos): " r; OPT_ONLY="$r" ;;
      6) printf '     Corridas disponibles:\n'
         ls -1 "$ROOT/out" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -10 | sed 's/^/       /'
         read -rp "     ID de corrida (vacío = nueva o la última): " r; OPT_RUN="$r" ;;
      0|q) return 0 ;;
      *) warn "Opción no válida" ;;
    esac
  done
}

# =============================================================================
#  Menú principal
# =============================================================================
cabecera() {
  local modo="escritura"; [[ "$OPT_DRY_RUN" == true ]] && modo="SIMULACIÓN (--dry-run)"
  printf '\n%s%s%s\n' "$C_CYA" "$(_rule '=')" "$C_RST"
  printf ' %sSANBA · CONSOLA DE CONTINGENCIA (DR)%s   %s\n' "$C_BLD" "$C_RST" "$(_now)"
  printf '%s%s%s\n' "$C_CYA" "$(_rule '=')" "$C_RST"
  # Etiquetas sin acentos: printf pad'ea por bytes, y una tilde desalinearía
  # la columna en el terminal.
  printf ' %-14s %-40s %s\n' "PROD (origen)" "${SRC_SERVER:-sin sesion}" "${SRC_USER:+usuario: $SRC_USER}"
  printf ' %-14s %-40s %s\n' "DR (destino)"  "${DST_SERVER:-sin sesion}" "${DST_USER:+usuario: $DST_USER}"
  printf ' %-14s %-40s %s\n' "NAMESPACES"    "$NS_ORDER" "sufijo: $DR_SUFFIX"
  printf ' %-14s %-40s %s\n' "CORRIDA"       "${OPT_RUN:-nueva / la ultima}" "modo: $modo"
  printf '%s%s%s\n' "$C_CYA" "$(_rule '=')" "$C_RST"
}

menu() {
  cabecera
  cat <<'MENU'
  PREPARACIÓN
    1) Preflight — host, sesiones, permisos, namespaces y StorageClasses
    2) Export    — extraer producción a out/<corrida>/raw  (SOLO LECTURA)
    3) Transform — sanear, renombrar namespaces y reescribir las URLs
    4) Revisar informes de la corrida

  DESPLIEGUE EN CONTINGENCIA
    5) Mirror    — copiar las imágenes por digest al registry de pre-producción
    6) Apply     — desplegar en pre-producción (encadena la carga de datos)
    7) Db-migrate— cargar los datos PostgreSQL por separado
    8) Validate  — comprobar rollouts, pods, PVCs, URLs, BD, SA y configuración

  FLUJOS
    9) Todo de una vez (preflight -> export -> transform -> apply -> validate)
   10) Rollback  — borrar el entorno de contingencia para repetir el drill

  UTILIDADES
   11) URLs de los componentes (mapa, informe y ficheros de mapeo)
   12) Opciones de ejecución (dry-run, verbose, corrida, namespace)
   13) Volver a autenticarse en los clústeres
    0) Salir
MENU
}

principal() {
  establecer_sesiones || warn "Sin sesiones válidas solo podrás usar las utilidades del menú"

  while true; do
    menu
    local o; read -rp "  Tarea: " o
    case "$o" in
      1)  sesiones_listas && ejecutar preflight  || { warn "Necesitas sesión en los dos clústeres"; pausa; } ;;
      2)  sesiones_listas && ejecutar export     || { warn "Necesitas sesión en los dos clústeres"; pausa; } ;;
      3)  ejecutar transform ;;
      4)  menu_informes ;;
      5)  sesiones_listas && ejecutar mirror     || { warn "Necesitas sesión en los dos clústeres"; pausa; } ;;
      6)  if ! sesiones_listas; then warn "Necesitas sesión en los dos clústeres"; pausa
          elif confirmar "Se va a ESCRIBIR en $DST_SERVER (namespaces $NS_ORDER con sufijo $DR_SUFFIX)." "aplicar"; then
            ejecutar apply
          else warn "Cancelado"; pausa; fi ;;
      7)  if ! sesiones_listas; then warn "Necesitas sesión en los dos clústeres"; pausa
          elif confirmar "Se hará pg_dump en PRODUCCIÓN (solo lectura) y pg_restore en contingencia." "cargar"; then
            ejecutar db-migrate
          else warn "Cancelado"; pausa; fi ;;
      8)  sesiones_listas && ejecutar validate   || { warn "Necesitas sesión en los dos clústeres"; pausa; } ;;
      9)  if ! sesiones_listas; then warn "Necesitas sesión en los dos clústeres"; pausa
          elif confirmar "Flujo completo: acabará ESCRIBIENDO en $DST_SERVER." "continuar"; then
            OPT_RUN=""      # 'all' abre siempre una corrida nueva
            ejecutar all
          else warn "Cancelado"; pausa; fi ;;
      10) if ! sesiones_listas; then warn "Necesitas sesión en los dos clústeres"; pausa
          elif confirmar "Se BORRARÁN los namespaces con sufijo $DR_SUFFIX en $DST_SERVER. Producción no se toca." "borrar"; then
            ejecutar rollback --confirm
          else warn "Cancelado"; pausa; fi ;;
      11) menu_urls ;;
      12) menu_opciones ;;
      13) establecer_sesiones || true; pausa ;;
      0|q|salir) printf '\n'; log "Fin de la sesión de contingencia"; exit 0 ;;
      *) warn "Opción no válida" ;;
    esac
  done
}

principal
