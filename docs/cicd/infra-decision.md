# Décision d'infrastructure — on-premise + Azure pour la seule sauvegarde

> Statut : **actée**, appliquée dans `infra/`
> Cadre : `EnerVision - Infra AWS vs OnPremise`, qui impose d'argumenter
> tout choix d'infrastructure sur cinq axes.
> Concerne : EC01 (conception), EC04 (cloud).

## Décision

L'ensemble des charges applicatives d'EnerVision — dashboard, API,
collecteur, bus Kafka, consommateurs, base TimescaleDB, supervision —
s'exécute sur le **serveur on-premise de l'école**, dans un cluster
**k3s** unique découpé en deux namespaces `g4-dev` et `g4-prod`.

**Azure n'intervient que pour une chose : stocker les sauvegardes
chiffrées de la base.** Aucun composant applicatif n'y tourne. Ce
périmètre est délibérément étroit, et volontairement réservé pour
accueillir plus tard la zone externe déjà prévue en EC01 (archive long
terme, module ML).

C'est donc un choix **hybride, à dominante on-premise**, avec une
frontière nette : *le calcul reste chez nous, seule la copie de secours
sort.*

## Pourquoi une décision, et pas un réflexe

Le document cadre est explicite : le choix lui-même n'est pas noté, son
argumentation l'est. Un « on-premise parce qu'on a un serveur » ne vaut
rien. Ce qui suit est la justification sur les cinq axes imposés, dans
l'ordre de poids **pour ce projet précis** — pas dans l'ordre d'une
grille générique.

---

## Axe 1 — Conformité légale et RGPD

EnerVision traite des relevés de consommation énergétique par site. Deux
choses en découlent.

**Ces données sont plus sensibles qu'elles n'en ont l'air.** Une courbe
de charge à pas fin est une donnée de comportement : sur un site
tertiaire elle révèle les horaires d'occupation, sur un site industriel
elle révèle les cadences de production, donc de l'information
commercialement exploitable. Rattachée à un local ou à un foyer, elle
devient une donnée à caractère personnel au sens du RGPD. Le projet doit
donc être conçu comme s'il traitait des données personnelles, même quand
le jeu de données de démonstration est synthétique.

**Conséquences concrètes retenues :**

- **Minimisation du nombre de responsables de traitement.** Tout garder
  sur une machine maîtrisée réduit la chaîne de sous-traitance à zéro
  pour le traitement, et à un seul acteur (Microsoft) pour la seule
  conservation de sauvegardes. Moins d'acteurs, moins de contrats
  d'article 28 à tenir, moins de registre à documenter.
- **Chiffrement de bout en bout côté client.** Les sauvegardes sont
  chiffrées par restic *avant* de quitter le serveur. Le fournisseur
  cloud stocke des blocs illisibles : il n'a pas accès aux données, ce
  qui rend le transfert nettement plus défendable qu'un simple
  « chiffrement au repos » géré par le fournisseur, où c'est lui qui
  détient les clés.
- **Localisation.** `location = "francecentral"` dans
  `infra/terraform/envs/*` : les sauvegardes ne quittent pas le
  territoire. La redondance de production est **ZRS** et non GRS
  précisément pour ça — GRS réplique vers une région secondaire, ce qui
  ferait sortir la donnée du périmètre qu'on vient de choisir.
- Le secteur de l'énergie relève par ailleurs des obligations de
  résilience des services essentiels (NIS2). C'est ce qui rend
  l'exercice de restauration automatisé (`backup-restore-drill.yml`) un
  élément de conformité, et pas une coquetterie d'ingénieur.

**Verdict de l'axe : favorable à l'on-premise**, avec un cloud toléré
uniquement là où le chiffrement client neutralise l'exposition.

---

## Axe 2 — Souveraineté des données

Distinct du précédent : le RGPD parle de licéité, la souveraineté parle
de **qui peut techniquement et juridiquement contraindre l'accès**.

AWS et Azure sont tous deux soumis au *CLOUD Act* : une autorité
américaine peut exiger d'un fournisseur de droit américain la
communication de données qu'il détient, y compris hébergées en Europe.
Cette exposition n'est pas neutralisée par le choix d'une région
européenne.

Elle est en revanche largement neutralisée par le **chiffrement côté
client avec une clé que nous seuls détenons**. Ce que Microsoft peut être
contraint de remettre, ce sont des blobs chiffrés dont il n'a pas la
passphrase. C'est la raison de fond pour laquelle Azure est acceptable
*pour la sauvegarde* et ne le serait pas pour la base vive : une base
managée déchiffre nécessairement pour servir les requêtes, la clé est
donc chez le fournisseur.

Argument miroir, à assumer : le serveur de l'école n'est pas non plus
notre propriété. Mais il est dans une juridiction unique, sur un réseau
que l'établissement maîtrise, sans intermédiaire contractuel étranger.
Pour un projet dont l'un des enjeux affichés est la sensibilité des
données énergétiques, c'est le meilleur compromis atteignable.

