# Labo 09 – Question 8

> Pourquoi un `Service` headless est-il nécessaire ici, alors qu'un Service ordinaire suffisait au Labo 05 ? Que contient l'entrée DNS d'un pod du StatefulSet, et que se passerait-il si vous utilisiez un `Deployment` à la place ? Illustrez avec la sortie de `kubectl get pods` et d'un `nslookup` depuis un pod.

Manifeste : `k8s/cockroachdb.yml` (Service headless `cockroachdb`, StatefulSet `cockroachdb`, Service normal `cockroachdb-public`).

## Pourquoi un Service headless

Au labo 05, le Store Manager était **sans état** : n'importe quelle réplique pouvait répondre à n'importe quelle requête. Un Service ordinaire suffisait. Il donne **une seule adresse IP virtuelle** (ClusterIP), et kube-proxy répartit les connexions au hasard entre les pods. Le client ne sait pas, et n'a pas besoin de savoir, quel pod lui répond.

Dans un cluster CockroachDB, c'est l'inverse. Chaque nœud a une **identité propre** : son identifiant dans le cluster, les plages de données (ranges) dont il est leader ou réplica, et son propre disque. Les nœuds doivent se contacter **individuellement**. Le nœud 1 doit joindre le nœud 0 précisément pour rejoindre le cluster, et les messages Raft d'une range doivent aller au bon réplica. Une IP virtuelle qui répartit au hasard rendrait cela impossible : un message destiné au nœud 2 pourrait arriver au nœud 0.

Avec `clusterIP: None`, Kubernetes ne crée pas d'IP virtuelle. À la place, le DNS du cluster publie **un enregistrement par pod**. C'est exactement ce qu'utilise la commande de démarrage :

```yaml
--advertise-addr=$(hostname -f)
--join=cockroachdb-0.cockroachdb,cockroachdb-1.cockroachdb,cockroachdb-2.cockroachdb
```

`publishNotReadyAddresses: true` est aussi indispensable. Un nœud CockroachDB n'est « prêt » qu'après avoir rejoint le cluster, mais pour le rejoindre il doit résoudre le nom des autres nœuds. Sans cette option, les noms ne seraient publiés qu'une fois les pods prêts, et aucun ne le deviendrait jamais (interblocage).

Le Service normal `cockroachdb-public` reste utile, mais pour l'**application**. Pour elle, n'importe quel nœud convient, puisque chaque nœud peut traiter une requête SQL et la router. C'est vers lui que pointe la chaîne de connexion (`DB_HOST=cockroachdb-public`).

## Contenu de l'entrée DNS d'un pod

Pour un pod de StatefulSet rattaché au Service headless, le nom DNS est :

```
<nom-du-pod>.<service-headless>.<namespace>.svc.cluster.local
cockroachdb-1.cockroachdb.log430-espace-etudiant-17.svc.cluster.local
```

L'enregistrement A associe ce nom à l'**IP du pod lui-même**, pas à une IP virtuelle. Le nom ne change jamais, car il est construit à partir de l'ordinal (`-0`, `-1`, `-2`). Si le pod est recréé avec une nouvelle IP, le DNS est mis à jour et le nom reste le même. Une requête sur le nom du Service seul (`cockroachdb`) retourne les IP de **tous** les pods.

## Et avec un Deployment ?

1. **Noms imprévisibles.** Les pods s'appelleraient `cockroachdb-7d9f8c6b5-x2kqp`, avec un nouveau suffixe aléatoire à chaque recréation. La liste `--join` ne pourrait pas être écrite d'avance, et `--advertise-addr` changerait à chaque redémarrage. Le cluster verrait alors un « nouveau » nœud plutôt que le retour de l'ancien.
2. **Pas de disque par pod.** Un Deployment n'a pas de `volumeClaimTemplates`. Soit les pods n'ont aucun volume persistant (données perdues au redémarrage), soit ils partagent le même PVC, ce que `ReadWriteOnce` interdit, et ce qui serait de toute façon incorrect, puisque chaque nœud doit avoir ses propres données. Avec le StatefulSet, `cockroachdb-1` retrouve toujours `datadir-cockroachdb-1`.
3. **Pas d'ordre de démarrage.** Le StatefulSet crée et met à jour les pods dans l'ordre (0, 1, 2) et un à la fois. Un Deployment remplace les pods en parallèle, et pourrait arrêter la majorité des réplicas d'une range en même temps, ce qui ferait perdre le quorum Raft.

## Déploiement sur la grappe du cours

