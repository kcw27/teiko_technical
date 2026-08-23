/*
 * Load the data as a SQLite db, and add a summary 
 */
process loadDB {
    conda "${workflow.projectDir}/envs/for_nextflow.yml"

    // no inputs required because the input data and db path are hard-coded as required by this assignment

    output:
    path "patient_data.db", emit: data_db

    script:
    """
    projDir="${workflow.projectDir}"
    python "\$projDir/load_data.py"
    python "\$projDir/summarize_data.py"
    """
}