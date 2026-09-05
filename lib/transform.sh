#!/usr/bin/env bash
# lib/transform.sh — saneo de manifiestos, renombrado de namespace y reescritura de Routes.
# Trabaja solo sobre archivos locales: no toca ningún clúster.
# shellcheck shell=bash

# --- mapas auxiliares como JSON para jq -------------------------------------
ns_map_json() {
  local s d out='{}'
  for s in $NS_ORDER; do
    d="$(ns_dst "$s")"
    out=$(jq -c --arg k "$s" --arg v "$d" '. + {($k):$v}' <<< "$out")
  done
  printf '%s' "$out"
}

sc_map_json() {
  local pair out='{}'
  for pair in $STORAGE_CLASS_MAP; do
    out=$(jq -c --arg k "${pair%%:*}" --arg v "${pair#*:}" '. + {($k):$v}' <<< "$out")
  done
  printf '%s' "$out"
}

route_map_json() {
  local out='{}' h1 h2
  if [[ -r "$ROOT/$ROUTE_MAP_FILE" ]]; then
    while read -r h1 h2; do
      [[ -z "$h1" || "$h1" == \#* || -z "${h2:-}" ]] && continue
      out=$(jq -c --arg k "$h1" --arg v "$h2" '. + {($k):$v}' <<< "$out")
    done < "$ROOT/$ROUTE_MAP_FILE"
  fi
  printf '%s' "$out"
}

# ===========================================================================
#  Mapa de URLs
#
#  El renombrado de namespace arregla las URLs INTERNAS
#  (postgresql.sanba-data-persistence.svc -> ...-dr.svc), pero no las EXTERNAS:
#  un ConfigMap que apunta a https://sanba-gui-sanba-gui.apps.prod.example.com
#  seguiría llamando a producción desde el entorno de contingencia.
#
#  Aquí se construye la tabla de sustituciones literales que se aplica al
#  contenido de ConfigMaps, Secrets, env, args y command, en este orden:
#
#    1. url-map.txt          — pares explícitos <origen> <destino> (lo que tú mandes)
#    2. hosts de las Routes  — host en PROD -> host que tendrá la Route en DR
#    3. apps-domain          — .apps.<prod> -> .apps.<preprod>, como red de seguridad
#
#  Se aplica siempre la coincidencia MÁS LARGA primero, para que un host
#  concreto gane sobre el dominio genérico que lo contiene.
# ===========================================================================

# Host que tendrá en contingencia la Route <name> del namespace <s>, con la
# MISMA regla que aplica el programa jq a .spec.host. Vacío = no deducible.
route_host_dst() {
  local name="$1" host="$2" d="$3" srcdom="$4" dstdom="$5" mapped
  [[ -z "$host" || "$host" == "null" ]] && return 0
  mapped=$(awk -v h="$host" '$1==h && $2!="" {print $2; exit}' "$RUN/.route-map.txt" 2>/dev/null)
  if [[ -n "$mapped" ]]; then printf '%s' "$mapped"; return 0; fi
  if [[ "$host" == *".$srcdom" ]]; then printf '%s' "${name}-${d}.${dstdom}"; return 0; fi
  return 0
}

# Genera out/<run>/url-map.tsv:  <origen> <TAB> <destino> <TAB> <procedencia>
build_url_map() {
  step "Mapa de URLs de los componentes"
  local srcdom dstdom s d name host new n_expl=0 n_route=0 n_custom=0
  srcdom="$(cat "$RUN/domain-src.txt")"; dstdom="$(cat "$RUN/domain-dst.txt")"

  # route-map.txt normalizado (sin comentarios) para route_host_dst
  : > "$RUN/.route-map.txt"
  if [[ -r "$ROOT/$ROUTE_MAP_FILE" ]]; then
    grep -vE '^[[:space:]]*(#|$)' "$ROOT/$ROUTE_MAP_FILE" >> "$RUN/.route-map.txt" || true
  fi

  local tmp="$RUN/.url-map.raw"; : > "$tmp"
  : > "$RUN/.url-unmapped.txt"

  # 1. pares explícitos
  if [[ -r "$ROOT/${URL_MAP_FILE:-url-map.txt}" ]]; then
    while read -r from to _rest; do
      [[ -z "${from:-}" || "$from" == \#* || -z "${to:-}" ]] && continue
      printf '%s\t%s\t%s\n' "$from" "$to" "url-map" >> "$tmp"
      n_expl=$((n_expl+1))
    done < "$ROOT/${URL_MAP_FILE:-url-map.txt}"
  fi

  # 2. hosts de las Routes exportadas de producción
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    [[ -r "$RAW/$s/route.json" ]] || continue
    while IFS=$'\t' read -r name host; do
      [[ -z "${name:-}" || -z "${host:-}" || "$host" == "null" ]] && continue
      new="$(route_host_dst "$name" "$host" "$d" "$srcdom" "$dstdom")"
      if [[ -n "$new" ]]; then
        printf '%s\t%s\t%s\n' "$host" "$new" "route" >> "$tmp"
        n_route=$((n_route+1))
      else
        # Host custom sin equivalente: el router asignará uno en DR, así que no
        # se puede reescribir la referencia. Queda como pendiente explícito.
        n_custom=$((n_custom+1))
        printf '%s\n' "$host" >> "$RUN/.url-unmapped.txt"
        warn "$d/$name: el host '$host' no sigue el patrón del apps-domain y no está en $ROUTE_MAP_FILE"
        todo "$d/$name: define el destino de '$host' en ${URL_MAP_FILE:-url-map.txt} o en $ROUTE_MAP_FILE; si no, los ConfigMaps/Secrets que lo mencionen seguirán apuntando a PRODUCCIÓN."
      fi
    done < <(jq -r '.items[] | [.metadata.name, (.spec.host // "")] | @tsv' < "$RAW/$s/route.json" 2>/dev/null)
  done

  # 3. apps-domain como red de seguridad para lo que no sea una Route nuestra
  if [[ "${REWRITE_APPS_DOMAIN:-true}" == true && -n "$srcdom" && "$srcdom" != "$dstdom" ]]; then
    printf '%s\t%s\t%s\n' "$srcdom" "$dstdom" "apps-domain" >> "$tmp"
  fi

  # Coincidencia más larga primero; se eliminan duplicados y sustituciones nulas.
  awk -F'\t' '$1 != "" && $1 != $2 && !seen[$1]++ { print length($1) "\t" $0 }' "$tmp" \
    | sort -k1,1nr -k2,2 | cut -f2- > "$RUN/url-map.tsv"
  rm -f "$tmp"

  local total; total=$(wc -l < "$RUN/url-map.tsv")
  log "  pares explícitos en ${URL_MAP_FILE:-url-map.txt}: $n_expl"
  log "  hosts de Route deducidos                      : $n_route"
  [[ "$n_custom" -gt 0 ]] && log "  hosts custom sin equivalente                  : $n_custom"
  [[ "${REWRITE_APPS_DOMAIN:-true}" == true && "$srcdom" != "$dstdom" ]] \
    && log "  apps-domain                                   : $srcdom -> $dstdom"
  awk -F'\t' '{printf "      %-52s -> %-52s (%s)\n", $1, $2, $3}' "$RUN/url-map.tsv" >&2
  ok "$total sustituciones de URL activas (mapa en $RUN/url-map.tsv)"
}

# Valores que NO deben tocarse, leídos de ns-rewrite-skip.txt.
#
# El renombrado de namespace trabaja sobre texto, y hay cadenas que son
# indistinguibles de un nombre de namespace pero significan otra cosa: el NOMBRE
# de un ConfigMap, de un Secret o de una aplicación. Un valor como
#   SPRING_CLOUD_KUBERNETES_CONFIG_NAME: location-resources
# apunta a un ConfigMap, no a un namespace: reescribirlo a
# 'location-resources-dr' hace que la aplicación busque un objeto que no existe.
# Este fichero es la lista de esas excepciones.
# Dos formatos por línea:
#   <valor>            -> se protege ese texto aparezca donde aparezca
#   <CLAVE>=<valor>    -> solo cuando es el valor de esa clave (o de esa
#                         variable de entorno); <CLAVE>=* protege cualquier valor
_skip_lines() {
  local f="$ROOT/${NS_REWRITE_SKIP_FILE:-ns-rewrite-skip.txt}" line
  [[ -r "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    printf '%s\n' "$line"
  done < "$f"
}

# Literales protegidos en cualquier sitio (líneas sin '=').
protect_json() {
  local out='[]' line
  while IFS= read -r line; do
    [[ "$line" == *=* ]] && continue
    out=$(jq -c --arg v "$line" '. + [$v]' <<< "$out")
  done < <(_skip_lines)
  printf '%s' "$out"
}

# Protecciones acotadas a una clave (líneas 'CLAVE=valor').
skipkv_json() {
  local out='[]' line
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    out=$(jq -c --arg k "${line%%=*}" --arg v "${line#*=}" '. + [{key:$k, value:$v}]' <<< "$out")
  done < <(_skip_lines)
  printf '%s' "$out"
}

# El mapa como array JSON ordenado, listo para --argjson.
url_map_json() {
  [[ -s "$RUN/url-map.tsv" ]] || { printf '[]'; return 0; }
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {from: .[0], to: .[1]})' \
    < "$RUN/url-map.tsv"
}

# --- programa jq principal --------------------------------------------------
build_jq_program() {
  local gsub_chain; gsub_chain="$(ns_jq_gsub)"
  cat <<JQEOF
# Sustitución literal (no regex) de cada par del mapa de URLs. El orden del
# array ya viene de más largo a más corto, así que un host concreto gana sobre
# el apps-domain que lo contiene.
def rewrite_urls:
  reduce \$urlmap[] as \$m (.; split(\$m.from) | join(\$m.to));

# Los valores de ns-rewrite-skip.txt se sustituyen por un centinela antes de
# reescribir nada y se restauran al final: así ninguna regla puede tocarlos.
# \u0001 no aparece en configuración de texto.
def proteger:
  reduce range(0; (\$protect | length)) as \$i
    (.; split(\$protect[\$i]) | join("\u0001" + (\$i | tostring) + "\u0001"));
def desproteger:
  reduce range(0; (\$protect | length)) as \$i
    (.; split("\u0001" + (\$i | tostring) + "\u0001") | join(\$protect[\$i]));

# Primero las URLs externas, después el renombrado de namespace: al revés, el
# renombrado partiría hosts como sanba-gui-sanba-gui.apps... por la mitad.
def rewrite_text:
  if type == "string" then (proteger | rewrite_urls | ${gsub_chain} | desproteger) else . end;

# Protección acotada a una clave: el mismo texto puede ser un namespace en una
# variable y el nombre de un ConfigMap en la de al lado.
def protegido(\$k; \$v):
  ([ \$skipkv[] | select((.key == \$k) and ((.value == "*") or (.value == \$v))) ] | length) > 0;

def rewrite_kv(\$k):
  . as \$v
  | if (\$k != null) and (type == "string") and protegido(\$k; \$v) then \$v else rewrite_text end;

# Reescribe un valor base64 solo si decodifica a texto UTF-8 que round-trippea
# (así nunca corrompemos claves privadas, keystores ni binarios) y solo si
# realmente menciona un namespace o una URL del mapa.
def rewrite_b64:
  . as \$orig
  | ((try (\$orig | @base64d) catch null)) as \$d
  | if (\$d != null) and ((\$d | @base64) == \$orig)
       and ((\$d | test(\$nsre))
            or ([\$urlmap[] | .from as \$f | select(\$d | contains(\$f))] | length > 0))
    then (\$d | rewrite_text | @base64)
    else \$orig
    end;

# Un namespaceSelector señala a OTRO namespace por su nombre o por la etiqueta
# kubernetes.io/metadata.name. Si no se traduce, en contingencia selecciona el
# namespace de PRODUCCIÓN —que allí no existe— y la NetworkPolicy deja fuera al
# tráfico legítimo entre los namespaces de la aplicación.
def fix_nssel:
  walk(
    if (type == "object") and (has("namespaceSelector")) and ((.namespaceSelector | type) == "object")
    then .namespaceSelector |= (
           (if .matchLabels then .matchLabels |= with_entries(.value |= (\$nsmap[.] // .)) else . end)
         | (if .matchExpressions then .matchExpressions |= map(
               if .values then .values |= map(\$nsmap[.] // .) else . end)
            else . end))
    else . end);

def rewrite_b64_kv(\$k):
  . as \$orig
  | ((try (\$orig | @base64d) catch null)) as \$d
  | if (\$d != null) and ((\$d | @base64) == \$orig) and (\$k != null) and protegido(\$k; \$d)
    then \$orig else rewrite_b64 end;

def sanitize:
  del(.metadata.uid, .metadata.resourceVersion, .metadata.generation,
      .metadata.creationTimestamp, .metadata.selfLink, .metadata.managedFields,
      .metadata.ownerReferences, .metadata.finalizers, .status)
  | (if .metadata.annotations then
       .metadata.annotations |= (
         del(."kubectl.kubernetes.io/last-applied-configuration",
             ."deployment.kubernetes.io/revision",
             ."openshift.io/generated-by",
             ."openshift.io/host.generated",
             ."autoscaling.alpha.kubernetes.io/conditions",
             ."autoscaling.alpha.kubernetes.io/current-metrics")
         | with_entries(select(.key | test("^(pv|volume)\\\\.(beta\\\\.)?kubernetes\\\\.io/") | not))
       )
     else . end)
  | (if (.metadata.annotations // {}) == {} then del(.metadata.annotations)
     else .metadata.annotations |= with_entries(.value |= rewrite_text) end);

def fix_container:
    (if .env      then .env      |= map(if has("value") then (.name as \$n | .value = (.value | rewrite_kv(\$n))) else . end) else . end)
  | (if .args     then .args     |= map(rewrite_text) else . end)
  | (if .command  then .command  |= map(rewrite_text) else . end);

def fix_podspec:
    (if .containers     then .containers     |= map(fix_container) else . end)
  | (if .initContainers then .initContainers |= map(fix_container) else . end);

def perkind:
  if .kind == "Service" then
      del(.spec.clusterIP, .spec.clusterIPs, .spec.ipFamilies, .spec.ipFamilyPolicy,
          .spec.healthCheckNodePort, .spec.loadBalancerIP, .spec.externalIPs)
    | (if .spec.ports then .spec.ports |= map(del(.nodePort)) else . end)
    # Un Service ExternalName es un alias DNS: si apunta a otro namespace de la
    # aplicación, en contingencia debe apuntar al -dr correspondiente.
    | (if (.spec.externalName // "") != "" then .spec.externalName |= rewrite_text else . end)

  elif .kind == "PersistentVolumeClaim" then
      del(.spec.volumeName, .spec.dataSource, .spec.dataSourceRef)
    | (if (.spec.storageClassName // "") != ""
       then .spec.storageClassName = (\$scmap[.spec.storageClassName] // .spec.storageClassName)
       else . end)

  elif .kind == "ServiceAccount" then
      del(.secrets)
    | (if .imagePullSecrets then
         .imagePullSecrets |= map(select(.name | test("-dockercfg-[a-z0-9]{5}\$") | not))
         | (if (.imagePullSecrets | length) == 0 then del(.imagePullSecrets) else . end)
       else . end)

  elif .kind == "Secret" then
      (if .data       then .data       |= with_entries(.key as \$k | .value = (.value | rewrite_b64_kv(\$k))) else . end)
    | (if .stringData then .stringData |= with_entries(.key as \$k | .value = (.value | rewrite_kv(\$k)))     else . end)

  elif .kind == "ConfigMap" then
      (if .data then .data |= with_entries(.key as \$k | .value = (.value | rewrite_kv(\$k))) else . end)

  elif (.kind == "RoleBinding") or (.kind == "ClusterRoleBinding") then
      (if .subjects then
         .subjects |= map(
           if (.kind == "ServiceAccount") and (.namespace != null)
           then .namespace = (\$nsmap[.namespace] // .namespace) else . end)
       else . end)
    | (if .userNames  then .userNames  |= map(rewrite_text) else . end)
    | (if .groupNames then .groupNames |= map(rewrite_text) else . end)

  elif .kind == "Route" then
      del(.status)
    | ((.spec.host // "") as \$h
       | if (\$routemap[\$h] // null) != null then
             .spec.host = \$routemap[\$h]
         elif (\$h != "") and (\$h | endswith("." + \$srcdom)) then
             .spec.host = (.metadata.name + "-" + \$dstns + "." + \$dstdom)
         elif \$h == "" then .
         elif \$custom == "generate" then del(.spec.host)
         else . end)
    | (if (\$tlsmode == "default") and (.spec.tls != null)
       then .spec.tls |= del(.certificate, .key, .caCertificate, .destinationCACertificate)
       else . end)

  elif (.kind | IN("Deployment","StatefulSet","DaemonSet","DeploymentConfig","Job")) then
      del(.spec.template.metadata.creationTimestamp)
    | (if .spec.template.metadata.annotations
       then .spec.template.metadata.annotations |= with_entries(.value |= rewrite_text) else . end)
    | (if .spec.triggers then .spec.triggers |= map(del(.imageChangeParams.lastTriggeredImage)) else . end)
    | (if .spec.template.spec then .spec.template.spec |= fix_podspec else . end)

  elif .kind == "CronJob" then
      del(.spec.jobTemplate.metadata.creationTimestamp,
          .spec.jobTemplate.spec.template.metadata.creationTimestamp)
    | (if .spec.jobTemplate.spec.template.spec
       then .spec.jobTemplate.spec.template.spec |= fix_podspec else . end)

  else . end;

# Descarta lo que el clúster destino genera por su cuenta.
def keep:
  if .kind == "Secret" then
    ((.type // "") | IN("kubernetes.io/service-account-token","kubernetes.io/dockercfg") | not)
    and ((.metadata.annotations // {}) | has("service.beta.openshift.io/originating-service-name") | not)
    and ((.metadata.annotations // {}) | has("service.alpha.openshift.io/originating-service-name") | not)
  elif .kind == "ConfigMap" then
    (.metadata.name | IN("kube-root-ca.crt","openshift-service-ca.crt") | not)
  elif .kind == "ServiceAccount" then
    # 'default', 'builder' y 'deployer' ya existen en el destino con sus propios
    # secrets autogenerados: aplicarlas los destruiría. La 'default' se reconcilia
    # con un patch en apply.sh.
    (.metadata.name | IN("default","builder","deployer") | not)
  elif .kind == "RoleBinding" then
    # OpenShift crea estos RoleBindings solo en cada namespace nuevo. Copiar el
    # 'admin' de producción daría permisos de administrador sobre el namespace de
    # contingencia a los dueños del proyecto de producción.
    # OpenShift numera estos bindings cuando hay más de uno: system:image-puller-0
    (\$keeprb == "true")
    or (.metadata.name
        | test("^(admin|system:(deployers?|image-builders?|image-pullers?)(-[0-9]+)?)\$") | not)
  else true end;

{ apiVersion: "v1", kind: "List",
  items: [ .items[]
           | select(keep)
           | sanitize
           | .metadata.namespace = \$dstns
           | perkind
           | fix_nssel ] }
JQEOF
}

# --- namespaces -------------------------------------------------------------
tf_namespaces() {
  step "Namespaces"
  local s d f
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    f="$RAW/_cluster/ns-$s.json"
    [[ -r "$f" ]] || { warn "No hay export del namespace $s"; continue; }
    # Las annotations de UID/MCS range las regenera el clúster destino; copiarlas
    # deja pods que no arrancan por SELinux/UID fuera de rango.
    jq --arg d "$d" '
      { apiVersion:"v1", kind:"Namespace",
        metadata: {
          name: $d,
          labels: ((.metadata.labels // {}) | with_entries(select(.key | startswith("kubernetes.io/metadata.name") | not))),
          annotations: ((.metadata.annotations // {})
                        | del(."openshift.io/sa.scc.uid-range",
                              ."openshift.io/sa.scc.mcs",
                              ."openshift.io/sa.scc.supplemental-groups",
                              ."openshift.io/requester",
                              ."kubectl.kubernetes.io/last-applied-configuration"))
        } }' < "$f" | to_manifest > "$CLEAN/_cluster/00-namespace-$d.$MANIFEST_EXT"
    ok "$s -> $d"
  done
}

# --- recursos por namespace -------------------------------------------------
tf_namespaced() {
  local s d kind in out prog n
  prog="$(build_jq_program)"
  local nsmap scmap routemap nsre srcdom dstdom urlmap protect skipkv
  nsmap="$(ns_map_json)"; scmap="$(sc_map_json)"; routemap="$(route_map_json)"
  urlmap="$(url_map_json)"; protect="$(protect_json)"; skipkv="$(skipkv_json)"
  nsre="$(ns_match_regex)"
  srcdom="$(cat "$RUN/domain-src.txt")"; dstdom="$(cat "$RUN/domain-dst.txt")"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    mkdir -p "$CLEAN/$d"
    step "Transformando $s -> $d"
    for kind in $EXPORT_KINDS_APPLY; do
      in="$RAW/$s/$(kind_file "$kind").json"
      [[ -r "$in" ]] || continue
      out="$CLEAN/$d/$(kind_order "$kind")-$(kind_file "$kind").$MANIFEST_EXT"
      jq --arg dstns "$d" --arg srcns "$s" \
         --argjson nsmap "$nsmap" --argjson scmap "$scmap" --argjson routemap "$routemap" \
         --argjson urlmap "$urlmap" --argjson protect "$protect" --argjson skipkv "$skipkv" \
         --arg nsre "$nsre" --arg srcdom "$srcdom" --arg dstdom "$dstdom" \
         --arg tlsmode "$ROUTE_TLS_STRATEGY" --arg custom "$ROUTE_CUSTOM_STRATEGY" \
         --arg keeprb "${MIGRATE_DEFAULT_ROLEBINDINGS:-false}" \
         "$prog" < "$in" > "$RUN/.tmp.json" \
        || die "jq falló transformando $s/$kind"

      n=$(jq '.items | length' < "$RUN/.tmp.json")
      if [[ "$n" == "0" ]]; then
        vlog "$d/$kind: todo descartado"
        continue
      fi
      to_manifest < "$RUN/.tmp.json" > "$out"
      log "  $d/$kind: $n"
    done
  done
  rm -f "$RUN/.tmp.json"
}

# --- auditoría de reescrituras de namespace ---------------------------------
tf_report_rewrites() {
  step "Auditoría de reescrituras de namespace"
  local s d f name kind changed=0
  {
    echo "Reescrituras de nombre de namespace dentro del CONTENIDO de ConfigMaps y Secrets."
    echo "Solo se listan objeto y clave; nunca el valor."
    echo
  } > "$REPORTS/ns-rewrites.txt"

  local nsre; nsre="$(ns_match_regex)"
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    for kind in configmap secret; do
      f="$RAW/$s/$kind.json"
      [[ -r "$f" ]] || continue
      while IFS=$'\t' read -r name key; do
        [[ -z "$name" ]] && continue
        printf '%s\t%s/%s\tclave=%s\n' "$d" "$kind" "$name" "$key" >> "$REPORTS/ns-rewrites.txt"
        changed=$((changed+1))
      done < <(jq -r --arg re "$nsre" '
          .items[]
          | .metadata.name as $n
          | ( (.data // {}) | to_entries[]
              | . as $e
              | (if ($e.value | test("^[A-Za-z0-9+/]*={0,2}$")) and ((try ($e.value|@base64d) catch null) != null)
                 then (try ($e.value|@base64d) catch "") else $e.value end) as $plain
              | select($plain | test($re))
              | [$n, $e.key] | @tsv )' < "$f" 2>/dev/null)
      done
  done
  log "  $changed claves contenían un nombre de namespace y fueron reescritas"

  # --- valores AMBIGUOS ------------------------------------------------------
  # Un valor que es EXACTAMENTE el nombre de un namespace puede significar dos
  # cosas: el namespace (hay que reescribirlo) o el nombre de un objeto que se
  # llama igual (no hay que tocarlo, porque los objetos conservan su nombre).
  # Si existe un objeto migrado con ese nombre, la ambigüedad es real y la tiene
  # que resolver una persona.
  local objetos="$RUN/.objetos-por-ns.tsv"; : > "$objetos"
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    clean_items "$d" | jq -r --arg d "$d" '.[] | [$d, .kind, .metadata.name] | @tsv' >> "$objetos"
  done

  local nsre_exact ambiguos=0 valor coincide
  nsre_exact="^($(printf '%s' "$NS_ORDER" | tr ' ' '|'))\$"
  {
    echo
    echo "Valores que son EXACTAMENTE un nombre de namespace."
    echo "AMBIGUO = existe además un objeto migrado con ese mismo nombre: comprueba si el"
    echo "valor se refiere al namespace (correcto reescribirlo) o al objeto (hay que"
    echo "protegerlo en ${NS_REWRITE_SKIP_FILE:-ns-rewrite-skip.txt})."
    echo
    printf '%-26s %-34s %-34s %-20s %s\n' "NAMESPACE(DR)" "OBJETO" "CLAVE" "VALOR" "ESTADO"
    printf '%s\n' "----------------------------------------------------------------------------------------------------------------------------"
  } >> "$REPORTS/ns-rewrites.txt"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r kind name key valor; do
      [[ -z "${valor:-}" ]] && continue
      coincide=$(awk -F'\t' -v x="$valor" '$3==x {printf "%s%s/%s", sep, $1, $2; sep=","}' "$objetos")
      if [[ -n "$coincide" ]]; then
        ambiguos=$((ambiguos+1))
        printf '%-26s %-34s %-34s %-20s %s\n' "$d" "$kind/$name" "$key" "$valor" "AMBIGUO -> $coincide" \
          >> "$REPORTS/ns-rewrites.txt"
        warn "$d: $kind/$name clave '$key' vale '$valor', que también es el nombre de un objeto ($coincide)"
        todo "$d: $kind/$name clave '$key' vale '$valor'. Si se refiere al OBJETO y no al namespace, añádelo a ${NS_REWRITE_SKIP_FILE:-ns-rewrite-skip.txt} y repite 'transform': si no, la aplicación buscará '$(ns_dst "$valor")' y no lo encontrará."
      else
        printf '%-26s %-34s %-34s %-20s %s\n' "$d" "$kind/$name" "$key" "$valor" "namespace" \
          >> "$REPORTS/ns-rewrites.txt"
      fi
    done < <(
      for kind in configmap secret; do
        [[ -r "$RAW/$s/$kind.json" ]] || continue
        jq -r --arg re "$nsre_exact" --arg k "$kind" '
          .items[] | .metadata.name as $n
          | ((.data // {}) | to_entries[]) | . as $e
          | (if $k == "secret" then ((try ($e.value | @base64d) catch "") // "") else ($e.value // "") end) as $v
          | select($v | test($re))
          | [$k, $n, $e.key, $v] | @tsv' < "$RAW/$s/$kind.json" 2>/dev/null
      done
      for kind in deployment deploymentconfig statefulset daemonset cronjob; do
        [[ -r "$RAW/$s/$kind.json" ]] || continue
        jq -r --arg re "$nsre_exact" --arg k "$kind" '
          .items[] | .metadata.name as $n
          | ((.spec.template.spec // .spec.jobTemplate.spec.template.spec // {})) as $ps
          | (($ps.containers // []) + ($ps.initContainers // []))[]
          | ((.env // [])[] | select(has("value")))
          | select(.value | test($re))
          | [$k, $n, ("env/" + .name), .value] | @tsv' < "$RAW/$s/$kind.json" 2>/dev/null
      done | sort -u)
  done

  if (( ambiguos > 0 )); then
    warn "$ambiguos valores son ambiguos: revisa la segunda tabla de $REPORTS/ns-rewrites.txt"
  fi
  ok "Detalle en $REPORTS/ns-rewrites.txt"
}

# --- SCC y bindings cluster-scoped ------------------------------------------
tf_cluster_bindings() {
  step "SCC y ClusterRoleBindings"
  local nsmap; nsmap="$(ns_map_json)"

  # Asignaciones de SCC -> TSV:  scc <TAB> ns_destino <TAB> serviceaccount <TAB> origen
  # El origen importa: las que vienen de un RoleBinding namespaced ya se migran
  # como manifiesto, así que 'apply' no debe volver a concederlas.
  #
  # Cada fuente es opcional: un export hecho con una versión anterior del script
  # puede no tener todos los ficheros, y eso no debe abortar la transformación.
  _scc_source() {
    local file="$1" prog="$2"
    if [[ ! -r "$file" ]]; then
      vlog "  fuente de SCC ausente: $(basename "$file") (export de una versión anterior)"
      return 0
    fi
    jq -r --argjson m "$nsmap" "$prog" < "$file" 2>/dev/null || true
  }

  {
    _scc_source "$RAW/_cluster/scc-crb.json" '
      .[] | .scc as $scc | .subjects[]
      | [$scc, ($m[.namespace] // .namespace), .name, "clusterrolebinding"] | @tsv'
    _scc_source "$RAW/_cluster/scc-rb.json" '
      .[] | .scc as $scc | .subjects[]
      | [$scc, ($m[.namespace] // .namespace), .name, "rolebinding"] | @tsv'
    _scc_source "$RAW/_cluster/scc-users.json" '
      .[] | .scc as $scc | .users[]
      | split(":") | select(length == 4)
      | [$scc, ($m[.[2]] // .[2]), .[3], "scc.users"] | @tsv'
  } | sort -u > "$CLEAN/_cluster/scc-assignments.tsv"

  # Si falta scc-rb.json, las SCC concedidas por RoleBinding namespaced no
  # aparecen en el inventario. El RoleBinding sí se migra igualmente (va en
  # 14-rolebinding), pero conviene rehacer el export para que el informe y la
  # validación estén completos.
  if [[ ! -r "$RAW/_cluster/scc-rb.json" ]]; then
    warn "Este export es de una versión anterior del script: falta scc-rb.json"
    todo "Vuelve a ejecutar 'export' (es de solo lectura) para que el inventario de SCC quede completo."
  fi

  local n; n=$(wc -l < "$CLEAN/_cluster/scc-assignments.tsv")
  log "  Asignaciones de SCC detectadas: $n"
  [[ "$n" -gt 0 ]] && awk -F'\t' '{printf "    %-16s %-28s %-24s (via %s)\n", $1, $2, $3, $4}' \
      "$CLEAN/_cluster/scc-assignments.tsv" >&2

  # ClusterRoleBindings normales: se renombran con el sufijo de DR para no pisar
  # bindings preexistentes del clúster de pre-producción.
  #
  # El export recoge todo ClusterRoleBinding que tenga AL MENOS UN subject en
  # nuestros namespaces, y esos bindings suelen ser de ámbito de clúster: el de
  # openshift-pipelines, por ejemplo, lista la ServiceAccount 'pipeline' de
  # decenas de namespaces. Copiarlo tal cual a pre-producción concedería
  # permisos de clúster a namespaces que no tienen nada que ver con el drill.
  # Por eso aquí se hacen dos cosas:
  #
  #   1. Se descartan los bindings con ownerReferences: son de un operador, que
  #      los recrea por su cuenta en pre-producción.
  #   2. De los demás solo se conservan los subjects que están en NUESTROS
  #      namespaces. El resto se descarta y se informa.
  if [[ -r "$RAW/_cluster/clusterrolebinding.json" ]] \
     && [[ "$(jq '.items | length' < "$RAW/_cluster/clusterrolebinding.json")" != "0" ]]; then

    local crb_name crb_owner
    while IFS=$'\t' read -r crb_name crb_owner; do
      [[ -z "${crb_name:-}" ]] && continue
      warn "ClusterRoleBinding/$crb_name lo gestiona el operador '$crb_owner': no se copia"
      todo "ClusterRoleBinding/$crb_name es propiedad de '$crb_owner'. El operador debe estar instalado en pre-producción; él recreará el binding."
    done < <(jq -r '.items[] | select((.metadata.ownerReferences // []) | length > 0)
                    | [.metadata.name, (.metadata.ownerReferences[0].kind + "/" + .metadata.ownerReferences[0].name)] | @tsv' \
             < "$RAW/_cluster/clusterrolebinding.json")

    local dropped
    while IFS=$'\t' read -r crb_name dropped; do
      [[ -z "${crb_name:-}" || "${dropped:-0}" == "0" ]] && continue
      log "  ClusterRoleBinding/$crb_name: se descartan $dropped subjects de namespaces ajenos a la migración"
    done < <(jq -r --argjson m "$nsmap" '
        .items[] | select((.metadata.ownerReferences // []) | length == 0)
        | [ .metadata.name,
            ([ (.subjects // [])[] | select((.kind != "ServiceAccount") or ($m[.namespace] == null)) ] | length | tostring)
          ] | @tsv' < "$RAW/_cluster/clusterrolebinding.json")

    jq --argjson m "$nsmap" --arg sfx "$DR_SUFFIX" '
      { apiVersion:"v1", kind:"List", items:
        [ .items[]
          # los de un operador se quedan fuera: los recrea él en pre-producción
          | select((.metadata.ownerReferences // []) | length == 0)
          # solo los subjects de los namespaces que estamos migrando
          | ([ (.subjects // [])[]
               | select(.kind == "ServiceAccount")
               | select($m[.namespace] != null)
               | .namespace = $m[.namespace] ]) as $subs
          | select($subs | length > 0)
          | del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
                .metadata.managedFields, .metadata.selfLink, .metadata.ownerReferences, .status)
          | .metadata.name = (.metadata.name + $sfx)
          | .subjects = $subs
          | del(.userNames, .groupNames)
        ] }' < "$RAW/_cluster/clusterrolebinding.json" \
      | to_manifest > "$CLEAN/_cluster/80-clusterrolebinding.$MANIFEST_EXT"

    local kept; kept=$(read_manifest "$CLEAN/_cluster/80-clusterrolebinding.$MANIFEST_EXT" | jq '.items | length')
    if [[ "$kept" == "0" ]]; then
      # Sin manifiesto: una List vacía haría fallar a 'oc apply' en la fase apply.
      rm -f "$CLEAN/_cluster/80-clusterrolebinding.$MANIFEST_EXT"
      log "  Ningún ClusterRoleBinding que copiar: todos son de un operador o no tienen subjects en los namespaces migrados"
    else
      log "  ClusterRoleBindings copiados con sufijo ${DR_SUFFIX}: $kept (solo con subjects de los namespaces migrados)"
    fi
  fi
  ok "Bindings preparados"
}

# --- ServiceAccounts: inventario y verificación cruzada ---------------------
tf_serviceaccounts() {
  step "ServiceAccounts"
  local s d sas used missing=0
  {
    printf '%-28s %-26s %-22s %s\n' "NAMESPACE(DR)" "SERVICEACCOUNT" "SCC" "USADA POR"
    printf '%s\n' "--------------------------------------------------------------------------------------------"
  } > "$REPORTS/serviceaccounts.txt"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"

    # SAs disponibles en destino = las que migramos + la 'default' que ya existe
    sas=$( { clean_items "$d" serviceaccount | jq -r '.[].metadata.name'; echo default; } | sort -u )

    # SAs referenciadas por los workloads
    used=$(clean_items "$d" | jq -r '
      .[]
      | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // {}) as $ps
      | ($ps.serviceAccountName // $ps.serviceAccount // empty)' | sort -u)

    local sa scc who
    while read -r sa; do
      [[ -z "$sa" ]] && continue
      scc=$(awk -F'\t' -v n="$d" -v a="$sa" '$2==n && $3==a {printf "%s%s", sep, $1; sep=","}' "$CLEAN/_cluster/scc-assignments.tsv")
      who=$(clean_items "$d" | jq -r --arg sa "$sa" '
        .[]
        | (.spec.template.spec // .spec.jobTemplate.spec.template.spec) as $ps
        | select($ps != null)
        | select(($ps.serviceAccountName // $ps.serviceAccount // "default") == $sa)
        | .kind + "/" + .metadata.name' | paste -sd, -)
      printf '%-28s %-26s %-22s %s\n' "$d" "$sa" "${scc:--}" "${who:--}" >> "$REPORTS/serviceaccounts.txt"
    done <<< "$sas"

    # imagePullSecrets creados a mano en la SA 'default' de PROD: se reconcilian
    # con un patch en el destino en lugar de aplicar el objeto entero.
    jq -r '.items[]
           | select(.metadata.name == "default")
           | (.imagePullSecrets // [])[].name
           | select(test("-dockercfg-[a-z0-9]{5}$") | not)' \
       < "$RAW/$s/serviceaccount.json" 2>/dev/null | sort -u > "$CLEAN/$d/default-sa-pullsecrets.txt" || true

    # Verificación cruzada: ningún workload puede apuntar a una SA inexistente
    while read -r sa; do
      [[ -z "$sa" ]] && continue
      if ! grep -qxF "$sa" <<< "$sas"; then
        err "$d: el workload referencia la ServiceAccount '$sa', que no se exportó"
        missing=$((missing+1))
      fi
    done <<< "$used"
  done

  if (( missing > 0 )); then
    die "$missing ServiceAccounts referenciadas no existen. Un pod con SA inexistente arranca con permisos equivocados."
  fi
  ok "Inventario en $REPORTS/serviceaccounts.txt; todas las referencias resuelven"
}

# --- ConfigMaps y Secrets: inventario y referencias -------------------------
tf_config_refs() {
  step "ConfigMaps y Secrets"
  local s d have_cm have_sec kind name miss=0 refs
  {
    printf '%-26s %-10s %-34s %-7s %s\n' "NAMESPACE(DR)" "KIND" "NOMBRE" "CLAVES" "CONSUMIDO POR"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------"
  } > "$REPORTS/config.txt"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    have_cm=$(clean_items "$d" configmap | jq -r '.[].metadata.name' | sort -u)
    have_sec=$(clean_items "$d" secret    | jq -r '.[].metadata.name' | sort -u)

    # Referencias desde los workloads:  KIND <TAB> NOMBRE <TAB> WORKLOAD
    refs="$RUN/.refs-$d.tsv"
    clean_items "$d" | jq -r '
      .[]
      | (.kind + "/" + .metadata.name) as $w
      | (.spec.template.spec // .spec.jobTemplate.spec.template.spec) as $ps
      | select($ps != null)
      | ( [ ( ($ps.containers // []) + ($ps.initContainers // []) )[]
            | ( (.envFrom // [])[]
                | (if .configMapRef then ["ConfigMap", .configMapRef.name]
                   elif .secretRef  then ["Secret",    .secretRef.name]
                   else empty end) ),
              ( (.env // [])[] | (.valueFrom // {})
                | (if .configMapKeyRef then ["ConfigMap", .configMapKeyRef.name]
                   elif .secretKeyRef  then ["Secret",    .secretKeyRef.name]
                   else empty end) )
          ]
          + [ ($ps.volumes // [])[]
              | (if .configMap then ["ConfigMap", .configMap.name]
                 elif .secret then ["Secret", .secret.secretName]
                 elif .projected then ( (.projected.sources // [])[]
                        | if .configMap then ["ConfigMap", .configMap.name]
                          elif .secret  then ["Secret",    .secret.name]
                          else empty end )
                 else empty end) ]
          + [ ($ps.imagePullSecrets // [])[] | ["Secret", .name] ]
        )[]
      | . + [$w] | @tsv' | sort -u > "$refs"

    # Inventario: nombre, tipo, nº de claves y quién lo consume. Nunca valores.
    local pat consumers nkeys
    for kind in ConfigMap Secret; do
      [[ "$kind" == ConfigMap ]] && pat=configmap || pat=secret
      while IFS=$'\t' read -r name nkeys; do
        [[ -z "${name:-}" ]] && continue
        consumers=$(awk -F'\t' -v k="$kind" -v n="$name" '$1==k && $2==n {print $3}' "$refs" | sort -u | paste -sd, -)
        printf '%-26s %-10s %-34s %-7s %s\n' "$d" "$kind" "$name" "$nkeys" "${consumers:--}" >> "$REPORTS/config.txt"
      done < <(clean_items "$d" "$pat" | jq -r '.[] | [.metadata.name, ((.data // {}) | keys | length | tostring)] | @tsv')
    done

    # Toda referencia debe resolver, o el pod se queda en CreateContainerConfigError
    while IFS=$'\t' read -r kind name _w; do
      [[ -z "${name:-}" ]] && continue
      # inyectados por el propio clúster destino
      [[ "$name" == "kube-root-ca.crt" || "$name" == "openshift-service-ca.crt" ]] && continue
      if [[ "$kind" == ConfigMap ]]; then
        grep -qxF "$name" <<< "$have_cm" && continue
      else
        grep -qxF "$name" <<< "$have_sec" && continue
        # los pull secrets autogenerados los crea el clúster destino
        [[ "$name" =~ -dockercfg-[a-z0-9]{5}$ ]] && continue
      fi
      warn "$d: se referencia $kind/$name pero no se exportó (¿gestionado por Vault/ESO o creado a mano?)"
      todo "$d: crear $kind/$name antes del apply — si no, el pod queda en CreateContainerConfigError"
      miss=$((miss+1))
    done < <(cut -f1,2 "$refs" | sort -u | sed 's/$/\t-/')
  done

  if (( miss > 0 )); then
    warn "$miss referencias a ConfigMap/Secret sin resolver — ver manual-todo.txt"
  else
    ok "Todas las referencias a ConfigMap/Secret resuelven"
  fi
  ok "Inventario en $REPORTS/config.txt"
}

# --- auditoría de URLs ------------------------------------------------------
# Deja constancia de QUÉ componente apunta ahora a QUÉ URL, y detecta lo que
# se haya quedado apuntando a producción. Nunca imprime el valor de un Secret:
# solo el objeto, la clave y el par de URLs sustituido.
tf_report_urls() {
  step "Auditoría de URLs en ConfigMaps, Secrets y variables de entorno"
  local s d kind f urlmap srcdom pats n_rw=0 n_left=0
  urlmap="$(url_map_json)"
  srcdom="$(cat "$RUN/domain-src.txt")"
  # Lo que NO debe quedar en contingencia: el apps-domain de producción y todo
  # host de PROD que no se haya podido traducir.
  pats=$( { [[ "${REWRITE_APPS_DOMAIN:-true}" == true ]] && printf '%s\n' "$srcdom"
            cat "$RUN/.url-unmapped.txt" 2>/dev/null; } \
          | grep -v '^$' | sort -u | jq -R . | jq -s -c . )

  {
    printf 'URLs de los componentes en el entorno de contingencia.\n'
    printf 'Corrida %s · %s\n\n' "$RUN_ID" "$(date -Is)"
    printf 'Sustituciones aplicadas (out/%s/url-map.tsv):\n' "$RUN_ID"
    awk -F'\t' '{printf "  %-52s -> %-52s (%s)\n", $1, $2, $3}' "$RUN/url-map.tsv" 2>/dev/null
    printf '\nDetalle por objeto (de los Secrets solo se muestra la clave):\n'
    printf '%-26s %-12s %-32s %-24s %s\n' "NAMESPACE(DR)" "KIND" "NOMBRE" "CLAVE" "SUSTITUCIÓN"
    printf '%s\n' "-----------------------------------------------------------------------------------------------------------------------------"
  } > "$REPORTS/urls.txt"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"

    # ConfigMaps y Secrets: se mira el valor ORIGEN para saber qué se sustituyó.
    for kind in configmap secret; do
      f="$RAW/$s/$kind.json"
      [[ -r "$f" ]] || continue
      while IFS=$'\t' read -r name key from to; do
        [[ -z "${name:-}" ]] && continue
        printf '%-26s %-12s %-32s %-24s %s -> %s\n' "$d" "$kind" "$name" "$key" "$from" "$to" >> "$REPORTS/urls.txt"
        n_rw=$((n_rw+1))
      done < <(jq -r --argjson m "$urlmap" --arg kind "$kind" '
        # Se reproduce la MISMA reducción que aplica la transformación, para
        # listar solo las sustituciones que de verdad ocurrieron (la más larga
        # gana; la genérica ya no encuentra nada que sustituir).
        def aplicadas($v):
          reduce $m[] as $u ({v: $v, hits: []};
            if (.v | contains($u.from))
            then {v: (.v | split($u.from) | join($u.to)), hits: (.hits + [$u])}
            else . end) | .hits[];
        .items[]
        | .metadata.name as $n
        | ((.data // {}) | to_entries[])
        | . as $e
        | (if $kind == "secret"
           then ((try ($e.value | @base64d) catch "") // "")
           else ($e.value // "") end) as $plain
        | aplicadas($plain)
        | [$n, $e.key, .from, .to] | @tsv' < "$f" 2>/dev/null)
    done

    # env, args y command de los workloads
    for kind in deployment deploymentconfig statefulset daemonset cronjob; do
      f="$RAW/$s/$kind.json"
      [[ -r "$f" ]] || continue
      while IFS=$'\t' read -r name key from to; do
        [[ -z "${name:-}" ]] && continue
        printf '%-26s %-12s %-32s %-24s %s -> %s\n' "$d" "$kind" "$name" "$key" "$from" "$to" >> "$REPORTS/urls.txt"
        n_rw=$((n_rw+1))
      done < <(jq -r --argjson m "$urlmap" '
        def aplicadas($v):
          reduce $m[] as $u ({v: $v, hits: []};
            if (.v | contains($u.from))
            then {v: (.v | split($u.from) | join($u.to)), hits: (.hits + [$u])}
            else . end) | .hits[];
        .items[]
        | .metadata.name as $n
        | ((.spec.template.spec // .spec.jobTemplate.spec.template.spec // {})) as $ps
        | (($ps.containers // []) + ($ps.initContainers // []))[]
        | . as $c
        | ( ( ($c.env // [])[] | select(has("value")) | {k: ("env/" + .name), v: (.value // "")} ),
            ( ($c.args    // [])[] | {k: "args",    v: .} ),
            ( ($c.command // [])[] | {k: "command", v: .} ) )
        | . as $x
        | aplicadas($x.v)
        | [$n, $x.k, .from, .to] | @tsv' < "$f" 2>/dev/null)
    done

    # Lo que HAYA QUEDADO apuntando a producción tras la transformación: el
    # apps-domain de PROD, o un host custom que no se pudo mapear. Es
    # exactamente el fallo que esta fase debe impedir.
    while IFS=$'\t' read -r kind name key hit; do
      [[ -z "${name:-}" ]] && continue
      err "$d: $kind/$name clave '$key' sigue apuntando a producción ('$hit')"
      todo "$d: $kind/$name clave '$key' conserva '$hit'. Declara su equivalente de contingencia en ${URL_MAP_FILE:-url-map.txt} y repite 'transform'."
      printf '%-26s %-12s %-32s %-24s %s\n' "$d" "$kind" "$name" "$key" "SIN RESOLVER -> $hit" >> "$REPORTS/urls.txt"
      n_left=$((n_left+1))
    done < <(clean_items "$d" | jq -r --argjson pats "$pats" '
      .[]
      | .kind as $k | .metadata.name as $n
      | ( ( (.data // {}) | to_entries[]
            | {key: .key,
               v: (if $k == "Secret" then ((try (.value | @base64d) catch "") // "") else (.value // "") end)} ),
          ( ((.spec.template.spec // .spec.jobTemplate.spec.template.spec // {})
             | (.containers // []) + (.initContainers // []))[]
            | ( ((.env // [])[] | select(has("value")) | {key: ("env/" + .name), v: (.value // "")}),
                ((.args // [])[] | {key: "args", v: .}),
                ((.command // [])[] | {key: "command", v: .}) ) ) )
      | select(.v | type == "string")
      | . as $e
      | $pats[] | . as $p
      | select($e.v | contains($p))
      | [$k, $n, $e.key, $p] | @tsv')
  done

  log "  sustituciones de URL aplicadas: $n_rw"
  if (( n_left > 0 )); then
    err "$n_left valores siguen apuntando a producción"
  else
    ok "Ningún ConfigMap, Secret ni variable de entorno apunta ya a producción"
  fi
  ok "Detalle en $REPORTS/urls.txt"
}

# --- asociación entre namespaces --------------------------------------------
# Los cuatro namespaces no son independientes: el backend lee la configuración
# de location-resources, habla con la base de datos y el GUI llama al backend,
# y todo eso está expresado como nombres DNS <servicio>.<namespace>.svc y como
# RoleBindings que cruzan de un namespace a otro.
#
# Esta comprobación verifica, ANTES de aplicar nada, que en contingencia:
#   - toda referencia <servicio>.<namespace>.svc apunta a un namespace -dr,
#   - y que ese Service existe de verdad en ese namespace -dr,
#   - que ningún RoleBinding ni ClusterRoleBinding sigue concediendo permisos a
#     una ServiceAccount del namespace de PRODUCCIÓN,
#   - y que las ServiceAccounts a las que se concede acceso existen.
tf_cross_refs() {
  step "Asociación entre namespaces (DNS interno y RBAC cruzado)"
  local s d ns_re svcs_file="$RUN/.svcs-por-ns.tsv" bad=0 refs=0
  local out="$REPORTS/cross-namespace.txt"

  # Inventario real de Services y ServiceAccounts que habrá en cada namespace -dr.
  : > "$svcs_file"
  local sas_file="$RUN/.sas-por-ns.tsv"; : > "$sas_file"
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    clean_items "$d" service        | jq -r --arg d "$d" '.[] | [$d, .metadata.name] | @tsv' >> "$svcs_file"
    { clean_items "$d" serviceaccount | jq -r '.[].metadata.name'; echo default; } \
      | awk -v d="$d" 'NF {print d "\t" $0}' >> "$sas_file"
  done

  # Alternancia de nombres: primero los -dr, después los de producción, para
  # poder distinguir una referencia ya traducida de una que se quedó atrás.
  ns_re=""
  for s in $(src_namespaces); do ns_re+="${ns_re:+|}$(ns_dst "$s")"; done
  for s in $(src_namespaces); do ns_re+="|$s"; done

  {
    printf 'Asociación entre los namespaces de contingencia.\n'
    printf 'Corrida %s · %s\n\n' "$RUN_ID" "$(date -Is)"
    printf 'DEPENDENCIAS DNS  (quién llama a qué servicio de qué namespace)\n'
    printf '%-26s %-34s %-22s %-26s %s\n' "NAMESPACE(DR)" "OBJETO" "CAMPO" "SERVICIO DESTINO" "ESTADO"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------------------------------"
  } > "$out"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r kind name campo svc tns; do
      [[ -z "${svc:-}" ]] && continue
      refs=$((refs+1))
      local estado="OK"
      if [[ "$tns" != *"$DR_SUFFIX" ]]; then
        estado="SIN TRADUCIR (apunta a PRODUCCIÓN)"
        err "$d: $kind/$name ($campo) llama a ${svc}.${tns}.svc, que es el namespace de PRODUCCIÓN"
        todo "$d: $kind/$name ($campo) sigue apuntando a ${svc}.${tns}.svc. Debe apuntar a $(ns_dst "$tns")."
        bad=$((bad+1))
      elif ! awk -F'\t' -v n="$tns" -v x="$svc" '$1==n && $2==x {f=1} END{exit !f}' "$svcs_file"; then
        estado="SERVICE INEXISTENTE en $tns"
        err "$d: $kind/$name ($campo) llama a ${svc}.${tns}.svc, pero en $tns no se migra ningún Service '$svc'"
        todo "$d: $kind/$name ($campo) apunta a un Service inexistente (${svc}.${tns}.svc). Services en $tns: $(awk -F'\t' -v n="$tns" '$1==n {printf "%s%s", sep, $2; sep=","}' "$svcs_file")"
        bad=$((bad+1))
      fi
      printf '%-26s %-34s %-22s %-26s %s\n' "$d" "$kind/$name" "$campo" "${svc}.${tns}.svc" "$estado" >> "$out"
    done < <(clean_items "$d" | jq -r --arg re "([A-Za-z0-9][A-Za-z0-9_-]*)\\.($ns_re)\\.svc" '
      .[] as $o
      | ($o | paths(strings)) as $p
      | ($o | getpath($p)) as $raw
      | (if ($o.kind == "Secret") and ($p[0] == "data")
         then ((try ($raw | @base64d) catch "") // "") else $raw end) as $v
      | select($v | type == "string")
      | $v | [match($re; "g")][]
      | [$o.kind, $o.metadata.name, ($p | map(tostring) | join(".")),
         .captures[0].string, .captures[1].string] | @tsv' | sort -u)
  done

  # --- RBAC que cruza de un namespace a otro --------------------------------
  {
    printf '\nRBAC CRUZADO  (a qué ServiceAccount de otro namespace se le concede acceso)\n'
    printf '%-26s %-30s %-22s %-30s %s\n' "NAMESPACE(DR)" "BINDING" "SERVICEACCOUNT" "NAMESPACE DE LA SA" "ESTADO"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------------------------------"
  } >> "$out"

  # Un subject puede estar en tres sitios distintos, y solo uno es un error:
  #   - en un namespace de PRODUCCIÓN que SÍ migramos -> se quedó sin traducir
  #   - en su equivalente -dr                          -> correcto
  #   - en un namespace ajeno a la migración           -> permiso a otra
  #     aplicación del clúster; no lo podemos traducir y no es un fallo nuestro,
  #     pero hay que revisarlo porque ese namespace puede no existir en
  #     pre-producción.
  local ajenos=0
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r bind sa sans; do
      [[ -z "${sa:-}" ]] && continue
      [[ -z "$sans" ]] && sans="$d"     # sin namespace = el del propio binding
      local estado="OK"
      if is_src_ns "$sans"; then
        estado="SIN TRADUCIR (SA de PRODUCCIÓN)"
        err "$d rolebinding/$bind concede permisos a la SA '$sa' del namespace de PRODUCCIÓN '$sans'"
        todo "$d: el RoleBinding '$bind' apunta a la SA '$sa' en '$sans'. Debe apuntar a '$(ns_dst "$sans")'."
        bad=$((bad+1))
      elif ! is_dst_ns "$sans"; then
        estado="EXTERNO a la migración"
        ajenos=$((ajenos+1))
        vlog "$d: $bind concede acceso a '$sa' de '$sans', ajeno a la migración"
      elif ! awk -F'\t' -v n="$sans" -v x="$sa" '$1==n && $2==x {f=1} END{exit !f}' "$sas_file"; then
        estado="SERVICEACCOUNT INEXISTENTE"
        err "$d rolebinding/$bind concede permisos a '$sa', que no existirá en $sans"
        todo "$d: el RoleBinding '$bind' apunta a la ServiceAccount '$sa' de '$sans', que no se migra. El permiso quedaría sin efecto."
        bad=$((bad+1))
      elif [[ "$sans" != "$d" ]]; then
        estado="CRUZADO (correcto)"
        vlog "$d: $bind concede acceso a $sa de $sans"
      fi
      printf '%-26s %-30s %-22s %-30s %s\n' "$d" "$bind" "$sa" "$sans" "$estado" >> "$out"
    done < <(clean_items "$d" rolebinding | jq -r '
      .[] | .metadata.name as $n | ((.subjects // [])[])
      | select(.kind == "ServiceAccount")
      | [$n, .name, (.namespace // "")] | @tsv')
  done

  if (( ajenos > 0 )); then
    warn "$ajenos concesiones apuntan a ServiceAccounts de namespaces ajenos a la migración (marcadas EXTERNO en el informe)"
    todo "Revisa las $ajenos concesiones marcadas EXTERNO en $out: dan permisos a ServiceAccounts de otras aplicaciones. Comprueba si esos namespaces existen en pre-producción; si no, el binding queda sin efecto."
  fi

  # ClusterRoleBindings: viven fuera de los namespaces, pero sus subjects no.
  local crb
  if crb="$(clean_file _cluster 80-clusterrolebinding)"; then
    while IFS=$'\t' read -r bind sa sans; do
      [[ -z "${sa:-}" ]] && continue
      local estado="CRUZADO (correcto)"
      if is_src_ns "$sans"; then
        estado="SIN TRADUCIR (SA de PRODUCCIÓN)"
        err "ClusterRoleBinding/$bind concede permisos de clúster a la SA '$sa' del namespace de PRODUCCIÓN '$sans'"
        todo "ClusterRoleBinding/$bind: la SA '$sa' sigue en '$sans'. Debe ser '$(ns_dst "$sans")'."
        bad=$((bad+1))
      elif ! is_dst_ns "$sans"; then
        estado="EXTERNO a la migración"
      elif ! awk -F'\t' -v n="$sans" -v x="$sa" '$1==n && $2==x {f=1} END{exit !f}' "$sas_file"; then
        estado="SERVICEACCOUNT INEXISTENTE"
        err "ClusterRoleBinding/$bind concede permisos a '$sa', que no existirá en $sans"
        bad=$((bad+1))
      fi
      printf '%-26s %-30s %-22s %-30s %s\n' "(cluster)" "$bind" "$sa" "$sans" "$estado" >> "$out"
    done < <(read_manifest "$crb" | jq -r '
      .items[] | .metadata.name as $n | ((.subjects // [])[])
      | select(.kind == "ServiceAccount") | [$n, .name, (.namespace // "")] | @tsv')
  fi

  # --- selectores de namespace en NetworkPolicies ---------------------------
  {
    printf '\nSELECTORES DE NAMESPACE  (NetworkPolicy)\n'
    printf '%-26s %-34s %-40s %s\n' "NAMESPACE(DR)" "NETWORKPOLICY" "SELECCIONA" "ESTADO"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------------------------------"
  } >> "$out"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    while IFS=$'\t' read -r name valor; do
      [[ -z "${valor:-}" ]] && continue
      local estado="OK"
      if [[ "$valor" != *"$DR_SUFFIX" ]]; then
        estado="SIN TRADUCIR (selecciona PRODUCCIÓN)"
        err "$d: NetworkPolicy/$name selecciona el namespace '$valor', que en contingencia no existe"
        todo "$d: NetworkPolicy/$name selecciona '$valor'. En contingencia debe seleccionar '$(ns_dst "$valor")' o el tráfico quedará bloqueado."
        bad=$((bad+1))
      fi
      printf '%-26s %-34s %-40s %s\n' "$d" "$name" "$valor" "$estado" >> "$out"
    done < <(clean_items "$d" networkpolicy | jq -r --arg re "^($ns_re)\$" '
      .[] | .metadata.name as $n
      | [ .. | objects | select(has("namespaceSelector")) | .namespaceSelector
          | ((.matchLabels // {}) | to_entries[] | .value),
            ((.matchExpressions // [])[] | (.values // [])[]) ]
      | .[] | select(test($re)) | [$n, .] | @tsv' | sort -u)
  done

  log "  referencias DNS entre namespaces analizadas: $refs"
  if (( bad > 0 )); then
    err "$bad asociaciones entre namespaces son incorrectas — ver $out"
  else
    ok "Todas las dependencias apuntan a los namespaces de contingencia y resuelven"
  fi
  ok "Detalle en $out"
}

# --- RoleBindings autogenerados por OpenShift -------------------------------
tf_report_default_rolebindings() {
  [[ "${MIGRATE_DEFAULT_ROLEBINDINGS:-false}" == true ]] && return 0
  local s d n subs
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    [[ -r "$RAW/$s/rolebinding.json" ]] || continue
    while IFS=$'\t' read -r name subs; do
      [[ -z "${name:-}" ]] && continue
      if [[ "$name" == "admin" ]]; then
        warn "$d: NO se migra el RoleBinding 'admin' de PROD (daría admin en contingencia a: ${subs:-?})"
        todo "$d: el RoleBinding 'admin' de producción no se migra por seguridad. Si necesitas esos permisos en contingencia, concédelos a mano: oc -n $d adm policy add-role-to-user admin <usuario>"
      else
        vlog "$d: se omite el RoleBinding autogenerado '$name'"
      fi
    done < <(jq -r '
      .items[]
      | select(.metadata.name | test("^(admin|system:(deployers?|image-builders?|image-pullers?)(-[0-9]+)?)$"))
      | [ .metadata.name,
          ([ (.subjects // [])[] | (.kind // "?") + "/" + (.name // "?") ] | join(",")) ] | @tsv' \
      < "$RAW/$s/rolebinding.json" 2>/dev/null)
  done
  return 0
}

# --- Routes -----------------------------------------------------------------
tf_routes() {
  step "Routes"
  local s d srcdom dstdom
  srcdom="$(cat "$RUN/domain-src.txt")"; dstdom="$(cat "$RUN/domain-dst.txt")"
  {
    printf '%-22s %-26s %-52s %-52s %s\n' "NAMESPACE(DR)" "ROUTE" "HOST ORIGEN" "HOST DESTINO" "TLS"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------------------------------------------------------"
  } > "$REPORTS/routes.txt"

  : > "$RUN/routes-dst.tsv"
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    [[ "$(clean_items "$d" route | jq 'length')" != "0" ]] || continue
    local old_hosts; old_hosts=$(jq -r '.items[] | [.metadata.name, (.spec.host // "-")] | @tsv' < "$RAW/$s/route.json" 2>/dev/null)

    while IFS=$'\t' read -r name newhost term; do
      [[ -z "$name" ]] && continue
      [[ "$newhost" == "<NONE>" ]] && newhost=""
      [[ "$term"    == "<NONE>" ]] && term=""
      local oldhost; oldhost=$(awk -F'\t' -v n="$name" '$1==n {print $2}' <<< "$old_hosts")
      printf '%-22s %-26s %-52s %-52s %s\n' "$d" "$name" "${oldhost:--}" "${newhost:-<generado por el router>}" "${term:--}" >> "$REPORTS/routes.txt"
      printf '%s\t%s\t%s\t%s\n' "$d" "$name" "$newhost" "$term" >> "$RUN/routes-dst.tsv"

      if [[ -z "$newhost" ]]; then
        todo "$d/$name: host custom sin mapeo; el router asignará uno. Revisa DNS/certificado."
      else
        # DNS limita cada etiqueta a 63 caracteres y el nombre completo a 253.
        # El límite NO es sobre la longitud total del host.
        local longest
        longest=$(tr '.' '\n' <<< "$newhost" | awk '{ if (length > m) m = length } END { print m+0 }')
        if [[ "$longest" -gt 63 ]]; then
          warn "$d/$name: el host generado tiene una etiqueta de $longest caracteres (>63); el router la rechazará"
          todo "$d/$name: acorta el nombre de la Route o define un host en $ROUTE_MAP_FILE"
        elif [[ ${#newhost} -gt 253 ]]; then
          warn "$d/$name: el host generado tiene ${#newhost} caracteres (>253)"
          todo "$d/$name: host demasiado largo; define uno más corto en $ROUTE_MAP_FILE"
        fi
      fi
      if [[ "$term" == "reencrypt" && "$ROUTE_TLS_STRATEGY" == "default" ]]; then
        todo "$d/$name: era reencrypt; se quitó destinationCACertificate (era del service-CA de PROD). Verifica el backend TLS."
      fi
    done < <(clean_items "$d" route \
             | jq -r '.[] | [.metadata.name, (.spec.host // "<NONE>"), (.spec.tls.termination // "<NONE>")] | @tsv')
  done
  ok "Mapa de rutas en $REPORTS/routes.txt"
}

# --- ResourceQuota / LimitRange (solo informativo) --------------------------
tf_quota_report() {
  local s d n
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    for kind in resourcequota limitrange; do
      [[ -r "$RAW/$s/$kind.json" ]] || continue
      n=$(jq '.items | length' < "$RAW/$s/$kind.json")
      [[ "$n" == "0" ]] && continue
      todo "$d: en PROD hay $n $kind. No se migran; comprueba que las cuotas de pre-producción admiten la carga."
    done
  done
  if [[ -s "$RAW/_cluster/custom-resources.txt" ]]; then
    while IFS=$'\t' read -r ns res; do
      todo "$(ns_dst "$ns"): recurso de operador '$res' presente en PROD. Instala el operador en pre-producción."
    done < "$RAW/_cluster/custom-resources.txt"
  fi
}

cmd_transform() {
  require_cmd oc jq
  [[ -d "$RAW" ]] || die "No hay export en $RAW. Ejecuta primero: $0 export"
  [[ -r "$RUN/domain-src.txt" && -r "$RUN/domain-dst.txt" ]] || die "Faltan los dominios. Ejecuta primero: $0 export"

  rm -rf "$CLEAN"; mkdir -p "$CLEAN/_cluster"
  clean_cache_reset
  : > "$REPORTS/manual-todo.txt"

  # 12 pasos fijos + uno por cada namespace transformado
  phase_steps $(( $(src_namespaces | wc -l) + 12 ))

  # El mapa de URLs se construye ANTES de transformar: tf_namespaced lo aplica
  # al contenido de ConfigMaps, Secrets, env, args y command.
  build_url_map
  tf_namespaces
  tf_namespaced
  tf_report_default_rolebindings
  tf_cluster_bindings
  tf_serviceaccounts
  tf_config_refs
  tf_report_rewrites
  tf_report_urls
  tf_cross_refs
  tf_routes
  cmd_images
  tf_rewrite_images
  tf_quota_report

  step "Transform terminado"
  log "Manifiestos listos en: $CLEAN"
  log "Reportes en:           $REPORTS"
  log "Mapa de URLs:          $REPORTS/urls.txt"
  log "Asociación de NS:      $REPORTS/cross-namespace.txt"
  if [[ -s "$REPORTS/manual-todo.txt" ]]; then
    warn "Hay $(wc -l < "$REPORTS/manual-todo.txt") puntos pendientes en $REPORTS/manual-todo.txt"
  fi
  ok "Revisa los reportes antes de ejecutar 'apply'"
}
