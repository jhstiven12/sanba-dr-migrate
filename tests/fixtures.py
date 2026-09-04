import json, os, base64, sys
RUN=sys.argv[1]
def w(p,o):
    os.makedirs(os.path.dirname(p),exist_ok=True); json.dump(o,open(p,'w'),indent=1)
def L(i): return {"apiVersion":"v1","kind":"List","items":i}
def meta(n,ns,**kw):
    m={"name":n,"namespace":ns,"uid":"abc-123","resourceVersion":"99","creationTimestamp":"2024-01-01T00:00:00Z","managedFields":[{"manager":"x"}]}
    m.update(kw); return m
b64=lambda s: base64.b64encode(s.encode()).decode()
os.makedirs(f"{RUN}/raw/_cluster",exist_ok=True)
open(f"{RUN}/domain-src.txt","w").write("apps.prod.example.com\n")
open(f"{RUN}/domain-dst.txt","w").write("apps.preprod.example.com\n")
for ns in ["location-resources","sanba-data-persistence","sanba-core","sanba-gui"]:
    w(f"{RUN}/raw/_cluster/ns-{ns}.json",{"apiVersion":"v1","kind":"Namespace","metadata":{"name":ns,"uid":"n-1",
      "labels":{"app":"sanba","kubernetes.io/metadata.name":ns},
      "annotations":{"openshift.io/sa.scc.uid-range":"1000660000/10000","openshift.io/sa.scc.mcs":"s0:c25,c0",
                     "openshift.io/description":"SANBA","openshift.io/requester":"admin"}}})
ns="sanba-core"
w(f"{RUN}/raw/{ns}/serviceaccount.json",L([
 {"apiVersion":"v1","kind":"ServiceAccount","metadata":meta("default",ns),"secrets":[{"name":"default-token-aaaaa"}],
  "imagePullSecrets":[{"name":"default-dockercfg-bbbbb"},{"name":"nexus-pull"}]},
 {"apiVersion":"v1","kind":"ServiceAccount","metadata":meta("builder",ns)},
 {"apiVersion":"v1","kind":"ServiceAccount","metadata":meta("sanba-core-sa",ns),"secrets":[{"name":"sanba-core-sa-token-ccccc"}],
  "imagePullSecrets":[{"name":"sanba-core-sa-dockercfg-ddddd"},{"name":"nexus-pull"}]}]))
w(f"{RUN}/raw/{ns}/secret.json",L([
 {"apiVersion":"v1","kind":"Secret","metadata":meta("sanba-core-sa-token-ccccc",ns),"type":"kubernetes.io/service-account-token","data":{"token":b64("xx")}},
 {"apiVersion":"v1","kind":"Secret","metadata":meta("core-serving-cert",ns,annotations={"service.beta.openshift.io/originating-service-name":"sanba-core"}),"type":"kubernetes.io/tls","data":{"tls.crt":b64("PEM")}},
 {"apiVersion":"v1","kind":"Secret","metadata":meta("nexus-pull",ns),"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":b64('{"auths":{}}')}},
 {"apiVersion":"v1","kind":"Secret","metadata":meta("sanba-core-db",ns),"type":"Opaque","data":{
   "JDBC_URL":b64("jdbc:postgresql://postgresql.sanba-data-persistence.svc.cluster.local:5432/sanba"),
   "PASSWORD":b64("s3cr3t"),
   "CALLBACK_URL":b64("https://sanba-gui-sanba-gui.apps.prod.example.com/callback"),
   "keystore.p12":base64.b64encode(bytes([0,1,2,255,254,200,180]*4)).decode()}}]))
w(f"{RUN}/raw/{ns}/configmap.json",L([
 {"apiVersion":"v1","kind":"ConfigMap","metadata":meta("kube-root-ca.crt",ns),"data":{"ca.crt":"PEM"}},
 {"apiVersion":"v1","kind":"ConfigMap","metadata":meta("sanba-core-config",ns),"data":{
   "application.yaml":"db:\n  host: postgresql.sanba-data-persistence.svc\ngui: http://sanba-gui.sanba-gui.svc:8080\nlegacy: sanba-core-legacy-app\n",
   "LOC_URL":"http://config.location-resources.svc/api",
   "GUI_PUBLIC_URL":"https://sanba-gui-sanba-gui.apps.prod.example.com/app",
   "PAGOS_URL":"https://api-pagos.corp.example.com/v1"}}]))
