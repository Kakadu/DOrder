##########################################################################
#                                                                        #
#  Ocamlgraph: a generic graph library for OCaml                         #
#  Copyright (C) 2004-2007                                               #
#  Sylvain Conchon, Jean-Christophe Filliatre and Julien Signoles        #
#                                                                        #
#  This software is free software; you can redistribute it and/or        #
#  modify it under the terms of the GNU Library General Public           #
#  License version 2, with the special exception on linking              #
#  described in file LICENSE.                                            #
#                                                                        #
#  This software is distributed in the hope that it will be useful,      #
#  but WITHOUT ANY WARRANTY; without even the implied warranty of        #
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.                  #
#                                                                        #
##########################################################################

# Where to install the binaries
prefix=/usr/local
exec_prefix=${prefix}
BINDIR=${exec_prefix}/bin

# Where to install the man page
MANDIR=${prefix}/share/man

# Other variables set by ./configure
OCAMLC   = ocamlc.opt
OCAMLOPT = ocamlopt.opt
OCAMLDEP = ocamldep
OCAMLDOC = ocamldoc.opt
OCAMLLEX = ocamllex.opt
OCAMLYACC= ocamlyacc
OCAMLLIB = /home/kakadu/.opam/4.05.0+flambda/lib/ocaml
OCAMLBEST= opt
OCAMLVERSION = 4.05.0
OCAMLWEB = true
OCAMLWIN32 = no
OCAMLFIND = ocamlfind
EXE = 
LIBEXT = .a
OBJEXT = .o

# Others global variables
SRCDIR	= src
LIBDIR	= lib

INCLUDES= -I $(SRCDIR) -I $(LIBDIR) 
BFLAGS = $(INCLUDES)
OFLAGS = $(INCLUDES) -for-pack Graph

# main target
#############

NAME=ocamlgraph

all: byte $(OCAMLBEST)
#all: byte $(OCAMLBEST) editor-no

# bytecode and native-code compilation
######################################

LIB= unionfind heap bitv
LIB:=$(patsubst %, $(LIBDIR)/%.cmo, $(LIB))

CMO = util blocks persistent imperative \
	delaunay builder classic rand oper \
	gpath traverse gcoloring topological components kruskal flow \
        graphviz gml dot_parser dot_lexer dot pack \
	gmap minsep cliquetree mcs_m md strat
CMO := $(LIB) $(patsubst %, $(SRCDIR)/%.cmo, $(CMO))

CMX = $(CMO:.cmo=.cmx)
CMA = graph.cma
CMXA = graph.cmxa

CMI = sig dot_ast sig_pack
CMI := $(patsubst %, src/%.cmi, $(CMI))

GENERATED = META \
	src/gml.ml src/version.ml \
	src/dot_parser.ml src/dot_parser.mli src/dot_lexer.ml

byte: $(CMA)
opt: $(CMXA)

graph.cma: graph.cmo
	$(OCAMLC) $(INCLUDES) -a -o $@ $^

graph.cmxa: graph.cmx
	$(OCAMLOPT) $(INCLUDES) -a -o $@ $^

graph.cmo: $(CMI) $(CMO)
	$(OCAMLC) $(INCLUDES) -pack -o $@ $^

graph.cmx: $(CMI) $(CMX)
	$(OCAMLOPT) $(INCLUDES) -pack -o $@ $^

EXAMPLESBIN=bin/demo.$(OCAMLBEST) bin/demo_planar.$(OCAMLBEST) \
  bin/bench.$(OCAMLBEST) bin/color.$(OCAMLBEST) bin/sudoku.$(OCAMLBEST) \
  bin/test.$(OCAMLBEST) 

.PHONY: examples
examples: $(EXAMPLESBIN)

.PHONY: demo
demo: bin/demo.$(OCAMLBEST)

bin/demo.byte: $(CMA) examples/demo.cmo
	$(OCAMLC) -o $@ $^

bin/demo.opt: $(CMXA) examples/demo.cmx
	$(OCAMLOPT) -o $@ $^

bin/demo_planar.byte: $(CMA) examples/demo_planar.cmo
	$(OCAMLC) -o $@ graphics.cma unix.cma $^

bin/demo_planar.opt: $(CMXA) examples/demo_planar.cmx
	$(OCAMLOPT) -o $@ graphics.cmxa unix.cmxa $^

bin/color.byte: $(CMA) examples/color.cmo
	$(OCAMLC) -o $@ graphics.cma unix.cma $^

bin/color.opt: $(CMXA) examples/color.cmx
	$(OCAMLOPT) -o $@ graphics.cmxa unix.cmxa $^

bin/sudoku.byte: $(CMA) examples/sudoku.cmo
	$(OCAMLC) -o $@ graphics.cma unix.cma $^

