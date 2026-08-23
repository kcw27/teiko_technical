/*
 * For all part 3 inputs, run all functions mentioned in part 3 of the assignment.
 */
process runPart3 {
    conda "${workflow.projectDir}/envs/for_nextflow.yml"
    
    input:
    path inputDir
    path data_db
    val threshold
    val trust_CLT
    val adjust

    output:
    path "statistical_analysis_results/", emit: part3_out

    script:
    """
    #!/usr/bin/env Rscript

    projDir <- "${workflow.projectDir}"
    source(paste(projDir, "statistical_analysis.R", sep="/"))
    
    parent_dir <- "${inputDir}"
    input_dirs <- list.dirs(path = parent_dir, full.names = TRUE, recursive = FALSE)

    for (dir in input_dirs) {
        print(paste("Processing:", dir))

        outdir <- paste(getwd(), "statistical_analysis_results", basename(dir), sep="/")
        box_out <- paste(outdir, "boxplots", sep="/")

        df <- parse_inputs(dir, "${data_db}", projDir_from_nextflow = projDir)

        make_boxplots(df, box_out)

        trust <- "${trust_CLT}" == "TRUE"
        stat_out <- paste(outdir, "stats", sep="/")
        para <- parametric_ok(df, stat_out, as.integer("${threshold}"), trust_CLT = trust, adjust = "${adjust}")

        run_statistical_tests(df, stat_out, parametric = para, adjust = "${adjust}")

        get_group_avgs_by_population(df, stat_out)
    }
    """
}