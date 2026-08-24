# phony targets don't represent files
.PHONY: pipeline dashboard

# Set up conda environment
setup: .conda_env_created

# Downstream steps require setup to have been run; use sentinel file to track
.conda_env_created:
	conda env create -f "envs/environment.yml"
	touch .conda_env_created

# Run pipeline.
# If the target requires multiple statements, use ; or && keeps the statements in the same line, and thus in the same shell session
pipeline: .conda_env_created
	conda run -n teiko-env nextflow run main.nf -output-dir nextflow_outputs -with-report nextflow_outputs/report.html

# Launch dashboard (requires setup to have been run)
# This script assumes you are at the root directory
dashboard: .conda_env_created
	python load_data.py
	python summarize_data.py
	@echo "Shiny app is probably running at: http://$$(hostname -I | tr -d ' '):3838"
	@echo "To terminate dashboard, press Ctrl + C"
	conda run -n teiko-env Rscript dashboard.R