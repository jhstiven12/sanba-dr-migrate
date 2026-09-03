#!/usr/bin/env bash
# lib/images.sh — resuelve la imagen EXACTA que corre en producción (por digest),
# genera el mirror con skopeo y reescribe los manifiestos de contingencia para
# que apunten a esos mismos digests.
#
# Por qué por digest y no por tag: un tag es móvil. Si en contingencia se tira
# de ':prod', se puede acabar ejecutando una imagen distinta de la que hoy está
# en producción, y entonces el drill no prueba lo que se cree que prueba.
# 'skopeo copy --all' conserva el manifiesto y, por tanto, el mismo digest.
# shellcheck shell=bash

INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

classify_image() {
  case "$1" in
    image-registry.openshift-image-registry.svc*|docker-registry.default.svc*) echo "INTERNA" ;;
    registry.redhat.io/*|registry.access.redhat.com/*|registry.connect.redhat.com/*) echo "REDHAT" ;;
    "" ) echo "SIN-RESOLVER" ;;
    *) echo "EXTERNA" ;;
  esac
}

# Construye, para un namespace de origen:
#   Kind/Nombre <TAB> contenedor <TAB> referencia-con-digest
# recorriendo pod -> ReplicaSet/ReplicationController -> Deployment/DeploymentConfig.
build_running_image_map() {
  local ns="$1"
  local out="$RUN/.running-images-$ns.tsv"
  : > "$out"
  local pods="$RAW/$ns/pod.json"
  [[ -r "$pods" ]] || { vlog "$ns: no hay export de pods; no se puede resolver el digest en uso"; return 0; }

  # Propietario intermedio -> workload final
  local owners="$RUN/.owners-$ns.json"
  # El 'true' final es necesario: si el último [[ -r ]] falla porque el
  # namespace no tiene ese tipo de recurso, el grupo devolvería 1 y con
  # 'set -e' se llevaría por delante toda la tubería.
  { [[ -r "$RAW/$ns/replicaset.json" ]] && jq '.items[]' < "$RAW/$ns/replicaset.json"
    [[ -r "$RAW/$ns/replicationcontroller.json" ]] && jq '.items[]' < "$RAW/$ns/replicationcontroller.json"
    true
  } 2>/dev/null | jq -s '
      [ .[] | { name: .metadata.name,
                owner: ((.metadata.ownerReferences // [])[0] // null) } ]
      | map(select(.owner != null))
      | map({ (.name): (.owner.kind + "/" + .owner.name) }) | add // {}' > "$owners"

  jq -r --slurpfile o "$owners" '
    ($o[0] // {}) as $owners
    | .items[]
    | select(.status.phase == "Running")
    | ((.metadata.ownerReferences // [])[0] // null) as $ref
    | (if $ref == null then null
       elif ($ref.kind | IN("ReplicaSet","ReplicationController")) then ($owners[$ref.name] // null)
       else ($ref.kind + "/" + $ref.name) end) as $workload
    | select($workload != null)
    | (.status.containerStatuses // [])[]
    | select(.imageID != null and .imageID != "")
    | [ $workload, .name, (.imageID | sub("^docker-pullable://";"") | sub("^docker://";"")) ]
    | @tsv' < "$pods" 2>/dev/null | sort -u > "$out"

  rm -f "$owners"
  local n; n=$(wc -l < "$out")
  vlog "$ns: $n contenedores en ejecución con digest resuelto"
}

# Sustituye el host del registry interno por la ruta expuesta, para que skopeo
# pueda alcanzarlo desde fuera del clúster.
to_external_ref() {
  local ref="$1" route="$2"
  [[ -n "$route" ]] || { printf '%s' "$ref"; return 0; }
  printf '%s' "${ref/$INTERNAL_REGISTRY/$route}"
}

cmd_images() {
  step "Imágenes de contenedor"
  local s d reg_src reg_dst
  reg_src=$(cat "$RUN/registry-src.txt" 2>/dev/null || true)
  reg_dst=$(cat "$RUN/registry-dst.txt" 2>/dev/null || true)

  local map="$RUN/image-map.tsv"        # ns_dr  workload  contenedor  origen  destino_en_DR
  local mirror="$RUN/mirror-commands.sh"
  : > "$map"
  {
    printf '%-26s %-34s %-9s %s\n' "NAMESPACE(DR)" "WORKLOAD/CONTENEDOR" "ORIGEN" "IMAGEN EN USO"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------------------"
  } > "$REPORTS/images.txt"

  local sin_digest=0 internas=0
  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    build_running_image_map "$s"
    local running="$RUN/.running-images-$s.tsv"

    while IFS=$'\t' read -r workload container spec_image; do
      [[ -z "${workload:-}" ]] && continue

      # La verdad es lo que está corriendo; el manifiesto es solo el respaldo.
      local real
      real=$(awk -F'\t' -v w="$workload" -v c="$container" '$1==w && $2==c {print $3; exit}' "$running" 2>/dev/null)
      [[ -z "$real" ]] && real="$spec_image"

      local origin; origin="$(classify_image "$real")"
      printf '%-26s %-34s %-9s %s\n' "$d" "$workload/$container" "$origin" "${real:-<sin resolver>}" >> "$REPORTS/images.txt"

      if [[ "$origin" == "SIN-RESOLVER" ]]; then
        sin_digest=$((sin_digest+1))
        todo "$d/$workload contenedor '$container': no se pudo determinar la imagen. ¿El workload está parado en producción?"
        continue
      fi

      # Se fija por digest TODO lo que se haya podido resolver, no solo lo
      # interno: ':latest' o ':prod' son tags móviles y en contingencia podrían
      # apuntar a otra build. Con el digest se ejecuta lo mismo, bit a bit.
      local repo digest name tag dst_ref mirror_needed
      repo="${real%@*}"; digest=""
      [[ "$real" == *@sha256:* ]] && digest="${real##*@}"
      name="${repo##*/}"
      tag="${spec_image##*:}"
      [[ "$tag" == "$spec_image" || "$tag" == */* ]] && tag="dr"

      if [[ -z "$digest" ]]; then
        sin_digest=$((sin_digest+1))
        todo "$d/$workload contenedor '$container': la imagen no tiene digest ($real); en contingencia se usará el tag, que puede moverse."
        continue
      fi

      if [[ "$origin" == "INTERNA" ]]; then
        internas=$((internas+1)); mirror_needed=si
        dst_ref="${INTERNAL_REGISTRY}/${d}/${name}@${digest}"
      else
        mirror_needed=no
        dst_ref="${repo}@${digest}"     # mismo registry, fijado por digest
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$d" "$workload" "$container" "$real" "$dst_ref" "$tag" "$mirror_needed" >> "$map"
    done < <(clean_items "$d" | jq -r '
        .[]
        | select(.kind | IN("Deployment","StatefulSet","DaemonSet","DeploymentConfig","CronJob","Job"))
        | (.kind + "/" + .metadata.name) as $w
        | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // {}) as $ps
        | (($ps.containers // []) + ($ps.initContainers // []))[]
        | [$w, .name, (.image // "")] | @tsv')
    rm -f "$running"
  done

  generate_mirror_script "$reg_src" "$reg_dst" "$mirror"

  if (( internas > 0 )); then
    warn "$internas contenedores usan el registry interno de producción"
    log  "  Mirror: revisa $mirror y ejecuta  $0 mirror --run $RUN_ID"
  else
    ok "Ninguna imagen depende del registry interno de producción"
  fi
  (( sin_digest > 0 )) && warn "$sin_digest contenedores sin imagen resuelta (ver manual-todo.txt)"
  ok "Inventario en $REPORTS/images.txt"
}

generate_mirror_script() {
  local reg_src="$1" reg_dst="$2" mirror="$3"
  {
    echo '#!/usr/bin/env bash'
    echo '# Generado por sanba-dr-migrate.sh. Copia cada imagen POR DIGEST, de modo'
    echo '# que en contingencia se ejecute exactamente el mismo contenido que en'
    echo '# producción. "skopeo copy --all" conserva el manifiesto y el digest.'
    echo 'set -euo pipefail'
    echo
    echo "# Autenticación previa (usa el token de cada kubeconfig; no hay que"
    echo "# adivinar el nombre de usuario):"
    echo "#   KUBECONFIG=\"\$KUBECONFIG_SRC\" oc registry login --registry ${reg_src:-<registry-produccion>} --to /tmp/auth-src.json"
    echo "#   KUBECONFIG=\"\$KUBECONFIG_DST\" oc registry login --registry ${reg_dst:-<registry-preproduccion>} --to /tmp/auth-dst.json"
    echo "# y añade a cada skopeo copy:"
    echo "#   --src-authfile /tmp/auth-src.json --dest-authfile /tmp/auth-dst.json"
    echo
  } > "$mirror"

  local d workload container src dst tag needs src_ext dst_ext repo name
  while IFS=$'\t' read -r d workload container src dst tag needs; do
    [[ -z "${d:-}" || "$needs" != si ]] && continue
    src_ext="$(to_external_ref "$src" "$reg_src")"
    repo="${dst%@*}"; name="${repo##*/}"
    dst_ext="$(to_external_ref "${repo}:${tag}" "$reg_dst")"
    {
      echo "# $d  $workload  ($container)"
      echo "skopeo copy --all --retry-times 3 \\"
      echo "  docker://${src_ext} \\"
      echo "  docker://${dst_ext}"
      echo
    } >> "$mirror"
  done < "$RUN/image-map.tsv"
  chmod +x "$mirror"
}

