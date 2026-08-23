library(dplyr)
library(dbplyr)
library(DBI)
library(RSQLite)
library(rlang)

parse_inputs_and_analyze <- function(inputdir, metadata_db, outfile) {
  # Use this wrapper if running in a Nextflow context; not necessary in the R Shiny context
  criteria_path <- paste(inputdir, "filtering_criteria.csv", sep="/")
  groupvar_path <- paste(inputdir, "grouping_variable.txt", sep="/")
  
  criteria_df <- read.csv(criteria_path, header = FALSE, sep = ",", col.names = c("name", "value"))
  groupvar <- readLines(groupvar_path, n=1)
  
  # finally pass information to analyze_subset
  analyze_subset(criteria_df, groupvar, df, outfile)
}

analyze_subset <- function(criteria_df, groupvar, metadata_db, outfile=NA) {
  connection <- dbConnect(RSQLite::SQLite(), dbname = "C:/Users/achro/Documents/GitHub/teiko_technical/data/patient_data.db")
  
  metadata_ref <- tbl(connection, "metadata")
  
  # get the type of each variable
  col_info <- dbGetQuery(connection, "PRAGMA table_info(metadata)") |>
    data.frame() |>
    select(name, type)
  
  criteria_df <- left_join(criteria_df, col_info, by="name")
  
  # if the variable is numeric in the db, don't wrap it in single quotes
  criteria_df <- criteria_df |>
    mutate(filter_command = paste(name, 
                                  ifelse(type=="INTEGER", 
                                         value, 
                                         paste0("'", value, "'")
                                         ),
                                  sep=" == "
                                  )
           )
  
  # filter by the criteria and get a summary table
  filter_string <- criteria_df |> 
    summarise(collapsed = paste(filter_command, collapse = "; ")) |> 
    pull(collapsed)
  
  summary_table <- metadata_ref |> 
    filter(!!!parse_exprs(filter_string)) |> 
    group_by(!!sym(groupvar)) |> 
    summarize(n=n()) |> 
    collect()
  
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
  
  dbDisconnect(connection)
}