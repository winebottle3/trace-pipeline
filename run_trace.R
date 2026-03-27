# High-throughput TRACE pipeline for trace v.1.0.0 ( latest  version as of Jan 2026)
#
# Purpose:
#   - Batch-process multiple .fsa files
#   - Perform ladder fitting, peak calling, allele calling
#   - Apply QC rules and classify samples as PASS / FAIL
#   - Generate plots, metrics, and summary tables
#
# Outputs:
#   - TRACE_outputs.xlsx (QC, fragment summary, metrics)
#   - PASS_samples.csv / FAIL_samples.csv
#   - Diagnostic PDFs (ladders + traces)
#
# Disclaimer:the trace package is found at: https://github.com/zachariahmclean/trace
# This code is meant to run on V 1.0 so please update your V if necessary
# Check installed version : packageVersion("trace")
# Install helper package (only needed once) : install.packages("remotes")
# Install TRACE from GitHub : remotes::install_github("zachariahmclean/trace")
# Be careful not to use the R debugging package "trace" 
# #Author: Ana Lucanu ( PhD Candidate, UBB)
# Date: Ian/Feb.2026

#####Load packages####
suppressPackageStartupMessages({
  library(trace)                                                                # Core fragment analysis, ladder fitting, plotting
  library(writexl)                                                              # Write Excel output files
  library(yaml)                                                                 # Read/write TRACE configuration YAML
})

# ----------------------------- USER SETTINGS -----------------------------
# EDITABLE
# Central configuration object controlling input paths,
# TRACE processing parameters and QC thresholds

cfg <- list(
  # Directory containing .fsa files and optional metadata
  working_dir = "your_path/to/the/data",  # change me!!!!!!!!!!
  #Files discovery
  fsa_regex = "\\.fsa$",                                                        # Finds all the .fsa files
  fsa_ignore_case = TRUE,                                                       # Finds files regardless of upper/lower case
  
  # ---- Ladder / sizing assumptions (edit to match your standard) ----

  ladder_channel = "DATA.4",                                                    # Channel containing ladder dye
  ladder_sizes = c(250, 300, 350, 400, 450, 475, 500, 550, 600, 650, 700,
                   750, 800, 850, 900, 950, 1000),                              # Edit for more flexibility 
  ladder_start_scan = 4000,                                                     # Scan number where ladder search starts
  ladder_min_signal = 90,                                                       # Minimum ladder peak signal
  ladder_warning_rsq_threshold = 0.998,                                         # TRACE warning threshold
  
  # ---- Fragment calling parameters  ----
  min_bp_size = 300,                                                            # Minimum fragment size (bp)
  smoothing_window = 21,                                                        # Signal smoothing window
  minimum_peak_signal = 20,                                                     # Minimum signal to call a peak
  max_bp_size = 1100,                                                           # Maximum fragment size (bp)
  
  # ---- Allele + repeat -                                                      
  number_of_alleles = 1,                                                        # Expected nr of true alleles
  peak_region_size_gap_threshold = 6,                                           # Minimum bp gap between peak regions
  peak_region_signal_threshold_multiplier = 2,                                  # Signal strength needed to define a real region
  assay_size_without_repeat = 104,                                              # Fixed assay length (bp)
  repeat_size = 3,                                                              # Size of one repeat unit (bp)
  correction = "none",                                                          # Whether sizing correcions are applied
  
  # ---- Index + metrics ----
  grouped = FALSE,
  metrics_peak_threshold = 0.2,                                                 # Fraction of max peak signal
  metrics_window_around_index_peak = c(-40, 40),
  
  # ---- QC thresholds ----
  qc_ladder_rsq_min = 0.995,                                                    # Minimum acceptable ladder R2
  qc_modal_signal_min = 200,                                                    # Minimum allele/peak signal
  qc_min_peaks_called = 3,                                                      # Minimum number of detected peaks
  
  # Optional files in working_dir
  metadata_csv = "metadata.csv",                                                # set NULL to disable
  index_override_csv = NULL,                                                    # Optional per-sample index override
  ladder_df_list_rds = NULL,                                                    # Optional fixed ladder definitions
  show_progress_bar = FALSE
)

