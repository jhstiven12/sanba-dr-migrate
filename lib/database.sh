#!/usr/bin/env bash
# lib/database.sh — migración lógica de PostgreSQL 10-el8 (pg_dump -> pg_restore).
#
# El transporte del volcado usa 'oc rsync', que es el mecanismo que Red Hat
# documenta justamente para este caso: «copying database archives to and from
# your pods for backup and restore purposes»
#   Nodes 4.18 > Working with containers > Copying files to or from a container.
# Si el contenedor no trae rsync, oc cae automáticamente a una copia por tar.
# shellcheck shell=bash

DB_REMOTE_DIR="/tmp/sanba-dr-dump"
DB_DUMP_NAME="sanba.dump"

# Localiza el pod de PostgreSQL. $1 = oc_src|oc_dst, $2 = namespace
# Si DB_SELECTOR está vacío se autodescubre por la imagen del contenedor.
db_find_pod() {
  local ocf="$1" ns="$2" pod=""
  if [[ -n "${DB_SELECTOR:-}" ]]; then
    pod=$("$ocf" -n "$ns" get pods -l "$DB_SELECTOR" \
          -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
  fi
  if [[ -z "$pod" ]]; then
    pod=$("$ocf" -n "$ns" get pods -o json 2>/dev/null | jq -r '
      .items[]
      | select(.status.phase == "Running")
      | select([.status.containerStatuses[]? | select(.ready)] | length > 0)
      | select([.spec.containers[].image] | join(" ") | test("postgres"; "i"))
      | .metadata.name' | head -1)
  fi
  printf '%s' "$pod"
}

# Lee las credenciales del propio pod (variables de la imagen de PostgreSQL de
# Red Hat). Nunca se imprimen: solo se exportan a PGU/PGP/PGD.
db_creds() {
  local ocf="$1" ns="$2" pod="$3" raw
  local admvar="${DB_ADMIN_PASSWORD_ENV:-POSTGRESQL_ADMIN_PASSWORD}"
  # La contraseña se resuelve DENTRO del pod: nunca aparece en la línea de
  # comandos del cliente ni en la lista de procesos de este host.
  raw=$("$ocf" -n "$ns" exec "$pod" -- bash -c \
        "printf '%s\037%s\037%s\037%s' \"\${POSTGRESQL_USER:-}\" \"\${POSTGRESQL_PASSWORD:-}\" \"\${POSTGRESQL_DATABASE:-}\" \"\${${admvar}:-}\"" 2>/dev/null) \
    || die "No se pudo ejecutar en el pod $ns/$pod"
  IFS=$'\037' read -r PGU PGP PGD PGADMIN <<< "$raw"
  [[ -n "${PGU:-}" && -n "${PGD:-}" ]] \
    || die "El pod $ns/$pod no expone POSTGRESQL_USER/POSTGRESQL_DATABASE. Indica el pod correcto con DB_SELECTOR."
  if [[ -n "${PGADMIN:-}" ]]; then
    log "  pod=$pod  usuario=$PGU  base=$PGD  (superusuario '${DB_ADMIN_USER:-postgres}' disponible via \$$admvar)"
  else
    log "  pod=$pod  usuario=$PGU  base=$PGD  (el pod no expone \$$admvar)"
  fi
}

# Ejecuta psql con el rol indicado: "app" (POSTGRESQL_USER) o "postgres"
# (superusuario, solo si el pod expone POSTGRESQL_ADMIN_PASSWORD).
# La contraseña se resuelve DENTRO del pod: nunca viaja en la línea de comandos.
db_psql_as() {
  local ocf="$1" ns="$2" pod="$3" role="$4" sql="$5"
  if [[ "$role" == postgres ]]; then
    "$ocf" -n "$ns" exec "$pod" -- bash -c \
      "PGPASSWORD=\"\$${DB_ADMIN_PASSWORD_ENV:-POSTGRESQL_ADMIN_PASSWORD}\" psql -U ${DB_ADMIN_USER:-postgres} -d \"\$POSTGRESQL_DATABASE\" -At -F' ' -c \"$sql\""
  else
    "$ocf" -n "$ns" exec "$pod" -- bash -c \
      "PGPASSWORD=\"\$POSTGRESQL_PASSWORD\" psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -At -F' ' -c \"$sql\""
  fi
}

# Objetos que el rol indicado NO puede leer. Si devuelve algo, pg_dump fallará
# con "permission denied for relation ...". Detectarlo antes ahorra un volcado
# largo que acaba abortando.
db_unreadable_objects() {
  local ocf="$1" ns="$2" pod="$3" role="$4" sql
  sql="SELECT n.nspname || '.' || c.relname || '  [' ||
              CASE c.relkind WHEN 'r' THEN 'tabla' WHEN 'p' THEN 'tabla'
                             WHEN 'S' THEN 'secuencia' WHEN 'v' THEN 'vista'
                             WHEN 'm' THEN 'vista mat.' ELSE c.relkind::text END || ']'
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname NOT IN ('pg_catalog','information_schema')
         AND n.nspname NOT LIKE 'pg_%'
         AND ( (c.relkind IN ('r','p','v','m','f') AND NOT has_table_privilege(c.oid,'SELECT'))
            OR (c.relkind = 'S' AND NOT has_sequence_privilege(c.oid,'SELECT')) )
       ORDER BY 1;"
  db_psql_as "$ocf" "$ns" "$pod" "$role" "$sql" 2>/dev/null
}

# Decide con qué rol volcar: DB_DUMP_ROLE = auto | app | postgres
db_pick_dump_role() {
  local ocf="$1" ns="$2" pod="$3" mode="${DB_DUMP_ROLE:-auto}" blocked

  if [[ "$mode" == app || "$mode" == postgres ]]; then
    printf '%s' "$mode"; return 0
  fi

  blocked=$(db_unreadable_objects "$ocf" "$ns" "$pod" app)
  if [[ -z "$blocked" ]]; then
    log "  el usuario '$PGU' puede leer todos los objetos"
    printf 'app'; return 0
  fi

  local n; n=$(grep -c . <<< "$blocked")
  warn "El usuario '$PGU' no puede leer $n objetos; pg_dump fallaría con 'permission denied'"
  printf '%s\n' "$blocked" | sed 's/^/      /' | head -20 >&2
  [[ "$n" -gt 20 ]] && log "      ... y $((n-20)) más"

  if [[ -n "${PGADMIN:-}" ]]; then
    log "  se usará el superusuario 'postgres' para el volcado (solo lectura)"
    printf 'postgres'; return 0
  fi

  printf '%s\n' "$blocked" > "$RUN/db/objetos-sin-permiso.txt"
  cat >&2 <<MSG

  El rol '$PGU' no tiene SELECT sobre esos objetos y el pod no expone
  POSTGRESQL_ADMIN_PASSWORD, así que no hay un superusuario al que recurrir.

  Lista completa: $RUN/db/objetos-sin-permiso.txt

  Opciones, de menos a más intrusiva:

   a) Si el pod SÍ tiene un superusuario pero con otro nombre de variable de
      entorno, indícalo en sanba-dr.env (la contraseña se sigue resolviendo
      dentro del pod, nunca en la línea de comandos):
          DB_ADMIN_PASSWORD_ENV="<NOMBRE_DE_LA_VARIABLE>"
          DB_ADMIN_USER="postgres"
      Para ver qué variables tiene el pod:
          oc -n $ns exec $pod -- env | grep -i -E 'user|admin|superuser'

   b) Excluir del volcado los esquemas que no puedes leer (perderás esos datos
      en la prueba de contingencia). En sanba-dr.env:
          DB_DUMP_EXTRA_ARGS="-N service_catalog"

   c) Pedir al DBA un GRANT de solo lectura en PRODUCCIÓN. Este script no lo
      hace por ti porque escribiría en producción:
          GRANT USAGE ON SCHEMA <esquema> TO $PGU;
          GRANT SELECT ON ALL TABLES IN SCHEMA <esquema> TO $PGU;
          GRANT SELECT ON ALL SEQUENCES IN SCHEMA <esquema> TO $PGU;

  No se ha modificado nada en producción.

