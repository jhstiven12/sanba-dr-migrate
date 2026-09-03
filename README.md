# Prueba de Disaster Recovery de SANBA — OpenShift 4.18

Despliega la aplicación SANBA que corre en **producción** sobre el clúster de
**pre-producción** como contingencia, carga los datos de PostgreSQL y valida que
las URLs y la aplicación responden.

El script se ejecuta desde un host **RHEL 9** con acceso de red a los dos
clústeres. No se instala nada en los clústeres.

| Origen (PRODUCCIÓN)      | Destino (PRE-PRODUCCIÓN)    | Contenido            |
|--------------------------|-----------------------------|----------------------|
| `location-resources`     | `location-resources-dr`     | Configuración        |
| `sanba-data-persistence` | `sanba-data-persistence-dr` | PostgreSQL 10-el8    |
| `sanba-core`             | `sanba-core-dr`             | Backend              |
| `sanba-gui`              | `sanba-gui-dr`              | Frontend y Routes    |

Migra ServiceAccounts (con sus SCC y RoleBindings, incluidos los que cruzan
namespaces), ConfigMaps, Secrets, PVCs, Services, Routes, workloads y los datos
de la base de datos.

---

## Garantías sobre producción

**Sobre el clúster de producción solo se lee.** Todas las llamadas pasan por un
envoltorio (`oc_src`) que compara el verbo contra una lista blanca antes de
invocar `oc`. Los únicos verbos admitidos son:

```
get  describe  logs  version  whoami  auth  api-resources  explain  status
exec  rsh  rsync  cp
```

Cualquier otro —`apply`, `create`, `patch`, `delete`, `scale`, `edit`, `label`,
`annotate`, `adm`— aborta el script antes de llegar a la API. Además `oc rsync`
y `oc cp` solo se permiten en dirección **pod → local**: no es posible subir
nada a producción ni por accidente.

Lo único que el script escribe en producción es un fichero temporal de volcado
en `/tmp` **dentro del pod** de PostgreSQL, que borra al terminar. Con
`DB_KEEP_REMOTE_DUMP="true"` ni siquiera lo borra.

**En pre-producción tampoco se borra nada por defecto.** `pg_restore` se ejecuta
sin `--clean`; si la base de datos de contingencia ya tiene tablas, el script se
detiene y te explica las opciones. El único subcomando que borra algo es
`rollback`, que exige `--confirm`, solo actúa sobre pre-producción y se niega a
tocar cualquier namespace cuyo nombre no acabe en el sufijo de DR.

---

## Todo está parametrizado

No hay ningún nombre de recurso incrustado en el código. Los parámetros se
declaran en `sanba-dr.env` o **se descubren leyendo el clúster de producción**:

| Parámetro | Origen |
|---|---|
| Namespaces y su equivalente en DR | `NS_ORDER` + `DR_SUFFIX` (o `NS_MAP` explícito) |
| Dominio de aplicaciones de cada clúster | `oc get ingresses.config.openshift.io cluster` |
| Pod, usuario y base de datos de PostgreSQL | autodescubierto por imagen y variables del pod |
| SCC de cada ServiceAccount | ClusterRoleBindings, RoleBindings y `.users[]` de las SCC |
| StorageClasses | los PVC de producción, con `STORAGE_CLASS_MAP` si difieren |
| Registries de las imágenes | los workloads de producción |
| Hostnames de las Routes | recalculados con el dominio del clúster destino |

`preflight` deja lo descubierto en `out/<run>/discovered.env` para que puedas
revisarlo antes de seguir.

---

## Paso 0 — Preparar el host RHEL 9

```bash
sudo dnf install -y jq curl sed gawk tar rsync
```

`jq` debe ser **1.6 o superior** (el de RHEL 9 lo es). `yq` **no hace falta**: no
está en los repos de RHEL 9, así que si no lo encuentra el script genera los
manifiestos en JSON, que `oc apply -f` acepta igual. Si lo tienes instalado, los
genera en YAML porque son más cómodos de revisar.

Instala el cliente **`oc` 4.18**. Con suscripción de OpenShift, por RPM:

```bash
sudo subscription-manager repos --list | grep rhocp-4.18     # localiza el repo de tu arquitectura
sudo subscription-manager repos --enable="<repo-que-aparezca>"
sudo dnf install -y openshift-clients
```

Sin suscripción de OpenShift, desde el mirror público:

```bash
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.18/openshift-client-linux.tar.gz \
  | sudo tar xz -C /usr/local/bin oc kubectl
oc version --client        # debe decir 4.18.x
```

> **Importante.** Un cliente `oc` muy alejado de la versión del clúster da fallos
> difíciles de diagnosticar. Red Hat soporta ±1 versión menor. El `preflight`
> comprueba el desfase y aborta si es mayor.

## Paso 1 — Iniciar sesión en los dos clústeres

Cada clúster tiene su propio token, así que cada uno usa su propio kubeconfig:

```bash
KUBECONFIG=~/.kube/config-prod    oc login https://api.<prod>:6443    --token=sha256~...
KUBECONFIG=~/.kube/config-preprod oc login https://api.<preprod>:6443 --token=sha256~...
```

El token se obtiene en la consola web: *tu usuario → Copy login command*.

En **pre-producción** hace falta `cluster-admin` o equivalente: crear namespaces,
ClusterRoleBindings y conceder SCC. En **producción** basta con permisos de
lectura sobre los cuatro namespaces y de `exec` sobre el pod de la base de datos.

## Paso 2 — Revisar la configuración

Edita `sanba-dr.env`. Lo mínimo:

```bash
KUBECONFIG_SRC="$HOME/.kube/config-prod"
KUBECONFIG_DST="$HOME/.kube/config-preprod"
NS_ORDER="location-resources sanba-data-persistence sanba-core sanba-gui"
DR_SUFFIX="-dr"
DB_NS="sanba-data-persistence"
HEALTH_PATH="/"          # o /actuator/health, si la app lo expone
```

El resto puede quedarse como está en la primera pasada.

## Paso 3 — Preflight

```bash
./sanba-dr-migrate.sh preflight
```

Comprueba dependencias, versión del cliente, que los dos tokens son válidos y
apuntan a **clústeres distintos**, permisos en pre-producción, existencia de los
namespaces, StorageClasses y cuotas; y descubre los parámetros de producción.

No escribe nada en ningún clúster. Si algo falla, para aquí.

## Paso 4 — Extraer de producción

```bash
./sanba-dr-migrate.sh export
```

Una sola llamada a la API por namespace (`oc get` acepta varios tipos separados
por coma) en vez de una por tipo de recurso. Deja los objetos crudos en
`out/<run>/raw/`.

## Paso 5 — Transformar

```bash
./sanba-dr-migrate.sh transform
```

Sanea los manifiestos, renombra los namespaces —también dentro del contenido de
ConfigMaps, Secrets, variables de entorno y argumentos—, recalcula los hostnames
de las Routes y genera los informes en `out/<run>/`.

## Paso 6 — REVISAR (no lo saltes)

```bash
./sanba-dr-migrate.sh report        # lista dónde está cada informe
```

| Informe | Qué mirar |
|---|---|
| `reports/manual-todo.txt` | Todo lo que el script no puede resolver solo. **Empieza aquí.** |
| `reports/images.txt` | Imágenes marcadas `INTERNA`: viven en el registry de producción y hay que mirrorearlas. |
| `reports/routes.txt` | Hostname que tendrá cada Route en contingencia. |
| `reports/serviceaccounts.txt` | Cada SA con sus SCC, su origen y los workloads que la usan. |
| `reports/config.txt` | ConfigMaps y Secrets, número de claves y quién los consume. |
| `reports/ns-rewrites.txt` | Qué claves contenían un nombre de namespace y fueron reescritas. |

Si hay imágenes internas:

```bash
less out/<run>/mirror-commands.sh    # revísalo primero
bash out/<run>/mirror-commands.sh    # lo genera el script, pero no lo ejecuta
```

