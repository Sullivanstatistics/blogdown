#' Build a website
#'
#' Compile all Rmd files, build the site through Hugo, and post-process HTML
#' files generated from Rmd if necessary (e.g. fix figure paths).
#'
#' You can use \code{\link{serve_site}()} to preview your website locally, and
#' \code{build_site()} to build the site for publishing.
#'
#' For the \code{method} argument: \code{method = "html"} means to render all
#' Rmd files to HTML via \code{rmarkdown::\link[rmarkdown]{render}()} (which
#' means Markdown is processed through Pandoc), copy all external dependencies
#' generated from R code chunks, including images and HTML dependencies, to the
#' website output directory (e.g. \file{public/}), and fix their paths in the
#' HTML output because the relative locations of the \file{.html} file and its
#' dependencies may have changed.
#'
#' \code{method = "html_raw"} is similar to \code{method = "html"}, and the
#' major differences are: (1) the HTML files under the \file{public} directory
#' are not post-processed to fix image or dependency paths (so it is faster to
#' build a site); (2) the \code{"html"} method moves all output files from the
#' \file{content} directory to the \file{blogdown} directory to keep the
#' \file{content} directory clean, so you won't see files or directories like
#' \code{foo.html}, \code{foo_files/}, or \code{foo_cache/}, whereas the
#' \code{"html_raw"} method does not move any \code{*.html} files (only
#' \code{*_files/} and \code{*_cache/} directories are moved). HTML widgets may
#' not work well when \code{method = 'html_raw'}.
#'
#' For all rendering methods, a custom R script \file{R/build.R} will be
#' executed if you have provided it under the root directory of the website
#' (e.g. you can compile Rmd to Markdown through
#' \code{knitr::\link[knitr]{knit}()} and build the side via
#' \code{\link{hugo_cmd}()}). \code{method = "custom"} means it is entirely up
#' to this R script how a website is rendered. The script is executed via
#' command line \command{Rscript "R/build.R"}, which means it is executed in a
#' separate R session. The value of the argument \code{local} is passed to the
#' command line (you can retrieve the command-line arguments via
#' \code{\link{commandArgs}(TRUE)}).
#' @param local Whether to build the website locally to be served via
#'   \code{\link{serve_site}()}.
#' @param method Different methods to build a website (each with pros and cons).
#'   See Details. The value of this argument will be obtained from the global
#'   option \code{getOption('blogdown.method')} when it is set.
#' @note For \code{method = "html"}, when \code{local = TRUE}, the site
#'   configurations \code{baseurl} will be set to \code{/} temporarily, and RSS
#'   feeds (typically the files named \code{index.xml} under the \file{public}
#'   directory) will not be post-processed to save time, which means if you have
#'   Rmd posts that contain R plots, these plots will not work in RSS feeds.
#'   Since \code{local = TRUE} is only for previewing a website locally, you may
#'   not care about RSS feeds. To build a website for production, you should
#'   always call \code{build_site(local = FALSE)}.
#' @export
build_site = function(local = FALSE, method = c('html', 'html_raw', 'custom')) {
  if (missing(method)) method = getOption('blogdown.method', method)
  method = match.arg(method)

  config = load_config()
  files = list.files('content', '[.][Rr]md$', recursive = TRUE, full.names = TRUE)
  # exclude Rmd that starts with _ (preserve these names for, e.g., child docs)
  files = files[grep('^_', basename(files), invert = TRUE)]
  # do not allow special characters in filenames so dependency names are more
  # predictable, e.g. foo_files/
  bookdown:::check_special_chars(files)

  if (getOption('knitr.use.cwd', FALSE)) knitr::opts_knit$set(root.dir = getwd())

  run_script('R/build.R', as.character(local))

  if (method != 'custom') {
    build_rmds(files, config, local, method == 'html_raw')
  }

  invisible()
}

build_rmds = function(files, config, local, raw = FALSE) {
  if (length(files) == 0) return(hugo_build(local, config))

  # copy by-products {/content/.../foo_(files|cache) dirs and foo.html} from
  # /blogdown/ or /static/ to /content/
  lib1 = by_products(files, c('_files', '_cache', if (!raw) '.html'))
  lib2 = gsub('^content', 'blogdown', lib1)  # /blogdown/.../foo_(files|cache)
  if (raw) {
    i = grep('_files$', lib2)
    lib2[i] = gsub('^blogdown', 'static', lib2[i])  # _files are copied to /static
  }
  # TODO: it may be faster to file.rename() than file.copy()
  for (i in seq_along(lib2)) if (dir_exists(lib2[i])) {
    file.copy(lib2[i], dirname(lib1[i]), recursive = TRUE)
  } else if (file.exists(lib2[i])) {
    file.rename(lib2[i], lib1[i])
  }

  for (f in files) in_dir(d <- dirname(f), {
    f = basename(f)
    html = with_ext(f, 'html')
    # do not recompile Rmd if html is newer when building for local preview
    if (local && file_test('-nt', html, f)) next
    render_page(f)
    x = readUTF8(html)
    x = encode_paths(x, by_products(f, '_files'), d, raw)
    writeUTF8(c(fetch_yaml2(f), '', x), html)
  })

  # copy (new) by-products from /content/ to /blogdown/ or /static to make the
  # source directory clean (e.g. only .Rmd stays there when method = 'html')
  for (i in seq_along(lib1)) if (dir_exists(lib1[i])) {
    dir_create(dirname(lib2[i]))
    file.copy(lib1[i], dirname(lib2[i]), recursive = TRUE)
  }

  hugo_build(local, config)
  if (!raw) {
    root = getwd()
    in_dir(publish_dir(config), process_pages(local, root))
    i = file_test('-f', lib1)
    lapply(unique(dirname(lib2[i])), dir_create)
    file.rename(lib1[i], lib2[i])  # use file.rename() to preserve mtime of .html
  }
  unlink(lib1, recursive = TRUE)
}

