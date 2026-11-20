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

## Validation de la commande de démarrage

Le cluster du cours n'était pas joignable au moment du test (hors VPN). Nous avons donc vérifié la commande de démarrage du StatefulSet avec trois conteneurs Docker qui reproduisent les noms DNS du Service headless (`cockroachdb-N.cockroachdb`) :

```
+ hostname -f
+ exec /cockroach/cockroach start --insecure --advertise-addr=cockroachdb-1.cockroachdb --listen-addr=0.0.0.0:26257 --http-addr=0.0.0.0:8080 --join=cockroachdb-0.cockroachdb,cockroachdb-1.cockroachdb,cockroachdb-2.cockroachdb

$ cockroach init --insecure --host=cockroachdb-0.cockroachdb
Cluster successfully initialized

$ cockroach node status --insecure --host=cockroachdb-0.cockroachdb
id  address                          build    is_available  is_live
1   cockroachdb-0.cockroachdb:26257  v26.4.1  true          true
2   cockroachdb-1.cockroachdb:26257  v26.4.1  true          true
3   cockroachdb-2.cockroachdb:26257  v26.4.1  true          true

$ getent hosts cockroachdb-1.cockroachdb
172.25.0.3      cockroachdb-1.cockroachdb
```

## Sorties sur la grappe du cours

<!-- TODO (avec le VPN) : exécuter les commandes ci-dessous et coller les sorties / captures ici, puis libérer les ressources. -->

```bash
kubectl apply -f k8s/cockroachdb.yml
kubectl get statefulset
kubectl get pods -l app=cockroachdb -o wide
kubectl exec -it cockroachdb-0 -- /cockroach/cockroach init --insecure
kubectl get pvc
kubectl exec -it cockroachdb-0 -- /cockroach/cockroach node status --insecure
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup cockroachdb-1.cockroachdb
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup cockroachdb

# Ne pas oublier :
kubectl delete -f k8s/cockroachdb.yml
kubectl delete pvc -l app=cockroachdb
```
