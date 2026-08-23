# library(dplyr)
# library(dbplyr)
# library(DBI)
# library(RSQLite)
# library(rlang)

# Source - https://stackoverflow.com/a/55322344
# Posted by Juan Bernabe
# Retrieved 2026-08-23, License - CC BY-SA 4.0

library(tidyverse)
getCurrentFileLocation <-  function()
{
  this_file <- commandArgs() %>% 
    tibble::enframe(name = NULL) %>%
    tidyr::separate(col=value, into=c("key", "value"), sep="=", fill='right') %>%
    dplyr::filter(key == "--file") %>%
    dplyr::pull(value)
  if (length(this_file)==0)
  {
    this_file <- rstudioapi::getSourceEditorContext()$path
  }
  return(dirname(this_file))
}

parse_inputs_and_analyze <- function(inputdir, db_file, outfile) {
  # Use this wrapper if running in a Nextflow context; not necessary in the R Shiny context
  criteria_path <- paste(inputdir, "filtering_criteria.csv", sep="/")
  groupvar_path <- paste(inputdir, "grouping_variable.txt", sep="/")
  
  criteria_df <- read.csv(criteria_path, header = FALSE, sep = ",", col.names = c("name", "value"))
  groupvar <- readLines(groupvar_path, n=1)
  
  # filter the database
  scriptdir <- getCurrentFileLocation()
  source(paste(scriptdir, "filter_table.R", sep="/"))
  df <- filter_table(criteria_df, db_file)
  
  # finally pass information to analyze_subset
  analyze_subset(df, groupvar, outfile)
}

analyze_subset <- function(df, groupvar, outfile=NA) {
  summary_table <- df |>
    group_by(!!sym(groupvar)) |> 
    summarize(n=n())
  
  if (is.na(outfile)) {
    print(summary_table, n=Inf)
  } else {
    summary_table |>
      write.table(file = outfile,
                  sep = "\t", 
                  row.names = FALSE, 
                  quote = FALSE
                  )
  }
  
}