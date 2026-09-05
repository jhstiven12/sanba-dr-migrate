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
for f in sanba-dr.sh sanba-dr-migrate.sh lib/*.sh; do
  bash -n "$f" && ok "$f" || bad "$f"
done

head_ "Funciones invocadas pero no definidas"
defined=$( { grep -hoP '^\K[a-z_]+(?=\(\) \{)' lib/*.sh sanba-dr-migrate.sh sanba-dr.sh; \
             printf '%s\n' log vlog step ok warn err die mask report todo; } | sort -u )
# Dos formas de invocar: al principio de una orden, y dentro de $( ). Se exige
# un espacio detrás del nombre para no confundir una asignación (db_pod=...)
# con una llamada.
prefijos='db_|cmd_|tf_|apply_|check_|v_|export_|clean_|read_manifest|to_manifest|discover_|wait_|reconcile_|build_|url_map|route_host_|login_cluster|session_info|menu_|flags_actuales|phase_|run_phase|run_summary|banner|step_'
invocadas=$( { grep -hoE "^[[:space:]]*($prefijos)[a-z_]*[[:space:]]"  lib/*.sh sanba-dr-migrate.sh sanba-dr.sh
               grep -hoE "\\\$\\(($prefijos)[a-z_]*[[:space:]]"       lib/*.sh sanba-dr-migrate.sh sanba-dr.sh | sed 's/^\$(//'
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

head_ "URLs nuevas en ConfigMaps, Secrets y variables de entorno"
rm -rf out/SMOKE; python3 tests/fixtures.py out/SMOKE >/dev/null
URL_MAP_FILE=tests/url-map-test.txt ./sanba-dr-migrate.sh transform --run SMOKE >/dev/null 2>&1

cm=$(yq -o=json '.' out/SMOKE/clean/sanba-core-dr/25-configmap.yaml | jq -r '.items[] | select(.metadata.name=="sanba-core-config") | .data')
[[ "$(jq -r .GUI_PUBLIC_URL <<< "$cm")" == "https://sanba-gui-sanba-gui-dr.apps.preprod.example.com/app" ]] \
  && ok "el host de la Route se reescribe al de contingencia" \
  || bad "GUI_PUBLIC_URL: $(jq -r .GUI_PUBLIC_URL <<< "$cm")"
[[ "$(jq -r .PAGOS_URL <<< "$cm")" == "https://api-pagos-qa.corp.example.com/v1" ]] \
  && ok "url-map.txt sustituye el endpoint externo" \
  || bad "PAGOS_URL: $(jq -r .PAGOS_URL <<< "$cm")"
grep -q 'sanba-data-persistence-dr.svc' <<< "$cm" \
  && ok "las URLs internas siguen usando el renombrado de namespace" \
  || bad "se perdió el renombrado de namespace en la URL interna"

sec=$(yq -o=json '.' out/SMOKE/clean/sanba-core-dr/20-secret.yaml | jq -r '.items[] | select(.metadata.name=="sanba-core-db") | .data')
[[ "$(jq -r .CALLBACK_URL <<< "$sec" | base64 -d)" == "https://sanba-gui-sanba-gui-dr.apps.preprod.example.com/callback" ]] \
  && ok "la URL dentro del Secret se reescribe" \
  || bad "CALLBACK_URL: $(jq -r .CALLBACK_URL <<< "$sec" | base64 -d)"
[[ "$(jq -r '.["keystore.p12"]' <<< "$sec")" == "AAEC//7ItAABAv/+yLQAAQL//si0AAEC//7ItA==" ]] \
  && ok "el binario del Secret queda intacto" || bad "se corrompió keystore.p12"

grep -q 'SIN RESOLVER' out/SMOKE/reports/urls.txt \
  && ok "el host custom sin mapear se marca como pendiente" || bad "no se detectó la URL sin resolver"
grep -q "env/PORTAL_URL" out/SMOKE/reports/manual-todo.txt \
  && ok "la URL sin resolver llega a manual-todo.txt" || bad "manual-todo.txt no recoge la URL sin resolver"
head -1 out/SMOKE/url-map.tsv | grep -q 'sanba-gui-sanba-gui.apps.prod.example.com' \
  && ok "el mapa aplica primero la coincidencia más larga" || bad "el mapa de URLs está mal ordenado"

head_ "Asociación entre namespaces"
rm -rf out/SMOKE; python3 tests/fixtures.py out/SMOKE >/dev/null
URL_MAP_FILE=tests/url-map-test.txt ./sanba-dr-migrate.sh transform --run SMOKE >/dev/null 2>&1

# El Service conserva su nombre; solo cambia la etiqueta de namespace del FQDN.
cm=$(yq -o=json '.' out/SMOKE/clean/sanba-core-dr/25-configmap.yaml | jq -r '.items[]|select(.metadata.name=="sanba-core-config")|.data')
grep -q 'sanba-gui.sanba-gui-dr.svc' <<< "$cm" \
  && ok "el FQDN interno conserva el nombre del Service" \
  || bad "FQDN mal reescrito: $(jq -r '.["application.yaml"]' <<< "$cm" | grep gui)"
grep -q 'sanba-gui-dr.sanba-gui-dr.svc' <<< "$cm" \
  && bad "se reescribió también la etiqueta de servicio" || ok "no se toca la etiqueta de servicio"
api=$(yq -o=json '.' out/SMOKE/clean/sanba-gui-dr/50-deployment.yaml | jq -r '.items[].spec.template.spec.containers[0].env[0].value')
[[ "$api" == "http://sanba-core.sanba-core-dr.svc:8080" ]] \
  && ok "el GUI apunta al backend de contingencia" || bad "env API: $api"

# ExternalName y anotaciones
svc=$(yq -o=json '.' out/SMOKE/clean/location-resources-dr/40-service.yaml)
[[ "$(jq -r '.items[]|select(.metadata.name=="core-alias")|.spec.externalName' <<< "$svc")" \
   == "sanba-core.sanba-core-dr.svc.cluster.local" ]] \
  && ok "el Service ExternalName apunta al namespace -dr" || bad "externalName sin traducir"
jq -r '.items[]|select(.metadata.name=="core-alias")|.metadata.annotations.doc' <<< "$svc" | grep -q 'sanba-core-dr.svc' \
  && ok "las anotaciones con URLs se reescriben" || bad "anotación sin reescribir"

# NetworkPolicy: matchLabels y matchExpressions
np=$(yq -o=json '.' out/SMOKE/clean/location-resources-dr/70-networkpolicy.yaml)
[[ "$(jq -r '[.. | objects | select(has("namespaceSelector")) | .namespaceSelector
              | ((.matchLabels // {}) | to_entries[] | .value), ((.matchExpressions // [])[] | (.values // [])[])]
             | map(select(endswith("-dr") | not)) | length' <<< "$np")" == "0" ]] \
  && ok "los namespaceSelector seleccionan los namespaces de contingencia" \
  || bad "queda un selector apuntando a producción: $(jq -c '[.. |objects|select(has("namespaceSelector")).namespaceSelector]' <<< "$np")"

# Informe de asociación
grep -q 'core-can-read .* sanba-core-sa .* sanba-core-dr .* CRUZADO (correcto)' out/SMOKE/reports/cross-namespace.txt \
  && ok "el RBAC cruzado queda registrado como correcto" || bad "el informe no refleja el RBAC cruzado"
grep -q 'SIN TRADUCIR' out/SMOKE/reports/cross-namespace.txt \
  && bad "queda una referencia sin traducir" || ok "ninguna referencia apunta a producción"
grep -q 'huerfano .* SERVICE INEXISTENTE' out/SMOKE/reports/cross-namespace.txt \
  && ok "detecta la referencia a un Service que no existe" || bad "no detectó el Service inexistente"

# Bindings de ámbito de clúster que el export arrastra por un solo subject
crb=$(yq -o=json '.' out/SMOKE/clean/_cluster/80-clusterrolebinding.yaml)
grep -q 'openshift-pipelines-clusterinterceptors' <<< "$crb" \
  && bad "se copió un ClusterRoleBinding gestionado por un operador" \
  || ok "no se copian los ClusterRoleBindings de un operador"
[[ "$(jq -r '[.items[]|select(.metadata.name=="lectores-varios-dr")|.subjects[]|.namespace]|join(",")' <<< "$crb")" \
   == "sanba-core-dr" ]] \
  && ok "del ClusterRoleBinding copiado solo quedan los subjects de los namespaces migrados" \
  || bad "quedan subjects ajenos: $(jq -c '[.items[]|select(.metadata.name=="lectores-varios-dr")|.subjects[]]' <<< "$crb")"
yq -o=json '.' out/SMOKE/clean/location-resources-dr/14-rolebinding.yaml | grep -q 'system:image-puller-0' \
  && bad "se migró un RoleBinding autogenerado numerado" \
  || ok "los RoleBindings autogenerados numerados no se migran"
grep -q 'gts-core-rb .* gts-core .* EXTERNO' out/SMOKE/reports/cross-namespace.txt \
  && ok "una SA de otra aplicación se marca EXTERNO, no como fallo" \
  || bad "no se clasificó como EXTERNO la concesión a otra aplicación"
salida=$(URL_MAP_FILE=tests/url-map-test.txt ./sanba-dr-migrate.sh transform --run SMOKE 2>&1)
grep -q "FAIL.*gts-core\|FAIL.*openshift-pipelines" <<< "$salida" \
  && bad "las referencias ajenas siguen contando como fallo" \
  || ok "las referencias ajenas ya no generan fallos"

# Validación en caliente (contra el oc simulado)
salida=$(./sanba-dr-migrate.sh validate --run SMOKE 2>&1)
grep -q 'config.location-resources-dr.svc resuelve y tiene endpoints' <<< "$salida" \
  && ok "validate comprueba que el backend alcanza la config de location-resources-dr" \
  || bad "validate no verificó la dependencia con location-resources-dr"
grep -q 'rolebinding/core-can-read concede acceso a sanba-core-sa de sanba-core-dr' <<< "$salida" \
  && ok "validate comprueba el RBAC cruzado en el clúster" || bad "validate no verificó el RBAC cruzado"
grep -q 'networkpolicy/allow-app selecciona correctamente' <<< "$salida" \
  && ok "validate comprueba los selectores de NetworkPolicy" || bad "validate no verificó las NetworkPolicies"

head_ "Fijado de imágenes por digest"
rm -rf out/SMOKE; python3 tests/fixtures.py out/SMOKE >/dev/null
./sanba-dr-migrate.sh transform --run SMOKE >/dev/null 2>&1
awk -F'\t' '$7=="si"' out/SMOKE/image-map.tsv | grep -q 'sanba-gui-dr' \
  && ok "el registry interno se marca para mirror" || bad "no se detectó la imagen interna"
awk -F'\t' '$7=="no"' out/SMOKE/image-map.tsv | grep -q 'registry.redhat.io' \
  && ok "el catálogo Red Hat se fija sin mirror" || bad "no se fijó la imagen de catálogo"
img=$(yq -o=json '.' out/SMOKE/clean/sanba-gui-dr/50-deployment.yaml | jq -r '.items[].spec.template.spec.containers[0].image')
[[ "$img" == *"/sanba-gui-dr/"*"@sha256:"* ]] \
  && ok "el manifiesto apunta al registry de DR por digest" || bad "manifiesto sin fijar: $img"
img=$(yq -o=json '.' out/SMOKE/clean/sanba-data-persistence-dr/50-deploymentconfig.yaml | jq -r '.items[].spec.template.spec.containers[0].image')
[[ "$img" == *"@sha256:"* ]] && ok "la imagen de catálogo queda por digest" || bad "sigue por tag: $img"
trig=$(yq -o=json '.' out/SMOKE/clean/sanba-data-persistence-dr/50-deploymentconfig.yaml | jq -r '[.items[].spec.triggers[]?.type] | join(",")')
[[ -z "$trig" ]] && ok "disparadores ImageChange eliminados" || bad "queda un disparador: $trig"
grep -q 'skopeo copy --all' out/SMOKE/mirror-commands.sh \
  && grep -q '@sha256:' out/SMOKE/mirror-commands.sh \
  && ok "mirror-commands.sh copia por digest" || bad "mirror-commands.sh incorrecto"
grep -q -- '--src-tls-verify=false --dest-tls-verify=false' out/SMOKE/mirror-commands.sh \
  && ok "los skopeo copy llevan los flags de TLS desactivado" || bad "faltan los flags de TLS"
grep -q -- '--insecure' out/SMOKE/mirror-commands.sh \
  && ok "oc registry login lleva --insecure" || bad "falta --insecure en el login"

head_ "La carga de datos es una fase aparte"
rm -rf out/SMOKE; python3 tests/fixtures.py out/SMOKE >/dev/null
./sanba-dr-migrate.sh transform --run SMOKE >/dev/null 2>&1
salida=$(./sanba-dr-migrate.sh apply --run SMOKE 2>&1)
grep -q 'FASE DB-MIGRATE' <<< "$salida" \
  && bad "'apply' sigue encadenando la carga de datos" || ok "'apply' ya no carga datos"
grep -q 'db-migrate --run SMOKE' <<< "$salida" \
  && ok "'apply' indica cuál es el siguiente paso" || bad "'apply' no indica el siguiente paso"
salida=$(./sanba-dr-migrate.sh apply --run SMOKE --with-db 2>&1)
grep -q 'FASE DB-MIGRATE' <<< "$salida" \
  && ok "--with-db recupera el encadenado" || bad "--with-db no encadena"
salida=$(./sanba-dr-migrate.sh restart --run SMOKE 2>&1)
grep -q 'sanba-data-persistence-dr: no se reinicia' <<< "$salida" \
  && ok "'restart' no toca el namespace de la base de datos" || bad "'restart' reinicia la base de datos"
grep -q 'rollout latest deploymentconfig/' <<< "$salida" \
  && ok "los DeploymentConfig se relanzan con 'rollout latest'" || bad "DeploymentConfig mal reiniciado"
./sanba-dr-migrate.sh --help | grep -q 'apply -> db-migrate -> restart -> validate' \
  && ok "la ayuda documenta el orden correcto" || bad "la ayuda no documenta el orden"

head_ "db-migrate de extremo a extremo"
rm -rf out/SMOKE; mkdir -p out/SMOKE/reports out/SMOKE/db
salida=$(./sanba-dr-migrate.sh db-migrate --run SMOKE 2>&1)
grep -qi 'syntax error\|orden no encontrada\|command not found' <<< "$salida" \
  && bad "errores de ejecución en db-migrate" || ok "sin errores de ejecución"
grep -q 'Conteo de filas idéntico' <<< "$salida" && ok "dump, restore y verificación" || bad "el flujo de datos no completó"
grep -q "rol de volcado: postgres-local" <<< "$salida" \
  && ok "escala al superusuario por socket local" || bad "no escaló de rol"

head_ "Recarga de una base de datos que ya tiene datos"
rm -rf out/SMOKE; mkdir -p out/SMOKE/reports out/SMOKE/db
salida=$(MOCK_DB_TABLES=42 ./sanba-dr-migrate.sh db-migrate --run SMOKE < /dev/null 2>&1)
grep -q 'no se autorizó recargarla' <<< "$salida" \
  && ok "sin autorización no se toca una BD con datos" || bad "recargó sin autorización"
grep -q -- '--reload-db' <<< "$salida" \
  && ok "explica cómo recargarla" || bad "no ofrece la recarga"
salida=$(MOCK_DB_TABLES=42 ./sanba-dr-migrate.sh db-migrate --run SMOKE --reload-db < /dev/null 2>&1)
grep -q 'se RECARGA la base de datos' <<< "$salida" \
  && ok "--reload-db recarga sobre los datos existentes" || bad "--reload-db no recargó"
grep -q 'pg_restore --clean --if-exists' <<< "$salida" \
  && ok "la recarga usa pg_restore --clean --if-exists" || bad "recarga sin --clean"
grep -q 'Conteo de filas idéntico' <<< "$salida" \
  && ok "la recarga termina verificando el conteo de filas" || bad "la recarga no verificó"
salida=$(MOCK_DB_TABLES=0 ./sanba-dr-migrate.sh db-migrate --run SMOKE < /dev/null 2>&1)
# El mensaje "(sin --clean, no borra nada)" también contiene la palabra: hay que
# buscar los flags tal y como se le pasan a pg_restore.
grep -q -- 'pg_restore --clean --if-exists' <<< "$salida" \
  && bad "usa --clean con la BD vacía" || ok "con la BD vacía no se pasa --clean"

head_ "El guardarraíl de producción bloquea escrituras"
for verbo in delete apply scale patch "adm policy"; do
  salida=$(bash -c 'source ./sanba-dr.env; source lib/common.sh; oc_src '"$verbo"' x 2>&1' || true)
  grep -q 'BLOQUEADO' <<< "$salida" && ok "oc $verbo bloqueado" || bad "oc $verbo NO bloqueado"
done

rm -rf out/SMOKE tests/oc
printf '\n%s\n' "----------------------------------------"
printf 'Correctas: %s   Fallidas: %s\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