# ----------------------------- HELPERS -----------------------------
                                                                                 #create directory if it does not exist
safe_mkdir <- function(p) if (!dir.exists(p)) 
  dir.create(p, recursive = TRUE, showWarnings = FALSE)
now_stamp <- function() format(Sys.time(), "%Y%m%d_%H%M%S")                     # Timestamp for output folder naming

read_optional_csv <- function(filename) {
  if (is.null(filename) || is.na(filename) || filename == "") return(NULL)
  p <- file.path(cfg$working_dir, filename)
  if (!file.exists(p)) return(NULL)
  utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE)
}                                                                               

read_optional_rds <- function(filename) {
  if (is.null(filename) || is.na(filename) || filename == "") return(NULL)
  p <- file.path(cfg$working_dir, filename)
  if (!file.exists(p)) return(NULL)
  readRDS(p)
}
                                                                                # Append QC failure reason 
qc_reason_add <- function(reasons, new_reason) {
  if (is.null(new_reason) || is.na(new_reason) || new_reason == "") return(reasons)
  if (is.null(reasons) || is.na(reasons) || reasons == "") return(new_reason)
  paste(reasons, new_reason, sep = "; ")
}

to_num <- function(x) suppressWarnings(as.numeric(x))
                                                                                # Ectract first numeric column matching set of name patterns
get_first_numeric <- function(df, patterns) {
  if (is.null(df) || nrow(df) == 0) return(NA_real_)
  nm <- names(df)
  for (pat in patterns) {
    hit <- grep(pat, nm, ignore.case = TRUE, value = TRUE)
    if (length(hit) > 0) return(to_num(df[[hit[1]]][1]))
  }
  NA_real_
}

infer_ladder_rsq <- function(ladder_summary_df) {
  if (is.null(ladder_summary_df) || nrow(ladder_summary_df) < 1) return(NA_real_)
  row <- ladder_summary_df[1, , drop = FALSE]
  nm <- names(row)
  
  rsq_cols <- grep("rsq|r2|r_squared|r\\^2", nm, ignore.case = TRUE, value = TRUE)
  rsq_cols <- rsq_cols[vapply(rsq_cols, function(x) is.numeric(row[[x]]), logical(1))]
  if (length(rsq_cols) > 0) return(mean(as.numeric(row[rsq_cols]), na.rm = TRUE))
  
  num_cols <- nm[vapply(nm, function(x) is.numeric(row[[x]]), logical(1))]
  if (length(num_cols) == 0) return(NA_real_)
  mean(as.numeric(row[num_cols]), na.rm = TRUE)
}

count_peaks_for_sample <- function(peaks_df, sample_id) {
  if (is.null(peaks_df) || nrow(peaks_df) == 0) return(0L)
  if ("unique_id" %in% names(peaks_df)) return(sum(peaks_df$unique_id == sample_id, na.rm = TRUE))
  nrow(peaks_df)
}

# Recursively update YAML list only where keys exist (safe across schema changes)
yaml_set_if_exists <- function(x, key, value) {
  if (!is.list(x)) return(x)
  if (!is.null(names(x)) && key %in% names(x)) x[[key]] <- value
  for (nm in names(x)) {
    if (is.list(x[[nm]])) x[[nm]] <- yaml_set_if_exists(x[[nm]], key, value)
  }
  x
}
                                                                                # Write a run-specific TRACE config YAML 