render_page = function(input) {
  args = c(pkg_file('scripts', 'render_page.R'), input)
  if (Rscript(shQuote(args)) != 0) stop("Failed to render '", input, "'")
}

# given the content of a .html file: (1) if method = 'html', encode the figure
# paths (to be restored later), and other dependencies will be moved to
# /public/rmarkdown-libs/; (2) if method = 'html_raw', replace content/*_files/
# with /*_files/ since these dirs have been moved to /static/
encode_paths = function(x, deps, parent, raw) {
  if (!dir_exists(deps)) return(x)
  # find the dependencies referenced in HTML, add a marker ##### to their paths
  r = paste0('(<img src|<script src|<link href)(=")(', deps, '/)')
  x = if (raw) {
    gsub(r, paste0('\\1\\2', gsub('^content', '', parent), '/\\3'), x)
  } else {
    gsub(r, paste0('\\1\\2#####', parent, '/\\3'), x)
  }
  x
}

decode_paths = function(x, dcur, env, root) {
  r = '(<img src|<script src|<link href)="#####([^"]+_files/[^"]+)"'
  m = gregexpr(r, x)
  regmatches(x, m) = lapply(regmatches(x, m), function(p) {
    if (length(p) == 0) return(p)
    path = gsub(r, '\\2', p)
    path = file.path(root, path)
    d0 = gsub('^(.+_files)/.+', '\\1', path)

    # process figure paths
    i = grepl('_files/figure-html/', path)
    d1 = gsub('^.+_files/figure-html/', 'figures/', path[i])
    d2 = dirname(file.path(dcur, d1))
    lapply(d2, dir_create)
    file.copy2(path[i], d2, overwrite = TRUE)
    env$files = c(env$files, path[i])
    path[i] = d1

    # process JS/CSS dependencies
    i = !i
    d3 = gsub('^(.+_files/[^/]+)/.+', '\\1', path[i])
    dir_create('rmarkdown-libs')
    file.copy2(d3, 'rmarkdown-libs/', recursive = TRUE, overwrite = TRUE)
    env$files = c(env$files, d3)
    up = paste(rep('../', length(gregexpr('/', dcur)[[1]])), collapse = '')
    path[i] = gsub('^.+_files/', paste0(up, 'rmarkdown-libs/'), path[i])

    env$dirs = c(env$dirs, unique(d0))

    paste0(gsub(r, '\\1="', p), path, '"')
  })
  x
}

decode_paths_xml = function(x, root) {
  r1 = '(&lt;img src=&#34;)#####.+?_files/figure-html/'
  if (length(grep(r1, x)) == 0) return(x)
  m = gregexpr(r1, x)
  z = regmatches(x, m)
  r2 = '^\\s*<link>(.+)</link>\\s*$'
  l = NULL
  for (i in seq_along(x)) {
    if (grepl(r2, x[i])) l = gsub(r2, '\\1', x[i])
    if (is.null(l) || length(z[[i]]) == 0) next
    z[[i]] = paste0(gsub(r1, '\\1', z[[i]]), l, 'figures/')
  }
  regmatches(x, m) = z
  x
}

process_pages = function(local = FALSE, root) {
  files = list.files(
    '.', if (local) '[.]html$' else '[.](ht|x)ml$', recursive = TRUE,
    full.names = TRUE
  )
  # collect a list of dependencies to be cleaned up (e.g. figure/foo.png, libs/jquery.js)
  clean = new.env(parent = emptyenv())
  clean$files = clean$dirs = NULL
  for (f in files) process_page(f, clean, local, root)
  unlink(unique(clean$files), recursive = TRUE)
  lapply(unique(clean$dirs), bookdown:::clean_empty_dir)
}

process_page = function(f, env, local = FALSE, root) {
  x = readUTF8(f)
  if (!local && grepl('[.]xml$', f)) {
    x = decode_paths_xml(x, root)
    return(writeUTF8(x, f))
  }
  i1 = grep('<!-- BLOGDOWN-BODY-BEFORE -->', x)
  if (length(i1) == 0) return()
  i2 = grep('<!-- /BLOGDOWN-BODY-BEFORE -->', x)
  i3 = grep('<!-- BLOGDOWN-HEAD -->', x)
  i4 = grep('<!-- /BLOGDOWN-HEAD -->', x)
  i5 = (i3 + 1):(i4 - 1)
  h = paste(x[i5], collapse = '\n')
  x = x[-c(i1, i2, i3, i4, i5)]
  # if you have provided a token in your Hugo template, I'll use it, otherwise I
  # will insert the head code introduced by HTML dependencies before </head>
  i6 = grep('<!-- RMARKDOWN-HEADER -->', x)
  if (length(i6) == 1) x[i6] = h else {
    i6 = grep('</head>', x)[1]
    x[i6] = paste0(h, '\n', x[i6])
  }
  x = decode_paths(x, dirname(f), env, root)
  writeUTF8(x, f)
}