# Reescribe los manifiestos limpios para que apunten al registry de contingencia
# por DIGEST, y elimina los disparadores de ImageChange: si se dejan, OpenShift
# sobrescribe el campo image con lo que diga un ImageStream que en contingencia
# no existe, y el despliegue se queda esperando para siempre.
tf_rewrite_images() {
  [[ -s "$RUN/image-map.tsv" ]] || return 0
  step "Fijando las imágenes de contingencia por digest"

  local d workload container src dst tag f n=0
  for d in $(src_namespaces | while read -r s; do ns_dst "$s"; done); do
    local pairs="$RUN/.imgpairs-$d.json"
    awk -F'\t' -v ns="$d" 'BEGIN{print "["} $1==ns {
        printf "%s{\"w\":\"%s\",\"c\":\"%s\",\"i\":\"%s\"}", (n++?",":""), $2, $3, $5 }
        END{print "]"}' "$RUN/image-map.tsv" > "$pairs"
    [[ "$(jq 'length' < "$pairs")" == "0" ]] && { rm -f "$pairs"; continue; }

    for f in "$CLEAN/$d"/5*-*.yaml "$CLEAN/$d"/5*-*.json; do
      [[ -r "$f" ]] || continue
      read_manifest "$f" | jq --slurpfile p "$pairs" '
        ($p[0]) as $pairs
        | def fixc($w): map(
            . as $c
            | ($pairs[] | select(.w == $w and .c == $c.name) | .i) as $new
            | if $new then .image = $new else . end);
          .items |= map(
            (.kind + "/" + .metadata.name) as $w
            | (if .spec.template.spec.containers      then .spec.template.spec.containers      |= fixc($w) else . end)
            | (if .spec.template.spec.initContainers  then .spec.template.spec.initContainers  |= fixc($w) else . end)
            | (if .spec.jobTemplate.spec.template.spec.containers
               then .spec.jobTemplate.spec.template.spec.containers |= fixc($w) else . end)
            # Sin esto el ImageStream inexistente ganaría sobre el digest fijado
            | (if .spec.triggers then .spec.triggers |= map(select(.type != "ImageChange")) else . end)
            | (if (.metadata.annotations // {}) | has("image.openshift.io/triggers")
               then .metadata.annotations |= del(."image.openshift.io/triggers") else . end)
          )' | to_manifest > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
    done
    n=$((n + $(jq 'length' < "$pairs")))
    rm -f "$pairs"
  done
  clean_cache_reset
  ok "$n contenedores fijados al digest de producción y sin disparadores de ImageChange"
}