w(f"{RUN}/raw/{ns}/service.json",L([{"apiVersion":"v1","kind":"Service","metadata":meta("sanba-core",ns),
 "spec":{"clusterIP":"172.30.1.5","clusterIPs":["172.30.1.5"],"ipFamilies":["IPv4"],"ipFamilyPolicy":"SingleStack",
  "ports":[{"port":8080,"targetPort":8080,"nodePort":31000}],"selector":{"app":"sanba-core"},"type":"ClusterIP"},"status":{"loadBalancer":{}}}]))
w(f"{RUN}/raw/{ns}/deployment.json",L([{"apiVersion":"apps/v1","kind":"Deployment",
 "metadata":meta("sanba-core",ns,annotations={"deployment.kubernetes.io/revision":"7","kubectl.kubernetes.io/last-applied-configuration":"{}"}),
 "spec":{"replicas":2,"selector":{"matchLabels":{"app":"sanba-core"}},
  "template":{"metadata":{"creationTimestamp":None,"labels":{"app":"sanba-core"}},
   "spec":{"serviceAccountName":"sanba-core-sa","imagePullSecrets":[{"name":"nexus-pull"}],
    "volumes":[{"name":"cfg","configMap":{"name":"sanba-core-config"}},{"name":"ks","secret":{"secretName":"sanba-core-db"}}],
    "containers":[{"name":"app","image":"nexus.corp.example.com/sanba/sanba-core:1.4.2",
     "args":["--config","http://config.location-resources.svc/api"],
     "env":[{"name":"DB_HOST","value":"postgresql.sanba-data-persistence.svc.cluster.local"},
            {"name":"PORTAL_URL","value":"https://sanba.corp.example.com/portal"},
            {"name":"PASSWORD","valueFrom":{"secretKeyRef":{"name":"sanba-core-db","key":"PASSWORD"}}},
            {"name":"MISSING","valueFrom":{"secretKeyRef":{"name":"vault-managed-secret","key":"k"}}}],
     "envFrom":[{"configMapRef":{"name":"sanba-core-config"}}]}]}}},"status":{"replicas":2}}]))
w(f"{RUN}/raw/{ns}/rolebinding.json",L([
 {"apiVersion":"rbac.authorization.k8s.io/v1","kind":"RoleBinding","metadata":meta("core-reads-location",ns),
  "roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"config-reader"},
  "subjects":[{"kind":"ServiceAccount","name":"sanba-core-sa","namespace":"sanba-core"}]},
 {"apiVersion":"rbac.authorization.k8s.io/v1","kind":"RoleBinding","metadata":meta("core-scc-restricted",ns),
  "roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"system:openshift:scc:restricted-v2"},
  "subjects":[{"kind":"ServiceAccount","name":"sanba-core-sa","namespace":"sanba-core"}]}]))
ns="sanba-gui"
w(f"{RUN}/raw/{ns}/route.json",L([
 {"apiVersion":"route.openshift.io/v1","kind":"Route","metadata":meta("sanba-gui",ns,annotations={"openshift.io/host.generated":"true"}),
  "spec":{"host":"sanba-gui-sanba-gui.apps.prod.example.com","to":{"kind":"Service","name":"sanba-gui"},"port":{"targetPort":8080},
   "tls":{"termination":"edge","certificate":"-----BEGIN CERT-----","key":"-----BEGIN KEY-----"}},"status":{"ingress":[{"host":"x"}]}},
 {"apiVersion":"route.openshift.io/v1","kind":"Route","metadata":meta("sanba-portal",ns),
  "spec":{"host":"sanba.corp.example.com","to":{"kind":"Service","name":"sanba-gui"},
   "tls":{"termination":"reencrypt","destinationCACertificate":"-----BEGIN CERT-----"}},"status":{"ingress":[]}}]))
w(f"{RUN}/raw/{ns}/serviceaccount.json",L([{"apiVersion":"v1","kind":"ServiceAccount","metadata":meta("default",ns)}]))
# El Service se llama igual que su namespace: el caso que rompía el FQDN interno.
w(f"{RUN}/raw/{ns}/service.json",L([{"apiVersion":"v1","kind":"Service","metadata":meta("sanba-gui",ns),
 "spec":{"clusterIP":"172.30.4.4","ports":[{"port":8080}],"selector":{"app":"sanba-gui"}}}]))