Y si `manual-todo.txt` menciona Secrets gestionados por Vault o External
Secrets, créalos en pre-producción antes de continuar: sin ellos los pods se
quedan en `CreateContainerConfigError`.

Antes de aplicar puedes hacer un ensayo en seco:

```bash
./sanba-dr-migrate.sh apply --dry-run
```

## Paso 7 — Aplicar en pre-producción

```bash
./sanba-dr-migrate.sh apply
```

Orden entre namespaces: `location-resources-dr` → `sanba-data-persistence-dr` →
`sanba-core-dr` → `sanba-gui-dr`.

Dentro de cada uno: ServiceAccounts → SCC → Roles y RoleBindings → Secrets →
ConfigMaps → PVCs (espera a `Bound`) → Services → workloads (espera al rollout)
→ Routes → NetworkPolicies, HPA y PDB.

La carga de la base de datos se encadena **justo después** de que PostgreSQL esté
listo y **antes** de que arranque `sanba-core`, para que el backend no se
encuentre un esquema vacío. Con `--no-db` se omite.

## Paso 8 — Cargar los datos (si lo hiciste por separado)

```bash
./sanba-dr-migrate.sh db-migrate
```

`pg_dump -Fc` en producción → descarga con `oc rsync` → `pg_restore` en
contingencia → comparación exacta del número de filas por tabla.

Si la base de datos de pre-producción ya tiene tablas, el script se detiene sin
tocar nada y te ofrece las opciones.

## Paso 9 — Validar

```bash
./sanba-dr-migrate.sh validate ; echo "exit=$?"
```

Informe completo en `out/<run>/reports/validation.txt`:

1. Réplicas listas de cada workload
2. Pods sin `CrashLoopBackOff`, `ImagePullBackOff`, `CreateContainerConfigError` ni `Pending` (con las últimas líneas de log de los que fallan)
3. PVCs en `Bound`
4. Eventos `Warning` recientes
5. **Tabla de URLs**: cada Route con su código HTTP y su tiempo de respuesta
6. Base de datos: `select 1`, conectividad desde `sanba-core-dr` y diff de filas
7. ServiceAccounts existentes y con las mismas SCC que en producción
8. ConfigMaps y Secrets con las mismas claves (solo claves, nunca valores)

### Criterios de éxito

- `validate` termina con `exit=0`.
- Todas las Routes de `sanba-gui-dr` aparecen como `OK` en la tabla de URLs.
- `out/<run>/db/rowcounts.diff` está vacío.
- Cada SA tiene en contingencia las mismas SCC que en producción.
- Y a mano: login en la GUI y una transacción de negocio de extremo a extremo.

## Paso 10 — Repetir el drill

```bash
./sanba-dr-migrate.sh rollback --confirm
```

Borra los cuatro namespaces de contingencia y los ClusterRoleBindings que creó
el script, **solo en pre-producción**. Después vuelve al paso 3.

---

## Todo de una vez

Cuando ya has hecho una pasada completa y sabes que los informes salen limpios:

```bash
./sanba-dr-migrate.sh all
```

Se detiene antes de aplicar si `manual-todo.txt` tiene entradas (`--force` para
continuar igualmente).

Opciones útiles: `--run <ID>` reutiliza una corrida anterior, `--only <ns>` la
limita a un namespace, `--dry-run` no escribe en el destino, `-v` da más detalle.

---

## Comandos `oc` utilizados y su documentación

Todos los comandos que ejecuta el script son comandos estándar documentados por
Red Hat para OpenShift Container Platform 4.18.

