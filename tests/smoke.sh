#!/usr/bin/env bash
# tests/smoke.sh — pruebas sin clúster. Ejecutar desde la raíz del repositorio.
#
# Cubre la clase de fallo que 'bash -n' no ve: funciones invocadas pero no
# definidas, y errores que solo aparecen al ejecutar una fase completa.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
ok()   { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
head_() { printf '\n== %s ==\n' "$*"; }

export PATH="$PWD/tests:$PATH"
ln -sf mock-oc tests/oc 2>/dev/null
mkdir -p "$HOME/.kube"; touch "$HOME/.kube/config-prod" "$HOME/.kube/config-preprod"

head_ "Sintaxis"
for f in sanba-dr-migrate.sh lib/*.sh; do
  bash -n "$f" && ok "$f" || bad "$f"
done

head_ "Funciones invocadas pero no definidas"
defined=$( { grep -hoP '^\K[a-z_]+(?=\(\) \{)' lib/*.sh sanba-dr-migrate.sh; \
             printf '%s\n' log vlog step ok warn err die mask report todo; } | sort -u )
# Dos formas de invocar: al principio de una orden, y dentro de $( ). Se exige
# un espacio detrás del nombre para no confundir una asignación (db_pod=...)
# con una llamada.
prefijos='db_|cmd_|tf_|apply_|check_|v_|export_|clean_|read_manifest|to_manifest|discover_|wait_|reconcile_'
invocadas=$( { grep -hoE "^[[:space:]]*($prefijos)[a-z_]*[[:space:]]"  lib/*.sh sanba-dr-migrate.sh
               grep -hoE "\\\$\\(($prefijos)[a-z_]*[[:space:]]"       lib/*.sh sanba-dr-migrate.sh | sed 's/^\$(//'
             } | tr -d ' ' | sort -u )
missing=0
for fn in $invocadas; do
  grep -qx "$fn" <<< "$defined" || { bad "función no definida: $fn"; missing=1; }
done
[[ $missing -eq 0 ]] && ok "todas las funciones invocadas están definidas ($(wc -w <<< "$invocadas") comprobadas)"

head_ "Pipeline con manifiestos YAML"
rm -rf out/SMOKE; python3 tests/fixtures.py out/SMOKE >/dev/null
./sanba-dr-migrate.sh transform --run SMOKE >/dev/null 2>&1 && ok "transform" || bad "transform"
./sanba-dr-migrate.sh apply --run SMOKE --dry-run >/dev/null 2>&1 && ok "apply --dry-run" || bad "apply --dry-run"

head_ "Pipeline con manifiestos JSON (RHEL 9 sin yq)"
cat > tests/yq <<'YQ'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "yq no disponible"; exit 127; }
echo "ERROR: yq invocado y no existe en RHEL 9" >&2; exit 127
YQ
chmod +x tests/yq
rm -rf out/SMOKE; python3 tests/fixtures.py out/SMOKE >/dev/null
./sanba-dr-migrate.sh transform --run SMOKE >/dev/null 2>&1 \
  && [[ -r out/SMOKE/clean/sanba-core-dr/10-serviceaccount.json ]] \
  && ok "transform genera JSON" || bad "transform sin yq"
./sanba-dr-migrate.sh apply --run SMOKE --dry-run >/dev/null 2>&1 && ok "apply --dry-run (JSON)" || bad "apply --dry-run (JSON)"
rm -f tests/yq

head_ "db-migrate de extremo a extremo"
rm -rf out/SMOKE; mkdir -p out/SMOKE/reports out/SMOKE/db
salida=$(./sanba-dr-migrate.sh db-migrate --run SMOKE 2>&1)
grep -qi 'syntax error\|orden no encontrada\|command not found' <<< "$salida" \
  && bad "errores de ejecución en db-migrate" || ok "sin errores de ejecución"
grep -q 'Conteo de filas idéntico' <<< "$salida" && ok "dump, restore y verificación" || bad "el flujo de datos no completó"
grep -q "rol de volcado: postgres-local" <<< "$salida" \
  && ok "escala al superusuario por socket local" || bad "no escaló de rol"

head_ "El guardarraíl de producción bloquea escrituras"
for verbo in delete apply scale patch "adm policy"; do
  salida=$(bash -c 'source ./sanba-dr.env; source lib/common.sh; oc_src '"$verbo"' x 2>&1' || true)
  grep -q 'BLOQUEADO' <<< "$salida" && ok "oc $verbo bloqueado" || bad "oc $verbo NO bloqueado"
done

rm -rf out/SMOKE tests/oc
printf '\n%s\n' "----------------------------------------"
printf 'Correctas: %s   Fallidas: %s\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