write_trace_config <- function(out_dir) {
  default_cfg <- system.file("extdata/trace_config.yaml", package = "trace")
  if (default_cfg == "") stop("trace_config.yaml not found in trace package.", call. = FALSE)
  
  y <- yaml::read_yaml(default_cfg)
  
  overrides <- list(
    ladder_channel = cfg$ladder_channel,
    ladder_sizes = cfg$ladder_sizes,
    ladder_start_scan = cfg$ladder_start_scan,
    minimum_ladder_signal = cfg$ladder_min_signal,
    warning_rsq_threshold = cfg$ladder_warning_rsq_threshold,
    min_bp_size = cfg$min_bp_size,
    max_bp_size = cfg$max_bp_size,
    smoothing_window = cfg$smoothing_window,
    minimum_peak_signal = cfg$minimum_peak_signal,
    number_of_alleles = cfg$number_of_alleles,
    peak_region_size_gap_threshold = cfg$peak_region_size_gap_threshold,
    peak_region_signal_threshold_multiplier = cfg$peak_region_signal_threshold_multiplier,
    assay_size_without_repeat = cfg$assay_size_without_repeat,
    repeat_size = cfg$repeat_size,
    correction = cfg$correction,
    grouped = cfg$grouped,
    show_progress_bar = cfg$show_progress_bar
  )
  
  for (k in names(overrides)) y <- yaml_set_if_exists(y, k, overrides[[k]])
  
  out_path <- file.path(out_dir, "trace_config_used.yaml")
  yaml::write_yaml(y, out_path)
  out_path
}
                                                                                # Proccess a single sample
process_one_sample <- function(sample_id, fsa_obj, metadata_df, 
                               index_override_df, ladder_df_list, config_path) {
  out <- list(
    unique_id = sample_id,
    status = "FAIL",
    fail_stage = NA_character_,
    fail_reason = NA_character_,
    error = NA_character_,
    ladder_rsq = NA_real_,
    allele_repeat = NA_real_,
    allele_size = NA_real_,
    allele_signal = NA_real_,
    n_peaks = NA_integer_,
    fsa_list = NULL,
    fragments_list = NULL
  )
  
  fsa_list <- list()
  fsa_list[[sample_id]] <- fsa_obj$clone()
  out$fsa_list <- fsa_list
  
  fragments_list <- tryCatch(
    trace::trace(
      fragments_list = fsa_list,
      metadata_data.frame = metadata_df,
      index_override_dataframe = index_override_df,
      ladder_df_list = ladder_df_list,
      config_file = config_path
    ),
    error = function(e) e
  )
  
  if (inherits(fragments_list, "error")) {
    out$fail_stage <- "trace()"
    out$error <- conditionMessage(fragments_list)
    out$fail_reason <- qc_reason_add(out$fail_reason, "trace() failed (ladder/peaks/alleles)")
    return(out)
  }
  
  out$fragments_list <- fragments_list
  
  ladder_summary <- tryCatch(trace::extract_ladder_summary(fragments_list, sort = FALSE), error = function(e) NULL)
  out$ladder_rsq <- infer_ladder_rsq(ladder_summary)
  if (is.na(out$ladder_rsq) || out$ladder_rsq < cfg$qc_ladder_rsq_min) {
    out$fail_reason <- qc_reason_add(out$fail_reason, paste0("Low ladder fit (rsq~", round(out$ladder_rsq, 4), ")"))
  }
  
  alleles_df <- tryCatch(trace::extract_alleles(fragments_list), error = function(e) NULL)
  out$allele_repeat <- get_first_numeric(alleles_df, c("allele_1_repeat", "allele_repeat", "repeat"))
  out$allele_size   <- get_first_numeric(alleles_df, c("allele_1_size", "allele_size", "size"))
  out$allele_signal <- get_first_numeric(alleles_df, c("allele_1_signal", "allele_signal", "signal", "modal_peak_signal"))
  
  if (is.na(out$allele_repeat)) out$fail_reason <- qc_reason_add(out$fail_reason, "No allele_repeat (failed allele call)")
  if (!is.na(out$allele_signal) && out$allele_signal < cfg$qc_modal_signal_min) {
    out$fail_reason <- qc_reason_add(out$fail_reason, paste0("Low modal signal (", round(out$allele_signal, 1), ")"))
  }
  
  peaks_df <- tryCatch(trace::extract_fragments(fragments_list), error = function(e) NULL)
  out$n_peaks <- count_peaks_for_sample(peaks_df, sample_id)
  if (is.na(out$n_peaks) || out$n_peaks < cfg$qc_min_peaks_called) {
    out$fail_reason <- qc_reason_add(out$fail_reason, paste0("Too few peaks (", out$n_peaks, ")"))
  }
  
  if (is.na(out$fail_reason) || out$fail_reason == "") out$status <- "PASS"
  out
}

