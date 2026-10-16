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

## The weather actually used for this sortie (RANDOM resolved to a real type).
func resolved_weather() -> int:
	if weather != Weather.RANDOM:
		return weather
	var options := [Weather.CLEAR, Weather.FAIR_CUMULUS, Weather.STORMS, Weather.OVERCAST, Weather.HIGH_CLOUD]
	return options[randi() % options.size()]