w(f"{RUN}/raw/{ns}/deployment.json",L([{"apiVersion":"apps/v1","kind":"Deployment","metadata":meta("sanba-gui",ns),
 "spec":{"replicas":1,"selector":{"matchLabels":{"app":"sanba-gui"}},
  "template":{"metadata":{"labels":{"app":"sanba-gui"}},
   "spec":{"containers":[{"name":"web","image":"image-registry.openshift-image-registry.svc:5000/sanba-gui/sanba-gui:prod",
    "env":[{"name":"API","value":"http://sanba-core.sanba-core.svc:8080"}]}]}}}}]))
ns="sanba-data-persistence"
w(f"{RUN}/raw/{ns}/serviceaccount.json",L([{"apiVersion":"v1","kind":"ServiceAccount","metadata":meta("default",ns)},
 {"apiVersion":"v1","kind":"ServiceAccount","metadata":meta("postgresql-sa",ns)}]))
w(f"{RUN}/raw/{ns}/persistentvolumeclaim.json",L([{"apiVersion":"v1","kind":"PersistentVolumeClaim",
 "metadata":meta("postgresql-data",ns,annotations={"pv.kubernetes.io/bind-completed":"yes","volume.beta.kubernetes.io/storage-provisioner":"ebs"}),
 "spec":{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"50Gi"}},"storageClassName":"gp3-prod","volumeName":"pvc-9999"},"status":{"phase":"Bound"}}]))
w(f"{RUN}/raw/{ns}/deploymentconfig.json",L([{"apiVersion":"apps.openshift.io/v1","kind":"DeploymentConfig","metadata":meta("postgresql",ns),
 "spec":{"replicas":1,"selector":{"name":"postgresql"},
  "triggers":[{"type":"ImageChange","imageChangeParams":{"lastTriggeredImage":"registry.redhat.io/rhel8/postgresql-10@sha256:aaa",
   "from":{"kind":"ImageStreamTag","name":"postgresql:10-el8","namespace":"openshift"}}}],
  "template":{"metadata":{"labels":{"name":"postgresql"}},
   "spec":{"serviceAccountName":"postgresql-sa","containers":[{"name":"postgresql","image":"registry.redhat.io/rhel8/postgresql-10:latest",
    "env":[{"name":"POSTGRESQL_DATABASE","value":"sanba"}]}]}}}}]))
w(f"{RUN}/raw/{ns}/service.json",L([{"apiVersion":"v1","kind":"Service","metadata":meta("postgresql",ns),
 "spec":{"clusterIP":"172.30.9.9","ports":[{"port":5432}],"selector":{"name":"postgresql"}}}]))
ns="location-resources"
w(f"{RUN}/raw/{ns}/serviceaccount.json",L([{"apiVersion":"v1","kind":"ServiceAccount","metadata":meta("default",ns)}]))
# 'config' es el Service del que el backend lee la configuración, y 'core-alias'
# un ExternalName que apunta a otro namespace de la aplicación.
w(f"{RUN}/raw/{ns}/service.json",L([
 {"apiVersion":"v1","kind":"Service","metadata":meta("config",ns),
  "spec":{"clusterIP":"172.30.7.7","ports":[{"port":80}],"selector":{"app":"config"}}},
 {"apiVersion":"v1","kind":"Service","metadata":meta("core-alias",ns,annotations={"doc":"alias de http://sanba-core.sanba-core.svc:8080"}),
  "spec":{"type":"ExternalName","externalName":"sanba-core.sanba-core.svc.cluster.local"}}]))
# La NetworkPolicy solo deja entrar a los otros dos namespaces de la aplicación.
w(f"{RUN}/raw/{ns}/networkpolicy.json",L([
 {"apiVersion":"networking.k8s.io/v1","kind":"NetworkPolicy","metadata":meta("allow-app",ns),
  "spec":{"podSelector":{},"ingress":[{"from":[
     {"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"sanba-core"}}},
     {"namespaceSelector":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"In",
                                                "values":["sanba-gui","sanba-core"]}]}}]}]}}]))
