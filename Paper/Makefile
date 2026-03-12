MAIN = main

PUML_FILES = $(wildcard figures/*.puml)
PNG_FILES  = $(PUML_FILES:.puml=.png)

.PHONY: all pdf figures clean

# Default: build everything
all: figures pdf

# Build PDF only (figures must exist or be placeholders)
pdf: $(MAIN).tex references.bib
	pdflatex $(MAIN).tex
	bibtex $(MAIN)
	pdflatex $(MAIN).tex
	pdflatex $(MAIN).tex

# Render PlantUML diagrams (requires plantuml + java)
figures: $(PNG_FILES)

figures/%.png: figures/%.puml
	plantuml -tpng $<

clean:
	rm -f *.aux *.bbl *.blg *.log *.out *.toc *.run.xml *.bcf $(MAIN).pdf
