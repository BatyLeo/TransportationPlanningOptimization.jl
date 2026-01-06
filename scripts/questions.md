## New questions for Mathis
- Pas mal de duplicate arcs
- Création du NetworkGraph : ajout de shortcut arcs (v, v) pour tout supplier v, à quoi ça sert?
- Y a un problème si on veut des arcs avec plusieurs moyens de transport, les temps de trajet ne sont pas les mêmes, j'ai l'impression qu'on a besoin d'un multigraph...
	- peut-être qu'on peut store en métadata la liste des arcs au lieu d'un unique arc, et adapter les algos de plus court chemin via des implems custom ?
	- si ça "tape" deux endroits différents, c'est peut-être même plus simple
- question sur les shortcut arcs dans le cas général où les suppliers peuvent être aussi des plateformes
	- j'ai l'impression qu'on doit ajouter un noeud via preprocessing si un supplier a des inneighbors
	- même question pour les units qui apparaissent uniquement dans le dernier time step du time travel graph
- A quoi ça sert de boucler (modulo) le time space graph? Pour pouvoir avoir T=1 au min delivery time? (11 time steps au lieu de 8 sur small)
- Wait arcs option ? Just add more shortcut arcs with cost 0
- Ka maximum number of bins available? Not in the code it seems
- Dans l'insertion des bundles, tu ne refais pas le full bin packing sur les arcs?
- Quelle est l'utilité du maxPackSize en field des bundle (=maximum size of a commodity in the bundle)
- Pareil pour les order, quelle est l'utilité de ces champs:
	- In orders, store some bin packing info for every arc type
	- minPackSize : minimum size d'une commodité dans l'order
	- stockCost : cout total de stockage des commodités dans l'order
	- volume : volume total de l'order

---

- Option to cut bundles by time, group by for bundles
- Option pour loop dans la construction du time space graph
- Wait option that adds shortcut everywhere, with some cost, holding costs