# ----------------------------- MAIN -----------------------------

setwd(cfg$working_dir)

fsa_files <- list.files(
  path = cfg$working_dir,
  pattern = cfg$fsa_regex,
  full.names = TRUE,
  ignore.case = cfg$fsa_ignore_case
)
if (length(fsa_files) == 0) stop("No .fsa files found in: ", cfg$working_dir, call. = FALSE)

out_dir <- file.path(cfg$working_dir, paste0("TRACE_outputs_", now_stamp()))
plots_dir <- file.path(out_dir, "plots")
safe_mkdir(out_dir)
safe_mkdir(plots_dir)

metadata_df <- read_optional_csv(cfg$metadata_csv)
index_override_df <- read_optional_csv(cfg$index_override_csv)
ladder_df_list <- read_optional_rds(cfg$ladder_df_list_rds)

# Read all once (fast), then process per sample (robust)
fsa_all <- trace::read_fsa(fsa_files)

# Ensure names are sane unique_ids
if (is.null(names(fsa_all)) || any(names(fsa_all) == "")) {
  names(fsa_all) <- tools::file_path_sans_ext(basename(fsa_files))
}

config_path <- write_trace_config(out_dir)

results <- lapply(names(fsa_all), function(id) {
  process_one_sample(
    sample_id = id,
    fsa_obj = fsa_all[[id]],
    metadata_df = metadata_df,
    index_override_df = index_override_df,
    ladder_df_list = ladder_df_list,
    config_path = config_path
  )
})

qc_df <- do.call(rbind, lapply(results, function(x) {
  data.frame(
    unique_id = x$unique_id,
    status = x$status,
    fail_stage = as.character(x$fail_stage),
    fail_reason = as.character(x$fail_reason),
    error = as.character(x$error),
    ladder_rsq = x$ladder_rsq,
    allele_repeat = x$allele_repeat,
    allele_size = x$allele_size,
    allele_signal = x$allele_signal,
    n_peaks = x$n_peaks,
    stringsAsFactors = FALSE
  )
}))

pass_ids <- qc_df$unique_id[qc_df$status == "PASS"]
fail_ids <- qc_df$unique_id[qc_df$status != "PASS"]

# Merge PASS fragments for plotting + metrics
fragments_pass <- list()
fragments_fail <- list()
fsa_pass <- list()
fsa_fail <- list()

for (r in results) {
  if (!is.null(r$fsa_list)) {
    if (identical(r$status, "PASS")) fsa_pass <- c(fsa_pass, r$fsa_list) else fsa_fail <- c(fsa_fail, r$fsa_list)
  }
  if (!is.null(r$fragments_list)) {
    if (identical(r$status, "PASS")) fragments_pass <- c(fragments_pass, r$fragments_list) else fragments_fail <- c(fragments_fail, r$fragments_list)
  }
}

# PDFs
if (length(fragments_pass) > 0) {
  grDevices::pdf(file.path(plots_dir, "all_ladders_PASS.pdf"), width = 8, height = 6)
  for (id in names(fragments_pass)) {
    trace::plot_ladders(fragments_pass[id])
  }
  grDevices::dev.off()
}

if (length(fragments_fail) > 0) {
  grDevices::pdf(file.path(plots_dir, "all_ladders_FAIL.pdf"), width = 8, height = 6)
  for (id in names(fragments_fail)) {
    trace::plot_ladders(fragments_fail[id])
  }
  grDevices::dev.off()
}

