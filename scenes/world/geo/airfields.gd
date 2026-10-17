extends RefCounted
## Airfields of summer 1940 at their real positions: [name, side, lat, lon].
## Side: "raf" or "lw" (Luftwaffe).  Shown on the map, and each one is a
## flat grass field with hangars on the ground (geo_data.gd, dover_scenery.gd).

const LIST : Array = [
	# RAF Fighter Command — 11 Group and neighbours
	["Hawkinge", "raf", 51.1135, 1.1530],
	["Lympne", "raf", 51.0800, 1.0200],
	["Manston", "raf", 51.3460, 1.3460],
	["Detling", "raf", 51.3030, 0.5970],
	["West Malling", "raf", 51.2700, 0.4020],
	["Gravesend", "raf", 51.4130, 0.3950],
	["Biggin Hill", "raf", 51.3310, 0.0330],
	["Kenley", "raf", 51.3050, -0.0930],
	["Croydon", "raf", 51.3560, -0.1170],
	["Hornchurch", "raf", 51.5390, 0.2050],
	["Rochford", "raf", 51.5710, 0.6950],
	["Eastchurch", "raf", 51.4010, 0.8500],
	["North Weald", "raf", 51.7220, 0.1540],
	["Northolt", "raf", 51.5530, -0.4180],
	["Debden", "raf", 52.0000, 0.2730],
	["Duxford", "raf", 52.0910, 0.1320],
	["Martlesham Heath", "raf", 52.0590, 1.2710],
	["Tangmere", "raf", 50.8460, -0.7060],
	["Westhampnett", "raf", 50.8590, -0.7590],
	["Middle Wallop", "raf", 51.1400, -1.5700],
	["Warmwell", "raf", 50.6930, -2.3500],
	# Luftwaffe — Luftflotte 2 and 3 across the Channel
	["Marquise", "lw", 50.8100, 1.7000],
	["Wissant", "lw", 50.8830, 1.6700],
	["Calais-Marck", "lw", 50.9620, 1.9540],
	["Guînes", "lw", 50.8500, 1.8600],
	["Saint-Omer", "lw", 50.7300, 2.2400],
	["Desvres", "lw", 50.6700, 1.8300],
	["Abbeville-Drucat", "lw", 50.1420, 1.8300],
	["Amiens-Glisy", "lw", 49.8730, 2.3870],
	["Beauvais-Tillé", "lw", 49.4540, 2.1130],
	["Cormeilles-en-Vexin", "lw", 49.0960, 2.0380],
	["Lille-Vendeville", "lw", 50.5630, 3.0890],
	["Caen-Carpiquet", "lw", 49.1730, -0.4500],
	["Cherbourg-Théville", "lw", 49.6500, -1.4800],
	["Brussels-Evere", "lw", 50.8700, 4.4500],
	["Schiphol", "lw", 52.3100, 4.7600],
	# Home defence round Cologne and the Ruhr
	["Köln-Butzweilerhof", "lw", 50.9830, 6.8970],
	["Köln-Ostheim", "lw", 50.9300, 7.0450],
	["Bonn-Hangelar", "lw", 50.7690, 7.1630],
	["Düsseldorf", "lw", 51.2890, 6.7670],
	["Essen-Mülheim", "lw", 51.4020, 6.9370],
]
