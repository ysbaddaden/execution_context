.POSIX:

CRYSTAL=crystal
CRFLAGS=--release

FIBER_QSORT_BINARIES=fiber_qsort fiber_qsort-mt fiber_qsort-ec fiber_qsort-ec-mt
HTTP_SERVER_BINARIES=http_server http_server-mt http_server-ec http_server-ec-mt

all: $(FIBER_QSORT_BINARIES) $(HTTP_SERVER_BINARIES)

%: %.cr ../src/*.cr ../src/**/*.cr
	$(CRYSTAL) build $(CRFLAGS) $< -o $@

%-mt: %.cr ../src/*.cr ../src/**/*.cr
	$(CRYSTAL) build -Dpreview_mt $(CRFLAGS) $< -o $@

%-ec: %.cr ../src/*.cr ../src/**/*.cr
	$(CRYSTAL) build -Dpreview_mt -Dec $(CRFLAGS) $< -o $@

%-ec-mt: %.cr ../src/*.cr ../src/**/*.cr
	$(CRYSTAL) build -Dpreview_mt -Dec -Dmt $(CRFLAGS) $< -o $@

clean: .phony
	rm -f $(FIBER_QSORT_BINARIES) $(HTTP_SERVER_BINARIES)

.phony:
