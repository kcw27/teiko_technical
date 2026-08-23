#!/usr/bin/env nextflow
include { loadDB } from './modules/part1and2.nf'
include { runPart3 } from './modules/part3.nf'
include { subset_analysis } from './modules/part4.nf'

params {
    // Assume that the user always wants to do parts 3 and 4... It's too much of a hassle to deal with empty channels
    // or paths that lead to empty dirs.

    // Part 3
    part3_inputdir: Path
    threshold: String
    trust_CLT: String
    adjust: String

    // Part 4
    part4_inputdir: Path
}

workflow {
    main:
    // Parts 1 and 2 are done together; I thought it'd make sense to put them in the same process
    loadDB()
    def data_db = loadDB.out.data_db

    // Part 3
    runPart3(params.part3_inputdir, data_db, params.threshold, params.trust_CLT, params.adjust)
    
    // Part 4
    subset_analysis(params.part4_inputdir, data_db)

    publish:
    data_db_file = data_db
    data_db_file_link = data_db
    part3_dir = runPart3.out.part3_out
    part4_dir = subset_analysis.out.part4_out
}

// I was planning to soft-link the db because generally it would be a large file,
// but I wasn't sure if that would meet the assignment's requirements,
// so I copied it instead
output {
    data_db_file {
        path { "${workflow.projectDir}" }
        mode 'copy'
    }

    data_db_file_link {
        path { "db_file_link" }
    }

    part3_dir {
        path { "./" }
        mode 'copy'
    }

    part4_dir {
        path { "./" }
        mode 'copy'
    }
}