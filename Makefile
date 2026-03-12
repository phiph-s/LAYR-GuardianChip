MAKEFILE_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

RUN_TAG = $(shell ls librelane/runs/ | tail -n 1)
TOP = hsrm_team1

PDK_ROOT ?= $(MAKEFILE_DIR)/IHP-Open-PDK
PDK ?= ihp-sg13g2
PDK_COMMIT ?= c4b8b4e5e7a05f375cca3815d51b3a37721fbf5c

.DEFAULT_GOAL := help

$(PDK_ROOT)/$(PDK):
	ciel enable $(PDK_COMMIT) --pdk-root $(PDK_ROOT) --pdk-family $(PDK)

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
.PHONY: help

clone-pdk: $(PDK_ROOT)/$(PDK) ## Clone the IHP-Open-PDK repository
.PHONY: clone-pdk

all: librelane ## Build the project (runs LibreLane)
.PHONY: all

librelane: $(PDK_ROOT)/$(PDK) ## Run LibreLane flow (synthesis, PnR, verification)
	librelane librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk
.PHONY: librelane

librelane-nodrc: $(PDK_ROOT)/$(PDK) ## Run LibreLane flow without DRC checks
	librelane librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk --skip KLayout.DRC --skip Magic.DRC
.PHONY: librelane-nodrc

librelane-openroad: $(PDK_ROOT)/$(PDK) ## Open the last run in OpenROAD
	librelane librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk --last-run --flow OpenInOpenROAD
.PHONY: librelane-openroad

librelane-klayout: $(PDK_ROOT)/$(PDK) ## Open the last run in KLayout
	librelane librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk --last-run --flow OpenInKLayout
.PHONY: librelane-klayout

sim: ## Run RTL simulation with cocotb
	cd cocotb; PDK_ROOT=${PDK_ROOT} PDK=${PDK} python3 chip_top_tb.py
.PHONY: sim

sim-aes: ## Run AES core unit tests (NIST vectors + round-trip + LAYR protocol ops)
	cd cocotb; python3 test_aes_core.py
.PHONY: sim-aes

sim-layr: ## Run LAYR core tests (full auth, wrong PSK, rollover, link drop, ...)
	cd cocotb; python3 test_layr_core.py
.PHONY: sim-layr

sim-unit: sim-aes sim-layr ## Run all unit testbenches
.PHONY: sim-unit

sim-gl: $(PDK_ROOT)/$(PDK) ## Run gate-level simulation with cocotb
	cd cocotb; GL=1 PDK_ROOT=${PDK_ROOT} PDK=${PDK} python3 chip_top_tb.py
.PHONY: sim-gl

sim-view: ## View simulation waveforms in GTKWave
	gtkwave cocotb/sim_build/chip_top.fst
.PHONY: sim-view

copy-final: ## Copy final output files from the last run
	rm -rf final/
	cp -r librelane/runs/${RUN_TAG}/final/ final/
.PHONY: copy-final

GDSFILL_CONFIG ?= $(MAKEFILE_DIR)/gdsfill_config.yaml

librelane-to-filler: $(PDK_ROOT)/$(PDK) ## Run LibreLane flow up to and including the metal filler step
	librelane librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk -T KLayout.Filler
.PHONY: librelane-to-filler

gdsfill-resume: ## Run gdsfill on last run's filler output, then resume LibreLane from density check onwards
	$(eval FILLER_GDS := $(shell ls librelane/runs/$(RUN_TAG)/63-klayout-filler/*.gds 2>/dev/null | head -1))
	@test -n "$(FILLER_GDS)" || (echo "ERROR: No GDS found in 63-klayout-filler/"; exit 1)
	@test -f "$(GDSFILL_CONFIG)" || (echo "ERROR: gdsfill config not found at $(GDSFILL_CONFIG)"; exit 1)
	@echo "==> Backing up $(FILLER_GDS)"
	cp "$(FILLER_GDS)" "$(FILLER_GDS).bak"
	@echo "==> Running gdsfill fill on $(FILLER_GDS)"
	gdsfill fill "$(FILLER_GDS)" --config-file "$(GDSFILL_CONFIG)"
	@echo "==> Clearing stale run logs"
	truncate -s 0 librelane/runs/$(RUN_TAG)/error.log librelane/runs/$(RUN_TAG)/warning.log librelane/runs/$(RUN_TAG)/flow.log 2>/dev/null || true
	@echo "==> Resuming LibreLane from KLayout.Density"
	librelane librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk --last-run -F KLayout.Density
.PHONY: gdsfill-resume

gdsfill-clean-resume: ## Erase KLayout M2/M3 fill, run gdsfill only, then resume (avoids double-fill DRC errors)
	$(eval FILLER_GDS := $(shell ls librelane/runs/$(RUN_TAG)/63-klayout-filler/*.gds 2>/dev/null | head -1))
	@test -n "$(FILLER_GDS)" || (echo "ERROR: No GDS found in 63-klayout-filler/"; exit 1)
	@test -f "$(GDSFILL_CONFIG)" || (echo "ERROR: gdsfill config not found at $(GDSFILL_CONFIG)"; exit 1)
	@echo "==> Backing up $(FILLER_GDS)"
	cp "$(FILLER_GDS)" "$(FILLER_GDS).bak"
	@echo "==> Erasing KLayout M2/M3 fill from $(FILLER_GDS)"
	klayout -zz -r $(MAKEFILE_DIR)/librelane/erase_m2m3_fill.py "$(FILLER_GDS)"
	@echo "==> Running gdsfill fill on $(FILLER_GDS)"
	gdsfill fill "$(FILLER_GDS)" --config-file "$(GDSFILL_CONFIG)"
	@echo "==> Clearing stale run logs"
	truncate -s 0 librelane/runs/$(RUN_TAG)/error.log librelane/runs/$(RUN_TAG)/warning.log librelane/runs/$(RUN_TAG)/flow.log 2>/dev/null || true
	@echo "==> Resuming LibreLane from KLayout.Density"
	librelane librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk --last-run -F KLayout.Density
.PHONY: gdsfill-clean-resume

librelane-full-gdsfill: librelane-to-filler gdsfill-resume ## Run full flow with gdsfill density fix (librelane-to-filler + gdsfill-resume)
.PHONY: librelane-full-gdsfill

librelane-full-gdsfill-clean: librelane-to-filler gdsfill-clean-resume ## Run full flow: synthesis+PnR, then erase M2/M3 KLayout fill, gdsfill, resume (recommended)
.PHONY: librelane-full-gdsfill-clean
