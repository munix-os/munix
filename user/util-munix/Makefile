CC = gcc
CFLAGS = -O2
DESTDIR =

.PHONY: all
all: init

init: init.c
	$(CC) $(CFLAGS) -o init init.c

.PHONY: install
install: init
	mkdir -p $(DESTDIR)/usr/bin/
	install -p -s init $(DESTDIR)/usr/bin/
