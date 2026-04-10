extends Node
## Persistent settings shared between the menu and game scenes.

enum CloudPreset {
	RANDOM       = 0,   # new random high-cloud type + altitude each session
	CLEAR        = 1,   # no clouds at all
	CUMULUS      = 2,   # mid-level fluffy clouds only
	CIRROSTRATUS = 3,   # high thin veil only
	CIRROCUMULUS = 5,   # mackerel sky only
	OVERCAST     = 6,   # cumulus + cirrostratus together
}

var cloud_preset : int = CloudPreset.RANDOM