bin/sudoku.opt: $(CMXA) examples/sudoku.cmx
	$(OCAMLOPT) -o $@ graphics.cmxa unix.cmxa $^

test: $(CMA) tests/test.ml
	ocaml unix.cma graphics.cma $^

bin/test.byte: $(CMA) tests/test.cmo
	$(OCAMLC) -g -unsafe -o $@ unix.cma graphics.cma $^

bin/test.opt: $(CMXA) tests/test.cmx
	$(OCAMLOPT) -unsafe -inline 100 -o $@ unix.cmxa graphics.cmxa $^

bench: bin/bench.$(OCAMLBEST)
	bin/bench.opt

bin/bench.opt: $(CMXA) tests/bench.ml
	$(OCAMLOPT) -unsafe -inline 100 -o $@ unix.cmxa $^

check: $(CMA) tests/check.ml
	ocaml $^

# gtk2 graph editor

ED_DIR=editor

editor-no:
editor-yes: $(ED_DIR)/editor.$(OCAMLBEST)

editor: $(ED_DIR)/editor.byte editor-yes

ED_CMO = ed_hyper ed_graph ed_draw ed_display ed_main
ED_CMO:= $(patsubst %, $(ED_DIR)/%.cmo, $(ED_CMO))
ED_CMX = $(ED_CMO:.cmo=.cmx)

ED_INCLUDES =  -I +threads -I $(ED_DIR)

$(ED_CMO): BFLAGS+= $(ED_INCLUDES)
$(ED_CMX): OFLAGS+= $(ED_INCLUDES)

$(ED_DIR)/editor.byte: $(CMA) $(ED_CMO)
	$(OCAMLC) -g -o $@  \
		lablgtk.cma lablgnomecanvas.cma unix.cma $^

$(ED_DIR)/editor.opt: $(CMXA) $(ED_CMX)
	$(OCAMLOPT) -o $@  \
		lablgtk.cmxa lablgnomecanvas.cmxa unix.cmxa $^

VERSION=0.99b

src/version.ml: Makefile
	echo "let version = \""$(VERSION)"\"" > $@
	echo "let date = \""`date`"\"" >> $@

META: META.in Makefile
	sed -e s/VERSION/$(VERSION)/ -e s/CMA/$(CMA)/ -e s/CMXA/$(CMXA)/ \
		$@.in > $@

# Additional rules
##################

EXAMPLES = demo color demo_planar sudoku
EXAMPLES:= $(patsubst %, examples/%.ml, $(EXAMPLES))

TESTS = test check
TESTS := $(patsubst %, tests/%.ml, $(TESTS))

DPD_GRAPH_ML= $(TESTS) $(EXAMPLES)

$(DPD_GRAPH_ML:.ml=.cmo): $(CMA)
$(DPD_GRAPH_ML:.ml=.cmx): $(CMXA)

# installation
##############

install: install-$(OCAMLBEST) install-byte

install-byte: 
	cp -f graph.cmo graph.cmi $(CMA) "$(OCAMLLIB)"

install-opt: install-byte
	cp -f graph$(LIBEXT) graph.cmx $(CMXA) "$(OCAMLLIB)"

install-findlib: META
ifdef OCAMLFIND
	$(OCAMLFIND) install ocamlgraph META *.mli \
		graph$(LIBEXT) graph.cmx graph.cmo graph.cmi $(CMA) $(CMXA)
endif

# documentation
###############

DOCFILES=$(NAME).ps $(NAME).html

NODOC	= util blocks dot_parser dot_lexer
NODOC	:= $(patsubst %, $(SRCDIR)/%.cmo, $(NODOC))
DOC_CMO	= $(filter-out $(NODOC) $(LIB), $(CMO))
DOC_SRC	= $(CMI:.cmi=.mli) $(DOC_CMO:.cmo=.mli) $(DOC_CMO:.cmo=.ml)

