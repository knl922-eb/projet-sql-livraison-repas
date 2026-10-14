# Livraison de repas — projet SQL avancé B2

Base PostgreSQL d'une plateforme de livraison de repas : restaurants, plats, clients, livreurs, commandes.
Règle métier protégée : **une commande livrée ne s'annule plus**.

Tables : `restaurants`, `plats`, `clients`, `livreurs`, `commandes`, `lignes_commande` (100 000 commandes, 200 000 lignes de commande, générées avec `generate_series`).

## Lancer le projet

```bash
docker compose exec db psql -U festival -c "DROP DATABASE IF EXISTS projet WITH (FORCE)" -c "CREATE DATABASE projet"
docker compose cp ../../mon-projet/projet.sql db:/tmp/projet.sql
docker compose exec db psql -U festival -d projet -f /tmp/projet.sql
```

Les scénarios de la démo sont dans `demo.sql`. Mots de passe de test : `dispatch123` (user_dispatch) et `controle123` (user_controle).

## Fonction et procédure

- **Ce qu'il fait :** `total_commande(id)` calcule le montant d'une commande (quantité × prix de chaque ligne). `annuler_commande(id)` passe une commande à « annulée » et signale une commande introuvable.
- **Pourquoi il est là :** le calcul du montant est centralisé au même endroit pour tous ; l'annulation est une opération métier unique, que le dispatch peut appeler sans avoir de droit sur la table (`SECURITY DEFINER`).
- **La preuve :** `SELECT total_commande(3);` renvoie 34,50. `CALL annuler_commande(53);` fonctionne (commande en attente) ; `CALL annuler_commande(999999);` répond « Commande 999999 introuvable ».

## Trigger

- **Ce qu'il fait :** `trg_statut_final` se déclenche avant tout changement de statut. Si la commande est déjà livrée ou annulée, il refuse avec un message qui dit quelle commande, quel statut était demandé et quoi faire à la place.
- **Pourquoi il est là :** dans la base plutôt que dans l'application, parce que toutes les voies d'accès (la vue du dispatch, la procédure, un script, un futur service) passent par lui : aucune ne peut contourner la règle.
- **La preuve :** `UPDATE commandes SET statut = 'annulee' WHERE id = 4;` (commande livrée) échoue avec « Commande 4 déjà livrée : son statut ne peut plus changer (demandé : annulee). » Sur la commande 53 (en attente), l'annulation passe.

## Index

Deux index, mesurés avec `EXPLAIN ANALYZE` (100 000 commandes, 200 000 lignes) :

| Index | Requête | Avant | Après |
|---|---|---|---|
| `idx_commandes_client_date` | historique d'un client : `WHERE client_id = 42 ORDER BY passee_le DESC` | Seq Scan, 4,5 ms | Bitmap Index Scan, 0,10 ms |
| `idx_lignes_plat` | popularité d'un plat : `WHERE plat_id = 57` | Seq Scan, 8,0 ms | Bitmap Index Scan, 1,6 ms |

- **Ce qu'il fait :** le premier retrouve les commandes d'un client déjà triées par date ; le second retrouve les lignes d'un plat.
- **Pourquoi il est là :** la clé primaire de `lignes_commande` est `(commande_id, plat_id)`, elle ne sert pas à chercher par plat ; et sans index sur `client_id`, PostgreSQL lit toute la table.
- **La preuve :** `DROP INDEX` puis `EXPLAIN ANALYZE` (avant), `CREATE INDEX` + `ANALYZE` puis `EXPLAIN ANALYZE` (après). Les temps varient d'une machine à l'autre, le passage de Seq Scan à Index Scan reste.

## Rôles

- **Ce qu'il fait :** `role_dispatch` (travail courant : suivre les commandes, changer statut et livreur, annuler) et `role_controle` (lecture seule des chiffres). Chacun a un utilisateur (`user_dispatch`, `user_controle`) qui hérite du rôle ; aucun droit n'est donné directement aux personnes.
- **Pourquoi il est là :** chaque profil n'a que le nécessaire : le contrôle ne peut rien modifier, le dispatch ne voit ni les coordonnées des clients ni les montants.
- **La preuve :** `SET ROLE user_dispatch;` puis `UPDATE v_suivi_commandes SET statut = 'en_preparation' WHERE id = 3;` marche, `SELECT * FROM clients;` donne « permission denied ». `SET ROLE user_controle;` puis `SELECT * FROM v_ca_par_restaurant;` marche, `UPDATE v_suivi_commandes ...` est refusé.

## Vues

- **Ce qu'il fait :** `v_suivi_commandes` (pour le dispatch) montre les commandes non annulées sans client ni montant ; `v_ca_par_restaurant` (pour le contrôle) donne le chiffre d'affaires des commandes livrées par restaurant.
- **Pourquoi il est là :** chaque rôle a le droit sur sa vue, pas sur les tables : la vue est la seule porte d'entrée et elle cache le reste.
- **La preuve :** en tant que `user_controle`, `SELECT * FROM commandes;` est refusé alors que `SELECT * FROM v_ca_par_restaurant;` répond.

## Données

- **Ce qu'il fait :** 20 restaurants, 200 plats, 5 000 clients, 15 livreurs, 100 000 commandes (94 % livrées) et 200 000 lignes de commande, fabriqués par `generate_series`.
- **Pourquoi il est là :** avec ce volume, la différence avant/après des index est mesurable.
- **La preuve :** `SELECT count(*) FROM commandes;` → 100000 ; `SELECT count(*) FROM lignes_commande;` → 200000.

## Organisation

Chaque membre commite son propre travail (historique Git).
