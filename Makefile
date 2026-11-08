.PHONY: ignition
ignition:
	butane --pretty --strict --files-dir . ignition/batcave.bu > ignition/batcave.ign
