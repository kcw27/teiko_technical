library(shiny)
library(shinydashboard)
library(DBI)
library(RSQLite)
library(pool)
library(DT)
library(base64enc)

# Written with assistance from Claude

### Global

get_script_dir <- function() {
    args <- commandArgs(trailingOnly = FALSE)
    file_arg <- "--file="
    script_path <- sub(file_arg, "", args[grep(file_arg, args)])
    if (length(script_path) == 0) {
        stop("Cannot determine script path. Are you running via Rscript?")
    }
    normalizePath(dirname(script_path))
}

script_dir <- get_script_dir()

db_file <- file.path(script_dir, "patient_data.db")

pool <- dbPool(
    drv = RSQLite::SQLite(),
    dbname = db_file
)

onStop(function() {
    poolClose(pool)
})

# source scripts that will be used later
source(file.path(script_dir, "statistical_analysis.R"))
source(file.path(script_dir, "subset_data.R"))


categorical_vars <- c("project", "condition", "sex", "treatment",
                       "response", "sample_type", "time_from_treatment_start")

get_table_for_column <- function(pool, colname) {
  for (tbl in c("metadata", "summary")) {
    if (colname %in% dbListFields(pool, tbl)) return(tbl)
  }
  stop(paste("Column", colname, "not found in metadata or summary tables"))
}

var_table_map <- setNames(
  sapply(categorical_vars, function(v) get_table_for_column(pool, v)),
  categorical_vars
)

### UI
ui <- navbarPage("Project GUI",
    tabPanel("Data overview",
        fluidRow(
            column(12,
            DTOutput("overview_table"),
            br(),
            div(style = "display:flex; align-items:center; gap:10px;",
                actionButton("prev_page", "Previous", icon = icon("arrow-left")),
                actionButton("next_page", "Next", icon = icon("arrow-right")),
                span("Page:"),
                numericInput("page_number", NULL, value = 1, min = 1, step = 1, width = "80px"),
                actionButton("go_to_page", "Go"),
                span(style = "margin-left:15px; font-weight:bold;",
                    textOutput("page_info", inline = TRUE)),
                actionButton("open_filter_menu", "Open filtering menu", icon = icon("filter")),
            ),
            br(),
            fluidRow(
                column(6, textInput("outdir", "Output directory for saved files", value = ".")),
                column(3, actionButton("save_outdir", "Update output directory", style = "margin-top:25px;"))
            ),
            textOutput("outdir_display")
            )
        )
    ),
    tabPanel("Statistical analysis",
        fluidRow(
            column(12,
                uiOutput("stat_analysis_description"),
                br(),
                tabsetPanel(
                    tabPanel("View boxplots",
                        br(),
                        actionButton("create_boxplots", "Create boxplots", class = "btn-primary"),
                        br(), br(),
                        uiOutput("boxplot_display")
                    ),
                    tabPanel("Run statistical analysis",
                        br(),
                        selectInput("adjust_method", "Multiple hypothesis testing adjustment method:",
                                    choices = c("", "holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"),
                                    selected = "bonferroni"),
                        hr(),
                        h4("Step 1: decide between the parametric test (t-test) and the non-parametric test (Mann-Whitney U test). Please review Q-Q plots before proceeding."),
                        numericInput("para_threshold", "Minimum group size", value = 30, min = 1, step = 1),
                        radioButtons("trust_CLT",
                                    "Invoke the Central Limit Theorem to ignore non-normal distributions as long as all groups are above the minimum group size",
                                    choices = c("TRUE" = "TRUE", "FALSE" = "FALSE"), selected = "TRUE"),
                        actionButton("submit_parametric_ok", "Submit", class = "btn-primary"),
                        br(), br(),
                        uiOutput("para_result_display"),
                        hr(),
                        h4("Step 2: run statistical tests."),
                        radioButtons("test_type", "Choose test type",
                                    choices = c("parametric" = "parametric", "non-parametric" = "non-parametric")),
                        actionButton("submit_stat_tests", "Submit", class = "btn-primary"),
                        br(), br(),
                        DTOutput("stat_test_summary_table"),
                        hr(),
                        selectInput("stats_file_preview", "Preview a file from outdir/stats:", choices = NULL),
                        uiOutput("stats_file_content")
                    ),
                    tabPanel("Get average cell count by population",
                        br(),
                        actionButton("get_pop_avgs", "Get population averages", class = "btn-primary"),
                        br(), br(),
                        DTOutput("pop_avg_table")
                    )
                )
            )
        )
    ),
    tabPanel("Subset analysis",
        fluidRow(
            column(12,
                uiOutput("subset_description"),
                br(),
                selectInput("groupvar", "Grouping variable", choices = categorical_vars),
                actionButton("run_subset_analysis", "Submit", class = "btn-primary"),
                br(), br(),
                DTOutput("subset_analysis_table")
            )
        )
    )
)