MSG
  die "pg_dump no puede leer todos los objetos con el rol '$PGU'."
}

# Ejecuta una consulta usando las credenciales que el propio pod tiene en su
# entorno: la contraseña nunca viaja por la línea de comandos del cliente.
db_psql() {
  local ocf="$1" ns="$2" pod="$3" sql="$4"
  "$ocf" -n "$ns" exec "$pod" -- bash -c \
    "PGPASSWORD=\"\$POSTGRESQL_PASSWORD\" psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -At -F' ' -c \"$sql\""
}

# Número de tablas de usuario en la base de datos
db_table_count() {
  db_psql "$1" "$2" "$3" \
    "SELECT count(*) FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema');" \
    2>/dev/null | tr -d '[:space:]'
}

# Conteo EXACTO de filas por tabla, comparable entre clústeres.
db_rowcounts() {
  local ocf="$1" ns="$2" pod="$3" out="$4" role="${5:-app}" sql
  sql="SELECT table_schema||'.'||table_name AS t,
              (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint AS n
       FROM information_schema.tables
       WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema')
       ORDER BY 1;"
  db_psql_as "$ocf" "$ns" "$pod" "$role" "$sql" 2>/dev/null | sort > "$out" \
    || warn "No se pudieron obtener los conteos de filas en $ns/$pod"
}

cmd_db_migrate() {
  require_cmd oc jq
  [[ "${DB_MIGRATE:-true}" == true ]] || { log "DB_MIGRATE=false, se omite la migración de datos"; return 0; }

  local src_ns="$DB_NS" dst_ns; dst_ns="$(ns_dst "$DB_NS")"
  step "Migración de datos PostgreSQL: $src_ns -> $dst_ns"

  # Guarda dura: solo se restaura sobre el namespace de contingencia.
  [[ "$dst_ns" == *"$DR_SUFFIX" ]] \
    || die "El namespace destino '$dst_ns' no termina en '$DR_SUFFIX'. Abortando por seguridad."

  if [[ "${DRY_RUN:-false}" == true ]]; then
    log "(dry-run) se haría pg_dump en $src_ns y pg_restore en $dst_ns"
    return 0
  fi

  cat >&2 <<'MSG'

  Sobre PRODUCCIÓN esta fase solo LEE: ejecuta pg_dump y descarga el fichero.
  No borra ni modifica ningún dato ni recurso. El único rastro es un fichero
  temporal en /tmp del pod, que se elimina al terminar (DB_KEEP_REMOTE_DUMP=true
  para conservarlo). Genera carga de I/O: elige una ventana de baja actividad.
  El volcado es un snapshot al instante de inicio; las escrituras posteriores en
  PROD no llegan a contingencia, así que fija la hora de corte del drill.

MSG

  mkdir -p "$RUN/db"
  local dump="$RUN/db/$DB_DUMP_NAME"

  # ======================= ORIGEN (solo lectura) =======================
  local src_pod; src_pod=$(db_find_pod oc_src "$src_ns")
  [[ -n "$src_pod" ]] || die "No se encontró un pod de PostgreSQL Running en $src_ns (ajusta DB_SELECTOR)"
  log "ORIGEN:"
  db_creds oc_src "$src_ns" "$src_pod"

  # Antes de volcar: comprobar que el rol puede leer TODOS los objetos. Si no,
  # se elige el superusuario o se aborta con la lista exacta de lo que falla.
  local dump_role; dump_role=$(db_pick_dump_role oc_src "$src_ns" "$src_pod")
  log "  rol de volcado: $dump_role"

  log "  conteo de filas previo al volcado"
  db_rowcounts oc_src "$src_ns" "$src_pod" "$RUN/db/rowcounts-src.txt" "$dump_role"
  log "  $(wc -l < "$RUN/db/rowcounts-src.txt") tablas en origen"

  local pg_user_expr
  if [[ "$dump_role" == postgres ]]; then
    pg_user_expr="PGPASSWORD=\"\$${DB_ADMIN_PASSWORD_ENV:-POSTGRESQL_ADMIN_PASSWORD}\" pg_dump -U ${DB_ADMIN_USER:-postgres}"
  else
    pg_user_expr='PGPASSWORD="$POSTGRESQL_PASSWORD" pg_dump -U "$POSTGRESQL_USER"'
  fi

  log "  pg_dump (formato custom, comprimido) en $DB_REMOTE_DIR"
  set +e
  oc_src exec -n "$src_ns" "$src_pod" -- bash -c \
    "mkdir -p $DB_REMOTE_DIR && $pg_user_expr -d \"\$POSTGRESQL_DATABASE\" \
       -Fc -Z6 --no-owner --no-privileges ${DB_DUMP_EXTRA_ARGS:-} \
       -f $DB_REMOTE_DIR/$DB_DUMP_NAME" \
    > "$RUN/db/pg_dump.log" 2>&1
  local dump_rc=$?
  set -e
  if (( dump_rc != 0 )); then
    err "pg_dump falló en $src_ns/$src_pod (rc=$dump_rc)"
    sed -n '1,20p' "$RUN/db/pg_dump.log" | sed 's/^/      /' >&2
    if grep -qi 'permission denied' "$RUN/db/pg_dump.log"; then
      cat >&2 <<MSG

  Sigue habiendo objetos que el rol '$dump_role' no puede leer. Revisa
  $RUN/db/pg_dump.log y usa DB_DUMP_EXTRA_ARGS para excluir ese esquema, o
  pide al DBA el GRANT de solo lectura correspondiente.

MSG
    fi
    # Limpiar el fichero parcial que dejó este script en el pod de producción
    oc_src exec -n "$src_ns" "$src_pod" -- rm -rf "$DB_REMOTE_DIR" >/dev/null 2>&1 || true
    die "No se pudo generar el volcado. En producción no se ha modificado nada."
  fi
  ok "pg_dump completado (traza en $RUN/db/pg_dump.log)"

  # oc rsync: método documentado por Red Hat para bajar archivos de BD de un pod.
  mkdir -p "$RUN/db/incoming"
  oc_src rsync -n "$src_ns" "$src_pod:$DB_REMOTE_DIR/" "$RUN/db/incoming/" --no-perms >/dev/null 2>&1 \
    || die "No se pudo descargar el volcado con 'oc rsync' desde $src_ns/$src_pod"
  mv -f "$RUN/db/incoming/$DB_DUMP_NAME" "$dump" 2>/dev/null \
    || die "El volcado no llegó completo desde el pod"
  rmdir "$RUN/db/incoming" 2>/dev/null || true

  if [[ "${DB_KEEP_REMOTE_DUMP:-false}" == true ]]; then
    warn "Se conserva $DB_REMOTE_DIR/$DB_DUMP_NAME en el pod de PRODUCCIÓN (DB_KEEP_REMOTE_DUMP=true)"
    todo "$src_ns/$src_pod: queda el fichero temporal $DB_REMOTE_DIR/$DB_DUMP_NAME. Bórralo cuando ya no lo necesites."
  else
    log "  eliminando el fichero temporal que creó este script en el pod origen"
    oc_src exec -n "$src_ns" "$src_pod" -- rm -rf "$DB_REMOTE_DIR" >/dev/null 2>&1 || true
  fi

  [[ -s "$dump" ]] || die "El volcado descargado está vacío"
  ok "Volcado: $dump ($(du -h "$dump" | cut -f1))"

  # ======================= DESTINO (pre-producción) =======================
  local dst_pod; dst_pod=$(db_find_pod oc_dst "$dst_ns")
  [[ -n "$dst_pod" ]] || die "No se encontró un pod de PostgreSQL Running en $dst_ns. ¿Se aplicó ese namespace?"
  log "DESTINO:"
  db_creds oc_dst "$dst_ns" "$dst_pod"

  # No se borra nada sin permiso explícito: si la BD de contingencia ya tiene
  # tablas, hay que decidir a mano.
  local existing; existing=$(db_table_count oc_dst "$dst_ns" "$dst_pod")
  if [[ "${existing:-0}" -gt 0 && "${DB_RESTORE_CLEAN:-false}" != true ]]; then
    cat >&2 <<MSG

  La base de datos de $dst_ns ya contiene $existing tablas.

  Con DB_RESTORE_CLEAN="false" (por defecto) el script no borra nada, y
  restaurar encima produciría errores de objeto duplicado o datos mezclados.

  Opciones:
    a) Vacía o recrea la base de datos de PRE-PRODUCCIÓN a mano y repite.
    b) Recrea el namespace:  ./sanba-dr-migrate.sh rollback --confirm
    c) Si aceptas que pg_restore BORRE los objetos de la BD de pre-producción,
       pon DB_RESTORE_CLEAN="true" en sanba-dr.env y vuelve a ejecutar
       './sanba-dr-migrate.sh db-migrate'.

  En PRODUCCIÓN no se ha tocado nada.