.PHONY: doc
doc: $(DOC_CMO)
	mkdir -p doc
	rm -f doc/*
	$(OCAMLDOC) -d doc -html $(INCLUDES) $(DOC_SRC)

# literate programming
$(NAME).tex: $(DOC_SRC)
	$(OCAMLWEB) -o $@ $^

wc:
	ocamlwc -p $(SRCDIRC)/*.mli $(SRCDIRC)/*.ml

# file headers
##############
headers:
	headache -c misc/headache_config.txt -h misc/header.txt \
		Makefile.in configure.in README \
		$(LIBDIR)*.ml $(LIBDIR)*.ml[ily] \
		$(SRCDIR)*.ml $(SRCDIR)*.ml[ily] \
		$(ED_DIR)/*.ml $(ED_DIR)/*.mli \

# export
########

EXPORTDIR=$(NAME)-$(VERSION)
TAR=$(EXPORTDIR).tar

FTP = $$HOME/ftp/$(NAME)
WWW = $$HOME/WWW/$(NAME)

FILES = src/*.ml* lib/*.ml* Makefile.in configure configure.in META.in  \
	.depend editor/ed_*.ml* editor/Makefile \
        editor/tests/*.dot editor/tests/*.gml \
	examples/*.ml tests/*.ml \
	.depend README FAQ CREDITS INSTALL COPYING LICENSE CHANGES

export: source export-doc export-web export-delaunay

source: 
	mkdir -p export
	cd export; rm -rf $(EXPORTDIR)
	mkdir -p export/$(EXPORTDIR)/bin
	cp --parents $(FILES) export/$(EXPORTDIR)
	cd export ; tar cf $(TAR) $(EXPORTDIR) ; gzip -f --best $(TAR)
	cp export/$(TAR).gz $(FTP)
	cp README FAQ CREDITS COPYING LICENSE CHANGES $(EXAMPLES) $(FTP)

www/version.prehtml: Makefile.in
	echo "<#def version>$(VERSION)</#def>" > www/version.prehtml

export-web: www/version.prehtml
	make -C www install

export-doc: $(DOC_CMO)
	rm -f $(WWW)/doc/*
	-$(OCAMLDOC) -d $(WWW)/doc -html $(INCLUDES) $(DOC_SRC)

MISCFTP = $(HOME)/WWW/ftp/ocaml/misc
DELAUNAY=delaunay.ml delaunay.mli
export-delaunay:
	cd src; cp -f $(DELAUNAY) $(MISCFTP)
	cd src; caml2html -d $(MISCFTP) $(DELAUNAY)

# generic rules
###############

.SUFFIXES: .mli .ml .cmi .cmo .cmx .mll .mly .tex .dvi .ps .html

.mli.cmi:
	$(OCAMLC) -c $(BFLAGS) $<

.ml.cmo:
	$(OCAMLC) -c $(BFLAGS) $<

.ml.o:
	$(OCAMLOPT) -c $(OFLAGS) $<

.ml.cmx:
	$(OCAMLOPT) -c $(OFLAGS) $<

.mll.ml:
	$(OCAMLLEX) $<

.mly.ml:
	$(OCAMLYACC) -v $<

.mly.mli:
	$(OCAMLYACC) -v $<

.tex.dvi:
	latex $< && latex $<

.dvi.ps:
	dvips $< -o $@ 

.tex.html:
	hevea $<

# Emacs tags
############

otags:
	otags -r src editor

tags:
	find . -name "*.ml*" | sort -r | xargs \
	etags "--regex=/let[ \t]+\([^ \t]+\)/\1/" \
	      "--regex=/let[ \t]+rec[ \t]+\([^ \t]+\)/\1/" \
	      "--regex=/and[ \t]+\([^ \t]+\)/\1/" \
	      "--regex=/type[ \t]+\([^ \t]+\)/\1/" \
              "--regex=/exception[ \t]+\([^ \t]+\)/\1/" \
	      "--regex=/val[ \t]+\([^ \t]+\)/\1/" \
	      "--regex=/module[ \t]+\([^ \t]+\)/\1/"

# Makefile is rebuilt whenever Makefile.in or configure.in is modified
######################################################################

Makefile: Makefile.in config.status
	if test -e $@; then chmod a+w $@; fi		
	./config.status
	chmod a-w $@

config.status: configure
	./config.status --recheck

configure: configure.in
	autoconf 

# clean
#######

clean:
	rm -f *~
	for d in $(SRCDIR) $(LIBDIR) $(ED_DIR) tests examples; do \
	  rm -f $$d/*.cm[iox] $$d/*$(OBJEXT) $$d/*~; \
	done
	rm -f $(GENERATED) $(SRCDIR)/dot_parser.output
	rm -f graph.*a graph$(LIBEXT) bin/$(NAME).byte bin/$(NAME).opt
	rm -f *.haux *.aux *.log $(NAME).tex $(NAME).dvi $(DOCFILES)
	rm -f $(EXAMPLESBIN)

dist-clean distclean:: clean
	rm -f Makefile config.cache config.log config.status *.byte *.opt

svnclean svn-clean:: dist-clean
	rm -f config.* configure configure.lineno

# depend
########

.PHONY: depend
.depend depend: $(GENERATED)
	rm -f .depend
	$(OCAMLDEP) $(INCLUDES) \
		$(LIBDIR)/*.ml $(LIBDIR)/*.mli \
		$(SRCDIR)/*.ml $(SRCDIR)/*.mli \
		$(ED_DIR)/*.mli $(ED_DIR)/*.ml > .depend

include .depend
