library(shiny)
library(shinydashboard)
library(DBI)
library(RSQLite)
library(pool)
library(DT)

### Global
db_file <- "patient_data.db"

pool <- dbPool(
    drv = RSQLite::SQLite(),
    dbname = db_file
)

onStop(function() {
    poolClose(pool)
})

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
                    textOutput("page_info", inline = TRUE))
            ),
            br(),
            actionButton("open_filter_menu", "Open filtering menu", icon = icon("filter")),
            br(), br(),
            fluidRow(
                column(6, textInput("outdir", "Output directory (for saved files)", value = ".")),
                column(3, actionButton("save_outdir", "Save output directory", style = "margin-top:25px;"))
            ),
            textOutput("outdir_display")
            )
        )
    ),
    tabPanel("Statistical analysis"
    ),
    tabPanel("Subset analysis"
    )
)

### Server
server <- function(input, output, session) {
    page_size <- 20
    current_offset <- reactiveVal(0)
    rv <- reactiveValues(filters = list(), next_id = 1)
    app_data <- reactiveValues(filtered_df = NULL)  # downstream tabs read app_data$filtered_df
    outdir_confirmed <- reactiveVal(".")            # confirmed via "Save output directory" button

    build_where_clause <- function(filters) {
        if (length(filters) == 0) return("")
        clauses <- sapply(filters, function(f) {
            alias <- if (f$table == "summary") "s" else "m"
            sprintf("%s.%s = %s", alias,
                    DBI::dbQuoteIdentifier(pool, f$variable),
                    DBI::dbQuoteLiteral(pool, f$level))
        })
        paste(" WHERE", paste(clauses, collapse = " AND "))
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
                column(4, actionButton("submit_filters", "Submit filters", class = "btn-primary")),
                column(4, actionButton("save_filtered_df", "Save filtered df", class = "btn-success")),
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
        updateSelectInput(session, "filter_level", choices = levels)
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

    observeEvent(input$submit_filters, {
        where_clause <- build_where_clause(rv$filters)
        df <- dbGetQuery(pool, sprintf(
            "SELECT s.*, m.* FROM summary s INNER JOIN metadata m ON s.sample = m.sample%s", where_clause))
        app_data$filtered_df <- df[, !duplicated(names(df))]
        showNotification(sprintf("filtered_df saved in memory (%d rows).", nrow(app_data$filtered_df)), type = "message")
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
        showNotification(sprintf("Saved to %s", outfile), type = "message")
    })

    ## ---- Output directory ----

    observeEvent(input$save_outdir, {
        req(input$outdir)
        outdir_confirmed(input$outdir)
        showNotification(sprintf("Output directory set to: %s", input$outdir), type = "message")
    })

    output$outdir_display <- renderText({
        sprintf("Current output directory: %s", outdir_confirmed())
    })
}

### Run the application
ip <- system("hostname -I", intern = TRUE)
message(paste("Shiny app running at: http://", trimws(ip), ":3838", sep=""))
shinyApp(ui = ui, server = server, options = list(host = "0.0.0.0", port = 3838))