### Server
server <- function(input, output, session) {
    page_size <- 20
    current_offset <- reactiveVal(0)
    rv <- reactiveValues(filters = list(), next_id = 1)
    app_data <- reactiveValues(filtered_df = NULL)  # downstream tabs read app_data$filtered_df
    outdir_confirmed <- reactiveVal(".")            # confirmed via "Save output directory" button
    
    # for she statistical test tab
    para_result <- reactiveVal(NULL)
    stat_test_result <- reactiveVal(NULL)
    pop_avg_result <- reactiveVal(NULL)
    boxplot_trigger <- reactiveVal(0)
    stats_files_trigger <- reactiveVal(0)

    build_where_clause <- function(filters) {
        if (length(filters) == 0) return("")
        clauses <- sapply(filters, function(f) {
            alias <- if (f$table == "summary") "s" else "m"
            col <- DBI::dbQuoteIdentifier(pool, f$variable)
            if (identical(f$level, "__NA__")) {
                sprintf("%s.%s IS NULL", alias, col)
            } else {
                sprintf("%s.%s = %s", alias, col, DBI::dbQuoteLiteral(pool, f$level))
            }
        })
        paste(" WHERE", paste(clauses, collapse = " AND "))
    }

    filters_to_text <- function(filters) {
        if (length(filters) == 0) {
            return("No filtering criteria applied.\n")
        }
        lines <- sapply(filters, function(f) {
            level_label <- if (identical(f$level, "__NA__")) "NA (missing)" else f$level
            sprintf("%s == %s", f$variable, level_label)
        })
        paste0("Filtering criteria:\n", paste(lines, collapse = "\n"), "\n")
    }

    pdf_to_iframe <- function(path, height = "800px") {
        b64 <- base64enc::base64encode(path)
        tags$iframe(style = sprintf("width:100%%; height:%s; border:none;", height),
                    src = sprintf("data:application/pdf;base64,%s", b64))
    }

    total_rows_filtered <- reactive({
        where_clause <- build_where_clause(rv$filters)
        dbGetQuery(pool, sprintf("
            SELECT COUNT(*) AS n FROM summary s
            INNER JOIN metadata m ON s.sample = m.sample%s
        ", where_clause))$n
    })

    page_data <- reactive({
        where_clause <- build_where_clause(rv$filters)
        query <- sprintf("
            SELECT s.*, m.* FROM summary s
            INNER JOIN metadata m ON s.sample = m.sample%s
            LIMIT %d OFFSET %d
        ", where_clause, page_size, current_offset())
        df <- dbGetQuery(pool, query)
        df[, !duplicated(names(df))]
    })

    # The df downstream tabs should operate on: the submitted filtered_df if it
    # exists, otherwise the full unfiltered join (loaded fully into memory here,
    # since this is an explicit, one-time user action rather than the paged preview)
    current_df_for_analysis <- reactive({
        if (!is.null(app_data$filtered_df)) {
            app_data$filtered_df
        } else {
            df <- dbGetQuery(pool, "
                SELECT s.*, m.* FROM summary s
                INNER JOIN metadata m ON s.sample = m.sample
            ")
            df[, !duplicated(names(df))]
        }
    })

    current_nrows <- reactive({
        if (!is.null(app_data$filtered_df)) {
            nrow(app_data$filtered_df)
        } else {
            dbGetQuery(pool, "
                SELECT COUNT(*) AS n FROM summary s
                INNER JOIN metadata m ON s.sample = m.sample
            ")$n
        }
    })

    # Metadata table filtered by whatever filtering criteria are currently
    # active, joined only to evaluate filters that live on summary columns.
    # DISTINCT guards against duplicate metadata rows if summary ever has
    # more than one row per sample.
    current_metadata_df <- reactive({
        where_clause <- build_where_clause(rv$filters)
        query <- sprintf("
            SELECT DISTINCT m.* FROM metadata m
            INNER JOIN summary s ON s.sample = m.sample%s
        ", where_clause)
        dbGetQuery(pool, query)
    })

    current_nrows_metadata <- reactive({
        nrow(current_metadata_df())
    })

    output$overview_table <- renderDT({
        datatable(page_data(),
                  options = list(paging = FALSE, searching = FALSE, info = FALSE, ordering = FALSE),
                  rownames = FALSE)
    })

    output$page_info <- renderText({
        total <- total_rows_filtered()
        total_pages <- max(1, ceiling(total / page_size))
        sprintf("Page %d of %d  (%d rows)", (current_offset() %/% page_size) + 1, total_pages, total)
    })

    observeEvent(input$next_page, {
        if (current_offset() + page_size < total_rows_filtered()) current_offset(current_offset() + page_size)
    })
    observeEvent(input$prev_page, {
        current_offset(max(0, current_offset() - page_size))
    })

    observe({
        updateNumericInput(session, "page_number", value = (current_offset() %/% page_size) + 1)
    })
    observeEvent(input$go_to_page, {
        req(input$page_number)
        total_pages <- max(1, ceiling(total_rows_filtered() / page_size))
        page <- min(max(1, input$page_number), total_pages)
        current_offset((page - 1) * page_size)
    })

    ## ---- Filter menu ----
    available_vars <- reactive({
        used <- sapply(rv$filters, function(f) f$variable)
        setdiff(categorical_vars, used)
    })

    observeEvent(input$open_filter_menu, {
        showModal(modalDialog(
            title = "Filter data",
            fluidRow(
                column(5, selectInput("filter_var", "Variable", choices = available_vars())),
                column(5, selectInput("filter_level", "Level", choices = NULL)),
                column(2, actionButton("add_filter", "Add filter", style = "margin-top:25px;"))
            ),
            hr(), h5("Active filters:"), uiOutput("filter_list_ui"),
            hr(), textOutput("filtered_row_count"),
            hr(),
            fluidRow(
                column(4, actionButton("submit_filters", "Submit filters and close", class = "btn-primary")),
                column(4, actionButton("save_filtered_df", "Save filtered df to file", class = "btn-success")),
                column(4, actionButton("clear_filters", "Clear selection", class = "btn-warning"))
            ),
            footer = modalButton("Close"), size = "l", easyClose = TRUE
        ))
    })

    # Keep the variable dropdown in sync as filters are added/removed
    observeEvent(available_vars(), {
        if (!is.null(input$filter_var)) {
            current <- input$filter_var
            choices <- available_vars()
            # preserve current selection if it's still valid, else pick the first remaining option
            selected <- if (current %in% choices) current else if (length(choices) > 0) choices[1] else character(0)
            updateSelectInput(session, "filter_var", choices = choices, selected = selected)
        }
    }, ignoreNULL = FALSE)

    # Repopulate level choices whenever the variable dropdown changes
    observeEvent(input$filter_var, {
        req(input$filter_var)
        tbl <- var_table_map[[input$filter_var]]
        levels <- dbGetQuery(pool, sprintf(
            "SELECT DISTINCT %s AS lvl FROM %s ORDER BY %s",
            DBI::dbQuoteIdentifier(pool, input$filter_var),
            DBI::dbQuoteIdentifier(pool, tbl),
            DBI::dbQuoteIdentifier(pool, input$filter_var)
        ))$lvl

        # Represent SQL NULL as a sentinel string so it can be a valid dropdown choice
        has_na <- any(is.na(levels))
        levels <- levels[!is.na(levels)]
        choices <- if (has_na) c(levels, "NA (missing)" = "__NA__") else levels

        updateSelectInput(session, "filter_level", choices = choices)
    })

    observeEvent(input$add_filter, {
        req(input$filter_var, input$filter_level)
        rv$filters[[length(rv$filters) + 1]] <- list(
            id = rv$next_id, variable = input$filter_var,
            level = input$filter_level, table = var_table_map[[input$filter_var]]
        )
        rv$next_id <- rv$next_id + 1
        current_offset(0)
    })

    observeEvent(input$remove_filter, {
        rv$filters <- Filter(function(f) f$id != input$remove_filter, rv$filters)
        current_offset(0)
    })

    observeEvent(input$clear_filters, {
        rv$filters <- list()
        current_offset(0)
    })

    output$filter_list_ui <- renderUI({
        if (length(rv$filters) == 0) return(tags$p("No filters added yet."))
        tagList(lapply(rv$filters, function(f) {
            div(style = "margin-bottom:5px;",
                span(sprintf("%s == %s", f$variable, f$level)),
                tags$a(href = "#", style = "margin-left:10px; color:red; font-weight:bold;",
                       onclick = sprintf("Shiny.setInputValue('remove_filter', %d, {priority: 'event'}); return false;", f$id),
                       "X")
            )
        }))
    })

    output$filtered_row_count <- renderText({
        sprintf("Number of rows currently selected: %d", total_rows_filtered())
    })

    output$subset_description <- renderUI({
        tags$p(sprintf(
            "Perform subset analysis on filtered metadata table (currently %d rows), counting the number of observations in each level of the selected grouping variable. Output is saved to %s/subset_analysis.tsv.",
            current_nrows_metadata(), outdir_confirmed()
        ))
    })

    # Keep groupvar choices in sync with available_vars() (defined earlier, alongside
    # the filter_var dropdown logic) so a variable already used as a filter disappears
    observeEvent(available_vars(), {
        if (!is.null(input$groupvar)) {
            choices <- available_vars()
            selected <- if (input$groupvar %in% choices) input$groupvar else if (length(choices) > 0) choices[1] else character(0)
            updateSelectInput(session, "groupvar", choices = choices, selected = selected)
        }
    }, ignoreNULL = FALSE)

    subset_result <- reactiveVal(NULL)

    observeEvent(input$run_subset_analysis, {
        req(input$groupvar)
        outdir <- outdir_confirmed()
        if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)

        df <- current_metadata_df()
        result <- analyze_subset(df, input$groupvar, outdir = outdir)

        # Fall back to reading the saved TSV if analyze_subset doesn't return a data frame
        if (!is.data.frame(result)) {
            result <- tryCatch(
                read.delim(file.path(outdir, "subset_analysis.tsv")),
                error = function(e) NULL
            )
        }
        subset_result(result)

        log_file <- file.path(outdir, "subset_analysis_filtering.log")
        writeLines(filters_to_text(rv$filters), log_file)
        write("Grouping variable:", log_file, append=TRUE)
        write(input$groupvar, log_file, append=TRUE)

        showNotification(sprintf("Subset analysis complete. Output saved to %s/subset_analysis.tsv", outdir), type = "message")
    })

    output$subset_analysis_table <- renderDT({
        req(subset_result())
        datatable(subset_result(), rownames = FALSE)
    })

    output$stat_analysis_description <- renderUI({
        tags$p(sprintf(
            "Produce boxplots from, statistically compare between responders and non-responders within, and get average cell counts from filtered table (currently %d rows). Please do not filter on the 'response' column if you intend to run this analysis. Boxplot is saved to %s/boxplot.pdf. Statistical analyses are saved to %s/stats/.",
            current_nrows(), outdir_confirmed(), outdir_confirmed()
        ))
    })

    ## ---- View boxplots ----

    observeEvent(input$create_boxplots, {
        outdir <- outdir_confirmed()
        if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)

        df <- current_df_for_analysis()
        make_boxplots(df, outdir)

        log_file <- file.path(outdir, "boxplot_filtering.log")
        writeLines(filters_to_text(rv$filters), log_file)

        boxplot_trigger(boxplot_trigger() + 1)
        showNotification("Boxplots created.", type = "message")
    })

    output$boxplot_display <- renderUI({
        boxplot_trigger()
        pdf_path <- file.path(outdir_confirmed(), "boxplot.pdf")
        req(file.exists(pdf_path))
        pdf_to_iframe(pdf_path)
    })

    ## ---- Run statistical analysis: Step 1 (parametric_ok) ----

    observeEvent(input$submit_parametric_ok, {
        req(input$para_threshold)
        outdir <- outdir_confirmed()
        stats_outdir <- file.path(outdir, "stats")
        if (!dir.exists(stats_outdir)) dir.create(stats_outdir, recursive = TRUE)

        df <- current_df_for_analysis()
        threshold <- input$para_threshold
        trust_CLT <- as.logical(input$trust_CLT)
        adjust_method <- input$adjust_method

        para_output <- capture.output(
            para <- parametric_ok(df, outdir = stats_outdir, threshold = threshold,
                                   trust_CLT = trust_CLT, adjust = adjust_method)
        )
        para_result(para)

        log_file <- file.path(stats_outdir, "parametricOK_filtering.log")
        log_lines <- c(
            filters_to_text(rv$filters),
            "--- parametric_ok() console output ---",
            para_output,
            "",
            sprintf("adjust_method: %s", adjust_method),
            sprintf("threshold: %s", threshold),
            sprintf("trust_CLT: %s", trust_CLT)
        )
        writeLines(log_lines, log_file)

        stats_files_trigger(stats_files_trigger() + 1)
    })

    output$para_result_display <- renderUI({
        req(!is.null(para_result()))
        tags$p(strong("Recommended test type: "), if (isTRUE(para_result())) "parametric" else "non-parametric")
    })

    ## ---- Run statistical analysis: Step 2 (run_statistical_tests) ----

    observeEvent(input$submit_stat_tests, {
        req(input$test_type)
        outdir <- outdir_confirmed()
        stats_outdir <- file.path(outdir, "stats")
        if (!dir.exists(stats_outdir)) dir.create(stats_outdir, recursive = TRUE)

        df <- current_df_for_analysis()
        parametric <- (input$test_type == "parametric")
        adjust_method <- input$adjust_method

        run_statistical_tests(df, outdir = stats_outdir, parametric = parametric, adjust = adjust_method)

        log_file <- file.path(stats_outdir, "stat_test_filtering.log")
        log_lines <- c(
            filters_to_text(rv$filters),
            "",
            sprintf("adjust_method: %s", adjust_method),
            sprintf("parametric: %s", parametric)
        )
        writeLines(log_lines, log_file)

        result <- tryCatch(read.delim(file.path(stats_outdir, "stat_test_summary.tsv")), error = function(e) NULL)
        stat_test_result(result)
        stats_files_trigger(stats_files_trigger() + 1)
        showNotification("Statistical tests complete.", type = "message")
    })

    output$stat_test_summary_table <- renderDT({
        req(stat_test_result())
        datatable(stat_test_result(), rownames = FALSE)
    })

    ## ---- File preview browser for outdir/stats ----

    observe({
        stats_files_trigger()
        stats_dir <- file.path(outdir_confirmed(), "stats")
        
        # Recursively list all files
        files <- if (dir.exists(stats_dir)) {
            # Get all files recursively
            all_files <- list.files(stats_dir, recursive = TRUE, full.names = FALSE)
            # Filter out directories (list.files with recursive doesn't return directories)
            all_files
        } else {
            character(0)
        }
        updateSelectInput(session, "stats_file_preview", choices = files)
    })

    output$stats_file_content <- renderUI({
        req(input$stats_file_preview)
        fpath <- file.path(outdir_confirmed(), "stats", input$stats_file_preview)
        req(file.exists(fpath))
        ext <- tolower(tools::file_ext(fpath))

        if (ext %in% c("tsv", "csv")) {
            sep <- if (ext == "tsv") "\t" else ","
            df <- tryCatch(read.delim(fpath, sep = sep), error = function(e) NULL)
            if (!is.null(df)) DT::datatable(df, rownames = FALSE)
            else tags$pre(paste(readLines(fpath, warn = FALSE), collapse = "\n"))
        } else if (ext == "pdf") {
            pdf_to_iframe(fpath)
        } else if (ext %in% c("png", "jpg", "jpeg", "gif", "svg")) {
            # Display image files
            if (ext %in% c("png", "jpg", "jpeg", "gif")) {
                # For raster images, use img tag with base64 encoding
                b64 <- base64enc::base64encode(fpath)
                tags$img(src = sprintf("data:image/%s;base64,%s", 
                                    ifelse(ext == "jpg", "jpeg", ext), 
                                    b64),
                        style = "max-width: 100%; height: auto;")
            } else if (ext == "svg") {
                # For SVG, read as text and embed directly
                svg_content <- paste(readLines(fpath, warn = FALSE), collapse = "\n")
                HTML(svg_content)
            }
        } else {
            # For other text files, read as text
            tags$pre(paste(readLines(fpath, warn = FALSE), collapse = "\n"))
        }
    })

    ## ---- Get average cell count by population ----

    observeEvent(input$get_pop_avgs, {
        outdir <- outdir_confirmed()
        stats_outdir <- file.path(outdir, "stats")
        if (!dir.exists(stats_outdir)) dir.create(stats_outdir, recursive = TRUE)

        df <- current_df_for_analysis()
        get_group_avgs_by_population(df, outdir = stats_outdir)

        log_file <- file.path(stats_outdir, "pop_average_filtering.log")
        writeLines(filters_to_text(rv$filters), log_file)

        result <- tryCatch(read.delim(file.path(stats_outdir, "pop_average_summary.tsv")), error = function(e) NULL)
        pop_avg_result(result)
        stats_files_trigger(stats_files_trigger() + 1)
        showNotification("Population averages computed.", type = "message")
    })

    output$pop_avg_table <- renderDT({
        req(pop_avg_result())
        datatable(pop_avg_result(), rownames = FALSE)
    })

    observeEvent(input$submit_filters, {
        where_clause <- build_where_clause(rv$filters)
        df <- dbGetQuery(pool, sprintf(
            "SELECT s.*, m.* FROM summary s INNER JOIN metadata m ON s.sample = m.sample%s", where_clause))
        app_data$filtered_df <- df[, !duplicated(names(df))]
        showNotification(sprintf("filtered_df saved in memory (%d rows).", nrow(app_data$filtered_df)), type = "message")
        removeModal()
    })

    observeEvent(input$save_filtered_df, {
        outdir <- outdir_confirmed()
        if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
        outfile <- file.path(outdir, sprintf("filtered_df_%s.csv", format(Sys.time(), "%Y%m%d_%H%M%S")))

        where_clause <- build_where_clause(rv$filters)
        query <- sprintf("SELECT s.*, m.* FROM summary s INNER JOIN metadata m ON s.sample = m.sample%s", where_clause)

        con <- poolCheckout(pool)
        on.exit(poolReturn(con), add = TRUE)

        res <- dbSendQuery(con, query)
        first_chunk <- TRUE
        repeat {
            chunk <- dbFetch(res, n = 5000)
            if (nrow(chunk) == 0) break
            chunk <- chunk[, !duplicated(names(chunk))]
            write.table(chunk, outfile, sep = ",", row.names = FALSE,
                        col.names = first_chunk, append = !first_chunk, quote = TRUE)
            first_chunk <- FALSE
        }
        dbClearResult(res)

        log_file <- file.path(outdir, paste0(tools::file_path_sans_ext(basename(outfile)), "_filtering.log"))
        writeLines(filters_to_text(rv$filters), log_file)

        showNotification(sprintf("Saved to %s", outfile), type = "message")
    })

    ## ---- Output directory ----

    observeEvent(input$save_outdir, {
        req(input$outdir)
        outdir_confirmed(input$outdir)
        showNotification(sprintf("Output directory set to: %s", input$outdir), type = "message")
        if (!dir.exists(input$outdir)) {
            dir.create(input$outdir)
        }
    })

    output$outdir_display <- renderText({
        sprintf("Current output directory: %s", outdir_confirmed())
    })
}

### Run the application
ip <- system("hostname -I", intern = TRUE)
message(paste("Shiny app running at: http://", trimws(ip), ":3838", sep=""))
shinyApp(ui = ui, server = server, options = list(host = "0.0.0.0", port = 3838))