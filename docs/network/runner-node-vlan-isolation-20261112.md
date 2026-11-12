# Dossier de preuves — impossibilité d'un data-plane Cilium en mode tunnel depuis le VLAN utilisateurs (`pc-bruno-gpu`)

**Date :** 2026-11-12
**Objet :** consigner, mesures reproductibles à l'appui, ce qui est **établi** sur le data-plane Cilium en mode `tunnel` (VXLAN) du nœud `pc-bruno-gpu` (`10.2.251.152`, VLAN utilisateurs `10.2.251.0/24`) — à savoir l'**échec confirmé** des flux encapsulés entrants — et l'état réel des décisions à cette date. **Révision du 2026-11-12 :** la version initiale de ce dossier prétendait *démontrer la cause* de cet échec (ports sources VXLAN éphémères × isolation entrante du VLAN). Cette cause est **rétractée** (§0 et §4) ; la question est **ouverte** (§4), et la correction que la version initiale rendait désirable est **structurellement indisponible** (§6.2).
**Méthode :** mesures côté hôte sur `pc-bruno-gpu` (en local) et sur le pair `compute-lsis-2` (via `ssh -o BatchMode=yes compute-lsis-2 ...`). Toute commande est bornée par un `timeout` explicite ; aucune commande réseau n'est laissée sans limite côté client.
**Confidentialité :** ce document ne contient aucun jeton, aucun identifiant, aucun credential, aucun contenu de Vault. Le seul identifiant long qui y figure (`sha256:72ac7d9f…`) est un **digest d'image de registre public** : il provient de la référence d'image telle qu'affichée dans les événements Kubernetes du pod. Ce n'est pas un secret.

---

## 0. Verdict

> **⚠ RÉTRACTION (2026-11-12).** La version initiale de cette section affirmait une cause. Elle est **fausse** et nulle part ailleurs dans ce dossier elle ne doit être lue comme vraie. Détail et motifs en §4 ; correction des deux erreurs matérielles (port jamais figé, WireGuard jamais activé) en §6.2 et §8.

**Fait confirmé (mesuré).** Le plan de contrôle fonctionne et le nœud est `Ready`, mais **les paquets encapsulés entrants n'arrivent jamais jusqu'au device tunnel** : `cat /sys/class/net/cilium_vxlan/statistics/rx_packets` est resté à **0** après **166 240** paquets transmis par ce device. Le pair `compute-lsis-2`, lui, compte bien du trafic VXLAN (`sport 5555 → dport 8472`) venant du guest lima, et c'est partout dans ce cluster la forme du trafic agent réel. L'échec est **data-plane uniquement** : le `10.2.248.31:6443` qui réussit est un flux **terminé par l'hôte** (§3 C6).

**Rétracté.** La phrase initiale — « cette unidirectionnalité résulte de l'association *ports sources VXLAN éphémères* × *isolation entrante du VLAN utilisateurs* » — **n'a plus de soutien expérimental** : la mesure qui la fondait (C2 : `0/15` entrant avec ports éphémères, contre ~399 300 dans les deux sens avec ports épinglés) était un **artefact du harnais de test** (le récepteur `udp_recv.py` ne vide son compteur que tous les 25 paquets et à la sortie : une salve courte ne produisait aucune sortie lisible, ce qui a été lu comme « rien reçu »), et une reprise propre a donné **540 reçus sur 540 émis** depuis le portable vers le guest lima **dans toutes les formes de ports sources testées**. **La forme des ports sources ne change rien à la livraison.**

**Hypothèse ouverte (le blocker réel).** La cause **n'est pas établie** : les hypothèses concurrentes notées **M1** et **M3** ne sont **pas départagées**. La seule mesure qui les discriminerait — `sudo tcpdump -ni <iface> 'udp port 8472 and src host 10.2.251.152'` sur `compute-lsis-2` — **n'a jamais été exécutée** (`sudo` refusé sur tous les hôtes). Ce dossier doit donc être lu comme **un constat solide sans explication**, et non comme un diagnostic.

**Contrainte mesurée qui tue la correction imaginée.** `sudo ip link set dev cilium_vxlan type vxlan srcport 8472 8472` → `Error: Cannot change port range.` : la plage de ports sources d'un device VXLAN **ne se modifie pas en place** ; il faudrait détruire/recréer le device, donc en pratique redémarrer l'agent Cilium sur **chaque** nœud, donc **couper le seul tunnel sain du cluster** (lima ↔ compute). L'option « plateforme » (§6.2) est **morte**, et aucune clé de `cilium-config` ne la remplace.

**Décision au 2026-11-12.** `pc-bruno-gpu` **reste cordonné** tant que M1/M3 ne sont pas départagés ; **rien n'est appliqué à Cilium** (règle en vigueur). La fence operative reste le **cordon**, pas le taint de quarantaine (§6.3.1). **Mais le cordon n'évince pas les pods déjà planifiés** : c'est lui qui a gelé la CI ~5 h (§9).

Le document sépare strictement, conformément au protocole SORA §7 :

| Section | Statut des énoncés |
|---|---|
| §1 à §3 | **FAITS CONFIRMÉS (mesurés)** le 2026-11-12, commandes de reproduction fournies — **sauf** les blocs **C2** et **C3**, rétractés en tant que preuve, et la **conclusion** de C4, retirée (§3) |
| §4 | **RÉTRACTION** d'une cause affirmée + **HYPOTHÈSE OUVERTE** (M1 vs M3, non départagées) |
| §5 | **FAITS** — causes écartées, chacune adossée à une mesure ; + ligne « cause rétractée » |
| §6 | **DÉCISIONS** — état de la décision au 2026-11-12, **contrainte noyau mesurée** (§6.2), **réponse de gouvernance** (§6.2.2) |
| §7, §8 | Annexe reproductibilité (dont le **défaut du harnais** qui a produit la fausse preuve) et limites de traçabilité |
| §9 | **FAITS** — conséquence CI mesurée le 2026-11-12 (~23:45) + **RECOMMANDATION** de procédure |

---

# PARTIE I — FAITS

## 1. Contexte : topologie et configuration réseau du cluster

### 1.1 Les trois nœuds

| Nœud | IP underlay | Rôle | Arch. | VLAN |
|---|---|---|---|---|
| `compute-lsis-2` | `10.2.248.31` | control-plane | amd64 | **serveur** `10.2.248.0/24` |
| `lima-k3s-agent` | `10.2.248.247` | worker | arm64 | **serveur** `10.2.248.0/24` |
| `pc-bruno-gpu` | `10.2.251.152` | worker (runner CI ARC) | amd64 | **utilisateurs** `10.2.251.0/24` |

Deux nœuds sont dans le VLAN serveur, le troisième (le poste qui nous occupe) dans le VLAN utilisateurs. C'est l'unique différence structurelle entre un nœud dont le data-plane fonctionne et celui dont il ne fonctionne pas.

### 1.2 Cilium (relevé 2026-11-12)

