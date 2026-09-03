#!/usr/bin/env bash
# lib/images.sh — clasifica las imágenes de los workloads y genera (sin ejecutar)
# los comandos de mirror necesarios.
# shellcheck shell=bash

classify_image() {
  case "$1" in
    image-registry.openshift-image-registry.svc*|docker-registry.default.svc*) echo "INTERNA" ;;
    registry.redhat.io/*|registry.access.redhat.com/*|registry.connect.redhat.com/*) echo "REDHAT" ;;
    *) echo "EXTERNA" ;;
  esac
}

cmd_images() {
  step "Imágenes de contenedor"
  local s d f mirror="$RUN/mirror-commands.sh" needs_mirror=0
  {
    printf '%-26s %-30s %-9s %s\n' "NAMESPACE(DR)" "WORKLOAD" "ORIGEN" "IMAGEN"
    printf '%s\n' "---------------------------------------------------------------------------------------------------------"
  } > "$REPORTS/images.txt"

  {
    echo '#!/usr/bin/env bash'
    echo '# Generado por sanba-dr-migrate.sh — REVISAR Y EJECUTAR A MANO.'
    echo '# Requiere: skopeo, y credenciales de ambos registries.'
    echo '#   skopeo login <registry-origen> ; skopeo login <registry-destino>'
    echo 'set -euo pipefail'
    echo ": \"\${MIRROR_REGISTRY:=${MIRROR_REGISTRY:-REGISTRY-DESTINO.example.com/sanba}}\""
    echo
  } > "$mirror"

  local seen="$RUN/.images-seen"; : > "$seen"

  for s in $(src_namespaces); do
    d="$(ns_dst "$s")"
    [[ -d "$CLEAN/$d" ]] || continue

    while IFS=$'\t' read -r workload image; do
      [[ -z "${image// }" ]] && continue
      local origin; origin="$(classify_image "$image")"
      printf '%-26s %-30s %-9s %s\n' "$d" "$workload" "$origin" "$image" >> "$REPORTS/images.txt"

      if [[ "$origin" == "INTERNA" ]]; then
        needs_mirror=$((needs_mirror+1))
        if ! grep -qxF "$image" "$seen"; then
          echo "$image" >> "$seen"
          local tag="${image##*/}"
          {
            echo "# $d / $workload"
            echo "skopeo copy --all --retry-times 3 \\"
            echo "  docker://${image} \\"
            echo "  docker://\${MIRROR_REGISTRY}/${tag}"
            echo
          } >> "$mirror"
        fi
        todo "$d/$workload: imagen en el registry interno de PROD ($image). Mirroréala y ajusta la referencia."
      fi
    done < <(clean_items "$d" | jq -r '
        .[]
        | select(.kind | IN("Deployment","StatefulSet","DaemonSet","DeploymentConfig","CronJob","Job"))
        | (.kind + "/" + .metadata.name) as $w
        | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // {}) as $ps
        | (($ps.containers // []) + ($ps.initContainers // []))[]
        | [$w, (.image // "")] | @tsv')

    # Workloads cuya imagen la resuelve un ImageStream (quedan con image: " ")
    while read -r w; do
      [[ -z "$w" ]] && continue
      warn "$d/$w: la imagen la resuelve un ImageStream del clúster de PROD"
      todo "$d/$w: depende de un ImageStream/trigger. Crea el ImageStream en DR o fija la imagen completa en el manifiesto."
    done < <(clean_items "$d" | jq -r '
      .[]
      | select(
          ((.spec.triggers // []) | map(select(.type=="ImageChange")) | length > 0)
          or ((.metadata.annotations // {}) | has("image.openshift.io/triggers"))
          or ([ ((.spec.template.spec // {}).containers // [])[] | select((.image // "") | test("^ *$")) ] | length > 0)
        )
      | .kind + "/" + .metadata.name')
  done

  chmod +x "$mirror"
  rm -f "$seen"

  if (( needs_mirror > 0 )); then
    warn "$needs_mirror contenedores usan el registry interno de PROD"
    log  "Comandos de mirror generados (NO ejecutados): $mirror"
  else
    ok "Ninguna imagen depende del registry interno de PROD"
  fi
  ok "Inventario en $REPORTS/images.txt"
}
