-- Warehouse Distribution: game script registration. The game finds *.gs.lua
-- files in a mod and runs the functions named here in the engine state.
function data()
	return {
		updateScript = {
			fileName = "warehouse_distribution.script@update",
		},
		handleEventScript = {
			fileName = "warehouse_distribution.script@handleEvent",
		},
	}
end
