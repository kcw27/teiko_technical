/*
 * For all part 4 inputs, run subset analysis
 */
process subset_analysis {
    conda "${workflow.projectDir}/envs/for_nextflow.yml"
    
    input:
    path inputDir
    path data_db

    output:
    path "subset_analysis_results/", emit: part4_out

    script:
    """
    #!/usr/bin/env Rscript

    projDir <- "${workflow.projectDir}"
    source(paste(projDir, "subset_data.R", sep="/"))
    
    parent_dir <- "${inputDir}"
    input_dirs <- list.dirs(path = parent_dir, full.names = TRUE, recursive = FALSE)

    for (dir in input_dirs) {
        print(paste("Processing:", dir))

        outdir <- paste(getwd(), "subset_analysis_results", basename(dir), sep="/")

        parse_inputs_and_analyze(dir, "${data_db}", outdir, projDir_from_nextflow = projDir)
    }
    """
}