**Verdict de l'axe : nettement favorable à l'on-premise.** C'est, avec
l'axe 1, l'axe qui pèse le plus lourd ici.

---

## Axe 3 — Scalabilité et élasticité

C'est l'axe où le cloud gagne — et où il faut être honnête sur le fait
qu'il ne sert pas ici.

La charge d'EnerVision est **prévisible et plate** : un collecteur
interroge une API à intervalle fixe, un flux Kafka constant, un dashboard
consulté par une poignée d'utilisateurs. Il n'y a pas de pic
saisonnier, pas de trafic public, pas d'événement de lancement.
L'élasticité — payer à la charge et absorber un facteur dix en minutes —
répond à un problème que ce projet n'a pas.

Ce dont le projet a besoin, c'est de **scalabilité de conception** :
pouvoir grandir sans réécriture. C'est exactement ce que k3s apporte, et
c'est ce qui a motivé son choix plutôt que Docker Compose :

- passer un composant de 1 à N replicas est une ligne dans une surcouche
  (`infra/k8s/overlays/prod/kustomization.yaml`) ;
- ajouter une machine au cluster est une ligne d'inventaire Ansible et
  une commande `k3s agent --server` : les rôles ne présupposent nulle
  part qu'il n'existe qu'un nœud ;
- les rôles Ansible et les modules Terraform ne référencent aucune
  adresse ni aucun nom propre au serveur de l'école — changer
  d'inventaire suffit à viser une VM cloud (`inventories/azure.ini` est
  là pour le démontrer, pas pour décorer).

Autrement dit : **on n'achète pas l'élasticité dont on n'a pas besoin,
mais on garde ouverte la porte pour l'obtenir.**

**Verdict de l'axe : favorable au cloud dans l'absolu, non discriminant
ici.** Le risque réel — se peindre dans un coin — est traité par la
portabilité, pas par la facturation à l'usage.

---

## Axe 4 — Coût et FinOps

Le serveur est fourni et déjà amorti : son coût marginal pour le projet
est nul. La seule dépense est le stockage Azure, et elle est petite par
construction :

| Poste | Dimensionnement | Ordre de grandeur |
|---|---|---|
| Blob Storage (sauvegardes) | quelques Go, dédupliqués par restic | quelques euros/mois |
| Sortie réseau | un dump compressé par jour | négligeable |
| Stockage de l'état Terraform | quelques Ko | négligeable |

Trois décisions FinOps explicites, visibles dans le code :

1. **Rétention par `restic forget`**, pas par une règle de cycle de vie
   Azure. Ce n'est pas d'abord un choix de coût : supprimer des blobs par
   âge dans un dépôt dédupliqué détruit des blocs encore référencés et
   corrompt le dépôt. La règle Azure ne fait donc que du changement de
   tier — voir `infra/terraform/modules/azure-backup-storage/main.tf`.
2. **Passage en tier Cool** au-delà de 30 jours (14 en dev) : les
   sauvegardes anciennes ne sont presque jamais relues.
3. **Redondance graduée** : LRS en dev, ZRS en prod. Payer une
   redondance multi-zones pour des données de développement n'a aucun
   sens.

Comparaison honnête avec l'alternative AWS complète : une architecture
équivalente (RDS PostgreSQL avec extension TimescaleDB, MSK ou Kafka
auto-géré, ECS ou EKS, ALB, CloudWatch) coûte de l'ordre de plusieurs
centaines d'euros par mois — pour une charge qu'un seul serveur absorbe
sans transpirer. Ce n'est pas un projet où le cloud est moins cher.

**Verdict de l'axe : nettement favorable à l'on-premise.**

---

## Axe 5 — Complexité opérationnelle

L'axe le plus défavorable à notre choix, et il faut le dire tel quel.

**Ce que l'on-premise nous coûte :**

- pas de haute disponibilité — un seul nœud, une seule alimentation, un
  seul disque. Si la machine tombe, tout tombe ;
- les sauvegardes, les mises à jour de sécurité, le pare-feu et les
  certificats sont à notre charge ;
- k3s ajoute un plan de contrôle Kubernetes à comprendre, là où Docker
  Compose se lisait d'un coup d'œil.

**Ce qui a été mis en face, concrètement :**

- **k3s plutôt que Kubernetes complet** : une seule binaire, base de
  données embarquée, Traefik et le provisionneur de stockage inclus. Le
  vocabulaire Kubernetes sans la charge d'exploitation d'un cluster
  managé.
- **Tout est décrit en code** : `infra/ansible/` reconstruit un serveur
  depuis zéro, `infra/terraform/` recrée les ressources Azure, et
  `scripts/k8s-apply.sh` est la *même* séquence de déploiement en CI et
  à la main. La reconstruction est un playbook, pas un souvenir.
