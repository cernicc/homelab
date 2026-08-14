.PHONY: ignition
ignition:
	butane --pretty --strict --files-dir . ignition/alfred.bu > ignition/alfred.ign