| Paramètre | Valeur |
|---|---|
| Version Cilium / chart | `1.20.0` / chart `cilium-1.20.0` |
| Release Helm / namespace | `cilium` / `kube-system` |
| Gestion GitOps | **Hors dépôt `gitops` et hors ArgoCD** (aucun manifeste, aucune App dans la chaîne `gitops-platform`) |
| `routing-mode` | `tunnel` |
| `tunnel-protocol` | `vxlan` |
| `tunnel-source-port-range` | `0-0` (Cilium ne fige donc **pas** le port source : il est laissé à l'éphémère noyau — voir §4 pour la portée exacte de ce point) |
| `ipam` | `cluster-pool` |
| Adressage des pods de `pc-bruno-gpu` | pool `10.0.0.0/24`, `cilium_host = 10.0.0.217` |
| `cilium_host` des pairs | `10.42.0.243` (`compute-lsis-2`), `10.42.1.x` (`lima-k3s-agent`) |

**Conséquence de `routing-mode=tunnel` :** tout paquet inter-pods entre deux nœuds est encapsulé en UDP/8472 sur l'underlay. Aucun routage direct des CIDR pods n'existe sur le réseau : le VLAN ne voit que des datagrammes VXLAN entre adresses de nœuds.

### 1.3 Ce qui n'est **pas** en cause structurellement

Le nœud `pc-bruno-gpu` est `Ready` et le plan de contrôle (apiserver, kubelet, heartbeat, `kubectl`, planification, cycle de vie des pods) fonctionne normalement depuis ce nœud. **Seul le data-plane inter-pods est atteint.** C'est précisément ce qui rend le symptôme trompeur (§2) et ce qui explique qu'un nœud dans cet état ait pu rester dans le pool de planification.

---

## 2. Symptômes observés : trois familles, un seul symptôme causal non expliqué

Les trois familles de pannes ci-dessous ont été observées le 2026-11-12 sur `pc-bruno-gpu`. Elles n'ont **qu'un seul dénominateur commun** : chacune dépend d'un flux dont une extrémité est un **pod distant**, donc d'un paquet encapsulé **entrant**. **Ce dénominateur est un constat, pas une cause : la raison pour laquelle l'entrant encapsulé manque n'est pas établie (§0, §4).**

### 2.1 Résolution DNS (CoreDNS est un pod distant)

Pods `keycloak-reconciler-*` :

```
socket.gaierror: [Errno -3] Temporary failure in name resolution
```

Le résolveur du pod pointe vers `kube-dns` (ClusterIP), dont les backends sont des pods CoreDNS hébergés sur les autres nœuds : la requête sort (chiffrée dans le tunnel) et la réponse ne revient jamais.

### 2.2 Sorties réseau depuis un pod (même diagnostic, couche applicative visible)

Pods `nexus-nexus3-sso-sync-*` :

```
DNS: transient error (try again later)   (résolution de dl-cdn.alpinelinux.org)
exit code 2
```

Le message « transient error » est le comportement correct d'un résolveur qui n'a **pas** de réponse : il ne s'agit pas d'une zone mal configurée (qui produirait un `NXDOMAIN`/SERVFAIL définitif) mais d'une absence de réponse, cohérente avec §2.1.

### 2.3 Tirage d'image sur le registre du cluster (`ErrImagePull`)

Runner ARC `arc-runners/ebpro-org-hflxm-runner-mxv6b` :

```
Failed to pull image "harbor.ebruno.fr/quarkus-microservices/quarkus-ci-runner@sha256:72ac7d9f…" :
dial tcp 10.2.248.31:443: i/o timeout
```

Répété **5 fois** (5 tentatives de pull, 5 timeouts) pour ce seul pod. Le digest `sha256:72ac7d9f…` cité est un identifiant public de l'image, pas un secret.

**Point d'interprétation essentiel (mesuré) :**

1. `harbor.ebruno.fr` résout en **`10.2.248.31`** sous la **résolution DNS du campus** — et non grâce à un `/etc/hosts` local. Le nom public du registre est donc pointé vers l'IP du nœud de control-plane.
2. Sur `10.2.248.31`, le port **443 n'a aucun socket d'hôte** : `ss -ltn '( sport = :443 )'` exécuté sur `compute-lsis-2` renvoie une liste vide. Le 443 public est donc un **DNAT `svclb-traefik`** (hôte) → **pod Traefik**.

Autrement dit, **tout tirage d'image depuis Harbor traverse le data-plane VXLAN entrant**, y compris la poignée de main TCP et le premier octet du flux TLS. Un `i/o timeout` sur cette adresse est donc, non pas une panne Harbor, mais une panne de tunnel entrant.

### 2.4 Lien de causalité

`gaierror` (§2.1), `DNS: transient error` (§2.2) et `dial tcp … i/o timeout` (§2.3) ne sont pas trois pannes : ce sont trois **vues, à trois niveaux différents, de l'absence d'un seul et même paquet entrant**.

---

## 3. Preuves chiffrées

Six blocs de mesures, numérotés **C1…C6** (à ne pas confondre avec les **CI-1…CI-4** de §9 : ceux-ci sont des conséquences CI, pas des mesures). Chaque bloc donne : **ce qui est mesuré**, **la commande exacte** (avec son `timeout`), **le résultat brut**, **la conclusion**, **ce que la preuve élimine**. **Mais deux blocs ont perdu leur statut de preuve, et un troisième son interprétation :** **C2 est NUL en totalité** (artefact de harnais — sa table est conservée comme trace d'erreur, pas comme mesure), **C4 est non conclusive** (ses chiffres sont conservés, sa conclusion « le drop est en amont de l'hôte » est retirée), **C3 garde ses compteurs mais perd son interprétation** (plus rien de « discriminant »). C1, C5 et C6 sont intégralement valides.

### C1 — Unidirectionnalité mesurée sur le device tunnel

**Ce qui est mesuré :** les compteurs du device VXLAN de chaque extrémité, avant et après une salve de 100 pings émis **depuis `pc-bruno-gpu`** vers un pod distant (`10.42.0.144`, pod sur `compute-lsis-2`).

**Commandes :**

```sh
# instantané T0, sur pc-bruno-gpu
timeout 30 cat /sys/class/net/cilium_vxlan/statistics/rx_packets \
               /sys/class/net/cilium_vxlan/statistics/tx_packets

# instantané T0, sur le pair
timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=5 compute-lsis-2 \
  'cat /sys/class/net/cilium_vxlan/statistics/rx_packets /sys/class/net/cilium_vxlan/statistics/tx_packets'

# la salve de trafic (100 paquets ICMP émis vers le pod distant)
timeout 120 ping -c 100 -W 1 10.42.0.144

# instantané T1 : re-exécuter les deux premières commandes
```

**Résultat brut (fenêtre T0→T1 du 2026-11-12) :**

| Compteur | T0 | T1 | Δ |
|---|---|---|---|
| `cilium_vxlan tx_packets` (pc-bruno-gpu) | 4759 | 4874 | **+115** |
| `cilium_vxlan rx_packets` (pc-bruno-gpu) | 0 | 0 | **0** |
| `cilium_vxlan rx_packets` (compute-lsis-2) | — | — | **+153** |

**Lecture :** nos 100 pings sont bien encapsulés et partent (Δtx = 115, cohérent avec 100 requêtes + le trafic d'appoint de la fenêtre), le pair **les reçoit bien** (Δrx = +153 sur la même fenêtre) — et **rien ne revient** : notre compteur d'entrée du device tunnel est resté strictement à **0**.

**Conclusion :** l'entrant encapsulé n'arrive jamais. Le pair reçoit, décapsule, répond ; la réponse est perdue avant nous.

**Ce que cette preuve élimine :** elle élimine l'hypothèse « erreur de configuration Cilium ». Si l'`ipcache` (table d'association IP pod ↔ IP de nœud), l'entrée de tunnel (`tunnelendpoint`) ou la FDB/route étaient faux d'un côté, le pair n'aurait **pas** Δrx = +153 et nos paquets ne seraient pas décapsulés là-bas. Le plan de contrôle Cilium est donc **correct des deux côtés** : c'est le flux de données entrant qui est coupé, ailleurs que dans Cilium. Une perte de 100 % en entrée et 0 % en sortie n'est pas non plus un problème de fiabilité de lien (le bruit réseau ne supprime jamais un seul sens de façon systématique).

### C2 — UDP à ports sources éphémères *(**Rétracté — NUL / NON AVENUE**)*

**Statut de ce bloc : il ne prouve rien et ne doit plus être cité comme preuve.** Commande, table et chiffres sont conservés intégralement, **comme trace d'une erreur de méthode**.

**Ce que la version initiale mesurait :** 15 datagrammes UDP envoyés dans chaque sens avec un port source **laissé à l'éphémère** (comportement supposé du tunnel VXLAN avec `tunnel-source-port-range: 0-0`).

**Commandes :**

```sh
# sur pc-bruno-gpu : écoute 15 s + envoi 15 datagrammes vers le pair
timeout 60 python3 /tmp/opencode/bidi.py
# variante d'écoute seule, si l'on pilote l'émetteur à la main :
timeout 60 python3 /tmp/opencode/udp_recv.py
```

**Lecture retirée — ce que la version initiale a cru observer :**

| Sens | Émis | Reçus |
|---|---|---|
| pair (`10.2.248.31`) → nous, destination `:19999` | 15 | **0 / 15** |
| nous → pair (`10.2.248.31`) | 15 | **15 / 15** |

**Pourquoi c'est NUL : artefact du harnais, et non une observation.** L'écouteur utilisé par ce test, `/tmp/opencode/udp_recv.py`, **ne vide son compteur que tous les 25 paquets et à la sortie** (défaut consigné en §7). Une salve de 15 datagrammes est **structurellement trop courte** pour produire une sortie lisible : « 0 reçu » est exactement ce que ce harnais *pouvait* afficher, quel qu'ait été le résultat réel. Le `0 / 15` n'a donc jamais mesuré une perte — c'est **l'absence de sortie d'un outil mal conçu**, interprétée comme un compteur.

**Fait confirmé (mesuré) — la reprise propre.** Le même échange, rejoué avec un récepteur qui compte paquet par paquet, donne **540 reçus sur 540 émis** du portable vers le guest lima **dans toutes les formes de ports sources testées** (éphémères comme épinglées). **La forme des ports sources ne change rien à la livraison.**

**Rétracté — ce que ce bloc affirmait et qui ne tient plus :**

- « avec des ports sources éphémères, l'aller passe, le retour est intégralement perdu » : **retiré**, la comparaison épinglé/éphémère n'a plus de terme éphémère valide ;
- « le VLAN utilisateurs autorise **le retour** de flux initiés par nous » **en tant qu'enseignement sur la forme des ports** : **retiré**, cette inférence reposait sur l'opposition C2 ↔ C3 ;
- la mention « et C4 établit que la carte réseau non plus » est **supprimée** : C4 n'établit pas cela (C4 est retirée en tant que preuve, plus bas dans ce §3).

**Ce qui survit (Fait confirmé, mesuré — et c'est C1 qui le donne, pas C2) :** notre égress a bien été **reçu par le pair** (C1 : Δrx = `+153` sur `compute-lsis-2` sur la même fenêtre). C'est le seul fait « sens aller » que ce dossier conserve de cette piste.

### C3 — UDP à ports sources épinglés : ~100 % dans **les deux** sens *(compteurs valides ; interprétation rétractée)*

**Ce qui est mesuré :** la même forme de salve qu'en C2, mais avec un port source **fixe** de chaque côté (nous `:5555` ↔ pair `:6666`), sur un volume suffisant pour écarter toute interprétation statistique. **Avertissement de méthode :** C2 étant **NUL** (artefact de harnais, ci-dessus), ces compteurs **n'ont pas de contre-épreuve** dans ce dossier — ils décrivent ce qui passe à ~100 % sur des ports épinglés, et rien d'autre.

**Commandes :**

```sh
# sur pc-bruno-gpu (port source épinglé :5555, destination le pair :6666)
timeout 300 python3 /tmp/opencode/probe_send.py

# sur le pair, même harnais, port source épinglé :6666 vers nous :5555
timeout 300 ssh -o BatchMode=yes -o ConnectTimeout=5 compute-lsis-2 \
  'python3 /tmp/opencode/probe_send.py'
```

**Résultat brut :**

```
# pc-bruno-gpu   (10.2.251.152)
SENT=399323 RECV={'10.2.248.31': 399307}

# compute-lsis-2 (10.2.248.31)
SENT=399318 RECV={'10.2.251.152': 399316}
```

Soit **399 307 / 399 323 ≈ 99,996 %** dans un sens et **399 316 / 399 318 ≈ 99,999 %** dans l'autre : la perte est du bruit résiduel, plus aucune asymétrie.

**Conclusion rétractée — ce que la version initiale écrivait :** « *c'est LA preuve discriminante du dossier* », avec l'affirmation que le chemin entre les deux VLAN « *laisse passer un flux entrant dès lors que son 4-tuple correspond à l'inverse d'un flux que nous avons initié* » et que, « *quand ils sont éphémères et appariés n'importe comment (cas VXLAN par défaut), l'entrant ne passe jamais* ».

**Rétracté — ce qui était « discriminant » ne l'est plus, et pour une raison simple : il n'y a plus de terme de comparaison.** Le lot éphémère censé lui s'opposer, c'est C2, et C2 est **NUL** (artefact de harnais). Des compteurs à ~100 % ne départagent rien sans contre-épreuve valide : le mot « discriminante » est retiré, et avec lui l'inférence sur les 4-tuples inverses et sur le comportement « par défaut » de VXLAN.

**Fait confirmé (mesuré) — la lecture honnête qui survit, et elle est plus modeste :**

1. un flux UDP entrant de **grande volumétrie atteint bien l'hôte** : le pair `compute-lsis-2` a reçu **399 316** datagrammes venus de `10.2.251.152`, et `pc-bruno-gpu` en a reçu **399 307** venus de `10.2.248.31` — **le VLAN utilisateurs n'est donc pas étanche à l'UDP entrant**, pas même à ce débit ;
2. ce bidirectionnel à ~100 % a été observé **sur des ports épinglés** (`:5555` ↔ `:6666`) ; cela ne dit **rien** du comportement d'autres ports, la mesure correspondante étant nulle ;
3. **et pourtant**, simultanément, l'entrant VXLAN sur **dport 8472** n'atteint **jamais** le device tunnel : C1 donne `rx_packets` **strictement 0**, y compris après **166 240** paquets émis.

**Hypothèse ouverte (le blocker du dossier).** La raison pour laquelle un hôte qui reçoit ~399 000 datagrammes UDP entrants sur un port épinglé n'en reçoit **aucun** sur `8472` **n'est pas établie**. Ce n'est pas la forme des ports sources (réfutée), ce n'est pas l'étanchéité du VLAN (réfutée au point 1). C'est exactement le **M1 vs M3** de §4, non départagé.

**Ce que cette mesure élimine encore (Fait confirmé) :** « le VLAN utilisateurs est étanche à tout trafic entrant » (faux : 399 307 paquets entrants en une seule salve), et « le tunnel est sous-dimensionné / la perte vient du débit » (faux : à ce débit, ~100 % passe). **Ce qui est retiré :** la phrase « *elle élimine « il faut ouvrir le VLAN en grand » (faux : seul le cas des ports éphémères croisés est bloqué)* » — son jugement sur les ports éphémères vient de C2 ; ainsi que « *Elle déplace donc le problème du câblage réseau vers la politique de ports sources du tunnel* » — ce déplacement n'était que la cause réfutée, et il n'y a plus rien à déplacer (§4).

### C4 — « Le drop est **en amont de l'hôte** » *(mesure **non conclusive** — retirée en tant que preuve)*

**Ce qui est mesuré :** d'une part les statistiques ICMP du noyau de `pc-bruno-gpu` pendant que le pair le ping, d'autre part le compteur d'entrée de la **carte physique** (`enp0s31f6`) pendant une fenêtre de 40 pings encapsulés, comparé à une fenêtre de repos de même durée.

**Commandes :**

```sh
# compteur d'entrées ICMP de l'hôte, avant / après 12 requêtes émises par le pair
timeout 30 grep '^Icmp:' /proc/net/snmp
timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=5 compute-lsis-2 \
  'ping -c 12 -W 1 10.2.251.152'
timeout 30 grep '^Icmp:' /proc/net/snmp

# carte physique : fenêtre de 40 pings encapsulés, puis fenêtre de repos équivalente
timeout 30 cat /sys/class/net/enp0s31f6/statistics/rx_packets
timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=5 compute-lsis-2 \
  'ping -c 40 -W 1 10.0.0.217'          # cilium_host de pc-bruno-gpu
timeout 30 cat /sys/class/net/enp0s31f6/statistics/rx_packets
```

**Résultat brut :**

| Mesure | Valeur |
|---|---|
| `Icmp: InMsgs` (hôte) avant/après 12 requêtes reçues du pair | **112 → 113** (Δ = 1) |
| Δ `enp0s31f6 rx_packets` pendant la fenêtre de 40 pings | **250** |
| Δ `enp0s31f6 rx_packets` sur une fenêtre de repos de même durée | **119** |

**Lecture :** la carte physique reçoit 250 trames pendant la fenêtre de test contre 119 sur une fenêtre de repos de même durée : **un excédent d'environ 131 trames sur un fond déjà de ~119**, et ces 250 trames couvrent tout le trafic de la fenêtre, pas seulement nos 40 pings. **C'est une résolution insuffisante pour conclure quoi que ce soit sur l'arrivée ou la non-arrivée des 40 pings** : l'écart mesuré est du même ordre que le bruit de fond qu'il est censé mesurer. Le compteur ICMP de l'hôte, lui, n'a quasiment pas bougé (Δ = 1 pour 12 sollicitations attendues).

**Conclusion — RETIRÉE (cet bloc n'est plus une preuve).** La version initiale écrivait : « *les trames ne parviennent **pas** jusqu'à la machine. Le rejet est donc effectué **en amont de l'hôte** (équipement réseau intermédiaire / politique du VLAN), et non par la machine elle-même.* » **C'est rétracté**, pour deux raisons :

1. **Résolution insuffisante** (ci-dessus) : 131 trames d'écart sur un bruit de 119 ne permettent pas de distinguer « 40 pings arrivent » de « 40 pings n'arrivent pas ». La mesure ne peut pas établir une absence de trames.
2. **Contradiction interne avec C3, qui n'était pas résolue :** C4 affirme que les trames entrantes ne parviennent pas jusqu'à la carte réseau, **alors que C3 consigne ~399 300 datagrammes entrants reçus par ce même hôte, sur cette même carte physique** (dont **399 316** comptés à l'entrée côté pair). Les deux énoncés ne peuvent pas être vrais tels qu'écrits. **C4 est la mesure la plus faible des deux** (fenêtre courte, fond non soustrait, résolution nettement trop juste) : c'est donc elle qui est retirée en tant que conclusion, les compteurs bruts restant ci-dessus pour qui voudrait les rejouer.

**Conséquence explicite — ce que le dossier ne sait plus (Hypothèse ouverte).** **M1 (« le drop est en amont de l'hôte ») vs M3 (« le drop est dans l'hôte, avant le device `cilium_vxlan` ») n'est PAS départagé.** C4 était la seule pièce qui apparentait le drop à M1 ; une fois retirée, **aucune mesure de ce dossier ne privilégie M1 ni M3**. La seule mesure qui les discriminerait — `sudo tcpdump -ni <iface> 'udp port 8472 and src host 10.2.251.152'` sur `compute-lsis-2` — **n'a jamais pu être exécutée** : `sudo` a été refusé sur tous les hôtes (§0, §8). **Ce point est le blocker réel du dossier.**

**Ce que ce bloc éliminait — et qui retombe :** il éliminait, selon la version initiale, « toute la famille `iptables`/`nftables`/`ufw`/eBPF locaux qui droppe » ainsi que « le filtrage par la pile TCP/IP de l'hôte ». **Cet acquis est retiré avec lui** : la famille « drop **dans** l'hôte, avant le device tunnel » (**M3**) n'est plus exclue par C4, et les règles `nft`/`iptables` hôtes restent **inaccessibles sans root** (C5). Elle n'est pas établie non plus : `ufw` est `inactif` et le firewall d'hôte Cilium `Disabled` (C5, faits confirmés), ce qui rend un drop par pare-feu d'hôte **peu probable** — mais « peu probable » n'est pas « éliminé en amont de la carte », et c'était exactement la force que C4 prétendait avoir.

*Remarque de méthode (conservée, toujours valable) :* un ping adressé à une IP de pod est répondu dans l'espace réseau du pod, pas par la pile de l'hôte ; le compteur `Icmp: InMsgs` n'a donc jamais rien prouvé — la version initiale le disait déjà, mais en attribuant au Δ `rx_packets` de la carte physique une force probante qu'il n'a pas.

### C5 — Élimination explicite des causes locales

| Cause testée | Commande | Résultat brut | Verdict |
|---|---|---|---|
| Pare-feu hôte `ufw` | `sudo ufw status numbered` (exécutée par l'opérateur du poste ; hors du périmètre lecture-seule de ce dossier) | `État : inactif` | **écartée** |
| Firewall d'hôte Cilium | état de l'agent Cilium du nœud (`cilium status`, ligne `Host firewall`) | `Host firewall: Disabled` | **écartée** |
| Agent Cilium vivant et sain | `timeout 15 curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9879/healthz` | `200` | **écartée** (l'agent répond, il n'est pas bloqué/choqué) |
| `sysctl` de forwarding | `timeout 30 sysctl net.ipv4.ip_forward net.ipv4.conf.all.forwarding` | valeurs conformes aux prérequis Cilium (capture brute non conservée — cf. §8 ; un écart aurait empêché l'agent d'être sain, or il l'est : ligne précédente) | **écartée** |
| MTU | `timeout 30 ip -o link show cilium_vxlan` | `mtu 1350` sur le device tunnel | **non en cause** : un MTU trop élevé produit une coupure **au-delà d'une taille de paquet**, jamais un `rx = 0` sur des paquets ICMP de 64 octets (C1) |
| Règles `nft` / `iptables` hôtes | `timeout 30 nft list ruleset`, `timeout 30 iptables -S` | **inaccessibles sans root** (refus de permission) — donc **non utilisées comme preuve** | **non tranché** : aucune règle d'hôte **active** connue n'existe (`ufw` inactif, firewall d'hôte Cilium désactivé), mais comme C4 est retirée, un drop **dans** l'hôte avant le device tunnel (**M3**, §4) n'est **plus écarté** — c'est l'une des raisons pour lesquelles **rien, dans ce dossier, ne départage M1 et M3** |

### C6 — Sélectivité TCP : ce qui échoue est exactement « pod distant → nous »

**Ce qui est mesuré :** six `connect()` TCP parallèles depuis `pc-bruno-gpu`, choisis pour discriminer « terminé par un pod » vs « terminé par l'hôte ».

**Commande (une par cible, même forme) :**

```sh
timeout 6 bash -c 'exec 3<>/dev/tcp/10.2.248.31/6443' && echo CONNECTED || echo FAIL
```

**Résultat brut :**

| Cible | Résultat | Nature de l'extrémité |
|---|---|---|
| `10.2.248.31:6443` | **CONNECTED** | apiserver : **terminé par l'hôte** `compute-lsis-2` |
| `10.2.248.247:443` | **CONNECTED** | pod Traefik sur le **même nœud** que le pod servi |
| `10.43.0.1:443` | **CONNECTED** | ClusterIP `kubernetes.default` : traitée **localement** par eBPF, aucun paquet encapsulé sortant |
| `1.1.1.1:443` | **CONNECTED** | Internet, hors cluster (sortie NAT locale) |
| `10.2.248.31:443` | **TIMEOUT** | DNAT d'hôte → **pod Traefik distant** (cf. §2.3 : aucun socket d'hôte sur ce port) |
| `10.42.0.144:8080` | **TIMEOUT** | **pod distant**, adresse directe du plan de données |

**Conclusion :** les deux seules cibles qui échouent sont précisément celles dont la réponse doit traverser le tunnel **entrant**. Tout ce qui reste sur l'hôte local, est traité localement par eBPF, ou ne relève pas du plan de données inter-pods fonctionne. Le motif d'échec est donc **directionnel et non applicatif** : il ne dépend ni du service, ni du port, ni de l'émetteur de la requête.

**Ce que cette preuve élimine :** elle élimine « Harbor/la chaîne d'ingress est cassée », « CoreDNS est HS », « le registre renvoie des erreurs », « un NetworkPolicy ou une Kyverno ClusterPolicy filtre le trafic » (ces mécanismes sont symétriques et ne expliquent pas le `rx = 0` de C1), et elle élimine toute explication par le plan de contrôle, qui est manifestement en état.

**Réserve d'interprétation (non expliquée, sans impact sur le verdict) :** le `CONNECTED` sur `10.2.248.247:443` n'est pas intégralement expliqué par le modèle simple « pod distant = échec » ; ce cas n'a pas été creusé (node non joignable en SSH, cf. §8) et n'est **pas** nécessaire au verdict. **Correction de portée :** ce verdict — *l'entrant encapsulé n'arrive jamais au device tunnel* — repose sur **C1** (compteurs) et **C6** (sélectivité hôte/pod), **désormais seuls intacts** : la mention « repose sur C1/C2/C3/C4 » est retirée, C2 étant nul et la conclusion de C4 non valable (§3).

---

# PARTIE II — HYPOTHÈSE

## 4. Rétractation de la cause affirmée, et hypothèses ouvertes

*(Vocabulaire, pour éviter toute confusion : **C1…C6** en §3 désignent les **mesures** de ce dossier ; **CI-1…CI-4** en §9 désignent les **conséquences CI** qui en ont découlé. Ces deux numérotations n'ont aucun rapport.)*

**Rétracté — voici la phrase que cette section affirmait** (citée pour être annulée, et pour aucune autre raison) :

> Avec `tunnel-source-port-range: 0-0`, le driver VXLAN du noyau choisit un **port source éphémère par paquet** pour l'encapsulation ; le 4-tuple du retour **n'est jamais l'inverse exact** de celui de l'aller ; un équipement à **inspection d'état** classe donc la réponse comme une **session entrante nouvelle**, que l'**isolation entrante du VLAN utilisateurs** rejette.

et son corollaire chiffré, tel qu'il était écrit :

```
notre égress   :  10.2.251.152:rand1  →  10.2.248.31:8472     (part, arrive : C1 Δtx=115)
la réponse     :  10.2.248.31:rand2   →  10.2.251.152:8472    (n'arrive jamais : C1 rx=0)
```

La mention `C2 0/15` qui accompagnait la deuxième ligne est **effacée** : C2 est NUL (§3). La mention `C2 15/15` de la première ligne est **également effacée** : le seul fait « l'aller arrive » vient de C1 (Δrx = +153 côté pair), pas de ce harnais.

**Deux motifs indépendants, tous deux établis, suffisent à tuer cette phrase :**

- **(a) La mesure qui la fondait est un artefact de harnais.** L'opposition « ports épinglés ≈ 100 % vs ports éphémères 0 % » reposait sur C2 ; l'écouteur `udp_recv.py` de C2 **ne vide son compteur que tous les 25 paquets et à la sortie**, donc une salve de 15 datagrammes ne *pouvait* rien afficher d'autre que rien. « 0/15 » n'a jamais été une observation (§3 C2, §7).
- **(b) Rejouée proprement, la mesure dit le contraire.** Avec un récepteur qui compte paquet par paquet : **540 reçus sur 540 émis**, du portable vers le guest lima, **dans toutes les formes de ports sources testées**. **La forme des ports sources ne change rien à la livraison** — et le mécanisme proposé ci-dessus ne peut donc plus expliquer quoi que ce soit.

**Fait confirmé (mesuré) — ce qui survit, et il est entier :** l'entrant encapsulé **n'atteint jamais le device tunnel**. `cilium_vxlan.rx_packets` est resté **strictement 0**, y compris après **166 240** paquets émis par ce device (C1), pendant que le pair reçoit nos paquets (Δrx = `+153`). L'échec est **data-plane uniquement** : le plan de contrôle et tout ce qui est **terminé par l'hôte** fonctionnent (C6 : `10.2.248.31:6443` `CONNECTED`). **Ce constat est solide ; son explication, elle, n'existe plus.**

**Hypothèse ouverte — le blocker réel du dossier : M1 et M3 ne sont PAS départagées.**

| id | énoncé | état dans ce dossier |
|---|---|---|
| **M1** | le rejet est réalisé **en amont de l'hôte** (équipement intermédiaire / politique du VLAN) | **non établi.** Son seul appui était C4, **retirée** en tant que preuve (§3 C4) |
| **M2** | le rejet est réalisé par **le pare-feu local du portable** qui « l'aveuglerait lui-même » | **réfutée par mesure** : `ss -ulnp` montre le socket de décapsulation lié à **`0.0.0.0:8472`**, `ufw` est `inactif`, le firewall d'hôte Cilium est désactivé, et le poste **reçoit** de l'entrant (SSH y parvient jusqu'à un prompt de mot de passe) |
| **M3** | le rejet est réalisé **dans l'hôte**, entre la carte physique et le device `cilium_vxlan` (le datagramme arrive mais n'est jamais livré au device tunnel) | **non établi, et jamais écarté.** C5 ne montre **aucune** règle d'hôte active connue, mais ce n'est pas une preuve d'absence : les règles `nft`/`iptables` étaient **inaccessibles sans root** |

**La seule mesure qui départagerait M1 et M3 n'a jamais pu être obtenue :** `sudo tcpdump -ni <iface> 'udp port 8472 and src host 10.2.251.152'` sur `compute-lsis-2` — **`sudo` refusé sur tous les hôtes**. Elle reste à faire **par quelqu'un qui a root**, et **rien ne doit être appliqué à Cilium avant** (§6.2).

**Matrice d'origine — conservée, mais frappée d'interdiction d'usage.** Le tableau ci-dessous est celui de la version initiale, corrigé de ses appuis retirés. **Il ne doit pas servir à classer des hypothèses tant que C2 n'aura pas été re-mesurée avec un récepteur qui vide son compteur à chaque paquet reçu** (§7) : deux de ses quatre lignes d'observations sont nulles.

| Observation | Hypothèse ports éphémères × isolation entrante | MTU | Pare-feu hôte | Config Cilium | Panne de service |
|---|---|---|---|---|---|
| C1 `rx = 0` sur 100 % des retours *(Fait)* | ❌ **rétractée (a)+(b)** | ❌ (les petits paquets passeraient) | ⚠ **non tranché** : C4 retirée ⇒ **M3 reste ouvert** ; seul acquis, aucune règle active connue (C5) | ❌ (le pair décapsule bien) | ❌ (C6 : d'autres services passent) |
| **C2 éphémère = `0/15` entrant** | **VOID — observation artifactuelle** : ligne à ne plus utiliser dans aucun raisonnement | — | — | — | — |
| C3 ports épinglés ≈ 100 % dans les deux sens *(compteurs valides)* | ❌ **ne soutient plus rien** : sans C2, aucun terme de comparaison | ❌ | ⚠ | ❌ | ❌ |
| **C4 « drop en amont de l'hôte »** | **RETIRÉE — non conclusive** : résolution insuffisante + contradiction avec C3 | — | — | — | — |

**Rétracté — « le critère décisif est C3 ».** La version initiale écrivait : « *le seul fait de figer les ports sources rétablit le bidirectionnel à ~100 % […]. Un phénomène indépendant des ports ne peut pas disparaître en épinglant les ports.* » Ce raisonnement suppose un phénomène **observé** à 0 % puis à ~100 % ; or le 0 % n'a jamais été mesuré. **Nous n'avons qu'un ~100 % isolé**, qui n'établit aucun rétablissement. La phrase est retirée.

**Statut de cette section — à lire attentivement (réécrit).** Ce qui est **confirmé** tient en une phrase : le device tunnel ne reçoit strictement rien (C1). Ce qui est **retiré** : la « corrélation reproductible et exclusive » (ports éphémères → 0 % entrant ; ports épinglés → 100 % entrant) — sa moitié éphémère est **nulle**. Ce qui était présenté comme « la formule exacte à retenir » — *« le rejet est réalisé par un équipement en amont de l'hôte, dont la politique est compatible avec une inspection d'état sur les ports sources »* — est **retiré lui aussi** : la première moitié venait de C4 (non concluante), la seconde de C2 (nulle). Restent, comme seules affirmations autorisées sur le réseau : **nous n'avons aucun accès à la configuration du pare-feu d'agrégation**, l'exploitant du poste n'est pas sysadmin réseau, et **la cause n'est pas établie**.

---

# PARTIE III — CAUSES ÉCARTÉES

## 5. Liste explicite de ce qui **n'est pas** la cause

| # | Cause écartée | Sur quelle preuve |
|---|---|---|
| 1 | **MTU / fragmentation** | C5 (`cilium_vxlan` à 1350) + C1 : une coupure liée au MTU dépend de la taille des paquets, or ici **100 %** des retours manquent, y compris de petits ICMP ; et C3 passe à 100 % avec des paquets de taille comparable. |
| 2 | **Pare-feu de l'hôte (`ufw`, `iptables`/`nft`, firewall d'hôte Cilium)** | C5 : `ufw` `inactif`, `Host firewall: Disabled` — **aucune règle active connue**. **Portée corrigée :** cette exclusion ne tient plus que par C5. La version initiale ajoutait « et surtout C4 : le drop est situé **avant** la carte réseau de l'hôte » ; C4 étant **retirée** comme non conclusive (§3), **un drop réalisé dans l'hôte, avant le device tunnel (M3) n'est plus écarté** — il n'est documenté par **aucune** règle active connue, ce qui est autre chose. |
| 3 | **Configuration Cilium (`ipcache`, `tunnelendpoint`, routes, FDB)** | C1 : le pair reçoit et décapsule nos paquets (Δrx = +153) — la résolution IP → nœud et l'écriture de FDB sont donc correctes des deux côtés. Un `ipcache` faux casserait l'aller aussi. |
| 4 | **Agent Cilium en erreur** | C5 : `http://127.0.0.1:9879/healthz` → `200`. |
| 5 | **Pool IPAM `10.0.0.0/24`** (incohérence de nommage avec `spec.podCIDR = 10.42.2.0/24`, ce dernier n'étant pas utilisé en `ipam=cluster-pool`) | **Cosmétique, sans effet observé.** Le pool est annoncé par `cilium_host 10.0.0.217`, l'`ipcache` des pairs contient bien cette association (sinon C1 échouerait à l'aller). Cette divergence de nommage est une dette de lisibilité à corriger un jour, **pas** une cause : elle n'affecte pas la direction des flux. |
| 6 | **Version / âge du noyau du poste** | §1.3 + C6 : nœud `Ready`, plan de contrôle opérationnel, kubelet et apiserver communiquent, `6443` établi. Un noyau trop ancien pour VXLAN/eBPF n'aurait pas Cet agent sain ni ce nœud `Ready`. |
| 7 | **Sélecteurs de taint / tolérations / affinités de nœud** | §2.1–§2.3 : les pods **ont été planifiés et démarrés** sur `pc-bruno-gpu` (ils exécutent et échouent en cours d'exécution, avec des erreurs réseau). Un problème de placement se voirait en `Pending`, pas en `gaierror`. |
| 8 | **Présence de swap sur le poste** | Tolérée : le swap n'a aucune incidence sur l'arrivée de trames sur `enp0s31f6`. À ne pas confondre avec un obstacle (aucun comportement réseau observé ici ne lui est imputable). |
| 9 | **Panne du registre Harbor / de l'ingress / de CoreDNS côté serveur** | C6 : la même adresse `10.2.248.31` répond en `6443` et pas en `443`, et les pairs servent correctement leurs propres pods. Ces composants fonctionnent pour tout le monde sauf pour nous. |
| 10 | **Cause rétractée : « ports sources VXLAN éphémères × isolation entrante du VLAN utilisateurs »** | **Ce n'est pas une cause écartée par le réseau : c'est une cause retirée par ce dossier, sur preuve méthodologique.** (a) la mesure qui l'établissait (**C2**, `0/15` entrant) est un **artefact de harnais** — l'écouteur `udp_recv.py` ne vide son compteur que tous les 25 paquets et à la sortie, donc une salve de 15 datagrammes ne *pouvait* rien afficher (§7) ; (b) rejouée avec un récepteur qui compte par paquet, la salve éphémère donne **540 reçus / 540 émis**, **dans toutes les formes de ports sources** → **la forme des ports ne change rien à la livraison**. Détail en §0 et §4. **Ce que ça laisse ouvert : la cause réelle (M1 vs M3, §4), non départagée.** |

---

# PARTIE IV — DÉCISIONS

## 6. Options de correction et **état de la décision au 2026-11-12**

### 6.1 Option « réseau » — **ÉCARTÉE** (mais dossier kept prêt pour escalade)

**Contenu.** Demander à l'équipe réseau d'autoriser, entre le VLAN utilisateurs `10.2.251.0/24` et le VLAN serveur `10.2.248.0/24`, les flux du tableau §6.1.1.

**Décision.** **Écartée par l'utilisateur**, pour deux raisons factuelles : l'équipe réseau n'est pas mobilisable sur ce sujet, et nous ne sommes pas sysadmin de ces équipements (nous ne pouvons donc ni vérifier ni modifier leur politique — cf. §4).

**Le dossier reste néanmoins rédigé en vue d'une escalade future**, d'où la demande formalisée ci-dessous.

#### 6.1.1 Demande explicite à l'équipe réseau (flux précis)

| # | Protocole | Source | Destination | Port destination | Sens | État mesuré aujourd'hui |
|---|---|---|---|---|---|---|
| F1 | UDP | `10.2.248.31` | `10.2.251.152` | **8472** (peu importe le port source côté `10.2.248.31`, **y compris éphémère**) | serveur → utilisateur (**entrant** pour nous) | **BLOQUÉ** — établi par **C1 seul** (`cilium_vxlan.rx_packets = 0`, y compris après **166 240** paquets émis). *La mention « (0/15, C2) » de la version initiale est retirée : C2 est NUL (§3).* |
| F2 | UDP | `10.2.248.247` | `10.2.251.152` | **8472** (idem, port source libre) | serveur → utilisateur | présumé identique à F1 (non mesuré séparément : `lima-k3s-agent` n'est pas joignable en SSH, cf. §8) |
| F3 | UDP | `10.2.251.152` | `10.2.248.31` / `10.2.248.247` | 8472 | utilisateur → serveur | **DÉJÀ OUVERT** (`+153` paquets reçus côté pair, C1) — rappelé pour éviter une demande trop large |
| F4 | TCP | `10.2.251.152` | `10.2.248.31` / `10.2.248.247` | **80, 443** (en tant que **client**) | utilisateur → serveur | à garantir : c'est le chemin des accès aux VIP d'ingress, y compris depuis le navigateur de l'opérateur assis sur ce VLAN |

**Formulation en une phrase, à copier-coller dans un ticket réseau :** *« nous demandons une seule observation de votre part, pas un changement de configuration : les flux dont la destination est `UDP/8472` vers `10.2.251.152`, en provenance de `10.2.248.0/24`, sont-ils autorisé ou filtrés par votre politique d'entrée du VLAN utilisateurs ? Nos faits mesurés sont ceux-ci, sans que nous en tirions aucun mécanisme : notre trafic encapsulé sortant est bien reçu et décapsulé par le pair `10.2.248.31`, alors que le retour vers `10.2.251.152` n'atteint jamais notre device tunnel (`cilium_vxlan.rx_packets` resté à **0** sur **166 240** paquets émis — C1) ; et l'UDP entrant sur d'autres ports traverse cette même frontière de VLAN à ~100 % (C3, `399 307`/`399 323` dans un sens et `399 316`/`399 318` dans l'autre, entre `10.2.251.152` et `10.2.248.31`). »* Cette demande est **volontairement limitée à ce constat** : elle **ne demande pas d'ouvrir le VLAN**, ne propose aucune mesure à prendre, et n'évoque **ni les ports sources ni leur figeage éventuel** — la cause réelle n'est pas établie de notre côté (M1 vs M3, §4), et la réponse à cette seule question est précisément ce qui permettrait de les départager.

#### 6.1.2 Comment nous vérifierons, côté client, que la demande a bien été prise en compte

Aucune accès côté réseau n'étant nécessaire, la vérification est **entièrement pilotee depuis `pc-bruno-gpu`** :

1. **C2 reproduit** (`timeout 60 python3 /tmp/opencode/bidi.py`) → **sans objet : ce contrôle n'a plus de valeur d'attente valide.** C2 est **NUL** (§3 C2) : son écouteur `udp_recv.py` **ne vide son compteur que tous les 25 paquets et à la sortie**, donc une salve de 15 datagrammes ne *pouvait* structurellement rien afficher d'autre que rien — ni `15/15`, ni `0/15` ne sont mesurables avec ce harnais. **Le vrai critère, mesurable et non mutant, est C1** : `cat /sys/class/net/cilium_vxlan/statistics/rx_packets` qui passe **strictement au-dessus de 0** sous trafic pair → nous (au lieu de rester bloqué à `0`, comme constaté sur **166 240** paquets émis — C1). Et, pour toute nouvelle mesure UDP de ce type : exiger d'abord un récepteur qui **vide son compteur à chaque paquet reçu** (ou le comptage de `probe_send.py`, rendu `SENT=` / `RECV={pair: compteur}` par paquet, qui est ce qui a rendu C3 fiable).
2. **C1 reproduit** (`timeout 120 ping -c 100 -W 1 10.42.0.144`, compteurs `cilium_vxlan` avant/après des deux côtés) → le critère est un **`rx_packets` strictement supérieur à 0** sur notre device tunnel, aligné sur le Δtx (au lieu de 0).
3. **C6 reproduit** (`timeout 6 bash -c 'exec 3<>/dev/tcp/10.2.248.31/443'`) → le critère est **CONNECTED** (au lieu du timeout), ce qui rouvre du même coup le tirage d'images depuis Harbor.

Ces trois contrôles sont non mutants et reproductibles par un tiers, réseau ou plateforme.

### 6.2 Option « plateforme » (épingler `8472-8472`) — **MORTE / NON APPLICABLE. RIEN n'est appliqué à Cilium.**

**Contenu que la version initiale présentait comme LA correction** (texte retiré, et consigné ici uniquement pour que la rétractation soit lisible) : épingler le port source de l'encapsulation — `tunnel-source-port-range: 8472-8472` dans `cilium-config` (`kube-system`), clé Helm `tunnelSourcePortRange` — afin que le 4-tuple de retour redevienne l'inverse exact de notre égress. **Cette option est morte**, et non « en cours d'audit », pour quatre raisons indépendantes, dont aucune ne repose sur une hypothèse :

1. **Rétracté — elle n'a plus d'objet.** Elle corrigeait la cause « ports sources éphémères × isolation entrante du VLAN » ; cette cause est **réfutée** (§0, §3 C2, §4). Sans C2, il n'y a plus d'asymétrie de forme de ports à réparer.
2. **Fait confirmé (mesuré) — la correction est structurellement impossible en place :**

   ```
   $ sudo ip link set dev cilium_vxlan type vxlan srcport 8472 8472
   Error: Cannot change port range.
   ```

   La plage de ports sources d'un device VXLAN **ne se modifie pas en place** : il faudrait **détruire puis recréer le device**, donc en pratique **redémarrer l'agent Cilium sur les trois nœuds**, donc **couper le seul tunnel sain du cluster** (`lima` ↔ `compute-lsis-2`). Ce n'est plus un « risque à évaluer par l'audit » comme l'écrivait cette section : c'est un refus du noyau, mesuré.
3. **Fait confirmé (relevé) — la valeur n'a jamais été déployée.** Le `cilium-config` en service porte `tunnel-source-port-range: "0-0"` (ligne 166 de la capture brute `/tmp/opencode/cilium_live_cm.json`), et `"0-0"` est la **valeur par défaut du chart Helm**. Il n'y a donc aucun figeage en service à « dé-figer », et l'écart entre « ce qui est dans le chart » et « ce qui a été décidé » est nul : cette ligne du dossier initial ne décrit pas un état du cluster.
4. **Fait confirmé par la lecture des sources (§6.2.1) — la clé n'est pas le levier supposé :** `tunnel-source-port-range` est une option du datapath **Geneve** (`hidden:DatapathGeneve`) ; même déployable, elle ne serait pas ce qui fixe le port source du device vxlan.

**État au 2026-11-12 — décision inscrite.** Option **abandonnée** : morte par la contrainte noyau (point 2), sans objet par la rétractation (point 1), hors service (point 3) et non probante (point 4). **Règle en vigueur : RIEN n'est appliqué à Cilium** — ni cette clé, ni aucune autre, ni aujourd'hui, ni après coup. Ce document ne fournit **aucune** procédure d'application et ne doit pas en être lu comme en contenant une.

**Deux verrous structurels, qui tiennent indépendamment du diagnostic :**

- **Portée cluster-wide.** `tunnel-source-port-range` est une clé de `cilium-config`, donc **globale** : elle modifierait le data-plane de **tous** les nœuds, y compris ceux qui fonctionnent aujourd'hui (les deux du VLAN serveur). Une valeur figée peut dégrader ce qui n'est pas cassé.
- **Cilium est hors git et hors ArgoCD** (§1.2). Aucune réconciliation, aucun diff, aucun rollback par git, aucun selfHeal : le changement ne peut pas être versé par la chaîne `gitops-platform` → AppSets → Applications, et ne serait **pas** annulé automatiquement s'il tournait mal. C'est aussi pourquoi il ne peut pas être traité comme un simple commit.
- **Effet partiel, même si l'option avait été viable :** elle n'aurait rien réglé à F4 (§6.1.1) ni à l'isolation entrante générale du VLAN.

**Où suivre l'audit :** son résultat est consigné en §6.2.1 ci-dessous ; `docs/network/` reste le point de dépôt. **À la date du présent document, aucune modification de Cilium n'a été appliquée, et aucune n'est prévue.**

#### 6.2.1 Résultat de l'audit (2026-11-12) — conclusion : option B **morte**, option B′ **non justifiée**

Dans ce sous-§, **B** désigne l'option « plateforme » du §6.2 (épingler `tunnel-source-port-range: 8472-8472`) et **B′** la variante chiffrement WireGuard examinée par le même audit. Constats issus de la lecture des sources Cilium 1.20.x. **Ces conclusions se lisent au passé** : elles consignent pourquoi les deux variantes sont écartées, **pas** ce qu'il faudrait appliquer.

- **Le port source du device VXLAN kernel est calculé par paquet** : dans `pkg/datapath/linux/devices.go`, `vxlanSourcePortMin/Max` sont initialisés à 0, puis le port est choisi par paquet (`encapIP6Loopback`/hash CRH). Le datapath **n'écrase jamais** la plage demandée avec `tunnel-source-port-range` en mode vxlan ⇒ **rien ne prouve que `8472-8472` change le comportement du device vxlan**.
- **`tunnel-source-port-range` est porteur du tag `hidden:DatapathGeneve`** (`pkg/option/config.go`) : c'est une option du **datapath Geneve**, sans effet documenté en dehors de `tunnel-protocol=geneve`. En vxlan, seule `tunnel-port` — le port **destination** — est câblée dans le device. **Donc « B », tel que compris initialement, est INOPÉRANT en `tunnel-protocol=vxlan`** : cette clé ne câble rien dans le device vxlan — et le point 2 de §6.2 l'a confirmé côté noyau (`Error: Cannot change port range.` : la plage ne se change même pas en place). Quant à corriger le port **destination**, c'est un changement cluster-wide qui casserait le trafic compute↔lima (ils s'attendent mutuellement sur 8472) s'il n'était pas appliqué simultanément sur les trois nœuds.
- **Le drapeau hive `--tunnel-source-port-range` existe bien en 1.20.0** (relevé via `cilium-dbg status --verbose` / `helm get values` : valeurs d'usine, `tunnel-source-port-range="0-0"`). L'option est donc reconnue, donc **statique au démarrage de l'agent** (recréation du device → coupure inter-nœuds). Mais « le drapeau existe » ≠ « l'agent l'applique au device vxlan » (cf. points ci-dessus).
- **Rétracté — B′ (chiffrement WireGuard, `encryption=wireguard`) n'est pas une correction : une expérience non vérifiée, désormais **sans justification**.** Ce sous-§ la présentait comme « la variante la plus crédible ». Cette crédibilité reposait **entièrement** sur l'argument « nos réponses sont reçues comme des sessions entrantes non sollicitées » — qui est la cause réfutée (§0, §4, et C2/C3 en §3). L'argument tombe, donc la présomption favorable tombe avec lui : le handshake WireGuard est bien initié par nous, mais **rien n'établit que ce soit là notre déficit**, et B′ n'a plus rien à réparer. Elle exige de toute façon **de redémarrer les agents sur les 3 nœuds pour aucun gain démontré**. Coûts relevés par l'audit, conservés pour la traçabilité : CPU de chiffrement, et `wg-deployment-type: systemd` obligatoire sous tunnel (le mode `native` est refusé — `pkg/nodeencryption/config.go:107-109`). **Non vérifié** dans notre build (Cilium 1.20.0 + kernel `7.0.0-42-generic` + k3s).
  **Fait confirmé (relevé) — le chiffrement n'a jamais tourné ici et n'est pas configuré :** drapeaux de l'agent `--enable-wireguard='false'` et `--encrypt-node='false'`, `lsmod` vide, `wg show` vide, les deux clés sont **absentes** du `cilium-config` en service (166 clés, capture `/tmp/opencode/cilium_live_cm.json`), et aucune release Helm des révisions 1 à 11 ne les a posées. **Nous n'affirmons pas qu'un tel chiffrement est impossible en principe** : nous affirmons qu'il n'a aucune part dans l'état mesuré et qu'aucune preuve ne le désigne comme remède ici.
- **Inconnu non résolvable sans root :** un socket utilisateur ne peut pas épier ni occuper UDP 8472 (le device VXLAN du noyau le détient en exclusif, pas de `SO_REUSEPORT` ; notre `udp_recv.py` écoutait 9999) → on ne peut **pas** tester « 8472 entrant bloqué » vs « entrant non sollicité bloqué ». La sonde `bind` a échoué en `EADDRINUSE` sur les deux hôtes. **Cette distinction est exactement le M1 vs M3 de §4, et c'est le blocker non résolu du dossier** : elle exige un root sur un nœud (refusé partout à la date du dossier), et **aucun essai réel n'a été tenté** — rien ne sera tenté sur Cilium (règle en vigueur, §6.2).

**Aucune de ces options n'est appliquée, et aucune ne doit l'être.** Ce sous-§ consigne le résultat de l'audit tel que mesuré/lu à la date du 2026-11-12 ; le dossier reste la source de vérité sur ce qui est mesuré vs non prouvé.

### 6.3 Conséquence opérationnelle immédiate — **ACTÉE : mise en quarantaine du nœud**

Puisque le data-plane est inutilisable et que le nœud reste `Ready` (donc planifiable), la mise en quarantaine du nœud est **ACTÉE**. Le taint visé pour porter cet état est :

```
quarantine=true:NoSchedule
```

**Attention (corrigé après coup, voir §6.3.1) : ce taint n'est pas la fence operative.** La fence réellement efficace sur `pc-bruno-gpu` au 2026-11-12 est le **cordon** (`kubectl cordon`, i.e. `spec.unschedulable=true`). Le taint ci-dessus ne survit pas à l'admission tant que les politiques sœurs écrasent `spec.taints` ; et la politique censée le matérialiser n'est pas déployée.

- **Mécanisme :** un **label** porté par l'objet Node doit piloter l'ajout du taint via un **ClusterPolicy Kyverno** ; le taint ne doit donc pas être posé « à la main » mais reconcilié, dans la continuité du pattern déjà utilisé pour `workload=runner:NoSchedule` et le taint arm64. **Ce mécanisme est décrit ici comme voulu, non comme en service.**
- **Manifeste concerné :** `kubernetes/arc/node-quarantine-taint.yaml`, référencé dans la liste `resources:` de `kubernetes/arc/kustomization.yaml` — c'est donc l'Application `arc` qui synchronisera la ClusterPolicy, **une fois ce commit poussé sur `main`**. Ce fichier et son référencement sont **commités localement** (`7c6171c`) mais **jamais poussés** à la date du 2026-11-12 : rien de ce lot n'est donc passé par ArgoCD. Vérifications en lecture seule du 2026-11-12 : la ClusterPolicy **n'est pas déployée** dans le cluster (`Error from server (NotFound): clusterpolicies.kyverno.io "node-quarantine-taint" not found`) et l'Application `arc` est `Synced Healthy Succeeded` sur une révision qui ne l'inclut pas. En l'état la fence par taint est donc **inerte côté cluster** : le Node `pc-bruno-gpu` porte bien le label `quarantine=true`, mais son `spec.taints` ne contient que `workload=runner:NoSchedule` — le taint de quarantaine n'a jamais été matérialisé, faute de politique. **Et même posé à la main, il n'aurait pas survécu** : voir §6.3.1. Rien ici n'atteste d'une réconciliation effective tant que `kubectl get clusterpolicy node-quarantine-taint` ne répond pas dans le cluster.
- **Réversibilité :** **le retrait du label ne suffit PAS**, et il ne suffit même pas à lui seul à rendre le nœud planifiable. La politique est explicitement **non auto-nettoyante** (en-tête du manifeste, bloc « NOT SELF-CLEANING ») : retirer le label arrête le matching des règles mais **ne retire pas** le taint — aucune règle ne le garbage-collecte. La levée exige donc les **trois** actions explicites, dans cet ordre : `kubectl label node pc-bruno-gpu quarantine-`, puis `kubectl taint nodes pc-bruno-gpu quarantine:NoSchedule-` **si** le taint a été re-posé (§6.3.1 : il ne survit aujourd'hui pas à l'admission, il est donc souvent déjà absent), puis `kubectl uncordon pc-bruno-gpu` — c'est **lui** qui rétablit la planifiabilité. Symétriquement, il faut **reposer le label après tout cycle leave/join** : un `runner-leave.sh` propre supprime l'objet Node, donc le label et le taint disparaissent avec lui. Preuve d'antériorité relevée le 2026-11-12 : `pc-bruno-gpu` recréé à `2026-11-12T17:22:19Z` (contre `2026-06-18T07:53:09Z` pour `compute-lsis-2`) — tout cycle a remis le Node à zéro.
- **Effet attendu (une fois les deux prérequis de §6.3.1 réunis) :** plus aucun pod `arc-runners/*`, `keycloak-reconciler-*`, `nexus-nexus3-sso-sync-*` planifié sur `pc-bruno-gpu` ; les échecs décrits en §2 cessent d'être visibles sans que rien d'autre ne soit touché. Le poste redevient un nœud présent mais non planifiable, en attendant §6.1 ou §6.2. **Cet effet est obtenu aujourd'hui par le seul cordon**, pas par le taint.

### 6.3.1 Cause de l'effacement du taint — **prouvée** (2026-11-12)

Le §6.3 affirmait que le taint de quarantaine n'était pas matérialisé « faute de politique ». C'est vrai, mais incomplet : **posé à la main, il n'aurait pas survécu non plus.** La cause a été isolée le 2026-11-12 par des écritures répétées et observées en lecture seule.

**Faits observés.**

1. **Trois tentatives** de `kubectl taint nodes pc-bruno-gpu quarantine=true:NoSchedule` : les trois sont **acceptées** par l'API server, et les trois sont **annulées en moins d'une seconde** — le taint disparaît du Node, sans intervention humaine.
2. **Le cordon, lui, survit** : `spec.unschedulable=true` vérifié stable sur 60 s, `resourceVersion` figé sur toute la fenêtre. C'est donc **LA fence operative** de l'incident.
3. **Signature de l'auteur de l'effacement**, en lecture seule sur la politique déployée :

   ```
   $ kubectl get clusterpolicy node-workload-runner-taint -o jsonpath='{.spec.rules[0].mutate}'
   {"patchStrategicMerge":{"spec":{"taints":[{...workload...}]}}}
   ```

   (sortie relevée le 2026-11-12 ; le contenu de l'élément de taint est abrégé ici, sa forme complète est celle du fichier git avant conversion, `git show 7c6171c:kubernetes/arc/node-workload-runner-taint.yaml` — `key: workload / value: "runner" / effect: NoSchedule`.)

**Mécanisme.** `Node.spec.taints` est typé `x-kubernetes-list-type: atomic` dans le schéma Kubernetes, **sans** `patchMergeKey` : une liste atomique n'est pas fusionnée élément par élément, elle est **remplacée dans son ensemble**. Un `mutate.patchStrategicMerge` qui nomme donc `spec.taints` réécrit le tableau entier à chaque requête d'admission admise par le webhook `kyverno-resource-mutating-webhook-cfg`. Comme `pc-bruno-gpu` porte le label `workload=runner`, la politique le fait matcher **et** muter à chaque UPDATE du Node : le tableau est remplacé par la seule entrée `workload=runner`, et le `quarantine=true:NoSchedule` qui s'y trouvait est supprimé. La politique `node-arm64-arch-taint` présente exactement le même défaut (sur `kubernetes.io/arch`).

**Ce qui a été écarté** (mêmes relevés, lecture seule) : aucune **autre** ClusterPolicy / MutatingPolicy ne cible les ressources `Node` ; aucun événement de re-registration du nœud sur la fenêtre d'observation ; et le kubelet ne réécrit pas `spec.taints` (il est de toute façon exclu de l'admission Kyverno par `excludeGroups: system:nodes`, ce qui est précisément la raison d'être de ces politiques).

**Pourquoi le cordon survit** : `spec.unschedulable` est **hors du champ de la patch** — aucune des politiques en cause ne le mentionne. Rien ne le reconcilie, donc rien ne l'efface.

**Conséquence — ce qui doit être vrai pour que la fence par label+taint soit operative :**

- (a) déployer `kubernetes/arc/node-quarantine-taint.yaml`, **et**
- (b) convertir les deux politiques sœurs en append non destructif.

Les deux ont été écrites le 2026-11-12 : (a) en `patchesJson6902` append, (b) idem pour `node-workload-runner-taint` et `node-arm64-arch-taint` (avec une règle dédiée pour le cas `spec.taints` absent/vide, car un `add /spec/taints` inconditionnel écraserait la liste existante — c'est le même bug). **Aucune de ces deux conditions n'est réunie en service** : tout ce lot est **uniquement en git, non poussé**, et sa validation se limite à une **matrice fire/skip des règles vérifiée hors ligne avec la version mineure `kyverno-cli` correspondante (v1.15.0)** — **les tableaux mutés en sortie n'ont pas été lus** et **le comportement du webhook en admission n'a pas été observé**.

> **Ce qui est dans le dépôt n'est pas ce qui est en service.** Tant que la conversion n'a pas été validée en admission réelle, la seule fence dont on puisse affirmer qu'elle tient est le cordon.

### 6.4 Règle de plateforme découlant de ce dossier *(à appliquer à tout futur ajout de nœud)*

> **Prérequis non négociable : un nœud worker CI ne doit être joint au cluster que depuis le VLAN serveur `10.2.248.0/24`.** En VLAN utilisateurs `10.2.251.0/24`, le mode `tunnel` de Cilium est **inutilisable** en l'état de la politique réseau, quel que soit le matériel, l'architecture ou l'âge du noyau.

Corollaires opérationnels :

- Avant toute jointure (ou tout retour de veille / changement de réseau d'un portable), vérifier le VLAN effectif (`ip -4 -o addr show` : l'adresse doit être dans `10.2.248.0/24`) **et** valider le data-plane **dans les deux sens** avant d'uncordonner. Une vérification de joignabilité TCP du seul plan de contrôle (`6443`) est **insuffisante** : C6 montre qu'elle reste vraie pendant que le plan de données est mort.
- Le point d'entrée de validation bidirectionnel correspondant est **en cours d'ajout** dans l'outillage du nœud runner (`infrastructure/laptop/`, hors périmètre du présent dossier).
- Un `Ready` + `NetworkUnavailable=False` **ne prouve pas** le data-plane : c'est la leçon centrale de l'incident, et c'est ce que la commande de réflexe du bullet `AGENTS.md` doit rappeler.

---

## 7. Annexe — reproductibilité (harnais de mesure)

**Attention : ces scripts vivaient dans `/tmp/opencode/`, donc en stockage volatil. Ils n'existent plus et doivent être recréés pour reproduire les mesures C2/C3.** Leur contenu n'est pas consigné ici (la mise en place d'un harnais permanent est hors du périmètre de ce dossier) ; seuls leur rôle et leur point d'appel le sont.

| Script | Rôle | Commande d'appel (bornée) |
|---|---|---|
| `/tmp/opencode/udp_recv.py` | écouteur UDP passif, affiche la source et le nombre de datagrammes reçus dans sa fenêtre d'écoute | `timeout 60 python3 /tmp/opencode/udp_recv.py` |
| `/tmp/opencode/udp_send.py` | émetteur UDP N datagrammes vers une cible, port source **libre** (éphémère) ou épinglé | `timeout 60 python3 /tmp/opencode/udp_send.py` |
| `/tmp/opencode/bidi.py` | **C2** : salve bidirectionnelle de 15 datagrammes avec ports sources éphémères, rendus des deux côtés | `timeout 60 python3 /tmp/opencode/bidi.py` |
| `/tmp/opencode/probe_send.py` | **C3** : salve de ~400 000 datagrammes avec port source **épinglé**, rendus `SENT=` / `RECV={pair: compteur}` | `timeout 300 python3 /tmp/opencode/probe_send.py` |
| `/tmp/opencode/vxdir.sh` | **C1** : lit les compteurs `rx_packets`/`tx_packets` de `cilium_vxlan` des deux extrémités autour d'une salve de ping, et rend les Δ | `timeout 120 bash /tmp/opencode/vxdir.sh` |
| `/tmp/opencode/diag2.sh` | **C4/C5** : ramasse les compteurs de la carte physique, `Icmp:` de `/proc/net/snmp`, l'état de l'agent (`9879/healthz`), le MTU du device tunnel | `timeout 60 bash /tmp/opencode/diag2.sh` |

Contraintes pour toute reproduction :

- `lima-k3s-agent` (`10.2.248.247`) **n'est pas joignable en SSH** (accès publickey refusé) : **aucune** commande de ce dossier ne l'utilise ; les mesures « côté pair » ont toutes été prises sur `compute-lsis-2`.
- Tout `ssh` est appelé avec `-o BatchMode=yes -o ConnectTimeout=5` et placé sous `timeout`, pour ne jamais bloquer une session sur un poste éteint ou injoignable.
- Les seules commandes cluster utilisées sont en **lecture seule** ; aucune commande mutante (`patch`, `apply`, `scale`, `delete`, `exec` modifiant l'état) n'a été exécutée pour produire ce dossier. Aucun `sudo` n'est requis, sauf pour le relevé `ufw status` de C5, exécuté par l'opérateur du poste.

---

## 8. Limites de traçabilité et inconnues assumées

Déclarées pour que le lecteur ne prenne aucun élément de ce dossier pour plus solide qu'il n'est :

1. **Contenu des scripts `/tmp` non conservé.** Les compteurs bruts de C2/C3 sont bien traçables à un script et à une forme d'appel, mais **les paramètres internes de ligne de commande de ces scripts n'ont pas été consignés**. Toute reproduction fidèle suppose de réécrire le harnais (§7) ou d'utiliser l'équivalent `udp_recv.py`/`udp_send.py` à la main.
2. **Valeurs de `sysctl` de C5 sans capture brute** : vérifiées conformes sur le moment, non archivées. **Portée de cette lacune — corrigée.** La version initiale écrivait « la preuve de l'innocuité locale est C4, qui place le drop avant la carte réseau ». **C4 est retirée en tant que preuve** (§3 C4), pour deux motifs indépendants : (a) **résolution insuffisante** — Δ `enp0s31f6 rx_packets` = **250** sur la fenêtre de 40 pings contre **119** sur une fenêtre de repos de même durée, soit ~**131** d'excédent sur un fond déjà de ~119, ce qui ne permet pas d'établir une absence de trames ; (b) **contradiction avec C3**, qui consigne **399 316** datagrammes entrants effectivement reçus par ce même hôte sur cette même carte physique. **Par suite, l'innocuité locale n'est plus établie par la mesure.** Elle ne subsiste qu'à l'état d'**hypothèse**, appuyée sur des indices indirects : `ss -ulnp` montre le socket de décapsulation VXLAN lié sur `0.0.0.0:8472`, `ufw` est `inactif`, le firewall d'hôte Cilium est `Disabled`, et le portable reçoit manifestement du trafic entrant puisque SSH y atteint un prompt de mot de passe. **Hypothèse ouverte qui en découle : M1 (drop en amont de l'hôte) vs M3 (drop dans l'hôte, avant le device tunnel) n'est pas départagé** ; le blocker est l'absence de `sudo tcpdump -ni <iface> 'udp port 8472 and src host 10.2.251.152'` sur `compute-lsis-2`, jamais exécuté car `sudo` a été refusé partout.
3. **Aucun accès à la politique réseau** (§4) : le mécanisme de filtrage côté VLAN est **déduit**, pas observé. Si un sysadmin réseau confirmait ou infirmait la règle, ce serait §4 qui devrait être corrigé, pas les mesures §3.
4. **`lima-k3s-agent` non mesuré directement** (SSH refusé) : F2 (§6.1.1) est une **présomption** fondée sur F1, pas une mesure. Les compteurs `cilium_vxlan` de ce nœud n'ont pas été relevés.
5. **Instantanés ponctuels** : toutes les valeurs de §3 sont des mesures du 2026-11-12, à un état donné du réseau (VPN/posture du portable incluses). Elles ne sont pas automatiquement valables après un changement de réseau ou d'équipement amont ; c'est pourquoi chaque bloc redonne sa commande.
6. **Le `CONNECTED` de `10.2.248.247:443` (C6) n'est pas expliqué** de façon satisfaisante. Non creusé, sans impact sur le verdict (qui repose sur C1–C4).
7. **Statut git réel du lot de mitigation (corrigé le 2026-11-12).** À la date du diagnostic, ni le manifeste de quarantaine (§6.3) ni l'outillage de validation bidirectionnelle (§6.4) n'existaient dans le dépôt. Ils ont **depuis été écrits et commités localement** (`7c6171c`) : le manifeste `kubernetes/arc/node-quarantine-taint.yaml` et son référencement dans `kubernetes/arc/kustomization.yaml` **sont commités**, ils ne sont **pas poussés** sur `main`. Ce dossier documente donc un problème et une mitigation **écrites mais non déployées** : rien ici n'atteste que ces fichiers sont en service dans le cluster (voir §6.3.1 pour l'écart entre dépôt et service).
8. **Le correctif Cilium (§6.2) est MORT — décision actée, et non plus un audit en cours ; rien n'est appliqué à Cilium.** Rappel explicite, car l'existence d'une clé Helm identifiée (`tunnelSourcePortRange`) pourrait être lue comme une correction en service ou en évaluation : elle ne l'est pas. L'option « épingler `tunnel-source-port-range: 8472-8472` » est **morte** pour deux raisons indépendantes et mesurées : (a) le noyau **refuse la modification en place** (`sudo ip link set dev cilium_vxlan type vxlan srcport 8472 8472` → `Error: Cannot change port range.`), donc il faudrait **détruire puis recréer le device**, soit en pratique **redémarrer l'agent Cilium sur les trois nœuds**, soit **couper le seul tunnel sain du cluster** (`lima` ↔ `compute-lsis-2`) ; (b) **la valeur n'a jamais été déployée** — le `cilium-config` en service porte `"0-0"`, qui est la **valeur par défaut du chart** (ligne 166 de la capture brute `/tmp/opencode/cilium_live_cm.json`) : il n'y a rien à « dé-figer ». Détail en §6.2 et §6.2.1.
9. **Rétracté — la variante chiffrement WireGuard n'est plus une piste de correction** (§6.2.1, option B′). Elle n'était motivée **que** par la cause « nos réponses sont reçues comme des sessions entrantes non sollicitées », aujourd'hui **réfutée** (§0, §3 C2/C3, §4) ; elle est **non vérifiée** dans notre build (Cilium 1.20.0 + kernel `7.0.0-42-generic` + k3s) ; et elle coûte, elle aussi, **un redémarrage des agents sur les 3 nœuds pour aucun gain démontré**. **Rien n'est appliqué à Cilium**, et rien ne l'a jamais été (§6.2). **Ce qui reste bel et bien ouvert — et n'est pas la même chose :** départager le mécanisme de filtrage (« `8472` entrant bloqué » vs « session entrante non sollicitée bloquée ») est **impossible sans privilège root sur un nœud** ; aucune de ces deux hypothèses n'a pu être testée en réel. Cette impossibilité est le **blocker du dossier** (cf. point 2 ci-dessus sur M1 vs M3), pas un arbitrage entre correctifs.
10. **Piège de formulation : `kube-proxy-replacement` — ne jamais n'en écrire qu'une moitié.** Le `cilium-config` en service **demande** `kube-proxy-replacement: "true"` (ligne 112 de la capture brute `/tmp/opencode/cilium_live_cm.json`), **alors que l'exécution relève `Partial` avec `Host: Legacy`** (agent en service, Cilium `v1.20.0`, chart `cilium-1.20.0`). Les deux moitiés sont vraies simultanément : la valeur demandée n'est pas le mode effectif. **Toute phrase qui écrit seulement « KPR est désactivé » est fausse ; toute phrase qui écrit seulement « KPR est `true` » l'est aussi.** Les deux mentions doivent voyager ensemble.

---

**Références croisées :** bullet **« VLAN utilisateurs ⇒ data-plane Cilium tunnel unidirectionnel (`pc-bruno-gpu`, 2026-11-12) — cause « ports sources VXLAN » RÉFUTÉE, lire avant toute déduction »** dans `AGENTS.md` (§ Troubleshooting Patterns) — titre exact, à respecter tel quel lors de toute citation ; outillage du nœud runner dans `infrastructure/laptop/` ; taints pilotés par label dans `kubernetes/arc/` ; état général de la plateforme dans `docs/deep-audit.md`.

