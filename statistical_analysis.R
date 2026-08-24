# library(dbplyr)
# library(DBI)
# library(RSQLite)

library(rstatix)
library(tidyverse)
theme_set(theme_classic())

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

parse_inputs <- function(inputdir, db_file, projDir_from_nextflow = NA) {
  # Use this wrapper if running in a Nextflow context; not necessary in the R Shiny context
  criteria_path <- paste(inputdir, "filtering_criteria.csv", sep="/")
  criteria_df <- read.csv(criteria_path, header = FALSE, sep = ",", col.names = c("name", "value"))
  
  # filter the database
  if (!is.na(projDir_from_nextflow)) {
    scriptdir <- projDir_from_nextflow
  } else {
    scriptdir <- get_script_dir()
  }
  source(paste(scriptdir, "filter_table.R", sep="/"))
  joined_df <- filter_table(criteria_df, db_file, join_with_summary=TRUE)
}

make_boxplots <- function(df, outdir) {
  df |> ggplot(aes(x=population, y=percentage, fill=response)) +
    geom_boxplot() +
    labs(x="Cell population", 
         y="Relative frequency (%)", 
         title="Cell population relative frequencies in responders vs non-responders")
  
  outfile <- paste(outdir, "boxplot.pdf", sep="/")
  
  if (!dir.exists(outdir)) {
    dir.create(outdir)
  }
  ggsave(outfile, width = 8, height = 4, create.dir = TRUE)
}

parametric_ok <- function(df, outdir, threshold=30, trust_CLT = TRUE, adjust = "bonferroni") {
  # for all groups, checks whether size is above threshold
  group_sizes_too_small <- df |> 
    group_by(population, response) |> 
    summarize(too_small = n() < threshold) |>
    pull(too_small)
  
  if (TRUE %in% group_sizes_too_small) {
    print("At least one group is too small for t-tests")
    return(FALSE)
  }
  
  # if passed, makes QQ plots and checks normality
  qqdir <- paste(outdir, "qqplots", sep="/")
  
  if (!dir.exists(outdir)) {
    dir.create(outdir)
  }
  if (!dir.exists(qqdir)) {
    dir.create(qqdir)
  }
  
  summary_df <- df |> 
    group_by(population, response) |> 
    group_map(function(group_data, group_keys) {
      curr_pop <- group_keys$population
      curr_resp <- group_keys$response
      
      group_id <- paste(curr_pop, curr_resp)
      
      # make QQ plot
      outfile <- paste(qqdir, "/", curr_pop, "_", curr_resp, ".png", sep="") 
      png(outfile, width = 800, height = 600, units = "px")
      qqnorm(group_data$percentage, main = paste("QQ Plot of relative frequency for population", curr_pop, "and response status of", curr_resp))
      qqline(group_data$percentage)
      dev.off()
      print(paste("QQ plot saved to", outfile))
      
      # test for normality
      if (length(unique(group_data$percentage)) == 1) { # shapiro.test doesn't work if all x values are identical
        print(paste("Cannot test for normality, as all percentage values are equal"))
        p_val <- 0 # dummy value meant to make it fail later on
      }
      
      set.seed(42)
      if (length(group_data$percentage) > 5000) { # shapiro.test() doesn't work on datasets larger than 5000 values
        subset <- sample(group_data$percentage, size = 5000)
        normality_test <- shapiro.test(subset)
      } else {
        normality_test <- shapiro.test(group_data$percentage)
      }
      
      # print(normality_test)
      p_val <- normality_test$p.val
      
      # if (normality_test$p.val < 0.05) {
      #   print(paste("percentage is probably not normal; non-adjusted p=", signif(normality_test$p.val, 3)))
      # } else {
      #   print(paste("percentage is probably normal; non-adjusted p=", signif(normality_test$p.val, 3)))
      # }
      
      tibble(
        group = group_id,
        p_value = p_val,
        n = nrow(group_data)
      )
    }) |>
    bind_rows()
  
  summary_df <- summary_df |>
    mutate(p_adj = p.adjust(p_value, method = adjust))
  print(summary_df$p_adj)
  
  p_threshold = 0.05
  summary_df <- summary_df |>
    mutate(normality_ok = p_adj >= p_threshold) |>
    mutate(n_above_threshold = n >= threshold)
  
  out_table <- paste(outdir, "normality_summary.tsv", sep="/") 
  summary_df |> 
    write.table(file = out_table,
                sep = "\t", 
                row.names = FALSE, 
                quote = FALSE
  )

  if (trust_CLT) {
    print("Even if data is non-normal, trust that the Central Limit Theorem will allow for valid parametric test results.")
    print("Please check QQ plots to confirm that the data is not extremely non-normal")
    if (any(!summary_df$n_above_threshold)) {
      print("At least one group is not large enough to overlook normality constraints")
      return(FALSE)
    } else {
      return(TRUE)
    }
  } else {
    if (any(!summary_df$normality_ok)) {
      print("At least one group is not normal for t-tests")
      return(FALSE)
    } else {
      return(TRUE)
    }
  }
}

run_statistical_tests <- function(df, outdir, parametric, adjust = "bonferroni") {
  # parametric <- parametric_ok(df, outdir)
  
  if (!dir.exists(outdir)) {
    dir.create(outdir)
  }
  
  summary_df <- df |> 
    group_by(population) |> 
    group_map(function(group_data, group_keys) {
      curr_pop <- group_keys$population
      # test for differences in "percentage" between groups
      if (parametric) { # if parametric tests are okay, run t-tests
        test_result <- group_data |>
          t_test(percentage ~ response) # implicit: alternative = "two.sided", mu = 0
        p_val <- test_result$p
      } else { # else use Mann-Whitney U tests (less powerful but doesn't assume the data is normal)
        test_result <- group_data |>
          wilcox_test(percentage ~ response) # implicit: alternative = "two.sided", mu = 0
        p_val <- test_result$p
      }
      
      tibble(
        group = curr_pop,
        p_value = p_val,
        n = nrow(group_data)
      )
    }) |>
    bind_rows()

  # remember to adjust the p-values
  # and add a boolean column for whether they're different
  # and save the table
  p_threshold = 0.05
  summary_df <- summary_df |>
    mutate(p_adj = p.adjust(p_value, method = adjust)) |>
    mutate(are_groups_different = p_adj < p_threshold)
  
  out_table <- paste(outdir, "stat_test_summary.tsv", sep="/") 
  summary_df |> 
    write.table(file = out_table,
                sep = "\t", 
                row.names = FALSE, 
                quote = FALSE
    )
  
}

get_group_avgs_by_population <- function(df, outdir) {
  if (!dir.exists(outdir)) {
    dir.create(outdir)
  }
  
  out_table <- paste(outdir, "pop_average_summary.tsv", sep="/") 
  
  summary_df <- df |> 
    group_by(population, response) |>
    summarize(n=n(), average_count = mean(count)) |>
    write.table(file = out_table,
                sep = "\t", 
                row.names = FALSE, 
                quote = FALSE
    )
}