PACKAGE = ca.vtrlx.Telepipe
VERSION = 1.2

APPID = $(PACKAGE)
ifdef DEVEL
CFLAGS += -DDEVEL
APPID = $(PACKAGE).Devel
endif

ifdef FLATPAK
CFLAGS += -DFLATPAK
endif

PREFIX ?= /usr/local

CSRCS = $(wildcard *.c)
LSRCS = $(wildcard *.lua)
RESXML = data/telepipe.gresource.xml
RES = $(patsubst %.xml, %, $(RESXML))
POTFILE = po/MESSAGES.pot
POFILES = $(wildcard po/*.po)
MOFILES = \
	$(patsubst po/%.po, \
	locale/%/LC_MESSAGES/messages.mo, \
	$(POFILES))

BIN = telepipe
BYTECODE = $(patsubst %.lua, %.bytecode, $(LSRCS))
LIBS = -llua -ldl -lm
CFLAGS += $(LIBS) -Wl,-E -DPACKAGE="$(APPID)" -DVERSION=$(VERSION) -DPREFIX=$(PREFIX)

DESKTOP_FILE = $(APPID).desktop
ICON = $(APPID).svg
SYMBOLIC = $(APPID)-symbolic.svg
ifndef DEVEL
METAINFO = $(PACKAGE).metainfo.xml
endif

all: $(BIN)

$(BIN): $(CSRCS) $(BYTECODE)
	cc -o $@ $(CSRCS) -L$(PREFIX)/lib $(CFLAGS)

%.gresource: %.gresource.xml
	glib-compile-resources --target=$@ --sourcedir=data $^

%.bytecode: %.lua
	luac -o $@ -- $<

locale/%/LC_MESSAGES/messages.mo: po/%.po
	@mkdir -p `dirname $@`
	msgfmt $< -o $@

po/%.po: $(POTFILE)
	[ -f $@ ] || msginit -i $< -o $@ -l $(patsubst po/%.po,%,$@)
	msgmerge -U $@ $<

po/MESSAGES.pot: $(LSRCS) $(CSRCS)
	xgettext --from-code utf-8 -o $@ $^

.PHONY: clean install

clean:
	rm -f $(BIN) $(BYTECODE)

install: $(BIN) $(RES) $(MOFILES)
	install -D -m 0755 -t $(PREFIX)/bin $<
	cp -r locale $(PREFIX)/share
	install -D -m 0644 -t $(PREFIX)/data $(RES)
	install -D -m 0644 -t $(PREFIX)/share/applications $(DESKTOP_FILE)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/scalable/apps icons/$(ICON)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/symbolic/apps icons/$(SYMBOLIC)
	if [ -n "$(METAINFO)" ]; then install -D -m 0644 -t $(PREFIX)/share/metainfo $(METAINFO); fi
