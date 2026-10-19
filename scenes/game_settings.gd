extends Node
## Persistent settings shared between the menu and game scenes.

enum Weather {
	RANDOM       = 0,   # pick one of the others each sortie
	CLEAR        = 1,   # a few small fair-weather cumulus, crisp visibility
	FAIR_CUMULUS = 2,   # scattered cumulus with the odd towering cumulus
	STORMS       = 3,   # towering cumulus and cumulonimbus with rain shafts
	OVERCAST     = 4,   # broken stratocumulus deck, grey and gloomy below
	HIGH_CLOUD   = 5,   # cirrus, cirrostratus veil and altocumulus at combat height
}

const WEATHER_INFO := {
	Weather.RANDOM:       ["Random",          "Let the Met Office decide."],
	Weather.CLEAR:        ["Clear Skies",     "Unlimited visibility. Nowhere to hide."],
	Weather.FAIR_CUMULUS: ["Fair Weather",    "Scattered summer cumulus over the Channel."],
	Weather.STORMS:       ["Thunderstorms",   "Towering cumulonimbus and heavy showers."],
	Weather.OVERCAST:     ["Overcast",        "Broken deck at 4,500 ft. Grey below, sun above."],
	Weather.HIGH_CLOUD:   ["High Cloud",      "Cirrus veils and altocumulus at fighting height."],
}

var weather : int = Weather.FAIR_CUMULUS

## Time of day the sortie starts (local British Summer Time, mid-August 1940).
## The clock runs on in real time, so a dusk raid ends in twilight.
## [hour, name, hint]; hour < 0 = random daylight start
const TIMES := [
	[6.0, "Dawn", "Sun just up in the east-north-east. Long orange shadows."],
	[8.5, "Morning", "Low sun in the east, fresh and clear."],
	[13.0, "Midday", "Sun high in the south. Flat light, short shadows."],
	[16.5, "Afternoon", "Sun in the south-west. Watch for the Hun in the sun."],
	[19.75, "Dusk", "Sun setting in the west-north-west. Fight into the twilight."],
	[-1.0, "Random", "Any time from dawn to dusk."],
]
var time_of_day := 16.5

## The start hour actually used for this sortie (random resolved)
func resolved_hour() -> float:
	if time_of_day >= 0.0:
		return time_of_day
	return randf_range(5.8, 19.8)

## Horizontal map scale: 1.0 = real distances.  Smaller shrinks the distances
## between places (shorter flights) while aircraft, buildings and trees keep
## their real size.
const MAP_SCALES := [[1.0, "Full Scale", "Real distances. The Channel is 33 km wide."],
	[0.75, "Reduced", "Three-quarter distances between airfields and targets."],
	[0.55, "Compact", "Arcade-style hops between the action."]]
var map_scale := 1.0

## Playable aircraft key in scenes/plane/aircraft_types.gd
var aircraft := "spitfire"

## Mission id (scenes/mission/missions.gd), the player's side ("raf" / "lw")
## and the airfield to start from (by name; "" = the mission's default)
var mission := "london"
var side := "raf"
var airfield := ""

## The weather actually used for this sortie (RANDOM resolved to a real type).
func resolved_weather() -> int:
	if weather != Weather.RANDOM:
		return weather
	var options := [Weather.CLEAR, Weather.FAIR_CUMULUS, Weather.STORMS, Weather.OVERCAST, Weather.HIGH_CLOUD]
	return options[randi() % options.size()]
