library(dplyr)
library(dbplyr)
library(DBI)
library(RSQLite)
library(rlang)

filter_table <- function(criteria_df, db_file, join_with_summary = FALSE) {
  connection <- dbConnect(RSQLite::SQLite(), dbname = db_file)
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
  
  # filter by the criteria
  filter_string <- criteria_df |> 
    summarise(collapsed = paste(filter_command, collapse = "; ")) |> 
    pull(collapsed)
  
  metadata_ref_filtered <- metadata_ref |> 
    filter(!!!parse_exprs(filter_string))
  
  if (join_with_summary) {
    print("Performing an inner join.")
    summary_ref <- tbl(connection, "summary")
    
    join_key = "sample"
    joined_df <- inner_join(summary_ref, metadata_ref_filtered, by = join_key) |>
      collect()
    
    dbDisconnect(connection)
    return(joined_df)
  }
  # otherwise:
  df <- metadata_ref_filtered |> 
    collect()
  
  dbDisconnect(connection)
  
  return(df)
}