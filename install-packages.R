# Helpers
read_packages <- function(profile) {
    packages_file <- paste0("packages-", profile, ".txt")
    packages <- readLines(packages_file)
    packages <- trimws(packages)
    packages <- packages[packages != ""]
    return(packages)
}

get_pkg_name <- function(remotes_string) {
    res <- renv:::renv_remotes_parse(remotes_string)
    return(res$package %||% res$repo)
}

# Create base profile
cat("Installing base profile packages...\n")
renv::activate(profile = "base")

base_packages <- read_packages("base")

renv::install(base_packages, prompt = FALSE)
renv::snapshot(packages = sapply(base_packages, get_pkg_name), prompt = FALSE, force = TRUE)

# Create tests profile
cat("\nInstalling tests profile packages...\n")
renv::activate(profile = "tests")

tests_packages <- read_packages("tests")

renv::install(tests_packages, prompt = FALSE)
renv::snapshot(packages = sapply(tests_packages, get_pkg_name), prompt = FALSE, force = TRUE)

# Reset to default
renv::activate(profile = "default")