# ---------------------------------------------------------------------------
# Ejecución del mirror
# ---------------------------------------------------------------------------
# Autentica contra un registry y, si falla, explica por qué en lugar de esconderlo.
registry_auth() {
  local ocf="$1" registry="$2" authfile="$3" label="$4"
  local insec="" kc
  [[ "${MIRROR_TLS_VERIFY:-true}" == false ]] && insec="--insecure"
  [[ "$label" == "PRODUCCIÓN" ]] && kc='$KUBECONFIG_SRC' || kc='$KUBECONFIG_DST'

  if "$ocf" registry login --registry "$registry" --to "$authfile" $insec \
       > "$RUN/.login.err" 2>&1; then
    ok "Autenticado en el registry de $label"
    rm -f "$RUN/.login.err"; return 0
  fi

  # La comprobación contra el registry puede fallar aunque las credenciales sean
  # correctas (proxy, red intermedia). Se reintenta guardándolas sin verificar.
  if "$ocf" registry login --registry "$registry" --to "$authfile" $insec --skip-check \
       >> "$RUN/.login.err" 2>&1; then
    warn "Credenciales guardadas para $label, pero la comprobación contra el registry falló"
    log  "  Si el mirror falla luego, la causa está en $RUN/.login.err"
    return 0
  fi

  err "No se pudo autenticar en el registry de $label ($registry)"
  sed 's/^/      /' "$RUN/.login.err" >&2

  if grep -qiE 'x509|certificate|tls' "$RUN/.login.err"; then
    cat >&2 <<MSG

  Es un problema de certificado: el registry usa uno firmado por la CA del
  clúster y este host no la reconoce. Dos salidas:

   a) Confiar en esa CA (lo correcto):
        KUBECONFIG="$kc" oc get secret -n openshift-ingress-operator router-ca \\
          -o jsonpath='{.data.tls\\.crt}' | base64 -d \\
          | sudo tee /etc/pki/ca-trust/source/anchors/ocp-router-ca.crt
        sudo update-ca-trust extract

   b) Saltarse la verificación, en sanba-dr.env:
        MIRROR_TLS_VERIFY="false"

MSG
  elif grep -qiE 'unauthorized|forbidden|401|403' "$RUN/.login.err"; then
    cat >&2 <<MSG

  El token sirve para la API pero el registry lo rechaza. Comprueba que la
  sesión sigue viva y que tienes acceso al registry:

      KUBECONFIG="$kc" oc whoami
      KUBECONFIG="$kc" oc auth can-i get imagestreams --all-namespaces

  Si la sesión caducó, repite el 'oc login' con un token nuevo.

MSG
  elif grep -qiE 'no such host|timeout|connection refused|dial tcp|i/o timeout' "$RUN/.login.err"; then
    cat >&2 <<MSG

  No hay conectividad con $registry desde este host:

      getent hosts $registry
      curl -sk -o /dev/null -w '%{http_code}\\n' https://$registry/v2/

  Si es un entorno con proxy, exporta HTTPS_PROXY y NO_PROXY antes de ejecutar.

MSG
  elif grep -qiE 'client certificate|unable to find|image stream' "$RUN/.login.err"; then
    cat >&2 <<MSG

  'oc registry login' no ha podido determinar las credenciales. Suele pasar si
  la sesión se abrió con certificado de cliente en vez de con token. Vuelve a
  entrar con token:

      KUBECONFIG="$kc" oc login <api> --token=sha256~...

MSG
  fi
  return 1
}

cmd_mirror() {
  require_cmd oc jq skopeo
  [[ -s "$RUN/image-map.tsv" ]] \
    || die "No hay inventario de imágenes en esta corrida. Ejecuta antes 'transform'."
  local pendientes; pendientes=$(awk -F'\t' '$7=="si"' "$RUN/image-map.tsv" | wc -l)
  [[ "$pendientes" -gt 0 ]] \
    || { ok "Ninguna imagen necesita mirror: todas están en registries que pre-producción ya alcanza."; return 0; }

  local reg_src reg_dst
  reg_src=$(cat "$RUN/registry-src.txt" 2>/dev/null || true)
  reg_dst=$(cat "$RUN/registry-dst.txt" 2>/dev/null || true)
  for par in "PRODUCCIÓN:$reg_src" "PRE-PRODUCCIÓN:$reg_dst"; do
    [[ -n "${par#*:}" ]] || die "El registry interno de ${par%%:*} no tiene ruta expuesta. Exponlo con:
    oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \\
       -p '{\"spec\":{\"defaultRoute\":true}}'
  (Ref: Registry 4.18 > Exposing the registry)"
  done

  step "Mirror de imágenes por digest"
  log "  ORIGEN : $reg_src"
  log "  DESTINO: $reg_dst"
  log "  Imágenes a copiar: $pendientes"

  local tlsflags=""
  [[ "${MIRROR_TLS_VERIFY:-true}" == false ]] && tlsflags="--src-tls-verify=false --dest-tls-verify=false"

  if [[ "${DRY_RUN:-false}" == true ]]; then
    log "(dry-run) no se copia nada; revisa $RUN/mirror-commands.sh"
    return 0
  fi

  # Autenticación. 'oc registry login' registra el token del kubeconfig como
  # credencial del registry indicado, sin tener que adivinar el nombre de
  # usuario (kube:admin, un service account...).
  local auth_src="$RUN/.auth-src.json" auth_dst="$RUN/.auth-dst.json"
  registry_auth oc_src "$reg_src" "$auth_src" "PRODUCCIÓN"     || return 1
  registry_auth oc_dst "$reg_dst" "$auth_dst" "PRE-PRODUCCIÓN" || return 1

  # Para empujar a un namespace hace falta system:image-builder o equivalente.
  local ns_dr
  for ns_dr in $(awk -F'\t' '$7=="si" {print $1}' "$RUN/image-map.tsv" | sort -u); do
    if [[ "$(oc_dst auth can-i create imagestreams -n "$ns_dr" 2>/dev/null)" != "yes" ]]; then
      warn "$ns_dr: puede que no tengas permiso para empujar imágenes"
      todo "$ns_dr: concede escritura en el registry: oc -n $ns_dr policy add-role-to-user system:image-builder <usuario>"
    fi
  done

  local d workload container src dst tag src_ext dst_ext repo digest got
  local copiadas=0 fallidas=0 verificadas=0
  while IFS=$'\t' read -r d workload container src dst tag needs; do
    [[ -z "${d:-}" || "$needs" != si ]] && continue
    src_ext="$(to_external_ref "$src" "$reg_src")"
    repo="${dst%@*}"
    dst_ext="$(to_external_ref "${repo}:${tag}" "$reg_dst")"
    digest="${src##*@}"

    log "  $d $workload/$container"
    if skopeo copy --all --retry-times 3 $tlsflags \
         --src-authfile "$auth_src" --dest-authfile "$auth_dst" \
         "docker://${src_ext}" "docker://${dst_ext}" >/dev/null 2>"$RUN/.skopeo.err"; then
      copiadas=$((copiadas+1))
      # La prueba de que es "tal cual": el digest del destino debe coincidir.
      if [[ "$src" == *@sha256:* ]]; then
        got=$(skopeo inspect --raw $tlsflags --authfile "$auth_dst" "docker://${dst_ext}" 2>/dev/null \
              | sha256sum | awk '{print "sha256:"$1}')
        if [[ "$got" == "$digest" ]]; then
          ok "  digest verificado: $digest"
          verificadas=$((verificadas+1))
        else
          err "  el digest NO coincide (origen $digest, destino $got)"
          todo "$d/$workload: la imagen copiada no tiene el mismo digest que producción."
        fi
      fi
    else
      fallidas=$((fallidas+1))
      err "  falló la copia"
      sed -n '1,5p' "$RUN/.skopeo.err" | sed 's/^/        /' >&2
      todo "$d/$workload contenedor '$container': falló el mirror de $src_ext"
    fi
  done < "$RUN/image-map.tsv"
  rm -f "$RUN/.skopeo.err" "$auth_src" "$auth_dst"

  step "Mirror terminado"
  log "  copiadas: $copiadas    con digest verificado: $verificadas    fallidas: $fallidas"
  if (( fallidas > 0 )); then
    err "$fallidas imágenes no se copiaron"
    return 1
  fi
  ok "Todas las imágenes están en el registry de pre-producción con el mismo digest"
}
