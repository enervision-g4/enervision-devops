# Portes de qualité — ce qui bloque, ce qui informe

EC03 demande qu'un linter et une analyse de sécurité soient intégrés à la
chaîne. Il demande aussi, implicitement, qu'on sache **quoi faire du
résultat**. Un contrôle qui bloque tout devient un contrôle qu'on
contourne ; un contrôle qui n'a jamais d'effet devient un contrôle qu'on
n'ouvre plus. La répartition ci-dessous est donc un choix explicite, pas
un réglage par défaut.

## Règle de tri

Un contrôle **bloque** s'il satisfait les trois conditions :

1. **déterministe** — même entrée, même verdict, pas de dépendance à un
   service tiers ni au moment de la journée ;
2. **actionnable** — la personne qui voit le rouge peut le corriger tout
   de suite, dans la PR en cours ;
3. **conséquent** — laisser passer casse quelque chose de réel : un
   déploiement, une donnée, un secret.

Un contrôle qui échoue une seule de ces conditions **informe** : il
produit un artefact consultable, il ne ferme pas la porte.

## Tableau

| Contrôle | Où | Verdict | Pourquoi |
|---|---|---|---|
| **gitleaks** | `security-scan.yml` | **bloquant** | Un secret commité reste dans l'historique même après retrait. L'historique Git est une pièce évaluée : il doit être propre par construction. Le seul contrôle où « on corrigera plus tard » n'existe pas. |
| **Tests unitaires** (pytest, npm test) | `ci.yml` | **bloquant** | Exigence centrale d'EC03. Déterministe, actionnable, conséquent. |
| **ruff check / ruff format** | `ci.yml` | **bloquant** | Quelques secondes, verdict binaire, correction automatique disponible. |
| **eslint** | `ci.yml` | **bloquant** | Idem côté dashboard. |
| **prettier** | `ci.yml` | informatif | Le dépôt dashboard n'a pas encore de configuration ; bloquer sur un formatage non défini n'apprendrait rien. À basculer en bloquant dès qu'une configuration existe. |
| **mypy** | `ci.yml` | informatif | Seul `enervision-etl` est aujourd'hui `strict`-propre. Bloquer imposerait un typage complet à des dépôts qui n'y sont pas — à rebasculer service par service. |
| **Trivy — HIGH/CRITICAL corrigeables** (`ignore-unfixed: true`) | `security-scan.yml` | **bloquant** | Une vulnérabilité avec correctif disponible est actionnable : on monte la version. |
| **Trivy — vulnérabilités sans correctif** | `security-scan.yml` | informatif | Rien à faire tant que l'amont n'a pas publié. Bloquer dessus apprendrait à l'équipe à ignorer le voyant rouge — exactement le contraire du but. |
| **yamllint** | `ci.yml` | **bloquant** | Ce dépôt est presque entièrement du YAML : c'est son linter principal. |
| **actionlint** | `ci.yml` | **bloquant** | Détecte les erreurs de workflow avant qu'elles ne se manifestent en production de CI, y compris les injections de script par une entrée non fiable. |
| **kubeconform** (manifestes construits) | `ci.yml` | **bloquant** | Un manifeste invalide fait échouer le déploiement. Autant le savoir en PR. |
| **ansible-lint** (profil `production`) | `security-scan.yml` | **bloquant** | Le profil `production` interdit précisément les motifs qui rendent un playbook non idempotent ou non rejouable. |
| **`terraform fmt` + `validate`** | `ci.yml` | **bloquant** | Instantané et binaire. |
| **checkov** (Terraform) | `security-scan.yml` | informatif | Beaucoup de règles portent sur des défauts Azure de faible gravité — journalisation, points de terminaison privés — dont plusieurs sont ici des choix assumés et documentés. Bloquer reviendrait à discuter de style, pas de risque. |
| **OWASP ZAP baseline** | `deploy-dev.yml` | informatif **pour la fusion**, **bloquant pour la promotion** | Un baseline sur une API de cette taille remonte surtout des en-têtes manquants. Il ne ferme pas une PR, mais `deploy-prod.yml` refuse de déployer si le passage sur dev n'est pas vert dans son ensemble. |
| **Contrôle de charge k6** (p95 < 500 ms, < 1 % d'erreurs) | `deploy-dev.yml` | **bloquant** | Seuils volontairement larges : ils attrapent une régression grossière — base saturée, pool épuisé — sans transformer une machine d'école partagée en source de faux positifs. |
| **Fumée `/health` après rollout** | `deploy-k8s.yml` | **bloquant** | Un rollout « réussi » dont l'application répond 500 n'est pas un déploiement réussi. |
| **Exercice de restauration** | `backup-restore-drill.yml` | **bloquant sur le job** (hebdomadaire) | Ne bloque aucune fusion, mais son échec signifie que les sauvegardes ne valent rien : c'est une alerte, pas une statistique. |

## Lien avec la protection de branche

Trois noms de jobs sont exigés comme *status checks* par la protection de
branche configurée sur GitHub :

```
build           (ci.yml)
test            (ci.yml)
security-scan   (security-scan.yml)
```

**Renommer l'un de ces jobs neutralise silencieusement la protection** :
GitHub attend un check qui n'arrive jamais, ou ne l'attend plus du tout.
En cas de renommage, mettre la liste à jour dans
`Settings > Branches > Branch protection rules`.

La configuration exacte à cocher est dans `runbook.md`, section 1.4.

## Ce que la protection de branche impose

| Règle | Valeur | Raison |
|---|---|---|
| Pull request obligatoire | oui | L'historique doit rester relisible : chaque changement passe par une PR traçable. |
| Revues approuvées exigées | **0** | Choix délibéré : ne pas bloquer une fusion sur la disponibilité d'un relecteur. |
| Poussée forcée | interdite | L'historique Git est une pièce évaluée : il ne doit pas pouvoir être réécrit. |
| Suppression de branche | interdite | Idem, sur `main` et `develop`. |
| Résolution des conversations | exigée | Un commentaire de revue non traité ne disparaît pas dans une fusion. |
| Application aux administrateurs | non | Porte de sortie assumée en cas de blocage la veille de la soutenance. |

En complément, `.github/workflows/enforce-branch-flow.yml` vérifie à
chaque PR que le flux de branches est respecté : `main` n'accepte que des
PR venant de `develop`, `develop` n'accepte que `feature/*`, `fix/*`,
`chore/*` et `dependabot/*`. C'est la règle que GitHub ne sait pas
exprimer nativement.

## Faire évoluer ces choix

- **Activer la revue obligatoire** : passer *Require approvals* à 1 dans
  la règle de protection de branche (Settings > Branches).
- **Rendre prettier ou mypy bloquant** : retirer le `|| echo` ou le
  `continue-on-error` correspondant dans `ci.yml`.
- **Durcir les seuils k6** : ils sont dans le script inline de
  `deploy-dev.yml`, section `thresholds`.
- **Rendre checkov bloquant** : retirer `soft_fail: true` et
  `continue-on-error: true` dans `security-scan.yml`, après avoir traité
  ou explicitement écarté les règles remontées.
