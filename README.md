# General Description

General library functions. The typical usage is to create a submodule in your
repo for this so you can carry it around and refer to it. There are a few ways to
do this:

1. In a centralized one big mono repo system where your repo will mainly be
   used as a submodule in the large source repo, link this repo into a central
   place that is high up in the tree such as ./src/lib and then all modules can
   use relative links. This works best if you are going to maintain the src
   directory and the working repo is always in the same relative place so that
   you can do references like `source ../../lib/include.mk` for Makefile
   includes as an example.
2. If you have a repo which is going to be forked independently alot, you can
   create a submodule that carries the library with `git submodule add` this
   is very clean, but has the overhead that in a big project, you can have lots
   of ./lib submodules which is messy so the relative link works well.
3. The last one which works if the repo is mainly used in a mono repo there are
   many references is to create a symbolic link and you have many references in
   many files so it is useful to just have a local relative link.

## Creating from template

If you are creating a new directory, then you can just:

1. Copy the Makefile.base to your brand new repo.
1. Adjust the .INCLUDE_DIR path to include the location of this .lib
1. The run `make install-repo` to get all the default files in place
1. The ones that you should think about are the envrc.base into your .envrc you
   do not usually want this except at the top level of your project. So if you
   have a ./ws/git/src, then you put it there, but don't put it below because lower
   .envrc mask the upper ones. You just want one place to put all your
   configuration. Particularly if you have keys that are read from 1Password

## Getting to the full documentation

This has moved to a Mkdocs formatted website at
[lib](https://lib/docs.tongfamily.com) which is actually hosted thanks to
[Netlify](https://netlify.com).

You can also browse the documents by looking through
[docs](docs)

You can also get these documentation yourself by cloning this repo and running:

```sh
# start and the
make mkdocs
open http://locahost:800w
# when you are documentation
make mkdocs-stop
```

## Status

[![Netlify Status](https://api.netlify.com/api/v1/badges/35c1b75c-3ebb-448d-ba0f-318e70fe16c8/deploy-status)](https://app.netlify.com/sites/guileless-donut-fb8630/deploys)