| Comando | Dónde se usa | Documentación |
|---|---|---|
| `oc login --token` | Paso 1, manual | [CLI tools 4.18 → OpenShift CLI (oc)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc) |
| `oc version` | preflight | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc whoami --show-server` | preflight | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc auth can-i` | preflight | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc api-resources` | export | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc get -o json` / `-o jsonpath` | export, apply, validate | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc apply -f` | apply | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc patch` | apply (SA `default`) | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc rollout status` | apply | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc logs` | validate | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |
| `oc exec` | db-migrate, validate | [Nodes 4.18 → Working with containers](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-containers) |
| `oc rsync` | db-migrate (transporte del volcado) | [Nodes 4.18 → Copying files to or from a container](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-containers#nodes-containers-copying-files) |
| `oc adm policy add-scc-to-user <scc> -z <sa>` | apply (SCC) | [Authentication and authorization 4.18 → Managing security context constraints](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/authentication_and_authorization/managing-pod-security-policies) |
| `oc delete namespace` | solo `rollback` | [CLI tools 4.18 → oc, developer commands](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#cli-developer-commands) |

Notas sobre dos de ellos:

- **`oc rsync`** es el mecanismo que Red Hat documenta explícitamente para
  *«copying database archives to and from your pods for backup and restore
  purposes»*. Si el contenedor no trae `rsync`, `oc` cae automáticamente a una
  copia por `tar`, que la imagen de PostgreSQL sí incluye.
- **`oc adm policy add-scc-to-user`** solo se usa para las SCC que en producción
  venían de un ClusterRoleBinding o del campo `.users[]` de la SCC. Las que
  venían de un RoleBinding namespaced —la forma recomendada en 4.18— se migran
  como manifiesto RBAC y no se vuelven a conceder.

---

## Problemas frecuentes

### `pg_dump: permission denied for relation <objeto>`

El usuario de la aplicación no tiene `SELECT` sobre alguna tabla o secuencia,
normalmente porque la creó otro rol (un esquema añadido por una migración, un
módulo de terceros). `pg_dump` aborta al leer el valor de esas secuencias.

El script lo detecta **antes** de lanzar el volcado: consulta qué objetos no
puede leer el rol y actúa según el caso.

- Si el pod expone `POSTGRESQL_ADMIN_PASSWORD`, cambia solo al superusuario y
  continúa. Sigue siendo una operación de solo lectura.
- Si no, se detiene sin tocar nada, deja la lista completa en
  `out/<run>/db/objetos-sin-permiso.txt` y te da tres salidas:

  **a) El superusuario existe con otro nombre de variable.** Mira qué tiene el pod:

  ```bash
  oc -n sanba-data-persistence exec <pod> -- env | grep -i -E 'user|admin|superuser'
  ```

  y ponlo en `sanba-dr.env`:

  ```bash
  DB_ADMIN_PASSWORD_ENV="<NOMBRE_DE_LA_VARIABLE>"
  DB_ADMIN_USER="postgres"
  ```

  La contraseña se sigue resolviendo dentro del pod: nunca viaja por la línea de
  comandos del host ni aparece en la lista de procesos.

  **b) Excluir el esquema ilegible.** Perderás esos datos en la prueba:

  ```bash
  DB_DUMP_EXTRA_ARGS="-N service_catalog"
  ```

  **c) Pedir al DBA un GRANT de solo lectura en producción.** El script no lo
  hace por ti porque escribiría en producción:

  ```sql
  GRANT USAGE  ON SCHEMA <esquema>                TO <usuario_app>;
  GRANT SELECT ON ALL TABLES    IN SCHEMA <esquema> TO <usuario_app>;
  GRANT SELECT ON ALL SEQUENCES IN SCHEMA <esquema> TO <usuario_app>;
  ```

Con `DB_DUMP_ROLE` puedes forzar el rol: `auto` (por defecto), `app` o `postgres`.

### RoleBindings que no se migran

OpenShift crea solo los RoleBindings `admin`, `system:deployers`,
`system:image-builders` y `system:image-pullers` en cada namespace nuevo. El
script **no** los migra: copiar el `admin` de producción daría permisos de
administrador sobre el namespace de contingencia a los dueños del proyecto de
producción. Si hace falta, se conceden a mano:

```bash
oc -n sanba-core-dr adm policy add-role-to-user admin <usuario>
```

Los RoleBindings propios de la aplicación sí se migran siempre. Para migrar
también los por defecto: `MIGRATE_DEFAULT_ROLEBINDINGS="true"`.

### `Warning: resource ... is missing the kubectl.kubernetes.io/last-applied-configuration annotation`

