# library(dplyr)
# library(dbplyr)
# library(DBI)
# library(RSQLite)
# library(rlang)

library(tidyverse)

# Get the directory of the currently executing script
get_script_dir <- function() {
  # When sourced, this gets the directory of the source file
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- "--file="
  match_idx <- grep(file_arg, cmd_args)
  if (length(match_idx) > 0) {
    # Running as script
    return(dirname(normalizePath(sub(file_arg, "", cmd_args[match_idx]))))
  } else {
    # Interactive or sourced
    if (interactive()) {
      return(getwd())
    } else {
      # Try to get from sys.frames
      frame <- sys.frames()[[1]]
      if (!is.null(frame$ofile)) {
        return(dirname(normalizePath(frame$ofile)))
      } else {
        return(getwd())
      }
    }
  }
}

parse_inputs_and_analyze <- function(inputdir, db_file, outdir, projDir_from_nextflow = NA) {
  # Use this wrapper if running in a Nextflow context; not necessary in the R Shiny context
  criteria_path <- paste(inputdir, "filtering_criteria.csv", sep="/")
  groupvar_path <- paste(inputdir, "grouping_variable.txt", sep="/")
  
  criteria_df <- read.csv(criteria_path, header = FALSE, sep = ",", col.names = c("name", "value"))
  groupvar <- readLines(groupvar_path, n=1)
  
  # filter the database
  if (!is.na(projDir_from_nextflow)) {
    scriptdir <- projDir_from_nextflow
  } else {
    scriptdir <- get_script_dir()
  }
  source(paste(scriptdir, "filter_table.R", sep="/"))
  df <- filter_table(criteria_df, db_file)
  
  # finally pass information to analyze_subset
  analyze_subset(df, groupvar, outdir)
}

analyze_subset <- function(df, groupvar, outdir=NA) {
  summary_table <- df |>
    group_by(!!sym(groupvar)) |> 
    summarize(n=n())
  
  if (is.na(outdir)) {
    print(summary_table, n=Inf)
  } else {
    dir.create(outdir, recursive = TRUE)
    outfile <- paste(outdir, "subset_analysis.tsv", sep="/")
    
    summary_table |>
      write.table(file = outfile,
                  sep = "\t", 
                  row.names = FALSE, 
                  quote = FALSE
                  )
  }
  
}