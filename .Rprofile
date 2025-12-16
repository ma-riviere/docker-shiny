if (Sys.getenv("RENV_PROFILE") == "") {
    Sys.setenv(RENV_PROFILE = paste0("dev-", paste0(version$major, ".", sub("\\..*", "", version$minor))))
}
source("r-utils/init.R")
source("renv/activate.R")
