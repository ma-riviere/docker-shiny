# Configure PPM repository for binary packages
options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/bookworm/latest"))

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

profiles <- list.files(pattern = "packages-.*.txt")
profiles <- sub("packages-", "", profiles)
profiles <- sub(".txt", "", profiles)

cat("Found", length(profiles), "profiles: ", paste(profiles, collapse = ", "), "\n")

# Create profiles
for (profile in profiles) {
    cat("\nInstalling profile: ", profile, "\n")
    renv::activate(profile = profile)

    packages <- read_packages(profile)

    renv::install(packages, prompt = FALSE)
    renv::snapshot(packages = sapply(packages, get_pkg_name), prompt = FALSE, force = TRUE)
}

# Reset to default
renv::activate(profile = "default")