MSG
    die "La base de datos destino no está vacía y DB_RESTORE_CLEAN=false."
  fi

  log "  subiendo el volcado al pod destino con oc rsync"
  oc_dstw exec -n "$dst_ns" "$dst_pod" -- mkdir -p "$DB_REMOTE_DIR" >/dev/null 2>&1 || true
  oc_dstw rsync -n "$dst_ns" "$RUN/db/" "$dst_pod:$DB_REMOTE_DIR/" --no-perms --exclude='*.txt' --exclude='*.diff' --exclude='*.log' >/dev/null 2>&1 \
    || die "No se pudo subir el volcado a $dst_ns/$dst_pod"

  local clean_flags=""
  if [[ "${DB_RESTORE_CLEAN:-false}" == true ]]; then
    clean_flags="--clean --if-exists"
    warn "pg_restore se ejecuta con --clean: BORRARÁ los objetos existentes en la BD de $dst_ns"
  fi

  log "  pg_restore ${clean_flags:-(sin --clean, no borra nada)}"
  set +e
  oc_dst exec -n "$dst_ns" "$dst_pod" -- bash -c \
    "PGPASSWORD=\"\$POSTGRESQL_PASSWORD\" pg_restore -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" \
       --no-owner --no-privileges $clean_flags $DB_REMOTE_DIR/$DB_DUMP_NAME" \
    > "$RUN/db/restore.log" 2>&1
  local rc=$?
  set -e
  oc_dst exec -n "$dst_ns" "$dst_pod" -- rm -rf "$DB_REMOTE_DIR" >/dev/null 2>&1 || true

  local errs; errs=$(grep -ci '^pg_restore: error' "$RUN/db/restore.log" 2>/dev/null || echo 0)
  if (( rc != 0 || errs > 0 )); then
    # Con --clean son habituales los errores por objetos inexistentes o por no ser
    # dueño de extensiones del sistema; el juez final es el diff de conteos.
    warn "pg_restore terminó con $errs errores (rc=$rc). Detalle: $RUN/db/restore.log"
    sed -n '1,15p' "$RUN/db/restore.log" | sed 's/^/      /' >&2
  else
    ok "pg_restore sin errores"
  fi

  # ======================= verificación =======================
  log "  conteo de filas en destino"
  db_rowcounts oc_dst "$dst_ns" "$dst_pod" "$RUN/db/rowcounts-dst.txt"

  if diff -u "$RUN/db/rowcounts-src.txt" "$RUN/db/rowcounts-dst.txt" > "$RUN/db/rowcounts.diff" 2>&1; then
    ok "Conteo de filas idéntico en origen y destino ($(wc -l < "$RUN/db/rowcounts-dst.txt") tablas)"
  else
    err "El conteo de filas NO coincide. Ver $RUN/db/rowcounts.diff"
    sed -n '1,25p' "$RUN/db/rowcounts.diff" | sed 's/^/      /' >&2
    todo "$dst_ns: el conteo de filas difiere de PROD. Revisa $RUN/db/rowcounts.diff antes de dar el drill por bueno."
  fi
}
