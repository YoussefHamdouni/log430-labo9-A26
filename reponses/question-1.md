# Labo 09 – Question 1

> Quelle est la sortie du terminal que vous obtenez? Si vous répétez cette commande sur `yugabyte2` et `yugabyte3`, est-ce que la sortie est identique? Illustrez votre réponse avec des captures d'écran ou des sorties du terminal.

## Avant le test : la table est vide

```
$ ysqlsh -h yugabyte1 -U yugabyte -c "SELECT * FROM orders;"
 id | user_id | total_amount | payment_link | is_paid | created_at
----+---------+--------------+--------------+---------+------------
(0 rows)
```

## Test de concurrence (5 threads, article 3)

```
$ python tests/concurrency_test.py --threads 5 --product 3

  Stratégie : Pessimiste (SELECT FOR UPDATE)
  ❌ thread 0  user_id=1  HTTP 409  0.13s   →  {'error': 'Order failed (stock or constraint issue)'}
  ✅ thread 1  user_id=2  HTTP 201  0.081s  →  {'order_id': 1, 'total': '5.75'}
  ❌ thread 2  user_id=3  HTTP 409  0.269s  →  {'error': 'Order failed (stock or constraint issue)'}
  ❌ thread 3  user_id=1  HTTP 409  0.17s   →  {'error': 'Order failed (stock or constraint issue)'}
  ✅ thread 4  user_id=2  HTTP 201  0.13s   →  {'order_id': 101, 'total': '5.75'}
  Résultat : 2 commande(s) réussie(s), 3 échouée(s) sur 5 threads

  Stratégie : Optimiste  (version + UPDATE conditionnel)
  ❌ thread 0  user_id=1  HTTP 409  0.264s  →  {'error': 'Order failed (stock or constraint issue)'}
  ❌ thread 1  user_id=2  HTTP 409  0.261s  →  {'error': 'Order failed (stock or constraint issue)'}
  ✅ thread 2  user_id=3  HTTP 201  0.028s  →  {'order_id': 2, 'total': '5.75'}
  ✅ thread 3  user_id=1  HTTP 201  0.072s  →  {'order_id': 3, 'total': '5.75'}
  ❌ thread 4  user_id=2  HTTP 409  0.245s  →  {'error': 'Order failed (stock or constraint issue)'}
  Résultat : 2 commande(s) réussie(s), 3 échouée(s) sur 5 threads
```

## Après le test : la même requête sur les trois nœuds

```
$ ysqlsh -h yugabyte1 -U yugabyte -c "SELECT * FROM orders;"
 id  | user_id | total_amount | payment_link | is_paid |          created_at
-----+---------+--------------+--------------+---------+-------------------------------
   1 |       2 |         5.75 |              | f       | 2026-11-20 19:01:05.972783+00
 101 |       2 |         5.75 |              | f       | 2026-11-20 19:01:05.991016+00
   2 |       3 |         5.75 |              | f       | 2026-11-20 19:01:06.252502+00
   3 |       1 |         5.75 |              | f       | 2026-11-20 19:01:06.290613+00
(4 rows)

$ ysqlsh -h yugabyte2 -U yugabyte -c "SELECT * FROM orders;"
 id  | user_id | total_amount | payment_link | is_paid |          created_at
-----+---------+--------------+--------------+---------+-------------------------------
   1 |       2 |         5.75 |              | f       | 2026-11-20 19:01:05.972783+00
 101 |       2 |         5.75 |              | f       | 2026-11-20 19:01:05.991016+00
   2 |       3 |         5.75 |              | f       | 2026-11-20 19:01:06.252502+00
   3 |       1 |         5.75 |              | f       | 2026-11-20 19:01:06.290613+00
(4 rows)

$ ysqlsh -h yugabyte3 -U yugabyte -c "SELECT * FROM orders;"
 id  | user_id | total_amount | payment_link | is_paid |          created_at
-----+---------+--------------+--------------+---------+-------------------------------
   1 |       2 |         5.75 |              | f       | 2026-11-20 19:01:05.972783+00
 101 |       2 |         5.75 |              | f       | 2026-11-20 19:01:05.991016+00
   2 |       3 |         5.75 |              | f       | 2026-11-20 19:01:06.252502+00
   3 |       1 |         5.75 |              | f       | 2026-11-20 19:01:06.290613+00
(4 rows)
```

**Oui, la sortie est identique sur les trois nœuds.** On y trouve les 4 commandes acceptées (2 par stratégie), ce qui correspond au stock initial de 2 unités de l'article 3, réinitialisé avant chaque stratégie.

## Pourquoi la sortie est identique

La table `orders` n'est pas copiée telle quelle sur chaque nœud : elle est découpée en **tablets**, et chaque tablet est **répliqué** sur plusieurs nœuds. Ici, la table n'a qu'un tablet, avec un facteur de réplication de 3. Son leader est `yugabyte3`, et `yugabyte1` et `yugabyte2` sont des followers :

```
$ yb-admin -master_addresses yugabyte1:7100 list_tablets ysql.yugabyte orders 0 include_followers
Tablet-UUID                       Range                         Leader-IP       Followers
d2686052f50547c79b182c412889c56a  hash_split: [0x0000, 0xFFFF]  yugabyte3:9100  yugabyte1:9100,yugabyte2:9100

$ yb-admin -master_addresses yugabyte1:7100 get_universe_config
"numReplicas":3
```

Chaque écriture (`INSERT` dans `orders`) est envoyée au leader du tablet. Elle n'est validée que lorsque la majorité des réplicas (2 sur 3) l'a écrite dans son log, grâce à l'algorithme de consensus **Raft**. Chaque nœud expose aussi la couche SQL (YSQL). Peu importe le nœud auquel on se connecte, la requête est routée vers le leader du tablet, et on obtient donc toujours la même vue, cohérente, des données.

Le cluster a lui aussi un leader au niveau des masters, qui gèrent les métadonnées (tables, emplacement des tablets) :

```
$ curl -s localhost:7000/api/v1/masters
yugabyte1 LEADER
yugabyte3 FOLLOWER
yugabyte2 FOLLOWER
```

## Observation : l'identifiant 101

Les identifiants ne sont pas consécutifs (1, 101, 2, 3). Dans YugabyteDB, chaque connexion réserve un bloc de valeurs de la séquence (cache de 100 valeurs par défaut) pour éviter un aller-retour réseau vers le leader de la séquence à chaque `INSERT`. Deux connexions concurrentes ont donc reçu des blocs différents (1–100 et 101–200). C'est un compromis typique des bases de données distribuées : on sacrifie la continuité des identifiants au profit des performances. L'unicité, elle, reste garantie.

## Note sur le démarrage du cluster

Au premier `docker compose up`, `yugabyte2` s'est arrêté avec l'erreur `Unable to add master yugabyte2 to existing cluster at yugabyte1`. `yugabyte2` et `yugabyte3` ont tenté de rejoindre le cluster en même temps, et un seul changement de configuration des masters peut se faire à la fois. Un simple `docker start yugabyte2` a suffi pour qu'il rejoigne le cluster comme follower.
