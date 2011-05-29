LAMBCMD=lambcmd

all: index.html

index.html: pgoctut.lambtex
	$(LAMBCMD) -f lambtex -t xhtml -i $< -o $@

clean:
	rm -rf index.html