- **La panne matérielle est traitée là où elle fait mal** : la donnée.
  Une sauvegarde chiffrée quotidienne part hors site, et
  `backup-restore-drill.yml` la restaure chaque semaine dans une base
  jetable, sur un runner GitHub — sans jamais toucher au serveur de
  l'école. C'est ce qui prouve qu'on peut repartir ailleurs.
- **Le point de bascule est identifié** : si le serveur devenait
  indisponible durablement, `inventories/azure.ini` + `playbooks/site.yml`
  reconstruisent le cluster sur une VM, et `scripts/db-restore-drill.sh`
  y recharge la dernière sauvegarde. Le chemin est écrit, pas improvisé.

**Verdict de l'axe : défavorable à l'on-premise**, atténué mais pas
annulé. C'est le prix assumé des axes 1 et 2.

---

## Synthèse

| Axe | On-premise | AWS / cloud complet | Poids ici |
|---|---|---|---|
| Conformité et RGPD | **+** chaîne courte, chiffrement client | − sous-traitance à documenter | fort |
| Souveraineté | **+** juridiction unique | − CLOUD Act sur la donnée vive | fort |
| Scalabilité | = suffisante, portable par conception | + élasticité réelle | faible (charge plate) |
| Coût / FinOps | **+** marginal nul | − plusieurs centaines d'€/mois | moyen |
| Complexité opérationnelle | − tout à notre charge | **+** managé | moyen |

Deux axes forts penchent nettement du même côté, un axe moyen aussi, un
axe moyen penche contre, un axe faible est neutre. **La décision suit les
axes qui pèsent, et le seul axe perdant est traité par de l'outillage
plutôt que nié.**

---

## Alternatives étudiées et écartées

**Tout sur AWS.** Écarté sur les axes 1, 2 et 4. La donnée vive serait
déchiffrable par le fournisseur, la chaîne de sous-traitance
s'allongerait, et le coût serait sans rapport avec la charge réelle.
Recevable dans un autre contexte — un service grand public avec des pics
de trafic — pas dans celui-ci.

**Tout on-premise, sauvegardes comprises.** Écarté pour une seule
raison, décisive : une sauvegarde stockée sur la machine qu'elle est
censée protéger ne protège de rien. Incendie, vol, chiffrement par
rançongiciel, erreur de manipulation sur le volume — tous ces scénarios
emportent la sauvegarde avec la base. Le hors-site n'est pas un luxe,
c'est la définition d'une sauvegarde. C'est ce point précis qui justifie
l'unique incursion dans le cloud.

**Tout sur Azure.** Écarté pour les mêmes raisons qu'AWS, sans le moindre
avantage supplémentaire. Azure a été retenu *pour la sauvegarde* parce
que la zone externe (archive + ML) y était déjà prévue en EC01 :
ouvrir un troisième fournisseur aurait été une complexité gratuite.

**Docker Compose plutôt que k3s.** Écarté après avoir été construit et
avoir fonctionné. Trois manques ont tranché : pas d'isolation propre
entre dev et prod sur une machine partagée (le préfixage manuel des
réseaux, volumes et conteneurs marche mais se contourne d'un oubli), pas
de retour arrière natif, pas de sondes de vivacité gérées par
l'ordonnanceur. `kubectl rollout undo` est un argument opérationnel, pas
un effet de mode. Le chemin Compose a été retiré du dépôt une fois la
décision prise : maintenir deux déploiements parallèles vers la même
machine double la documentation et le débogage pour un chemin qu'on
n'utiliserait plus. Il reste dans l'historique Git si la démonstration
d'un repli devenait nécessaire.

---

## Ce qui ferait changer cette décision

Formulé à l'avance, pour que la décision soit révisable plutôt que
défendue par principe :

- **une exigence de disponibilité** (engagement de service, astreinte) :
  un seul nœud ne tient pas, il faudrait plusieurs machines ou un cluster
  managé ;
- **un trafic public et irrégulier** : l'élasticité deviendrait un vrai
  besoin et l'axe 3 changerait de poids ;
- **la perte de l'accès au serveur de l'école** : le basculement est déjà
  outillé (`inventories/azure.ini`), il deviendrait la cible par défaut ;
- **une exigence de souveraineté renforcée** (donnée de comptage réelle,
  client industriel) : il faudrait alors sortir du CLOUD Act, donc
  remplacer Azure par un hébergeur européen ou SecNumCloud pour les
  sauvegardes — restic supporte S3, SFTP et le disque local, la cible se
  change avec une seule variable, `RESTIC_REPOSITORY`.

Ce dernier point est important à l'oral : **le choix d'Azure n'est pas
verrouillant.** Rien dans le code ne dépend d'une API Azure ; seul
`infra/terraform/modules/azure-backup-storage` est spécifique, et il
n'approvisionne qu'un compte de stockage.

## Voir aussi

- `architecture.md` — le schéma correspondant
- `runbook.md` — installation, restauration, rotation des secrets
- `EnerVision - Infra AWS vs OnPremise` — le document cadre