Inofensivo. Aparece la primera vez que se hace `oc apply` sobre un recurso que
el clúster había creado por su cuenta (los RoleBindings y ServiceAccounts que
OpenShift genera al crear el namespace). `oc` añade la anotación y sigue.

### `Warning: apps.openshift.io/v1 DeploymentConfig is deprecated in v4.14+`

También inofensivo en 4.18: los DeploymentConfig siguen funcionando. Es un aviso
de que Red Hat recomienda migrar a `Deployment` en el futuro, no un fallo de
esta migración.

---

## Decisiones de implementación

Puntos donde una migración ingenua rompe la aplicación, y cómo se resuelven:

- **Anotaciones de UID/MCS del namespace** (`openshift.io/sa.scc.uid-range`,
  `sa.scc.mcs`, `sa.scc.supplemental-groups`) se eliminan a propósito: las
  regenera el clúster destino. Copiarlas deja pods que no arrancan.
- **Secrets autogenerados** (`service-account-token`, `dockercfg`) y los del
  service-CA operator no se copian: el destino crea los suyos. Los certificados
  de servicio de un clúster no valen en otro.
- **La ServiceAccount `default`** no se aplica como objeto —destruiría los
  secrets que el destino ya le generó—; se le añaden con `oc patch` únicamente
  los `imagePullSecrets` creados a mano, fusionados con los que ya tenía.
- **Reescritura de namespaces en el contenido**: el patrón exige etiqueta DNS
  completa, así que `sanba-core.svc` se reescribe pero `sanba-core-legacy-app`
  no, y aplicarlo dos veces no produce `sanba-core-dr-dr`.
- **Valores binarios de Secret** (keystores, claves privadas) quedan intactos:
  un valor solo se reescribe si decodifica a UTF-8, vuelve a codificar idéntico
  y además menciona un namespace.
- **RoleBindings entre namespaces**: se reescribe el `namespace` de los subjects,
  para que `sanba-core-dr` siga pudiendo leer `location-resources-dr`.
- **RoleBindings por defecto de OpenShift** (`admin`, `system:deployers`,
  `system:image-builders`, `system:image-pullers`) no se migran: el destino los
  crea solos, y copiar el `admin` de producción daría permisos de administrador
  en contingencia a los dueños del proyecto de producción.
- **El rol de `pg_dump` se elige comprobando permisos antes de volcar**, para no
  descubrir a los diez minutos que una secuencia era ilegible.
- **Services**: se quitan `clusterIP`, `clusterIPs`, `ipFamilies` y `nodePort`,
  que son propiedad del clúster de origen.
- **PVCs**: se quitan `volumeName` y las anotaciones del provisionador.
- **Routes**: con `ROUTE_TLS_STRATEGY="default"` se retira el certificado
  embebido de producción, que no valida para el hostname de contingencia, y el
  router usa su wildcard.

## Lo que el script no hace

Queda registrado en `reports/manual-todo.txt`:

- **Instalar operadores.** Detecta los CRs de operador que hay en producción y
  los lista, pero el operador debe existir en pre-producción antes del `apply`.
- **Mirrorear imágenes.** Genera los `skopeo copy`; ejecutarlos es decisión tuya.
- **DNS ni certificados corporativos** para hosts custom.
- **Secrets externos** (Vault, External Secrets): detecta las referencias que no
  resuelven y las lista.
- **Reglas de firewall o proxy** de salida desde pre-producción hacia terceros.
- **ResourceQuota y LimitRange** del destino: los compara y avisa, no los migra.

---

## Estructura

```
sanba-dr-migrate.sh      orquestador
sanba-dr.env             parámetros
route-map.txt            mapeo opcional de hosts custom
lib/                     common, preflight, export, transform, images, apply, database, validate
out/<run>/
  raw/                   objetos crudos de producción
  clean/                 manifiestos listos para aplicar
  reports/               informes
  db/                    volcado, conteos de filas y su diff
  discovered.env         parámetros descubiertos en producción
  mirror-commands.sh     comandos de mirror (generados, no ejecutados)
  migrate.log            traza completa
```
