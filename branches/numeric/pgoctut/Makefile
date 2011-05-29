#
# Makefile for PG'OCaml tutorial
# Dario Teixeira - August 2007.
# (dario.teixeira@yahoo.com)
#

NAME=pgoctut
all: $(NAME).pdf

#
# Implict rule for producing PDF files.
#

%.pdf: %.tex Makefile
	pdflatex -shell-escape $<
	pdflatex -shell-escape $<
	pdflatex -shell-escape $<

#
# Cleanup rule.
#

.PHONY: clean
clean:
	rm -f $(NAME).asy $(NAME).aux $(NAME).log $(NAME).out $(NAME).toc $(NAME).bbl $(NAME).blg $(NAME)_*.eps $(NAME)_*.tex $(NAME)_*.pdf texput.log