w(f"{RUN}/raw/{ns}/configmap.json",L([{"apiVersion":"v1","kind":"ConfigMap","metadata":meta("endpoints",ns),
 "data":{"core":"http://sanba-core.sanba-core.svc:8080","db":"postgresql.sanba-data-persistence.svc",
         # referencia a un Service que no existe: debe detectarse antes de aplicar
         "huerfano":"http://inexistente.sanba-core.svc:8080"}}]))
w(f"{RUN}/raw/{ns}/role.json",L([{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"Role","metadata":meta("config-reader",ns),
 "rules":[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list"]}]}]))
w(f"{RUN}/raw/{ns}/rolebinding.json",L([{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"RoleBinding","metadata":meta("core-can-read",ns),
 "roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"config-reader"},
 "subjects":[{"kind":"ServiceAccount","name":"sanba-core-sa","namespace":"sanba-core"}]}]))
json.dump([{"name":"scc-anyuid-core","scc":"anyuid","subjects":[{"kind":"ServiceAccount","name":"sanba-core-sa","namespace":"sanba-core"}]}],open(f"{RUN}/raw/_cluster/scc-crb.json","w"))
json.dump([{"scc":"nonroot","users":["system:serviceaccount:sanba-data-persistence:postgresql-sa"]}],open(f"{RUN}/raw/_cluster/scc-users.json","w"))
json.dump([{"name":"core-scc-restricted","scc":"restricted-v2","subjects":[{"name":"sanba-core-sa","namespace":"sanba-core"}]}],open(f"{RUN}/raw/_cluster/scc-rb.json","w"))
w(f"{RUN}/raw/_cluster/clusterrolebinding.json",L([{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRoleBinding",
 "metadata":{"name":"sanba-core-cluster-reader","uid":"z"},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"cluster-reader"},
 "subjects":[{"kind":"ServiceAccount","name":"sanba-core-sa","namespace":"sanba-core"}]}]))
open(f"{RUN}/raw/_cluster/custom-resources.txt","w").write("sanba-core\tservicemonitor.monitoring.coreos.com/sanba-core\n")

# --- pods en ejecución, para resolver el digest EXACTO que corre en PROD -----
DIG_GUI = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
DIG_PG  = "sha256:2222222222222222222222222222222222222222222222222222222222222222"

w(f"{RUN}/raw/sanba-gui/replicaset.json", L([
 {"apiVersion":"apps/v1","kind":"ReplicaSet",
  "metadata":{"name":"sanba-gui-7d9f","namespace":"sanba-gui",
              "ownerReferences":[{"kind":"Deployment","name":"sanba-gui"}]}}]))
w(f"{RUN}/raw/sanba-gui/pod.json", L([
 {"apiVersion":"v1","kind":"Pod",
  "metadata":{"name":"sanba-gui-7d9f-k2m4","namespace":"sanba-gui",
              "ownerReferences":[{"kind":"ReplicaSet","name":"sanba-gui-7d9f"}]},
  "status":{"phase":"Running","containerStatuses":[
     {"name":"web",
      "image":"image-registry.openshift-image-registry.svc:5000/sanba-gui/sanba-gui:prod",
      "imageID":"docker-pullable://image-registry.openshift-image-registry.svc:5000/sanba-gui/sanba-gui@"+DIG_GUI}]}}]))

w(f"{RUN}/raw/sanba-data-persistence/replicationcontroller.json", L([
 {"apiVersion":"v1","kind":"ReplicationController",
  "metadata":{"name":"postgresql-1","namespace":"sanba-data-persistence",
              "ownerReferences":[{"kind":"DeploymentConfig","name":"postgresql"}]}}]))
w(f"{RUN}/raw/sanba-data-persistence/pod.json", L([
 {"apiVersion":"v1","kind":"Pod",
  "metadata":{"name":"postgresql-1-vv8q","namespace":"sanba-data-persistence",
              "ownerReferences":[{"kind":"ReplicationController","name":"postgresql-1"}]},
  "status":{"phase":"Running","containerStatuses":[
     {"name":"postgresql",
      "image":"registry.redhat.io/rhel8/postgresql-10:latest",
      "imageID":"registry.redhat.io/rhel8/postgresql-10@"+DIG_PG}]}}]))

open(f"{RUN}/registry-src.txt","w").write("default-route-openshift-image-registry.apps.prod.example.com\n")
open(f"{RUN}/registry-dst.txt","w").write("default-route-openshift-image-registry.apps.preprod.example.com\n")

print("fixtures OK")
