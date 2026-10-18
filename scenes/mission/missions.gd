extends RefCounted
## Mission definitions.  mission.gd turns one of these into aircraft.
##
##   attacker      "lw" / "raf" — whose bombers fly the raid ("" = no raid)
##   target        [name, lat, lon, radius m] — the aiming point
##   from          [lat, lon] — the direction the raid comes from
##   approach      game metres from the target at which the raid starts
##   alt           bomber altitude (m)
##   bombers       [type, count]       escorts [type, count]
##   defenders     list of [type, count, role, start] — start "air" or "ground"
##                 (the player's own section, when defending, is added on top)
##   player_start  how a defending player starts: "ground" (chosen airfield) or "air"

const LIST : Array = [
	{
		"id": "london", "name": "The Blitz", "date": "7 September 1940",
		"blurb": "A massed raid on the London docks.",
		"brief_raf": "Scramble! A heavy raid is crossing Kent for the London docks. Get airborne, climb, and break up the bombers before they reach the river.",
		"brief_lw": "Escort the Heinkels to the London docks. Keep the Spitfires and Hurricanes off the bombers until the bombs are gone.",
		"attacker": "lw",
		"target": ["London Docks", 51.5055, -0.0235, 2600.0],
		"from": [50.95, 1.75], "approach": 52000.0, "alt": 4000.0,
		"bombers": ["he111", 12], "escorts": ["bf109", 8],
		"defenders": [["hurricane", 6, "intercept", "air"], ["spitfire", 4, "sweep", "air"]],
		"player_start": "ground",
	},
	{
		"id": "biggin", "name": "The Hardest Day", "date": "18 August 1940",
		"blurb": "The Luftwaffe goes for Biggin Hill.",
		"brief_raf": "Bandits heading for Biggin Hill. Get your section off the ground and stop them cratering the airfield.",
		"brief_lw": "Escort the raid on Biggin Hill, the sector station guarding London. Destroy it on the ground.",
		"attacker": "lw",
		"target": ["RAF Biggin Hill", 51.3310, 0.0330, 1100.0],
		"from": [50.73, 0.25], "approach": 40000.0, "alt": 3200.0,
		"bombers": ["he111", 9], "escorts": ["bf109", 6],
		"defenders": [["hurricane", 6, "intercept", "air"]],
		"player_start": "ground",
	},
	{
		"id": "channel", "name": "Channel Convoy", "date": "July 1940",
		"blurb": "A quick scrap over the Dover Strait.",
		"brief_raf": "A Heinkel formation is going for Dover harbour. You are already up: get stuck in.",
		"brief_lw": "Escort a small raid on Dover harbour. Tommies are waiting over the cliffs.",
		"attacker": "lw",
		"target": ["Dover Harbour", 51.1150, 1.3250, 1300.0],
		"from": [50.90, 1.80], "approach": 15000.0, "alt": 3500.0,
		"bombers": ["he111", 5], "escorts": ["bf109", 4],
		"defenders": [["hurricane", 4, "intercept", "air"]],
		"player_start": "air",
	},
	{
		"id": "boulogne", "name": "Battle of the Barges", "date": "September 1940",
		"blurb": "Bomb the invasion fleet in Boulogne harbour.",
		"brief_raf": "Bomber Command is going for the invasion barges in Boulogne. Escort the Wellingtons there and back.",
		"brief_lw": "Tommy bombers are after the barges in Boulogne harbour. Scramble and shoot them down before they bomb.",
		"attacker": "raf",
		"target": ["Boulogne Harbour", 50.7270, 1.5970, 1300.0],
		"from": [51.10, 1.05], "approach": 34000.0, "alt": 3000.0,
		"bombers": ["wellington", 9], "escorts": ["spitfire", 6],
		"defenders": [["bf109", 6, "intercept", "air"], ["bf109", 2, "sweep", "air"]],
		"player_start": "ground",
	},
	{
		"id": "cologne", "name": "Raid on Cologne", "date": "August 1941",
		"blurb": "A daylight raid deep into the Reich.",
		"brief_raf": "A daylight Wellington raid on Cologne. Escort them over the Rhine and keep the 109s off.",
		"brief_lw": "RAF bombers are crossing Belgium for Cologne. Scramble from the Rhineland fields and defend the city.",
		"attacker": "raf",
		"target": ["Cologne", 50.9400, 6.9580, 2500.0],
		"from": [50.85, 5.45], "approach": 42000.0, "alt": 3600.0,
		"bombers": ["wellington", 12], "escorts": ["spitfire", 8],
		"defenders": [["bf109", 6, "intercept", "air"], ["bf109", 4, "sweep", "air"]],
		"player_start": "ground",
	},
	{
		"id": "free", "name": "Free Flight", "date": "Any day",
		"blurb": "No enemies. Fly anywhere on the map.",
		"brief_raf": "Take off from any RAF airfield, or start in the air over Dover, and explore.",
		"brief_lw": "Take off from any Luftwaffe airfield, or start in the air over Dover, and explore.",
		"attacker": "",
		"player_start": "ground",
	},
]

## Pseudo-airfield for starting in the air in Free Flight
const AIRBORNE := "Airborne over Dover"

static func by_id(id: String) -> Dictionary:
	for m in LIST:
		if m.id == id:
			return m
	return LIST[0]

static func other(side: String) -> String:
	return "raf" if side == "lw" else "lw"

## Is the player on the attacking side?
static func player_attacks(m: Dictionary, side: String) -> bool:
	return m.attacker != "" and m.attacker == side