```
$ kubectl apply -f k8s/cockroachdb.yml
service/cockroachdb created
statefulset.apps/cockroachdb created
service/cockroachdb-public created

$ kubectl exec cockroachdb-0 -- /cockroach/cockroach init --insecure
Cluster successfully initialized

$ kubectl get statefulset cockroachdb
NAME          READY   AGE
cockroachdb   3/3     57s

$ kubectl get pods -l app=cockroachdb -o wide
NAME            READY   STATUS    RESTARTS   AGE   IP             NODE
cockroachdb-0   1/1     Running   0          58s   10.1.102.221   mk8s-fiware-1
cockroachdb-1   1/1     Running   0          51s   10.1.204.156   mk8s-fiware-2
cockroachdb-2   1/1     Running   0          44s   10.1.163.28    atreides

$ kubectl get pvc -l app=cockroachdb
NAME                    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
datadir-cockroachdb-0   Bound    pvc-61edaad8-aa03-42c4-99c7-65bf6e68d13c   1Gi        RWO            default-storage
datadir-cockroachdb-1   Bound    pvc-d1d50a0b-9e71-4d5a-9355-0b223be218e7   1Gi        RWO            default-storage
datadir-cockroachdb-2   Bound    pvc-197a7a53-8b4e-4205-aa47-e20be734a691   1Gi        RWO            default-storage

$ kubectl get svc -l app=cockroachdb
NAME                 TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)
cockroachdb          ClusterIP   None             <none>        26257/TCP,8080/TCP
cockroachdb-public   ClusterIP   10.152.183.132   <none>        26257/TCP

$ kubectl exec cockroachdb-0 -- /cockroach/cockroach node status --insecure
id  address                                                                       build    is_available  is_live
1   cockroachdb-0.cockroachdb.log430-espace-etudiant-17.svc.cluster.local:26257   v26.4.1  true          true
2   cockroachdb-1.cockroachdb.log430-espace-etudiant-17.svc.cluster.local:26257   v26.4.1  true          true
3   cockroachdb-2.cockroachdb.log430-espace-etudiant-17.svc.cluster.local:26257   v26.4.1  true          true
```

Les noms ordinaux sont prévisibles (`cockroachdb-0`, `-1`, `-2`), chaque pod a son propre volume (`datadir-cockroachdb-N`), et chaque nœud s'annonce au cluster sous son nom DNS stable. C'est le résultat de `$(hostname -f)` :

```
$ kubectl exec cockroachdb-1 -- hostname -f
cockroachdb-1.cockroachdb.log430-espace-etudiant-17.svc.cluster.local
```

Le Service headless n'a pas d'IP virtuelle (`CLUSTER-IP: None`), contrairement à `cockroachdb-public` (`10.152.183.132`).

## nslookup depuis un pod

Le nom d'un pod résout vers **l'IP de ce pod** (`10.1.204.156` est bien `cockroachdb-1`) :

```
$ kubectl run dns-test --rm -i --image=busybox:1.36 --restart=Never -- nslookup cockroachdb-1.cockroachdb.log430-espace-etudiant-17.svc.cluster.local
Server:    10.152.183.10
Address:   10.152.183.10:53
Name:      cockroachdb-1.cockroachdb.log430-espace-etudiant-17.svc.cluster.local
Address:   10.1.204.156
```

Le nom du Service headless retourne **les IP des trois pods**, et non une IP virtuelle :

```
$ kubectl run dns-test --rm -i --image=busybox:1.36 --restart=Never -- nslookup cockroachdb
Name:      cockroachdb.log430-espace-etudiant-17.svc.cluster.local
Address:   10.1.204.156
Name:      cockroachdb.log430-espace-etudiant-17.svc.cluster.local
Address:   10.1.163.28
Name:      cockroachdb.log430-espace-etudiant-17.svc.cluster.local
Address:   10.1.102.221
```

Le Service normal, lui, retourne **une seule IP virtuelle** (ClusterIP), derrière laquelle kube-proxy répartit les connexions. C'est ce dont l'application a besoin, pas les nœuds entre eux :

```
$ kubectl run dns-test --rm -i --image=busybox:1.36 --restart=Never -- nslookup cockroachdb-public
Name:      cockroachdb-public.log430-espace-etudiant-17.svc.cluster.local
Address:   10.152.183.132
```

## Libération des ressources

```
$ kubectl delete -f k8s/cockroachdb.yml
service "cockroachdb" deleted
statefulset.apps "cockroachdb" deleted
service "cockroachdb-public" deleted

$ kubectl delete pvc -l app=cockroachdb
persistentvolumeclaim "datadir-cockroachdb-0" deleted
persistentvolumeclaim "datadir-cockroachdb-1" deleted
persistentvolumeclaim "datadir-cockroachdb-2" deleted
```
