# Labo 09 – Question 7

> Quelle base de données affiche le plus bas taux d'erreurs et la plus basse latence ? Est-ce que c'est YugabyteDB ou CockroachDB ?

Comparaison des activités 3 et 5 : mêmes paramètres Locust (50 utilisateurs, spawn rate 5/s, 60 s), même application, mêmes stocks de départ. Captures dans [question-4.md](question-4.md) et [question-6.md](question-6.md).

| | YugabyteDB | CockroachDB |
|---|---|---|
| Requêtes traitées en 60 s | 3861 | **6063** (+57 %) |
| Débit en régime stable | ≈ 65–75 req/s | **≈ 90–133 req/s** |
| Latence moyenne (total) | 414 ms | **157 ms** |
| Médiane (total) | 250 ms | **71 ms** |
| 95e centile (total) | 1400 ms | **610 ms** |
| Pessimiste : moyenne / 95e centile | 290 ms / 1100 ms | **83 ms / 250 ms** |
| Optimiste : moyenne / 95e centile | 698 ms / 1900 ms | **289 ms / 1400 ms** |
| `GET /stocks` : moyenne | 93 ms | **63 ms** |
| Taux d'échec brut (total) | **47 %** | 64,5 % |
| Commandes acceptées / stock disponible (1592) | 1704 (**112 unités vendues en trop**) | **1592 (exact)** |

## Réponse

**CockroachDB a la plus basse latence, sur toutes les mesures.** Sa latence moyenne est environ 2,6 fois plus basse (157 ms contre 414 ms), et il traite 57 % de requêtes de plus avec le même nombre d'utilisateurs. L'écart est le même pour chaque stratégie : le pessimiste passe de 290 à 83 ms, et l'optimiste de 698 à 289 ms.

**Pour le taux d'erreurs, le chiffre brut est trompeur.** YugabyteDB affiche moins d'échecs (47 % contre 64,5 %), mais pour deux raisons qui ne sont pas à son avantage :
1. **CockroachDB a vidé le stock plus vite.** Comme il traite plus de requêtes, il épuise les 1592 unités avant la fin des 60 s. Toutes les commandes suivantes sont refusées (409). Plus de requêtes après l'épuisement du stock, c'est automatiquement un taux d'échec plus élevé.
2. **YugabyteDB a accepté des commandes qu'il aurait dû refuser.** Il a validé 1704 commandes pour seulement 1592 unités (le produit 2 a été vendu 801 fois pour un stock de 500), à cause des mises à jour perdues entre les deux stratégies (voir la question 4). Une partie de ses « succès » sont donc des erreurs de cohérence. CockroachDB, en isolation SERIALIZABLE, a vendu **exactement** le stock disponible.

Si on regarde les erreurs qui comptent vraiment, c'est-à-dire les commandes acceptées à tort, les incohérences de stock et les échecs techniques, **CockroachDB est meilleur** : aucune erreur 500, aucune vente au-delà du stock.

**Conclusion :** pour cette charge, très concurrente et concentrée sur quelques lignes, **CockroachDB** est le meilleur choix : il est plus rapide, traite plus de requêtes et garde des données correctes. Le taux d'échec brut plus bas de YugabyteDB s'explique par un débit plus faible et par des ventes au-delà du stock, pas par une meilleure gestion de la concurrence. Il faut toutefois noter que ce test a été fait avec les 3 nœuds sur la même machine Docker. En production, avec des nœuds sur des serveurs séparés, la latence réseau entre les nœuds changerait les chiffres absolus.
