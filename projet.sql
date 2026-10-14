-- =====================================================================
-- Projet SQL avancé B2 (Ycode A2627_4728) — Livraison de repas
-- Base PostgreSQL : restaurants, plats, clients, livreurs, commandes
-- Règle métier protégée : une commande livrée ne s'annule plus.
-- Ordre : tables, données, fonction/procédure, trigger, vues, rôles, index
-- Le script s'exécute sans erreur sur une base vide, et peut être rejoué.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. LES TABLES
-- ---------------------------------------------------------------------

CREATE TABLE restaurants (
    id      SERIAL PRIMARY KEY,
    nom     TEXT NOT NULL,
    cuisine TEXT NOT NULL,
    ville   TEXT NOT NULL
);

CREATE TABLE plats (
    id            SERIAL PRIMARY KEY,
    restaurant_id INT NOT NULL REFERENCES restaurants(id),
    nom           TEXT NOT NULL,
    prix          NUMERIC(6,2) NOT NULL CHECK (prix > 0)
);

CREATE TABLE clients (
    id        SERIAL PRIMARY KEY,
    nom       TEXT NOT NULL,
    email     TEXT NOT NULL UNIQUE,
    telephone TEXT NOT NULL,
    ville     TEXT NOT NULL
);

CREATE TABLE livreurs (
    id       SERIAL PRIMARY KEY,
    nom      TEXT NOT NULL,
    vehicule TEXT NOT NULL CHECK (vehicule IN ('velo', 'scooter', 'voiture')),
    actif    BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE commandes (
    id            SERIAL PRIMARY KEY,
    client_id     INT NOT NULL REFERENCES clients(id),
    restaurant_id INT NOT NULL REFERENCES restaurants(id),
    livreur_id    INT REFERENCES livreurs(id),
    statut        TEXT NOT NULL DEFAULT 'en_attente'
                  CHECK (statut IN ('en_attente', 'en_preparation',
                                    'en_livraison', 'livree', 'annulee')),
    passee_le     TIMESTAMP NOT NULL DEFAULT now(),
    -- une commande en livraison ou livrée a forcément un livreur
    CONSTRAINT chk_livreur_assigne
        CHECK (statut NOT IN ('en_livraison', 'livree') OR livreur_id IS NOT NULL)
);

CREATE TABLE lignes_commande (
    commande_id INT NOT NULL REFERENCES commandes(id) ON DELETE CASCADE,
    plat_id     INT NOT NULL REFERENCES plats(id),
    quantite    INT NOT NULL CHECK (quantite > 0),
    PRIMARY KEY (commande_id, plat_id)
);

-- ---------------------------------------------------------------------
-- 2. LES DONNÉES (la plus grosse table : lignes_commande, 200 000 lignes ;
--    commandes : 100 000 lignes)
-- ---------------------------------------------------------------------

-- 20 restaurants
INSERT INTO restaurants (nom, cuisine, ville)
SELECT 'Restaurant ' || i,
       (ARRAY['pizza', 'sushi', 'burger', 'indien', 'libanais'])[1 + (i % 5)],
       (ARRAY['Paris', 'Nanterre', 'Courbevoie', 'Versailles'])[1 + (i % 4)]
FROM generate_series(1, 20) AS i;

-- 200 plats : 10 par restaurant (plats 1 à 10 -> restaurant 1, etc.)
INSERT INTO plats (restaurant_id, nom, prix)
SELECT 1 + ((i - 1) / 10),
       'Plat ' || i,
       round((6 + (i % 15) + (i % 7) * 0.5)::numeric, 2)
FROM generate_series(1, 200) AS i;

-- 5 000 clients
INSERT INTO clients (nom, email, telephone, ville)
SELECT 'Client ' || i,
       'client' || i || '@exemple.fr',
       '06' || lpad((10000000 + i * 7)::text, 8, '0'),
       (ARRAY['Paris', 'Nanterre', 'Courbevoie', 'Versailles'])[1 + (i % 4)]
FROM generate_series(1, 5000) AS i;

-- 15 livreurs
INSERT INTO livreurs (nom, vehicule, actif)
SELECT 'Livreur ' || i,
       (ARRAY['velo', 'scooter', 'voiture'])[1 + (i % 3)],
       (i % 10 <> 0)
FROM generate_series(1, 15) AS i;

-- 100 000 commandes. Pour chaque i, le statut dépend de i % 50 :
--   0 -> en_livraison, 1 -> en_preparation, 2 -> annulee, 3 -> en_attente,
--   le reste (94 %) -> livree. Livreur seulement si en livraison ou livrée.
INSERT INTO commandes (client_id, restaurant_id, livreur_id, statut, passee_le)
SELECT 1 + (i % 5000),
       1 + (i % 20),
       CASE WHEN i % 50 IN (0) OR i % 50 > 3 THEN 1 + (i % 15) END,
       CASE i % 50 WHEN 0 THEN 'en_livraison'
                   WHEN 1 THEN 'en_preparation'
                   WHEN 2 THEN 'annulee'
                   WHEN 3 THEN 'en_attente'
                   ELSE 'livree' END,
       timestamp '2026-01-01' + (i % 300) * interval '1 day'
                              + (i % 24) * interval '1 hour'
FROM generate_series(1, 100000) AS i;

-- 2 lignes par commande, sur des plats du bon restaurant :
-- le restaurant r = 1 + (i % 20) possède les plats (r-1)*10+1 à r*10 ;
-- (id / 20) % 10 fait varier le plat choisi d'une commande à l'autre.
INSERT INTO lignes_commande (commande_id, plat_id, quantite)
SELECT c.id,
       (c.restaurant_id - 1) * 10 + 1 + ((c.id / 20) % 10),
       1 + (c.id % 3)
FROM commandes c;

INSERT INTO lignes_commande (commande_id, plat_id, quantite)
SELECT c.id,
       (c.restaurant_id - 1) * 10 + 1 + (((c.id / 20) + 3) % 10),
       1 + (c.id % 2)
FROM commandes c;

-- Statistiques à jour pour que le planificateur fasse de bons choix
ANALYZE;

-- ---------------------------------------------------------------------
-- 3. FONCTION ET PROCÉDURE
-- ---------------------------------------------------------------------

-- Fonction : montant total d'une commande (somme quantité x prix).
-- SECURITY DEFINER : un rôle sans droit sur les tables peut l'appeler.
CREATE OR REPLACE FUNCTION total_commande(p_commande_id INT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COALESCE(SUM(l.quantite * p.prix), 0)
    FROM lignes_commande l
    JOIN plats p ON p.id = l.plat_id
    WHERE l.commande_id = p_commande_id;
$$;

-- Procédure : annuler une commande (le trigger refuse si elle est livrée).
CREATE OR REPLACE PROCEDURE annuler_commande(p_commande_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE commandes
    SET statut = 'annulee'
    WHERE id = p_commande_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Commande % introuvable.', p_commande_id;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. LE TRIGGER : une commande livrée ou annulée est définitive
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION verrouiller_statut_final()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.statut = 'livree' THEN
        RAISE EXCEPTION
            'Commande % déjà livrée : son statut ne peut plus changer (demandé : %).',
            OLD.id, NEW.statut
            USING HINT = 'Pour un litige sur une commande livrée, passer par un remboursement.',
                  ERRCODE = 'check_violation';
    ELSIF OLD.statut = 'annulee' THEN
        RAISE EXCEPTION
            'Commande % déjà annulée : son statut ne peut plus changer (demandé : %).',
            OLD.id, NEW.statut
            USING HINT = 'Créer une nouvelle commande.',
                  ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_statut_final
BEFORE UPDATE OF statut ON commandes
FOR EACH ROW
WHEN (OLD.statut IS DISTINCT FROM NEW.statut)
EXECUTE FUNCTION verrouiller_statut_final();

-- ---------------------------------------------------------------------
-- 5. LES VUES (une par rôle)
-- ---------------------------------------------------------------------

-- Vue du dispatch : suivi des commandes non annulées.
-- Vue simple sur une seule table : modifiable (UPDATE possible via la vue).
-- Elle ne montre ni les clients (email, téléphone) ni les montants.
CREATE OR REPLACE VIEW v_suivi_commandes AS
SELECT id, restaurant_id, livreur_id, statut, passee_le
FROM commandes
WHERE statut <> 'annulee';

-- Vue du contrôle : chiffre d'affaires des commandes livrées, par restaurant.
-- Ne montre que des agrégats : aucune commande ni client individuel.
CREATE OR REPLACE VIEW v_ca_par_restaurant AS
SELECT r.id AS restaurant_id,
       r.nom AS restaurant,
       COUNT(DISTINCT c.id) AS commandes_livrees,
       SUM(l.quantite * p.prix) AS chiffre_affaires
FROM restaurants r
JOIN commandes c ON c.restaurant_id = r.id AND c.statut = 'livree'
JOIN lignes_commande l ON l.commande_id = c.id
JOIN plats p ON p.id = l.plat_id
GROUP BY r.id, r.nom;

-- ---------------------------------------------------------------------
-- 6. LES RÔLES (rôles-métiers + un utilisateur chacun)
-- ---------------------------------------------------------------------
-- Les rôles existent pour tout le serveur : on teste leur existence
-- pour que le script puisse être rejoué sans erreur.

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_dispatch') THEN
        CREATE ROLE role_dispatch NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_controle') THEN
        CREATE ROLE role_controle NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'user_dispatch') THEN
        CREATE ROLE user_dispatch LOGIN PASSWORD 'dispatch123';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'user_controle') THEN
        CREATE ROLE user_controle LOGIN PASSWORD 'controle123';
    END IF;
END
$$;

-- On part de zéro : aucun droit direct sur les tables.
REVOKE ALL ON restaurants, plats, clients, livreurs, commandes, lignes_commande
    FROM role_dispatch, role_controle;

-- Dispatch : travail courant. Lit le suivi, change statut et livreur
-- uniquement (pas la date, pas le client), peut annuler et connaître un total.
GRANT SELECT ON v_suivi_commandes TO role_dispatch;
GRANT UPDATE (statut, livreur_id) ON v_suivi_commandes TO role_dispatch;
GRANT EXECUTE ON PROCEDURE annuler_commande(INT) TO role_dispatch;
GRANT EXECUTE ON FUNCTION total_commande(INT) TO role_dispatch;

-- Contrôle : lecture seule des chiffres, sans rien modifier.
GRANT SELECT ON v_ca_par_restaurant TO role_controle;

-- Les droits vont aux rôles-métiers, les personnes en héritent.
GRANT role_dispatch TO user_dispatch;
GRANT role_controle TO user_controle;

-- Par défaut, tout le monde peut exécuter une fonction : on retire ce droit
-- à PUBLIC pour que seuls les rôles prévus puissent appeler ces routines.
REVOKE EXECUTE ON PROCEDURE annuler_commande(INT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION total_commande(INT) FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 7. LES INDEX (mesurés avant / après dans le README)
-- ---------------------------------------------------------------------

-- Historique d'un client : WHERE client_id = ? ORDER BY passee_le DESC
CREATE INDEX idx_commandes_client_date
    ON commandes (client_id, passee_le DESC);

-- Popularité d'un plat : WHERE plat_id = ?
-- (la clé primaire (commande_id, plat_id) ne sert pas à chercher par plat)
CREATE INDEX idx_lignes_plat
    ON lignes_commande (plat_id);

ANALYZE;