trace_xlim <- c(110, 150)
if (length(fragments_pass) > 0) {
  grDevices::pdf(file.path(plots_dir, "all_traces_PASS.pdf"), width = 8, height = 6)
  for (id in names(fragments_pass)) trace::plot_traces(fragments_pass[id], xlim = trace_xlim)
  grDevices::dev.off()
}
if (length(fragments_fail) > 0) {
  grDevices::pdf(file.path(plots_dir, "all_traces_FAIL.pdf"), width = 8, height = 6)
  for (id in names(fragments_fail)) trace::plot_traces(fragments_fail[id], xlim = trace_xlim)
  grDevices::dev.off()
}

# Metrics (PASS only)
metrics_df <- data.frame()
if (length(fragments_pass) > 0) {
  metrics_df <- trace::calculate_instability_metrics(
    fragments_list = fragments_pass,
    peak_threshold = cfg$metrics_peak_threshold,
    window_around_index_peak = cfg$metrics_window_around_index_peak
  )
}

# Fragment summary (PASS only)
fragment_summary_df <- data.frame()
if (length(fragments_pass) > 0) {
  alleles_df <- trace::extract_alleles(fragments_pass)
  peaks_df <- trace::extract_fragments(fragments_pass)
  ladder_df <- trace::extract_ladder_summary(fragments_pass, sort = FALSE)
  
  fragment_summary_df <- qc_df[qc_df$status == "PASS", ]
  if (!is.null(alleles_df) && nrow(alleles_df) > 0) fragment_summary_df <- merge(fragment_summary_df, alleles_df, by = "unique_id", all.x = TRUE)
  if (!is.null(ladder_df) && nrow(ladder_df) > 0) fragment_summary_df <- merge(fragment_summary_df, ladder_df, by = "unique_id", all.x = TRUE)
  
  # Optional peak means around top fraction
  if (!is.null(peaks_df) && nrow(peaks_df) > 0) {
    if (!("unique_id" %in% names(peaks_df))) peaks_df$unique_id <- rownames(peaks_df)
    if ("signal" %in% names(peaks_df)) peaks_df$signal <- to_num(peaks_df$signal)
    if ("size" %in% names(peaks_df)) peaks_df$size <- to_num(peaks_df$size)
    if ("calculated_repeats" %in% names(peaks_df)) peaks_df$calculated_repeats <- to_num(peaks_df$calculated_repeats)
    
    uniq <- unique(peaks_df$unique_id)
    mean_rows <- lapply(uniq, function(uid) {
      sub <- peaks_df[peaks_df$unique_id == uid, , drop = FALSE]
      max_sig <- suppressWarnings(max(sub$signal, na.rm = TRUE))
      thr <- max_sig * 0.2
      size_mean <- if ("size" %in% names(sub)) mean(sub$size[sub$signal >= thr], na.rm = TRUE) else NA_real_
      rpt_mean <- if ("calculated_repeats" %in% names(sub)) mean(sub$calculated_repeats[sub$signal >= thr], na.rm = TRUE) else NA_real_
      data.frame(unique_id = uid, allele_size_mean = size_mean, allele_repeat_mean = rpt_mean, stringsAsFactors = FALSE)
    })
    mean_df <- do.call(rbind, mean_rows)
    fragment_summary_df <- merge(fragment_summary_df, mean_df, by = "unique_id", all.x = TRUE)
  }
}

# Write outputs
writexl::write_xlsx(
  list(
    QC = qc_df,
    Fragment_Summary_PASS = fragment_summary_df,
    Instability_Metrics_PASS = metrics_df
  ),
  path = file.path(out_dir, "TRACE_outputs.xlsx")
)

utils::write.csv(qc_df[qc_df$status == "PASS", ], file.path(out_dir, "PASS_samples.csv"), row.names = FALSE)
utils::write.csv(qc_df[qc_df$status != "PASS", ], file.path(out_dir, "FAIL_samples.csv"), row.names = FALSE)

message("Done.")
message("trace version: ", as.character(packageVersion("trace")))
message("Config used: ", config_path)
message("Output folder: ", out_dir)
message("PASS: ", sum(qc_df$status == "PASS"), " | FAIL: ", sum(qc_df$status != "PASS"))
